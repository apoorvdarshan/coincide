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
    effort: Option<String>,
    automatic_effort_required: bool,
    speed: Option<String>,
    effort_proof: Option<crate::model_catalog::CodexEffortProof>,
    named_proof: Option<crate::model_catalog::NamedModelProof>,
}
impl Policy {
    /// This validates only mode/selection compatibility. Native bot snapshot
    /// authorization, account policy and imported-source checks remain required
    /// at their existing trusted Engine boundaries before launch.
    pub fn parse(thread: &Value, origin: Origin) -> Result<Self> {
        ensure!(
            thread["selection"]["effort"].is_null() && thread["selection"]["speed"].is_null(),
            "Effort/speed requires a trusted private model catalog proof"
        );
        Self::parse_with_effort_proof(thread, origin, None)
    }
    pub(crate) fn parse_with_effort_proof(
        thread: &Value,
        origin: Origin,
        proof: Option<&crate::model_catalog::CodexEffortProof>,
    ) -> Result<Self> {
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
                thread["selection"]["effort"].is_null() && thread["selection"]["speed"].is_null(),
                "Frozen bot effort/speed is fixed and unsupported"
            );
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
            provider == "codex" || interaction == Interaction::Build,
            "Plan mode is not implemented for this provider"
        );
        let model = composer_selection::launch_model(&thread["selection"])?;
        if let Some(proof) = proof {
            ensure!(
                !bot,
                "Frozen bots cannot acquire model-option default authority"
            );
            proof.validate(&thread["selection"])?;
        }
        Ok(Self {
            effort: proof
                .and_then(|proof| proof.effective_effort())
                .or_else(|| thread["selection"]["effort"].as_str())
                .map(str::to_owned),
            automatic_effort_required: !bot
                && crate::model_catalog::astra_default_needed(&thread["selection"]),
            speed: thread["selection"]["speed"].as_str().map(str::to_owned),
            effort_proof: proof.cloned(),
            named_proof: None,
            access,
            interaction,
            provider,
            model,
            bot,
        })
    }
    /// Engine-only named-profile authority. Never constructs or borrows a
    /// default-account effort proof through the internal selection alias.
    pub(crate) fn parse_named(
        thread: &Value,
        origin: Origin,
        proof: Option<&crate::model_catalog::NamedModelProof>,
    ) -> Result<Self> {
        ensure!(
            origin == Origin::Ordinary
                && !composer_selection::default_account(&thread["selection"]["accountID"]),
            "Named effort requires an ordinary selected Codex profile"
        );
        crate::codex_login_profiles::validate_model_thread(thread)?;
        if thread["selection"]["modelID"] != "default" {
            proof
                .context("Refresh this profile's exact model catalog before sending")?
                .validate_thread(thread)?;
        } else {
            ensure!(
                proof.is_none(),
                "Provider default cannot borrow named model proof"
            );
        }
        let mut syntax = crate::codex_login_profiles::validation_view(thread);
        let selection = syntax["selection"]
            .as_object_mut()
            .context("Invalid profile selection")?;
        for option in ["effort", "speed"] {
            selection.remove(option);
        }
        let mut policy = Self::parse_with_effort_proof(&syntax, origin, None)?;
        policy.effort = proof
            .and_then(|proof| proof.effective_effort())
            .or_else(|| thread["selection"]["effort"].as_str())
            .map(str::to_owned);
        policy.speed = thread["selection"]["speed"].as_str().map(str::to_owned);
        policy.named_proof = proof.cloned();
        policy.automatic_effort_required = thread["selection"]["effort"].is_null()
            && thread["selection"]["modelID"]
                .as_str()
                .is_some_and(crate::model_catalog::astra_model);
        Ok(policy)
    }
    pub(crate) fn codex_effort(&self) -> Option<&str> {
        self.effort.as_deref()
    }
    pub(crate) fn codex_speed(&self) -> Option<&str> {
        self.speed.as_deref()
    }
    pub fn require_codex(&self) -> Result<()> {
        ensure!(
            self.provider == "codex",
            "Mode policy is implemented only for Codex"
        );
        Ok(())
    }
    fn validate_effort_proof(&self) -> Result<()> {
        // OpenCode carrying a reasoning variant in its model reference needs no
        // separate proof: the variant is part of the model it was discovered with.
        if self.provider == "opencode" {
            return Ok(());
        }
        if let Some(proof) = &self.named_proof {
            ensure!(
                self.effort_proof.is_none(),
                "Named options cannot borrow default proof"
            );
            return proof.validate_policy(
                self.model.as_deref(),
                self.effort.as_deref(),
                self.speed.as_deref(),
            );
        }
        if self.effort.is_some() || self.speed.is_some() {
            let proof = self.effort_proof.as_ref().context(
                "Refresh the exact Codex model catalog before applying reasoning effort or speed",
            )?;
            proof.validate_executable_for_policy()?;
        }
        Ok(())
    }
    fn validate_runtime_effort(&self) -> Result<()> {
        self.validate_effort_proof()?;
        ensure!(
            !self.automatic_effort_required || self.effort.as_deref() == Some("medium"),
            "Refresh the exact Astra model catalog advertising medium before using its app default"
        );
        Ok(())
    }
    pub fn preflight(&self) -> Result<()> {
        self.validate_runtime_effort()?;
        self.preflight_base()
    }
    /// Repair syntax/mode checks only. Remaining explicit options still require
    /// private proof; only an automatic Astra default may stay unproved here.
    pub(crate) fn preflight_base(&self) -> Result<()> {
        self.validate_effort_proof()?;
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
    pub(crate) fn validate_launch_executable(&self, executable: &std::path::Path) -> Result<()> {
        if let Some(proof) = &self.effort_proof {
            proof.validate_executable(executable)?;
        }
        if let Some(proof) = &self.named_proof {
            proof.validate_executable(executable)?;
        }
        Ok(())
    }
    /// Exact turn/start policy fields only. Thread creation/resume parameters,
    /// text/images and account selection are separate.
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
        // The source-bound resolved model above is valid at this wire boundary.
        // Admission preflight has no such evidence and remains stricter.
        self.validate_runtime_effort()?;
        let mut fields = json!({"approvalPolicy":if self.access==Access::Approval{"untrusted"}else{"never"},"approvalsReviewer":"user","sandboxPolicy":{"type":if self.access==Access::Approval{"readOnly"}else{"dangerFullAccess"}}});
        if let Some(effort) = &self.effort {
            fields["effort"] = json!(effort);
        }
        if let Some(model) = model {
            validate_actual_model(model)?;
            fields["model"] = json!(model);
            fields["collaborationMode"] = json!({"mode":if self.interaction==Interaction::Plan{"plan"}else{"default"},"settings":{"model":model,"reasoning_effort":self.effort,"developer_instructions":null}});
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
