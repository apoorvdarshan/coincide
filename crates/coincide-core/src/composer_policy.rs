//! Ordinary-turn mode contract, derived from Swift CodexProtocol.
//! No discovery, account authorization,
//! process launch, source mutation, or relaxation of bot/import execution gates.
use crate::composer_selection;
use anyhow::{Context, Result, ensure};
use serde_json::{Value, json};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Access {
    Approval,
    FullAccess,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interaction {
    Build,
    Plan,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Origin {
    Ordinary,
    Imported,
    FrozenBot,
}
/// Must come from trusted runtime/session state, not arbitrary thread JSON.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CollaborationHistory {
    NeverApplied,
    PreviouslyApplied,
    Unknown,
}

/// An app-server thread/start or thread/resume result's actual resolved model,
/// bound to the source thread whose result the protocol worker requested.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedCodexModel {
    thread_id: String,
    model: String,
}
impl ResolvedCodexModel {
    pub fn from_thread_result(expected_thread_id: &str, result: &Value) -> Result<Self> {
        ensure!(
            !expected_thread_id.is_empty()
                && expected_thread_id.len() <= 512
                && !expected_thread_id.chars().any(char::is_control),
            "Invalid expected source thread identity"
        );
        ensure!(
            result["thread"]["id"] == expected_thread_id,
            "Resolved model belongs to another source thread"
        );
        let model = result["model"]
            .as_str()
            .context("Codex did not report an actual resolved model")?;
        validate_actual_model(model)?;
        Ok(Self {
            thread_id: expected_thread_id.into(),
            model: model.into(),
        })
    }
}
fn validate_actual_model(model: &str) -> Result<()> {
    composer_selection::validate_model(model)?;
    ensure!(
        model != "default" && model.trim() == model && !model.trim().is_empty(),
        "Collaboration mode requires an explicit or provider-resolved actual model ID"
    );
    Ok(())
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Policy {
    pub access: Access,
    pub interaction: Interaction,
    provider: String,
    model: Option<String>,
    bot: bool,
}
impl Policy {
    /// This validates only mode/selection compatibility. Native bot snapshot
    /// authorization, account policy and imported-source checks remain required
    /// at their existing trusted Engine boundaries before launch.
    pub fn parse(thread: &Value, origin: Origin) -> Result<Self> {
        ensure!(
            origin != Origin::Imported,
            "Imported conversations remain read-only; fork before executing"
        );
        // Reuse strict selection validation without translating the requested
        // modes. This envelope validates selection ONLY; parsed modes below
        // determine the returned policy and exact provider wire fields.
        composer_selection::validate_selection(&thread["selection"])?;
        let provider = thread["selection"]["provider"]
            .as_str()
            .context("Missing provider")?
            .to_owned();
        let access = match thread["accessMode"].as_str() {
            Some("approval") => Access::Approval,
            Some("fullAccess") => Access::FullAccess,
            None if thread["accessMode"].is_null() => Access::Approval,
            _ => anyhow::bail!("Unsupported access mode"),
        };
        let interaction = match thread["interactionMode"].as_str() {
            Some("build") => Interaction::Build,
            Some("plan") => Interaction::Plan,
            None if thread["interactionMode"].is_null() => Interaction::Build,
            _ => anyhow::bail!("Unsupported interaction mode"),
        };
        let bot = origin == Origin::FrozenBot
            || !thread["rustBotContext"].is_null()
            || !thread["botID"].is_null();
        if bot {
            ensure!(
                access == Access::Approval && interaction == Interaction::Build,
                "Frozen bot conversations require approval/build modes"
            );
            ensure!(
                matches!(provider.as_str(), "codex" | "claude")
                    && composer_selection::default_account(&thread["selection"]["accountID"]),
                "Frozen bots support Codex/Claude default accounts only"
            );
            ensure!(
                thread["rustBotContext"].is_object()
                    && thread["rustBotContext"]["selection"] == thread["selection"],
                "Bot selection differs from its frozen snapshot"
            );
            let model = thread["selection"]["modelID"].as_str().unwrap_or("");
            ensure!(
                model.len() <= 256 && model.trim() == model,
                "Invalid frozen bot model"
            );
        }
        ensure!(
            provider == "codex"
                || (access == Access::Approval && interaction == Interaction::Build),
            "Plan/full access policy is not implemented for this provider"
        );
        let model = composer_selection::launch_model(&thread["selection"])?;
        Ok(Self {
            access,
            interaction,
            provider,
            model,
            bot,
        })
    }
    pub fn require_codex(&self) -> Result<()> {
        ensure!(
            self.provider == "codex",
            "Mode policy is implemented only for Codex"
        );
        Ok(())
    }
    pub fn preflight(&self) -> Result<()> {
        if self.provider == "codex"
            && let Some(model) = &self.model
        {
            validate_actual_model(model)?;
        }
        if self.interaction == Interaction::Plan {
            let model=self.model.as_deref().context("Codex Plan requires an explicit model before selection or creation; provider default has no resolved model proof")?;
            validate_actual_model(model)?;
        }
        Ok(())
    }
    /// Exact turn/start policy fields only. Thread creation/resume parameters,
    /// text/images, effort/speed and account selection are deliberately separate.
    pub fn codex_turn_fields(
        &self,
        source_thread_id: &str,
        resolved: Option<&ResolvedCodexModel>,
        history: CollaborationHistory,
    ) -> Result<Value> {
        ensure!(
            self.provider == "codex",
            "This wire policy is implemented only for Codex"
        );
        if let Some(resolved) = resolved {
            ensure!(
                resolved.thread_id == source_thread_id,
                "Resolved model belongs to another active source thread"
            );
        }
        let model = self
            .model
            .as_deref()
            .or_else(|| resolved.map(|m| m.model.as_str()));
        if self.interaction == Interaction::Plan || history != CollaborationHistory::NeverApplied {
            ensure!(
                model.is_some(),
                "Codex collaboration mode requires an explicit model or matching provider-resolved model; provider default alone cannot apply or clear Plan mode"
            );
        }
        let mut fields = json!({"approvalPolicy":if self.access==Access::Approval{"untrusted"}else{"never"},"approvalsReviewer":"user","sandboxPolicy":{"type":if self.access==Access::Approval{"readOnly"}else{"dangerFullAccess"}}});
        if let Some(model) = model {
            validate_actual_model(model)?;
            fields["model"] = json!(model);
            fields["collaborationMode"] = json!({"mode":if self.interaction==Interaction::Plan{"plan"}else{"default"},"settings":{"model":model,"reasoning_effort":null,"developer_instructions":null}});
        }
        // Existing bot launch remains separately constrained by Engine. No
        // mode-capability advertisement or credential readiness follows here.
        if self.bot {
            ensure!(
                self.access == Access::Approval && self.interaction == Interaction::Build,
                "Frozen bot policy changed"
            );
        }
        Ok(fields)
    }
}
