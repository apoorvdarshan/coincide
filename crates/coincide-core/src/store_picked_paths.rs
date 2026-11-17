//! Compact, transactional updates for user-selected local path references.
use super::*;

impl Store {
    fn update_picked_context(
        &mut self,
        id: &str,
        adding: bool,
        edit: impl FnOnce(&Value) -> Result<Option<(Value, Value)>>,
    ) -> Result<Option<Value>> {
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        // The transcript may be very large. SQLite extracts only the fields
        // needed for this edit instead of decoding its entire item array.
        let source: String = tx.query_row(
            "SELECT json_object('id',document -> '$.id','draft',document -> '$.draft',
             'draftContext',document -> '$.draftContext','rustDraftImages',document -> '$.rustDraftImages',
             'isArchived',document -> '$.isArchived','itemsType',json_type(document,'$.items'))
             FROM threads WHERE id=?1 COLLATE NOCASE", [id], |row| row.get(0))?;
        let source: Value = serde_json::from_str(&source)?;
        ensure!(
            Uuid::parse_str(text(&source, "id").as_str())? == Uuid::parse_str(id)?,
            "Conversation identity changed"
        );
        ensure!(source["itemsType"] == "array", "Invalid transcript");
        if adding {
            ensure!(
                source["isArchived"] != true,
                "Restore this conversation before attaching files"
            );
            let imported: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1 COLLATE NOCASE)",
                [id],
                |row| row.get(0),
            )?;
            ensure!(!imported, "Fork an imported thread before attaching files");
        }
        let Some((context, result)) = edit(&source["draftContext"])? else {
            return Ok(None);
        };
        crate::composer_context::validate(&context)?;
        let navigation = tx
            .query_row(
                "SELECT metadata FROM thread_navigation WHERE id=?1 COLLATE NOCASE",
                [id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
            .filter(Value::is_object)
            .map(|mut value| {
                value["has_draft"] = json!(
                    source["draft"]
                        .as_str()
                        .is_some_and(|draft| !draft.is_empty())
                        || source["rustDraftImages"]
                            .as_array()
                            .is_some_and(|images| !images.is_empty())
                        || crate::composer_context::has_context(&context)
                );
                value.to_string()
            });
        ensure!(tx.execute(
            "UPDATE threads SET document=json_set(document,'$.draftContext',json(?2)) WHERE id=?1 COLLATE NOCASE",
            params![id, context.to_string()],
        )? == 1, "Conversation is unavailable");
        if let Some(metadata) = navigation {
            tx.execute("INSERT INTO thread_navigation(id,metadata) VALUES (?1,?2) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata", params![id, metadata])?;
        }
        tx.commit()?;
        Ok(Some(result))
    }

    pub(crate) fn attach_picked_path(
        &mut self,
        id: &str,
        path: &crate::composer_context::PickedPath,
    ) -> Result<Value> {
        self.update_picked_context(id, true, |raw| {
            let (next, card) = crate::composer_context::append_picked_path(raw, path)?;
            Ok(Some((next, card)))
        })?
        .context("Attachment was not saved")
    }

    pub(crate) fn remove_cancelled_picked_path(&mut self, id: &str, card: &Value) -> Result<bool> {
        Ok(self
            .update_picked_context(id, false, |raw| {
                let Some(rows) = raw.as_array() else {
                    return Ok(None);
                };
                if rows.iter().filter(|row| *row == card).count() != 1 {
                    return Ok(None);
                }
                let card_id = card["id"].as_str().context("Attachment has no ID")?;
                Ok(Some((
                    crate::composer_context::remove(raw, card_id)?,
                    Value::Null,
                )))
            })?
            .is_some())
    }

    /// Remove a specific visible draft card without overwriting other changes.
    /// A changed or ambiguous identity is an error so a waiting send cannot
    /// accidentally include a reference the user meant to remove.
    pub(crate) fn remove_exact_context_card(&mut self, id: &str, card: &Value) -> Result<bool> {
        let card_id = Uuid::parse_str(card["id"].as_str().context("Attachment has no ID")?)?;
        Ok(self
            .update_picked_context(id, false, |raw| {
                let Some(rows) = raw.as_array() else {
                    return Ok(None);
                };
                let matches = rows
                    .iter()
                    .filter(|row| {
                        row["id"].as_str().and_then(|id| Uuid::parse_str(id).ok()) == Some(card_id)
                    })
                    .collect::<Vec<_>>();
                if matches.is_empty() {
                    return Ok(None);
                }
                ensure!(
                    matches.len() == 1 && matches[0] == card,
                    "Attached reference changed; reload before removing it"
                );
                Ok(Some((
                    crate::composer_context::remove(raw, &card_id.to_string())?,
                    Value::Null,
                )))
            })?
            .is_some())
    }
}
