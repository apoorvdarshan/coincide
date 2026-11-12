//! Keep submitted previews out of the editor until their delivery is resolved.
use serde_json::Value;
use std::collections::HashMap;

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

    pub(super) fn images(&self, sequence: u64) -> Option<&[Value]> {
        self.sends
            .get(&sequence)
            .map(|(_, images)| images.as_slice())
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
