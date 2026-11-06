//! Visibility authority from completed list layouts, never transient row-cache reads.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Binding {
    pub thread: String,
    pub revision: u64,
    pub epoch: u64,
}
#[derive(Default)]
pub(super) struct CompletedLayout {
    context: Option<Binding>,
    sequence: u64,
    visible: Vec<String>,
}
impl CompletedLayout {
    pub fn set_context(&mut self, context: Option<Binding>) {
        if self.context != context {
            self.context = context;
            self.visible.clear();
        }
    }
    pub fn clear(&mut self) {
        self.context = None;
        self.visible.clear();
    }
    pub fn complete(&mut self, binding: &Binding, sequence: u64, mut visible: Vec<String>) -> bool {
        if self.context.as_ref() != Some(binding) || sequence <= self.sequence {
            return false;
        }
        self.sequence = sequence;
        visible.truncate(20);
        visible.sort();
        visible.dedup();
        let changed = self.visible != visible;
        self.visible = visible;
        changed
    }
    pub fn visible(&self) -> Vec<String> {
        self.visible.clone()
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn binding() -> Binding {
        Binding {
            thread: "thread".into(),
            revision: 3,
            epoch: 7,
        }
    }
    #[test]
    fn image_install_cache_invalidation_is_not_an_empty_completed_layout() {
        let binding = binding();
        let mut state = CompletedLayout::default();
        state.set_context(Some(binding.clone()));
        assert!(state.complete(&binding, 1, vec!["image-row".into()]));
        // Installing images invalidates ListState measurements, but creates no
        // completed layout. Repeated parent ticks keep the last actual result.
        state.set_context(Some(binding.clone()));
        state.set_context(Some(binding.clone()));
        assert_eq!(state.visible(), ["image-row"]);
        assert!(!state.complete(&binding, 2, vec!["image-row".into()]));
        // A genuinely completed offscreen/empty layout must revoke immediately.
        assert!(state.complete(&binding, 3, vec![]));
        assert!(state.visible().is_empty());
    }
    #[test]
    fn stale_layouts_cannot_restore_old_thread_revision_epoch_or_closed_context() {
        let old = binding();
        for current in [
            None,
            Some(Binding {
                thread: "other".into(),
                ..old.clone()
            }),
            Some(Binding {
                revision: 4,
                ..old.clone()
            }),
            Some(Binding {
                epoch: 8,
                ..old.clone()
            }),
        ] {
            let mut state = CompletedLayout::default();
            state.set_context(Some(old.clone()));
            state.complete(&old, 1, vec!["old-image".into()]);
            state.set_context(current);
            assert!(state.visible().is_empty());
            assert!(!state.complete(&old, 2, vec!["old-image".into()]));
            assert!(state.visible().is_empty());
        }
    }
    #[test]
    fn older_deferred_layout_cannot_repopulate_a_newer_empty_layout() {
        let binding = binding();
        let mut state = CompletedLayout::default();
        state.set_context(Some(binding.clone()));
        state.complete(&binding, 5, vec!["image-row".into()]);
        state.complete(&binding, 7, vec![]);
        assert!(!state.complete(&binding, 6, vec!["image-row".into()]));
        assert!(state.visible().is_empty());
        state.clear();
        assert!(!state.complete(&binding, 8, vec!["image-row".into()]));
    }
}
