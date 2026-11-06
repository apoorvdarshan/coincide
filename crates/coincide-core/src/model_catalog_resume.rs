//! Private catalog fences/admission for resident parked native continuations.
//! A fence is not launch authority; it only prevents reusing a pre-departure job.
use super::*;
#[derive(Clone)]
pub(crate) struct NamedCatalogFence {
    binding: NamedBinding,
    actor: Arc<AtomicBool>,
}
#[derive(Clone)]
pub(crate) struct NamedResumeAdmission {
    binding: NamedBinding,
    selection: Value,
    actor: Arc<AtomicBool>,
}
impl NamedResumeAdmission {
    pub(crate) fn is_actor(&self, fence: &NamedCatalogFence) -> bool {
        Arc::ptr_eq(&self.actor, &fence.actor)
    }
    pub(crate) fn validate(
        &self,
        binding: &NamedBinding,
        selection: &Value,
        fence: Option<&NamedCatalogFence>,
    ) -> Result<()> {
        self.binding.validate()?;
        ensure!(
            &self.binding == binding
                && &self.selection == selection
                && !self.actor.load(Ordering::Acquire),
            "Parked continuation needs this selected account's fresh private catalog"
        );
        if let Some(fence) = fence {
            ensure!(
                fence.binding == self.binding && !Arc::ptr_eq(&fence.actor, &self.actor),
                "A pre-departure catalog cannot readmit a parked native continuation"
            );
        }
        Ok(())
    }
}
impl ModelCatalog {
    pub(crate) fn named_catalog_fence(&self, binding: &NamedBinding) -> Option<NamedCatalogFence> {
        let job = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.jobs.get(id))
            .find(|job| profile::same_scope(job.named.as_ref(), Some(binding)))?;
        Some(NamedCatalogFence {
            binding: binding.clone(),
            actor: job.cancelled.clone(),
        })
    }
    pub(crate) fn named_resume_admission(
        &self,
        thread: &Value,
        binding: &NamedBinding,
    ) -> Result<NamedResumeAdmission> {
        ensure!(!self.shutdown.closed, "Model catalog is shutting down");
        binding.validate()?;
        ensure!(
            thread["id"] == binding.thread()
                && thread["selection"]["provider"] == "codex"
                && thread["selection"]["accountID"] == binding.account(),
            "Continuation catalog belongs to another selected account"
        );
        let job=self.order.iter().rev().filter_map(|id|self.jobs.get(id))
            .find(|job|profile::same_scope(job.named.as_ref(),Some(binding)))
            .context("Refresh this selected account's private catalog before resuming its parked session")?;
        ensure!(
            job.named.as_ref() == Some(binding)
                && job.response["state"] == "ready"
                && job.response["authenticationChecked"] == true
                && !job.cancelled.load(Ordering::Acquire),
            "Latest selected-account catalog is not authenticated and ready"
        );
        Ok(NamedResumeAdmission {
            binding: binding.clone(),
            selection: thread["selection"].clone(),
            actor: job.cancelled.clone(),
        })
    }
}

#[cfg(test)]
impl ModelCatalog {
    pub(crate) fn fixture_resume_job(&mut self, binding: NamedBinding, id: &str) {
        self.jobs.insert(id.into(), Job {
            binding: None, named: Some(binding),
            response: serde_json::json!({"state":"ready","authenticationChecked":true,"models":[]}),
            cancelled: Arc::new(AtomicBool::new(false)),
        });
        self.order.push_back(id.into());
    }
}
