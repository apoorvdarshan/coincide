//! One-field reply quote commit; original files and every other draft/history
//! field survive an exact raw-row compare in the same SQLite transaction.
use super::*;
impl Store {
    #[cfg(test)]
    pub(crate) fn native_reply_context_source(&self, id: &str) -> Result<String> {
        let raw:Option<String>=self.connection()?.query_row("SELECT CASE WHEN length(CAST(document AS BLOB))<=8388608 THEN document ELSE NULL END FROM threads WHERE id=?1",[id],|row|row.get(0))?;
        raw.context("Reply source conversation exceeds 8 MiB")
    }
    #[cfg(test)]
    pub(crate) fn commit_native_reply_context(
        &mut self,
        id: &str,
        source: &str,
        context: &Value,
    ) -> Result<()> {
        crate::composer_context::validate(context)?;
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let raw: String =
            tx.query_row("SELECT document FROM threads WHERE id=?1", [id], |row| {
                row.get(0)
            })?;
        ensure!(
            raw == source,
            "Conversation changed; select the reply text again"
        );
        ensure!(
            !tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1 COLLATE NOCASE)",
                [id],
                |row| row.get::<_, bool>(0)
            )?,
            "Imported history cannot receive reply context"
        );
        let mut thread: Value = serde_json::from_str(&raw)?;
        ensure!(
            validate_thread(&thread)? == id,
            "Conversation identity changed"
        );
        ensure_not_deleted(&tx, id)?;
        thread["draftContext"] = context.clone();
        ensure!(
            tx.execute(
                "UPDATE threads SET document=?2 WHERE id=?1 AND document=?3",
                params![id, thread.to_string(), raw]
            )? == 1,
            "Reply source changed during context commit"
        );
        cache_thread(&tx, &thread, false)?;
        tx.commit()?;
        Ok(())
    }

    /// Check the displayed source and edit only context in one transaction.
    /// Do not materialize the complete transcript in Rust; conversations can
    /// be much larger than the selected message.
    pub(crate) fn commit_selected_reply(
        &mut self,
        id: &str,
        expected_draft: Option<&str>,
        expected_context: &crate::composer_context::ExpectedContext,
        selection: &crate::reply_selection::NativeReplySelection,
    ) -> Result<Value> {
        let tx = self
            .connection_mut()?
            .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        ensure_not_deleted(&tx, id)?;
        ensure!(
            !tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM imported_threads WHERE id=?1 COLLATE NOCASE)",
                [id],
                |row| row.get::<_, bool>(0),
            )?,
            "Fork imported history before attaching reply text"
        );
        let raw: String = tx.query_row(
            "SELECT json_object('id',document -> '$.id','draft',document -> '$.draft',
             'draftContext',document -> '$.draftContext','contextType',json_type(document,'$.draftContext'),
             'rustDraftImages',document -> '$.rustDraftImages','isArchived',document -> '$.isArchived',
             'itemsType',json_type(document,'$.items')) FROM threads WHERE id=?1 COLLATE NOCASE",
            [id], |row| row.get(0),
        )?;
        let mut thread: Value = serde_json::from_str(&raw)?;
        ensure!(
            Uuid::parse_str(text(&thread, "id").as_str())? == Uuid::parse_str(id)?,
            "Conversation identity changed"
        );
        ensure!(
            thread["itemsType"] == "array" && thread["isArchived"] != true,
            "Conversation cannot receive reply text"
        );
        if thread["contextType"].is_null() {
            thread.as_object_mut().unwrap().remove("draftContext");
        }
        let appended_since_capture = thread["draftContext"].as_array().is_some_and(|rows| {
            if let Some(previous) = expected_context.value.as_array() {
                rows.len() > previous.len() && rows.starts_with(previous)
            } else {
                expected_context.value.is_null() && !rows.is_empty()
            }
        });
        ensure!(
            expected_context.matches(&thread)
                || (expected_draft.is_none() && appended_since_capture),
            "Attached context changed; select the text again"
        );
        if let Some(draft) = expected_draft {
            ensure!(
                draft.len() <= 1024 * 1024 && text(&thread, "draft") == draft,
                "Composer changed; select the text again"
            );
        }
        let mut statement = tx.prepare(
            "SELECT json_object('id',value -> '$.id','kind',value -> '$.kind',
                    'text',value -> '$.text','provider',value -> '$.provider')
             FROM threads, json_each(threads.document,'$.items')
             WHERE threads.id=?1 COLLATE NOCASE AND json_extract(value,'$.id')=?2 COLLATE NOCASE LIMIT 2"
        )?;
        let items = statement
            .query_map(params![id, selection.item.to_string()], |row| {
                row.get::<_, String>(0)
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        drop(statement);
        ensure!(items.len() == 1, "Selected message is missing or ambiguous");
        let item: Value = serde_json::from_str(&items[0])?;
        ensure!(
            item["kind"] == selection.source_kind
                && item["text"]
                    .as_str()
                    .is_some_and(|current| current.starts_with(&selection.source)),
            "The selected message changed; select its text again"
        );
        let mut card = selection.reference_preview(&item["provider"])?;
        card["sourceItemID"] = item["id"].clone();
        let next = crate::composer_context::append_quote_card(
            thread.get("draftContext").unwrap_or(&Value::Null),
            card,
        )?;
        ensure!(tx.execute("UPDATE threads SET document=json_set(document,'$.draftContext',json(?2)) WHERE id=?1 COLLATE NOCASE",
            params![id,next.to_string()])? == 1, "Conversation is unavailable");
        if let Some(mut navigation) = tx
            .query_row(
                "SELECT metadata FROM thread_navigation WHERE id=?1 COLLATE NOCASE",
                [id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?
            .flatten()
            .and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
            .filter(Value::is_object)
        {
            navigation["has_draft"] = json!(true);
            tx.execute(
                "UPDATE thread_navigation SET metadata=?2 WHERE id=?1 COLLATE NOCASE",
                params![id, navigation.to_string()],
            )?;
        }
        tx.commit()?;
        Ok(json!({"threadId":id,"draftContext":next}))
    }
}
