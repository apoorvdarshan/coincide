//! Mac-local list width, matching Swift UIState.listWidth and split-view bounds.
//! Motion is memory-only; only a changed, completed native drag may save.
use super::*;
pub const DEFAULT: f64 = 288.;
const MIN: f64 = 240.;
const MAX: f64 = 400.;
const RAIL: f64 = 60.;
const MIN_CHAT: f64 = 420.;
const SAVE_ERROR: &str =
    "Conversation width is kept for this session but could not be saved. Drag again to retry.";

fn preference(document: &Value) -> Result<f64> {
    anyhow::ensure!(document.is_object(), "Interface state is not an object");
    match &document["listWidth"] {
        Value::Null => Ok(DEFAULT),
        Value::Number(value) => value
            .as_f64()
            .filter(|v| v.is_finite())
            .map(|v| v.clamp(MIN, MAX))
            .ok_or_else(|| anyhow::anyhow!("Invalid list width")),
        _ => anyhow::bail!("Invalid stored list width"),
    }
}
pub fn persist(store: &mut Store, width: f64) -> Result<()> {
    anyhow::ensure!(
        width.is_finite() && (MIN..=MAX).contains(&width),
        "Invalid resized width"
    );
    // Refuse malformed state rather than replacing it. Store merges this one
    // field into the local document; captured originals and unknown keys survive.
    preference(
        &store
            .document("ui-state.json")?
            .unwrap_or_else(|| json!({})),
    )?;
    store.patch_document("ui-state.json", &json!({"listWidth":width}))?;
    Ok(())
}
struct Drag {
    original: f64,
    rendered: f64,
    pointer: f64,
}
pub struct State {
    requested: f64,
    drag: Option<Drag>,
    error: Option<&'static str>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            requested: DEFAULT,
            drag: None,
            error: None,
        }
    }
}
impl State {
    pub fn load(engine: &SharedEngine) -> Self {
        let value = (|| -> Result<f64> {
            let engine = try_state(engine)?;
            preference(
                &engine
                    .store
                    .document("ui-state.json")?
                    .unwrap_or_else(|| json!({})),
            )
        })();
        match value {
            Ok(requested) => Self {
                requested,
                ..Self::default()
            },
            Err(_) => Self {
                error: Some(
                    "Saved conversation width could not be read. Default width is shown; existing interface state is retained.",
                ),
                ..Self::default()
            },
        }
    }
    pub fn visible(&self, window: f64) -> f64 {
        let available = if window.is_finite() {
            (window - RAIL - MIN_CHAT).max(0.)
        } else {
            0.
        };
        self.requested.min(available)
    }
    pub fn begin(&mut self, pointer: f64, window: f64) {
        if pointer.is_finite() {
            self.drag = Some(Drag {
                original: self.requested,
                rendered: self.visible(window),
                pointer,
            });
        }
    }
    pub fn move_to(&mut self, pointer: f64, window: f64) -> bool {
        let Some(drag) = &self.drag else {
            return false;
        };
        if !pointer.is_finite() || !window.is_finite() {
            return false;
        }
        let target = (drag.rendered + pointer - drag.pointer)
            .clamp(MIN, MAX)
            .min((window - RAIL - MIN_CHAT).max(MIN));
        // A gesture ending at the same drawn edge must not replace a wider
        // stored preference merely because this window currently clamps it.
        let next = if (target - drag.rendered).abs() < 0.5 {
            drag.original
        } else {
            target
        };
        if (next - self.requested).abs() < 0.5 {
            return false;
        }
        self.requested = next;
        true
    }
    pub fn finish(&mut self) -> Option<f64> {
        let drag = self.drag.take()?;
        ((self.requested - drag.original).abs() >= 0.5).then_some(self.requested)
    }
    pub fn cancel(&mut self) {
        if let Some(drag) = self.drag.take() {
            self.requested = drag.original;
        }
    }
    pub fn saved(&mut self, success: bool) {
        self.error = (!success).then_some(SAVE_ERROR);
    }
    pub fn error(&self) -> Option<&'static str> {
        self.error
    }
}
#[derive(Clone)]
pub struct ResizeList;
impl Render for ResizeList {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        Empty
    }
}
impl Coincide {
    pub(super) fn sync_sidebar_resize(&mut self, window: &Window) {
        if !self.thread_list_open
            || self.media.close_requested
            || self.media.shutdown_requested
            || !window.is_window_active()
        {
            self.sidebar_resize.cancel();
        }
    }
    pub(super) fn finish_sidebar_resize(&mut self, cx: &mut Context<Self>) {
        let Some(width) = self.sidebar_resize.finish() else {
            return;
        };
        let result = (|| -> Result<()> {
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
            persist(&mut engine.store, width)
        })();
        self.sidebar_resize.saved(result.is_ok());
        cx.notify();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn current_key_defaults_and_bounds_match_swift_without_old_key_migration() {
        assert_eq!(
            preference(&json!({"sidebarWidth":390,"threadListWidth":350})).unwrap(),
            288.
        );
        assert_eq!(preference(&json!({"listWidth":100})).unwrap(), 240.);
        assert_eq!(preference(&json!({"listWidth":900})).unwrap(), 400.);
        assert!(preference(&json!({"listWidth":"300"})).is_err());
        assert!(preference(&json!([])).is_err());
    }
    #[::core::prelude::v1::test]
    fn narrow_window_only_clamps_display_and_widening_restores_the_preference() {
        let mut state = State {
            requested: 400.,
            ..State::default()
        };
        assert_eq!(state.visible(820.), 340.);
        assert_eq!(state.visible(1200.), 400.);
        state.begin(400., 820.);
        assert!(!state.move_to(410., 820.));
        assert!(state.finish().is_none());
        assert_eq!(state.requested, 400.);
    }
    #[::core::prelude::v1::test]
    fn only_changed_real_drag_end_can_save_and_cancel_restores_original() {
        let mut state = State::default();
        assert!(state.finish().is_none());
        assert!(!state.move_to(900., 1200.));
        state.begin(500., 1200.);
        assert!(state.move_to(600., 1200.));
        assert_eq!(state.finish(), Some(388.));
        assert!(state.finish().is_none());
        state.begin(500., 1200.);
        assert!(state.move_to(200., 1200.));
        state.cancel();
        assert_eq!(state.requested, 388.);
        assert!(state.finish().is_none());
        state.begin(500., 1200.);
        assert!(!state.move_to(f64::NAN, 1200.));
        assert!(state.finish().is_none());
    }
    #[::core::prelude::v1::test]
    fn persistence_changes_only_list_width_and_malformed_state_is_never_replaced() {
        let root = std::env::temp_dir().join(format!("coincide-sidebar-width-{}", Uuid::new_v4()));
        let mut store = Store::open(&root.join("coincide.sqlite")).unwrap();
        let original = json!({"listWidth":288,"opaque":{"keep":[1,2]},"threadPanels":{"thread":"preview"},"sidebarWidth":333});
        store.save_document("ui-state.json", &original).unwrap();
        persist(&mut store, 350.).unwrap();
        let mut expected = original;
        expected["listWidth"] = json!(350.);
        assert_eq!(store.document("ui-state.json").unwrap(), Some(expected));
        for malformed in [json!([]), json!({"listWidth":"invalid","opaque":true})] {
            store.save_document("ui-state.json", &malformed).unwrap();
            assert!(persist(&mut store, 300.).is_err());
            assert_eq!(store.document("ui-state.json").unwrap(), Some(malformed));
        }
        drop(store);
        std::fs::remove_dir_all(root).unwrap();
    }
}
