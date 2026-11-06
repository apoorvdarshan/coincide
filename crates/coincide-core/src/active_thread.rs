//! All production selection transitions revoke prior Computer Use authority
//! synchronously. A desktop poll cannot safely infer A -> B -> A transitions.
use super::*;
impl Engine {
    pub fn active_thread(&self) -> Option<&str> {
        self.active_thread.as_deref()
    }
    /// Native UI and owner API selection only. Resolve a real stored identity,
    /// preserve its exact spelling, and never grant/enable the next thread.
    pub fn set_active_thread(&mut self, thread: Option<String>) -> Result<()> {
        let selected = thread
            .as_deref()
            .map(|text| -> Result<String> {
                let id = Uuid::parse_str(text).context("Invalid selected thread UUID")?;
                self.store
                    .resolve_thread_id(id)?
                    .context("Selected thread not found")
            })
            .transpose()?;
        let prior = self
            .active_thread
            .as_deref()
            .map(Uuid::parse_str)
            .transpose()
            .context("Invalid current thread UUID")?;
        let next = selected
            .as_deref()
            .map(Uuid::parse_str)
            .transpose()
            .context("Invalid selected thread UUID")?;
        if prior != next
            && let Some(prior) = prior
        {
            self.computer_use_selection_changed(prior);
            if let Some(id) = self.store.resolve_thread_id(prior)? {
                let departing = self.store.thread(&id)?;
                self.park_named_departure(&departing)?;
            } else {
                // Observed absence can revoke, never mint. Closed/ambiguous or
                // failed Store reads still propagate above rather than being
                // mistaken for a successfully removed conversation.
                self.named_resume
                    .invalidate_threads(&[prior.to_string()], &self.store)?;
            }
        }
        if prior != next
            && let Some(id) = &selected
        {
            let arriving = self.store.thread(id)?;
            self.park_named_departure(&arriving)?;
        }
        if self.active_thread != selected {
            self.active_thread = selected;
            self.revision += 1;
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::computer_use::{Authority, Failure};
    fn fixture() -> (tempfile::TempDir, Engine, String, String, Authority) {
        let dir = tempfile::tempdir().unwrap();
        let mut e = Engine::fixture(Store::open(&dir.path().join("state.sqlite")).unwrap());
        let a = text(&e.execute("threads.create", &json!({})).unwrap(), "id");
        let b = text(&e.execute("threads.create", &json!({})).unwrap(), "id");
        e.set_active_thread(Some(a.clone())).unwrap();
        e.ui_available = true;
        let authority = Authority::default();
        authority.native_enable(true);
        authority
            .native_grant(Uuid::parse_str(&a).unwrap())
            .unwrap();
        e.computer_use_bind_authority(authority.clone());
        (dir, e, a, b, authority)
    }
    #[test]
    fn owner_api_a_b_a_revokes_old_epoch_before_any_desktop_mount_poll() {
        let (_dir, mut e, a, b, authority) = fixture();
        let a_id = Uuid::parse_str(&a).unwrap();
        let accepted = e
            .execute(
                "computer_use.request",
                &json!({"threadId":a,"request":{"action":"status"}}),
            )
            .unwrap();
        let op = Uuid::parse_str(accepted["operationId"].as_str().unwrap()).unwrap();
        e.computer_use_drain();
        assert!(e.computer_use_reply(op, a_id, Ok(json!({"private":"old-observation"}))));
        let before = e.store.thread(&a).unwrap();
        e.execute("threads.open", &json!({"threadId":b})).unwrap();
        assert_eq!(e.active_thread(), Some(b.as_str()));
        e.execute("threads.open", &json!({"threadId":a})).unwrap();
        assert_eq!(e.active_thread(), Some(a.as_str()));
        assert_eq!(e.requested_open.as_deref(), Some(a.as_str()));
        assert_eq!(authority.grant(a_id), Err(Failure::NotGranted));
        assert_eq!(
            e.execute(
                "computer_use.result",
                &json!({"threadId":a,"operationId":op})
            )
            .unwrap()["error"],
            "revoked"
        );
        assert!(
            e.execute(
                "computer_use.request",
                &json!({"threadId":a,"request":{"action":"status"}})
            )
            .is_err(),
            "switching back must not regrant"
        );
        assert_eq!(e.store.thread(&a).unwrap(), before);
    }
    #[test]
    fn native_setter_case_alias_is_same_identity_invalid_target_is_atomic_and_clear_revokes() {
        let (_dir, mut e, a, _b, authority) = fixture();
        let id = Uuid::parse_str(&a).unwrap();
        let stamp = authority.grant(id).unwrap();
        e.set_active_thread(Some(id.to_string())).unwrap();
        assert_eq!(e.active_thread(), Some(a.as_str()));
        assert_eq!(authority.grant(id), Ok(stamp));
        let revision = e.revision;
        for value in ["invalid".to_owned(), Uuid::new_v4().to_string()] {
            assert!(e.set_active_thread(Some(value)).is_err());
            assert_eq!(e.active_thread(), Some(a.as_str()));
            assert_eq!(authority.grant(id), Ok(stamp));
            assert_eq!(e.revision, revision);
        }
        e.set_active_thread(None).unwrap();
        assert_eq!(e.active_thread(), None);
        assert_eq!(authority.grant(id), Err(Failure::NotGranted));
        assert!(authority.enabled());
    }
    #[test]
    fn closed_store_departure_is_not_treated_as_missing_and_revokes_native_grant() {
        let (_dir, mut e, a, _b, authority) = fixture();
        let id = Uuid::parse_str(&a).unwrap();
        e.store.close_for_shutdown().unwrap();
        assert!(e.set_active_thread(None).is_err());
        assert_eq!(e.active_thread(), Some(a.as_str()));
        assert_eq!(authority.grant(id), Err(Failure::NotGranted));
    }
    #[test]
    fn independently_absent_prior_row_can_clear_without_inventing_departure_context() {
        let (_dir, mut e, _a, _b, _authority) = fixture();
        e.active_thread = Some(Uuid::new_v4().to_string());
        e.set_active_thread(None).unwrap();
        assert!(e.active_thread().is_none());
    }
}
