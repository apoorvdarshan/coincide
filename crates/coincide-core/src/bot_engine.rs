//! Native bot conversations use locally authorized instruction CONTENT.
//! Imported unknown metadata never becomes provider launch authorization.
use super::*;
use std::path::Path;

impl Engine {
    pub(super) fn create_bot_conversation(&mut self, params: &Value) -> Result<Value> {
        let result = crate::bot_runtime::create(&mut self.store, params)?;
        self.revision += 1;
        self.requested_open = result["threadId"].as_str().map(str::to_owned);
        self.new_composer = self.requested_open.clone();
        Ok(result)
    }

    /// A paired phone may create its own conversation, but must not make the
    /// Mac's UI navigate to it (that action is local-only).
    pub(crate) fn create_remote_bot_conversation(&mut self, params: &Value) -> Result<Value> {
        self.require_admissions()?;
        let result = crate::bot_runtime::create(&mut self.store, params)?;
        self.revision += 1;
        Ok(result)
    }

    /// Make a policy-only view after verifying the bot identity and local
    /// instruction authority. Never persist this view or accept one from a client.
    pub(super) fn bot_validation_view(&self, thread: &Value) -> Result<Value> {
        if thread["botID"].is_null() && thread["rustBotContext"].is_null() {
            return Ok(thread.clone());
        }
        let cwd = self.working_directory(thread)?;
        if thread["rustBotContext"].is_null() {
            crate::bot_runtime::existing_context(&self.store, thread, &cwd)?;
        } else {
            self.bot_instructions(thread, &cwd)?;
        }
        // Policy needs only these fields. Avoid cloning a long bot transcript
        // on every composer capability refresh.
        let fields = thread.as_object().context("Invalid bot conversation")?;
        Ok(Value::Object(
            ["id", "selection", "accessMode", "interactionMode"]
                .into_iter()
                .filter_map(|key| fields.get(key).map(|value| (key.to_owned(), value.clone())))
                .collect(),
        ))
    }

    /// A user-initiated send or selection can attach a snapshot to an older
    /// conversation. The atomic Store operation preserves its exact thread ID,
    /// transcript, draft, sessions and settings.
    pub(super) fn authorize_existing_bot(&mut self, thread: &mut Value) -> Result<()> {
        if !thread["botID"].is_null() && thread["rustBotContext"].is_null() {
            let cwd = self.working_directory(thread)?;
            let (source, context) =
                crate::bot_runtime::existing_context(&self.store, thread, &cwd)?;
            *thread = self.store.authorize_existing_bot_if_unchanged(
                source.as_ref(),
                thread,
                &context,
            )?;
            self.revision += 1;
        }
        Ok(())
    }

    /// Apply a saved personality or instruction edit at the next turn boundary.
    /// The old context is validated first, and the Store compares both the
    /// thread and bot document before granting authority to the replacement.
    pub(super) fn refresh_bot_instructions(&mut self, thread: &mut Value) -> Result<bool> {
        if thread["botID"].is_null() {
            return Ok(false);
        }
        if thread["rustBotContext"].is_null() {
            self.authorize_existing_bot(thread)?;
            return Ok(false);
        }
        let cwd = self.working_directory(thread)?;
        self.bot_instructions(thread, &cwd)?;
        let (source, context) = crate::bot_runtime::current_context(&self.store, thread, &cwd)?;
        if context["instructions"] == thread["rustBotContext"]["instructions"] {
            return Ok(false);
        }
        *thread =
            self.store
                .authorize_existing_bot_if_unchanged(source.as_ref(), thread, &context)?;
        self.revision += 1;
        Ok(true)
    }

    /// Validate on EVERY send, including resume/queue/schedule, before any
    /// transcript/draft mutation. A replacement snapshot is authorized at a
    /// turn boundary, never in the middle of an existing provider turn.
    pub(super) fn bot_instructions(&self, thread: &Value, cwd: &Path) -> Result<Option<String>> {
        let Some(context) = thread.get("rustBotContext") else {
            ensure!(
                thread["botID"].is_null(),
                "This bot conversation has no trusted instruction snapshot; create a new bot conversation"
            );
            return Ok(None);
        };
        ensure!(
            context.is_object() && context["version"] == 1,
            "Unsupported bot instruction snapshot"
        );
        ensure!(
            !self.store.is_imported(required(thread, "id")?)?,
            "Imported bot conversations cannot execute; create a fresh bot conversation"
        );
        let trusted = self
            .store
            .local_document(&crate::bot_runtime::context_document_name(context)?)?;
        ensure!(
            trusted.as_ref() == Some(context),
            "Bot instruction snapshot is not locally authorized; create a fresh bot conversation"
        );
        ensure!(
            context["botId"] == thread["botID"],
            "Bot identity differs from its instruction snapshot"
        );
        Uuid::parse_str(required(context, "botId")?).context("Invalid bot identity")?;
        let selection = &thread["selection"];
        crate::composer_selection::validate_selection(selection)?;
        let fields = selection
            .as_object()
            .context("Invalid bot provider selection")?;
        ensure!(
            fields.keys().all(|key| matches!(
                key.as_str(),
                "provider" | "modelID" | "accountID" | "effort" | "speed"
            )),
            "Bot selection contains unsupported options"
        );
        required(selection, "provider")?;
        ensure!(
            selection["accountID"].is_null()
                || matches!(selection["accountID"].as_str(), Some("" | "default")),
            "Alternate bot accounts are not yet connected"
        );
        let saved_cwd = Path::new(required(context, "cwd")?);
        ensure!(
            saved_cwd.is_absolute() && saved_cwd.is_dir() && cwd.is_absolute() && cwd.is_dir(),
            "Bot folder is unavailable"
        );
        ensure!(
            saved_cwd.canonicalize()? == saved_cwd && cwd.canonicalize()? == saved_cwd,
            "Bot working directory differs from its instruction snapshot"
        );
        let instructions = required(context, "instructions")?;
        ensure!(
            !instructions.trim().is_empty()
                && instructions.len() <= agent::MAX_INSTRUCTIONS_BYTES
                && instructions.chars().count() <= crate::bot_runtime::INSTRUCTIONS_LIMIT
                && !instructions.contains('\0'),
            "Invalid bot-local instruction content"
        );
        Ok(Some(instructions.into()))
    }

    pub(super) fn preserve_bot_branch(&self, source: &Value, branch: &mut Value) -> Result<()> {
        if source.get("rustBotContext").is_none() && source["botID"].is_null() {
            return Ok(());
        }
        if self.store.is_imported(required(source, "id")?)? {
            // Preserve ordinary transcript-only fork behavior, not activation
            // metadata supplied by a captured legacy/imported document.
            branch
                .as_object_mut()
                .context("Invalid branch")?
                .remove("rustBotContext");
            branch.as_object_mut().unwrap().remove("botID");
            return Ok(());
        }
        let cwd = self.working_directory(source)?;
        self.bot_instructions(source, &cwd)?;
        // The generic fork drops accounts; a validated native bot must retain
        // its exact approved default-account representation and model snapshot.
        branch["selection"] = source["selection"].clone();
        Ok(())
    }
}

#[cfg(test)]
#[path = "bot_engine_tests.rs"]
mod tests;
