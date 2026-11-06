//! Explicit named-profile model controls. Caller metadata never supplies a proof.
use super::*;
use crate::{
    codex_login_profiles as profiles,
    model_catalog::{NamedBinding, NamedModelProof},
};

pub(super) fn named_thread(thread: &Value) -> bool {
    thread["selection"]["provider"] == "codex"
        && !crate::composer_selection::default_account(&thread["selection"]["accountID"])
}
impl Engine {
    pub(super) fn profile_model_binding(&self, thread: &Value) -> Result<NamedBinding> {
        let id = required(thread, "id")?;
        ensure!(
            self.active_thread().and_then(|id| Uuid::parse_str(id).ok())
                == Some(Uuid::parse_str(id)?),
            "Codex profile model target is no longer selected"
        );
        ensure!(
            !self.runs.contains_key(id) && !self.unsaved_threads.contains_key(id),
            "Stop the turn and wait for persistence before changing profile models"
        );
        ensure!(
            named_thread(thread),
            "Select a configured named Codex profile first"
        );
        // Default is an explicit repair target. It does not confer authority on
        // an unsupported stored model or clear any other selection field.
        let mut shape = thread.clone();
        shape["selection"]["modelID"] = json!("default");
        // Read/repair binding grants no option authority. Retained effort must
        // not trap Refresh after restart or after its catalog was revoked.
        shape["selection"]
            .as_object_mut()
            .context("Invalid profile selection")?
            .remove("effort");
        // Binding capture grants no model/access authority. Keep refresh and
        // explicit approval repair available for a saved, now-unproved mode.
        if shape["accessMode"] == "fullAccess" {
            shape["accessMode"] = json!("approval");
        }
        let profile = self
            .codex_login_context(&shape)?
            .context("Missing named Codex profile")?;
        crate::composer_selection::validate_thread_with_proof(
            &profiles::validation_view(&shape),
            None,
        )?;
        NamedBinding::capture(profile, id, &self.working_directory(thread)?)
    }
    fn profile_model_proof(
        &self,
        thread: &Value,
        binding: &NamedBinding,
        request: Option<&str>,
    ) -> Result<Option<NamedModelProof>> {
        self.model_catalog
            .named_model_proof(thread, binding, request)
    }
    pub(super) fn codex_profile_model_capabilities(&self, thread: &Value) -> Value {
        let mut result = crate::composer_selection::capabilities();
        let binding = self.profile_model_binding(thread);
        let base_reason = if self.admissions_frozen() {
            Some("Application admission is closed".to_owned())
        } else {
            binding.as_ref().err().map(ToString::to_string)
        };
        let proof = binding
            .as_ref()
            .ok()
            .map(|binding| self.profile_model_proof(thread, binding, None));
        let proof_reason = proof
            .as_ref()
            .and_then(|proof| proof.as_ref().err())
            .map(ToString::to_string);
        let full_access = base_reason.is_none() && matches!(proof, Some(Ok(Some(_))));
        let effort = binding
            .as_ref()
            .map(|binding| self.model_catalog.named_effort_capability(thread, binding))
            .unwrap_or_else(
                |error| json!({"supported":false,"choices":[],"reason":error.to_string()}),
            );
        let reason = base_reason.clone().or(proof_reason);
        result["locked"] = json!(reason.is_some());
        result["lockReason"] = json!(reason);
        result["namedModels"] = json!({"supported":true,"accountID":thread["selection"]["accountID"],"threadId":thread["id"],
            "refreshAllowed":base_reason.is_none(),"reason":base_reason,"authenticationChecked":false,
            "accountIdentityVerified":false,"effortSupported":base_reason.is_none() && effort["supported"] == true,"speedSupported":false,"nativeResumeSupported":false,"fullAccessSupported":full_access});
        if let Some(codex) = result["providers"]
            .as_array_mut()
            .and_then(|rows| rows.iter_mut().find(|row| row["provider"] == "codex"))
        {
            codex["accountPolicy"] = json!("configured_codex_profile");
            codex["customModel"] = json!({"supported":false,"reason":"Choose a model reported by this exact profile's refreshed catalog"});
            codex["accessModes"] = if full_access {
                json!(["approval", "fullAccess"])
            } else {
                json!(["approval"])
            };
            codex["interactionModes"] = json!(["build"]);
            codex["effort"] = effort;
            codex["speed"] =
                json!({"supported":false,"reason":"Named-profile speed is not connected"});
        }
        result
    }
    pub(super) fn codex_profile_model_command(&mut self, method: &str, p: &Value) -> Result<Value> {
        self.require_admissions()?;
        let fields = p
            .as_object()
            .context("Profile model request must be an object")?;
        let allowed = match method {
            "providers.codex.profiles.models.refresh" => {
                &["threadId", "accountId", "expectedSelection"][..]
            }
            "providers.codex.profiles.models.status" => &["threadId", "accountId", "requestId"][..],
            "providers.codex.profiles.models.select" => &[
                "threadId",
                "accountId",
                "expectedSelection",
                "requestId",
                "model",
                "accessMode",
                "effort",
                "expectedAccessMode",
                "expectedInteractionMode",
            ][..],
            _ => bail!("Unknown profile model operation"),
        };
        ensure!(
            fields.keys().all(|key| allowed.contains(&key.as_str())),
            "Unsupported profile model field"
        );
        let id = required(p, "threadId")?;
        let mut thread = self.store.thread(id)?;
        ensure!(
            p.get("accountId") == thread["selection"].get("accountID"),
            "Selected Codex profile changed"
        );
        let binding = self.profile_model_binding(&thread)?;
        if method == "providers.codex.profiles.models.status" {
            let request = required(p, "requestId")?;
            ensure!(request.len() <= 128, "Invalid profile catalog request");
            if self.model_catalog.poll() {
                self.revision += 1;
            }
            return self.model_catalog.named_status(request, &binding);
        }
        ensure!(
            p.get("expectedSelection") == thread.get("selection"),
            "Selection changed; reload profile model controls"
        );
        if method == "providers.codex.profiles.models.refresh" {
            let result = self.model_catalog.refresh_named(binding)?;
            self.revision += 1;
            return Ok(result);
        }
        let model = required(p, "model")?;
        crate::composer_selection::validate_model(model)?;
        let clear_only = p.get("effort").is_some_and(Value::is_null)
            && !thread["selection"]["effort"].is_null()
            && thread["selection"]["modelID"] == model
            && !fields.contains_key("accessMode");
        if fields.contains_key("accessMode") || fields.contains_key("effort") {
            ensure!(
                fields.contains_key("expectedAccessMode")
                    && fields.contains_key("expectedInteractionMode")
                    && p.get("expectedAccessMode") == thread.get("accessMode")
                    && p.get("expectedInteractionMode") == thread.get("interactionMode"),
                "Conversation modes changed; reload profile controls"
            );
        } else {
            ensure!(
                !fields.contains_key("expectedAccessMode")
                    && !fields.contains_key("expectedInteractionMode"),
                "Expected modes require an explicit access mode or effort"
            );
        }
        if let Some(access) = p.get("accessMode") {
            ensure!(access.is_string(), "Access mode must be text");
            thread["accessMode"] = access.clone();
        }
        if let Some(effort) = p.get("effort") {
            thread["selection"]["effort"] = effort.clone();
        }
        thread["selection"]["modelID"] = json!(model);
        profiles::validate_model_thread(&thread)?;
        if clear_only {
            ensure!(
                !fields.contains_key("requestId"),
                "Effort repair does not accept catalog authority"
            );
            // Only removes this exact stored option. An unproved model or mode
            // remains locked by the ordinary named turn preflight after save.
            crate::composer_selection::validate_thread_with_proof(
                &profiles::validation_view(&thread),
                None,
            )?;
        } else {
            let request = if model == "default" {
                None
            } else {
                Some(required(p, "requestId")?)
            };
            let proof = self.profile_model_proof(&thread, &binding, request)?;
            crate::composer_policy::Policy::parse_named(
                &thread,
                crate::composer_policy::Origin::Ordinary,
                proof.as_ref(),
            )?
            .preflight()?;
        }
        self.store.save(&thread)?;
        self.revision += 1;
        Ok(thread)
    }
}
