//! Keep submitted previews out of the editor until their delivery is resolved.
use serde_json::Value;
use std::collections::HashMap;

/// A store refresh may observe an attachment change before its local job has
/// finished. Keep the visible draft authoritative until the job resolves, so
/// a removed image or reference cannot reappear during a background save.
pub(super) fn preserve_inflight_draft(current: &Value, next: &mut Value, in_flight: bool) {
    if !in_flight || current["id"] != next["id"] {
        return;
    }
    for key in ["rustDraftImages", "draftContext"] {
        if let Some(value) = current.get(key) {
            next[key] = value.clone();
        } else if let Some(object) = next.as_object_mut() {
            object.remove(key);
        }
    }
}

#[derive(Default)]
pub(super) struct PendingImages {
    sends: HashMap<u64, (String, Vec<Value>)>,
}

impl PendingImages {
    pub(super) fn visible(&self, thread: &str, images: &[Value]) -> Vec<Value> {
        images
            .iter()
            .filter(|image| {
                !self.sends.values().any(|(owner, pending)| {
                    owner == thread && pending.iter().any(|submitted| submitted == *image)
                })
            })
            .cloned()
            .collect()
    }

    pub(super) fn begin(&mut self, sequence: u64, thread: &str, images: Vec<Value>) {
        if !images.is_empty() {
            self.sends.insert(sequence, (thread.to_owned(), images));
        }
    }

    pub(super) fn finish(&mut self, sequence: u64) -> Option<(String, Vec<Value>)> {
        self.sends.remove(&sequence)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn refresh_does_not_reintroduce_a_cancelled_inflight_image() {
        let current = json!({"id":"one", "rustDraftImages":[]});
        let mut refreshed = json!({"id":"one", "rustDraftImages":[{"id":"still-importing"}]});
        preserve_inflight_draft(&current, &mut refreshed, true);
        assert_eq!(refreshed["rustDraftImages"], json!([]));
        let mut other = json!({"id":"two", "rustDraftImages":[{"id":"other"}]});
        preserve_inflight_draft(&current, &mut other, true);
        assert_eq!(other["rustDraftImages"], json!([{"id":"other"}]));
    }

    #[::core::prelude::v1::test]
    fn refresh_keeps_removed_reference_hidden_until_its_save_finishes() {
        let current = json!({"id":"one", "draftContext":[]});
        let mut old = json!({"id":"one", "draftContext":[{"id":"removed","kind":"quote"}]});
        preserve_inflight_draft(&current, &mut old, true);
        assert_eq!(old["draftContext"], json!([]));
        let mut finished = json!({"id":"one", "draftContext":[{"id":"new","kind":"quote"}]});
        preserve_inflight_draft(&current, &mut finished, false);
        assert_eq!(finished["draftContext"][0]["id"], "new");
    }

    #[test]
    fn submitted_images_hide_immediately_and_failure_restores_them() {
        let mut pending = PendingImages::default();
        let old = json!({"id":"old", "name":"first.png"});
        let new = json!({"id":"new", "name":"second.png"});
        pending.begin(1, "first", vec![old.clone()]);
        assert_eq!(
            pending.visible("first", &[old.clone(), new.clone()]),
            vec![new]
        );
        assert_eq!(
            pending.visible("other", std::slice::from_ref(&old)),
            vec![old.clone()]
        );
        pending.finish(1);
        assert_eq!(
            pending.visible("first", std::slice::from_ref(&old)),
            vec![old]
        );
    }

    #[test]
    fn overlapping_sends_and_changed_images_are_independent() {
        let mut pending = PendingImages::default();
        let first = json!({"id":"a", "name":"old"});
        let changed = json!({"id":"a", "name":"new"});
        let second = json!({"id":"b"});
        pending.begin(1, "thread", vec![first.clone()]);
        pending.begin(2, "thread", vec![second.clone()]);
        assert_eq!(
            pending.visible("thread", &[first.clone(), changed.clone(), second.clone()]),
            vec![changed]
        );
        pending.finish(1);
        assert_eq!(
            pending.visible("thread", &[first.clone(), second.clone()]),
            vec![first]
        );
        pending.finish(2);
        assert_eq!(
            pending.visible("thread", std::slice::from_ref(&second)),
            vec![second]
        );
    }
}
