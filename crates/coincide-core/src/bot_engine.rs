//! Native bot conversations use frozen, locally authorized instruction CONTENT.
//! Imported unknown metadata never becomes provider launch authorization.
use super::*;
use std::path::Path;

impl Engine {
    pub(super) fn create_bot_conversation(&mut self, params: &Value) -> Result<Value> {
        let result = crate::bot_runtime::create(&mut self.store, params)?;
        self.revision += 1;
        self.requested_open = result["threadId"].as_str().map(str::to_owned);
        Ok(result)
    }

    /// Validate on EVERY send, including resume/queue/schedule, before any
    /// transcript/draft mutation. Later bot edits never change this snapshot.
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
        ensure!(
            thread["accessMode"] == "approval" && thread["interactionMode"] == "build",
            "Bot conversation requires its saved approval/build modes"
        );
        let selection = &thread["selection"];
        ensure!(
            selection == &context["selection"],
            "Bot selection differs from its instruction snapshot; create a new bot conversation"
        );
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
        let provider = required(selection, "provider")?;
        ensure!(
            matches!(provider, "codex" | "claude") && context["provider"] == provider,
            "Bot provider differs from its supported instruction snapshot"
        );
        ensure!(
            selection["accountID"].is_null()
                || matches!(selection["accountID"].as_str(), Some("" | "default")),
            "Alternate bot accounts are unsupported"
        );
        ensure!(
            selection["effort"].is_null() && selection["speed"].is_null(),
            "Bot effort/speed is unsupported"
        );
        let model = required(selection, "modelID")?;
        ensure!(
            !model.is_empty()
                && model.len() <= 256
                && model.trim() == model
                && !model.starts_with('-')
                && !model.chars().any(char::is_control),
            "Invalid saved bot model"
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
