//! A selected thread's local version changes whenever it can be mutated.
//! Consumers can cheaply reject stale work without comparing its transcript on
//! every frame; authoritative operations still validate their full snapshots.
use serde_json::Value;
use std::ops::{Deref, DerefMut};

#[derive(Default)]
pub(super) struct SelectedThread {
    thread: Option<Value>,
    revision: u64,
}

impl SelectedThread {
    pub(super) fn revision(&self) -> u64 {
        self.revision
    }

    pub(super) fn replace(&mut self, thread: Option<Value>) {
        self.advance();
        self.thread = thread;
    }

    fn advance(&mut self) {
        self.revision = self
            .revision
            .checked_add(1)
            .expect("selected thread revision exhausted");
    }
}

impl Deref for SelectedThread {
    type Target = Option<Value>;

    fn deref(&self) -> &Self::Target {
        &self.thread
    }
}

impl DerefMut for SelectedThread {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.advance();
        &mut self.thread
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn mutable_access_and_replacement_invalidate_old_revisions() {
        let mut selected = SelectedThread::default();
        let before = selected.revision();
        selected.replace(Some(json!({"id":"t", "items":[]})));
        assert_ne!(before, selected.revision());
        let before = selected.revision();
        selected.as_mut().unwrap()["items"] = json!([{"id":"new"}]);
        assert_ne!(before, selected.revision());
        let before = selected.revision();
        assert_eq!(selected.as_ref().unwrap()["id"], "t");
        assert_eq!(before, selected.revision());
    }
}
