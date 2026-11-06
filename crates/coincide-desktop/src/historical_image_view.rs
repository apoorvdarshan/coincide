//! Selection for an enlarged view of already verified historical-image bytes.
//! This module has no path, file, network, provider or image-decoding authority.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    pub thread: String,
    pub item: String,
    pub candidate: String,
    pub epoch: u64,
    pub revision: u64,
}
impl Selection {
    pub fn current(
        &self,
        thread: Option<&str>,
        epoch: u64,
        revision: u64,
        candidate_present: bool,
        stopping: bool,
    ) -> bool {
        !stopping
            && !self.thread.is_empty()
            && !self.item.is_empty()
            && !self.candidate.is_empty()
            && thread == Some(self.thread.as_str())
            && self.epoch == epoch
            && self.revision == revision
            && candidate_present
    }
}
#[derive(Default)]
pub struct Viewer {
    selection: Option<Selection>,
}
impl Viewer {
    /// Rejected stale clicks cannot replace an already opened image.
    pub fn open(&mut self, selection: Selection, current: bool) -> bool {
        if !current {
            return false;
        }
        self.selection = Some(selection);
        true
    }
    pub fn selection(&self) -> Option<&Selection> {
        self.selection.as_ref()
    }
    pub fn close(&mut self) -> bool {
        self.selection.take().is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn selection() -> Selection {
        Selection {
            thread: "thread-one".into(),
            item: "item-one".into(),
            candidate: "candidate-one".into(),
            epoch: 7,
            revision: 11,
        }
    }
    #[test]
    fn changes_to_thread_epoch_revision_or_candidate_revoke_the_view() {
        let selection = selection();
        assert!(selection.current(Some("thread-one"), 7, 11, true, false));
        for (thread, epoch, revision, present, stopping) in [
            (Some("thread-two"), 7, 11, true, false),
            (None, 7, 11, true, false),
            (Some("thread-one"), 8, 11, true, false),
            (Some("thread-one"), 7, 12, true, false),
            (Some("thread-one"), 7, 11, false, false),
            (Some("thread-one"), 7, 11, true, true),
        ] {
            assert!(!selection.current(thread, epoch, revision, present, stopping));
        }
    }
    #[test]
    fn stale_or_unavailable_click_cannot_open_or_replace_the_current_image() {
        let mut viewer = Viewer::default();
        assert!(!viewer.open(selection(), false));
        assert!(viewer.selection().is_none());
        assert!(viewer.open(selection(), true));
        let mut stale = selection();
        stale.candidate = "other-candidate".into();
        assert!(!viewer.open(stale, false));
        assert_eq!(viewer.selection(), Some(&selection()));
    }
    #[test]
    fn close_drops_selection_and_is_idempotent() {
        let mut viewer = Viewer::default();
        viewer.open(selection(), true);
        assert!(viewer.close());
        assert!(!viewer.close());
        assert!(viewer.selection().is_none());
    }
    #[test]
    fn incomplete_identity_is_never_displayable() {
        for field in 0..3 {
            let mut selection = selection();
            match field {
                0 => selection.thread.clear(),
                1 => selection.item.clear(),
                _ => selection.candidate.clear(),
            }
            assert!(!selection.current(Some("thread-one"), 7, 11, true, false));
        }
    }
}
