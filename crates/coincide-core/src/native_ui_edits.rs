//! Typed native-editor custody. This has no JSON constructor/setter and carries
//! no file path or instruction text. Native UI owners hold a lease so API Quit
//! cannot silently discard edits which have not reached their explicit Save.
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

#[derive(Clone, Default)]
pub struct NativeUiEditors {
    pending: Arc<AtomicUsize>,
}
impl NativeUiEditors {
    pub fn editor(&self) -> NativeUiEditLease {
        NativeUiEditLease {
            pending: self.pending.clone(),
            dirty: false,
        }
    }
    pub(crate) fn pending(&self) -> usize {
        self.pending.load(Ordering::Acquire)
    }
}
pub struct NativeUiEditLease {
    pending: Arc<AtomicUsize>,
    dirty: bool,
}
impl NativeUiEditLease {
    /// Independent custody for a native picker future. Editor Save/Discard
    /// cannot release it; only actual future/callback completion drops it.
    /// This carries no path/text and has no control API constructor.
    pub fn pending_native_action(&self) -> Self {
        self.pending.fetch_add(1, Ordering::AcqRel);
        Self {
            pending: self.pending.clone(),
            dirty: true,
        }
    }
    /// Only the retained native editor calls this after native input, explicit
    /// Save, or explicit Discard. It is not registered on any control API.
    pub fn set_dirty(&mut self, dirty: bool) {
        if dirty == self.dirty {
            return;
        }
        if dirty {
            self.pending.fetch_add(1, Ordering::AcqRel);
        } else {
            self.pending.fetch_sub(1, Ordering::AcqRel);
        }
        self.dirty = dirty;
    }
}
impl Drop for NativeUiEditLease {
    fn drop(&mut self) {
        self.set_dirty(false);
    }
}

#[cfg(test)]
mod tests {
    use crate::{api::Engine, store::Store};
    use serde_json::json;
    #[test]
    fn api_quit_refuses_native_unsaved_edits_before_shutdown_side_effects() {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        let mut first = engine.native_ui_editors().editor();
        let mut second = engine.native_ui_editors().editor();
        first.set_dirty(true);
        first.set_dirty(true);
        second.set_dirty(true);
        let refused = engine.dispatch(json!({"method":"app.quit","params":{}}));
        assert!(
            refused["error"]["message"]
                .as_str()
                .unwrap()
                .contains("native editor")
        );
        assert!(!engine.shutdown);
        assert_eq!(engine.native_ui_editors.pending(), 2);
        first.set_dirty(false);
        assert!(
            engine
                .dispatch(json!({"method":"app.quit","params":{}}))
                .get("error")
                .is_some()
        );
        drop(second);
        assert_eq!(engine.native_ui_editors.pending(), 0);
        assert_eq!(
            engine.dispatch(json!({"method":"app.quit","params":{}}))["result"]["requested"],
            true
        );
    }
    #[test]
    fn native_picker_action_outlives_editor_save_and_blocks_api_quit_until_actual_drop() {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        let mut editor = engine.native_ui_editors().editor();
        editor.set_dirty(true);
        let action = editor.pending_native_action();
        editor.set_dirty(false);
        drop(editor);
        assert_eq!(engine.native_ui_editors.pending(), 1);
        assert!(
            engine
                .dispatch(json!({"method":"app.quit","params":{}}))
                .get("error")
                .is_some()
        );
        assert!(!engine.shutdown && !engine.admissions_frozen());
        drop(action);
        assert_eq!(engine.native_ui_editors.pending(), 0);
        assert_eq!(
            engine.dispatch(json!({"method":"app.quit","params":{}}))["result"]["requested"],
            true
        );
    }
    #[test]
    fn native_custody_has_no_json_setter_or_path_write_route() {
        let root = tempfile::tempdir().unwrap();
        let mut engine = Engine::fixture(Store::open(&root.path().join("state.sqlite")).unwrap());
        let mut lease = engine.native_ui_editors().editor();
        lease.set_dirty(true);
        for method in [
            "native.editors.clear",
            "native.editors.set",
            "instructions.write",
        ] {
            assert!(
                engine
                    .dispatch(json!({"method":method,"params":{"pending":0}}))
                    .get("error")
                    .is_some()
            );
        }
        assert_eq!(engine.native_ui_editors.pending(), 1);
        assert!(!engine.shutdown);
    }
}
