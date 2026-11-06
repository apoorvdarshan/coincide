use super::*;
impl Engine {
    pub(crate) fn park_named_departure(&mut self, thread: &Value) -> Result<()> {
        if thread["selection"]["provider"] != "codex"
            || crate::composer_selection::default_account(&thread["selection"]["accountID"])
        {
            return Ok(());
        }
        if let Some(binding) = self.named_resume.departure_binding(thread)? {
            let fence = self.model_catalog.named_catalog_fence(&binding);
            self.named_resume.park_departure(thread, fence)?;
        }
        Ok(())
    }
}
