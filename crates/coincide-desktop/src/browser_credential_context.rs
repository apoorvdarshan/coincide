//! Private native SDK metadata proof only; never an approval or JSON API type.
use coincide_core::credentials::Failure;
use serde_json::Value;
use std::{cell::Cell, rc::Rc};
#[derive(Clone, PartialEq, Eq)]
pub(super) struct UniqueContext(String);
impl UniqueContext {
    pub(super) fn as_str(&self) -> &str {
        &self.0
    }
}
struct Observed {
    number: i64,
    unique: UniqueContext,
}
pub(super) struct WorldBinding {
    frame: String,
    world: String,
    expected: Option<i64>,
    observed: Option<Observed>,
}
impl WorldBinding {
    pub(super) fn new(frame: String, world: String) -> Result<Self, Failure> {
        if frame.is_empty() || frame.len() > 256 || world.is_empty() || world.len() > 256 {
            return Err(Failure::Unavailable);
        }
        Ok(Self {
            frame,
            world,
            expected: None,
            observed: None,
        })
    }
    pub(super) fn created(&mut self, number: i64) -> Result<Option<UniqueContext>, Failure> {
        if number <= 0 {
            return Err(Failure::Unavailable);
        }
        if self.expected.is_some_and(|old| old != number) {
            return Err(Failure::StalePage);
        }
        self.expected = Some(number);
        self.resolved()
    }
    pub(super) fn observe(&mut self, event: &Value) -> Result<Option<UniqueContext>, Failure> {
        let value = &event["context"];
        if value["name"].as_str() != Some(self.world.as_str())
            || value["auxData"]["frameId"].as_str() != Some(self.frame.as_str())
            || value["auxData"]["isDefault"] == true
        {
            return Ok(None);
        }
        if value["auxData"]["isDefault"].as_bool() != Some(false) {
            return Err(Failure::Unavailable);
        }
        let number = value["id"]
            .as_i64()
            .filter(|id| *id > 0)
            .ok_or(Failure::Unavailable)?;
        let unique = value["uniqueId"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 256 && !id.chars().any(char::is_control))
            .ok_or(Failure::Unavailable)?;
        let unique = UniqueContext(unique.into());
        if self
            .observed
            .as_ref()
            .is_some_and(|old| old.number != number || old.unique != unique)
        {
            return Err(Failure::StalePage);
        }
        self.observed = Some(Observed { number, unique });
        self.resolved()
    }
    fn resolved(&self) -> Result<Option<UniqueContext>, Failure> {
        let (Some(number), Some(observed)) = (self.expected, self.observed.as_ref()) else {
            return Ok(None);
        };
        if number != observed.number {
            return Err(Failure::StalePage);
        }
        Ok(Some(observed.unique.clone()))
    }
}
#[derive(Clone)]
pub(super) struct EventReceipt(Rc<Cell<bool>>);
pub(super) struct EventOwner(EventReceipt);
impl Drop for EventOwner {
    fn drop(&mut self) {
        self.0.0.set(true);
    }
}
pub(super) struct Custody {
    calls: usize,
    event: Option<EventReceipt>,
}
impl Custody {
    pub(super) fn new() -> Self {
        Self {
            calls: 0,
            event: None,
        }
    }
    pub(super) fn began(&mut self) {
        self.calls += 1;
    }
    pub(super) fn returned(&mut self) {
        assert!(self.calls > 0);
        self.calls -= 1;
    }
    pub(super) fn event_owner(&mut self) -> Result<EventOwner, Failure> {
        if self.event.is_some() {
            return Err(Failure::FillFailed);
        }
        let receipt = EventReceipt(Rc::new(Cell::new(false)));
        self.event = Some(receipt.clone());
        Ok(EventOwner(receipt))
    }
    pub(super) fn returned_all(&self) -> bool {
        self.calls == 0 && self.event.as_ref().is_none_or(|event| event.0.get())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn event(id: i64, unique: Option<&str>) -> Value {
        let mut value = json!({"context":{"id":id,"name":"owned-world","auxData":{"frameId":"owned-frame","isDefault":false}}});
        if let Some(unique) = unique {
            value["context"]["uniqueId"] = json!(unique);
        }
        value
    }
    #[::core::prelude::v1::test]
    fn event_and_command_may_arrive_in_either_order_but_both_proofs_are_required() {
        for event_first in [false, true] {
            let mut binding =
                WorldBinding::new("owned-frame".into(), "owned-world".into()).unwrap();
            if event_first {
                assert!(
                    binding
                        .observe(&event(4, Some("system-unique")))
                        .unwrap()
                        .is_none()
                );
                assert_eq!(
                    binding.created(4).unwrap().unwrap().as_str(),
                    "system-unique"
                );
            } else {
                assert!(binding.created(4).unwrap().is_none());
                assert_eq!(
                    binding
                        .observe(&event(4, Some("system-unique")))
                        .unwrap()
                        .unwrap()
                        .as_str(),
                    "system-unique"
                );
            }
        }
    }
    #[::core::prelude::v1::test]
    fn numeric_reuse_missing_unique_id_wrong_frame_and_page_world_never_supply_a_target() {
        let mut binding = WorldBinding::new("owned-frame".into(), "owned-world".into()).unwrap();
        binding.created(4).unwrap();
        let mut old_document = event(4, Some("old-document-unique"));
        old_document["context"]["name"] = json!("world-namespaced-by-old-loader");
        assert!(binding.observe(&old_document).unwrap().is_none());
        let mut wrong = event(4, Some("other"));
        wrong["context"]["auxData"]["frameId"] = json!("other-frame");
        assert!(binding.observe(&wrong).unwrap().is_none());
        let mut page = event(4, Some("page-world"));
        page["context"]["auxData"]["isDefault"] = json!(true);
        assert!(binding.observe(&page).unwrap().is_none());
        assert!(matches!(
            binding.observe(&event(4, None)),
            Err(Failure::Unavailable)
        ));
        binding.observe(&event(4, Some("first-unique"))).unwrap();
        assert!(matches!(
            binding.observe(&event(4, Some("reused-number-new-context"))),
            Err(Failure::StalePage)
        ));
    }
    #[::core::prelude::v1::test]
    fn cancellation_or_unregister_ack_does_not_return_pending_metadata_or_event_closure_custody() {
        let mut custody = Custody::new();
        let host_reference = Rc::new(custody.event_owner().unwrap());
        let sdk_reference = host_reference.clone();
        custody.began();
        // Unregister/host release is not the final native closure release.
        drop(host_reference);
        assert!(!custody.returned_all());
        custody.returned();
        assert!(!custody.returned_all());
        drop(sdk_reference);
        assert!(custody.returned_all());
        custody.began();
        assert!(!custody.returned_all());
        custody.returned();
        assert!(custody.returned_all());
    }
}
