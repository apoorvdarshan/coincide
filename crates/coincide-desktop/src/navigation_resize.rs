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
    load_pending: bool,
    save_pending: Option<f64>,
    error: Option<&'static str>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            requested: DEFAULT,
            drag: None,
            load_pending: false,
            save_pending: None,
            error: None,
        }
    }
}
impl State {
    pub fn load(engine: &SharedEngine) -> Self {
        let mut state = Self {
            load_pending: true,
            ..Self::default()
        };
        state.retry(engine);
        state
    }
    /// A busy engine is temporary. Retry without covering the conversation
    /// list, and never let a late load replace a width the user has dragged.
    pub fn retry(&mut self, engine: &SharedEngine) -> bool {
        if self.drag.is_some() {
            return false;
        }
        if let Some(width) = self.save_pending {
            let result = (|| -> Result<()> {
                let mut engine = try_state(engine)?;
                anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
                persist(&mut engine.store, width)
            })();
            match result {
                Ok(()) => {
                    self.save_pending = None;
                    self.error = None;
                    return true;
                }
                Err(error) if engine_busy(&error) => return false,
                Err(error) => {
                    eprintln!("Conversation width could not be saved: {error}");
                    self.save_pending = None;
                    self.error = Some(SAVE_ERROR);
                    return true;
                }
            }
        }
        if !self.load_pending {
            return false;
        }
        let result = (|| -> Result<f64> {
            let engine = try_state(engine)?;
            preference(
                &engine
                    .store
                    .document("ui-state.json")?
                    .unwrap_or_else(|| json!({})),
            )
        })();
        match result {
            Ok(requested) => {
                self.requested = requested;
                self.load_pending = false;
                true
            }
            Err(error) if engine_busy(&error) => false,
            Err(error) => {
                eprintln!("Saved conversation width could not be read: {error}");
                self.load_pending = false;
                false
            }
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
    pub fn queue_save(&mut self, width: f64) {
        self.load_pending = false;
        self.save_pending = Some(width);
        self.error = None;
    }
    pub fn take_error(&mut self) -> Option<&'static str> {
        self.error.take()
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
        self.sidebar_list_height = (f32::from(window.viewport_size().height) - 130.).max(0.);
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
        self.sidebar_resize.queue_save(width);
        self.poll_sidebar_resize(cx);
    }
    pub(super) fn poll_sidebar_resize(&mut self, cx: &mut Context<Self>) {
        if self.sidebar_resize.retry(&self.engine) {
            if let Some(error) = self.sidebar_resize.take_error() {
                self.status = error.into();
            }
            cx.notify();
        }
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
        let root =
            std::env::temp_dir().join(format!("coincide-sidebar-width-{}", uuid::Uuid::new_v4()));
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

    #[::core::prelude::v1::test]
    fn busy_startup_retries_and_a_drag_wins_over_a_late_load() {
        let root = tempfile::tempdir().unwrap();
        let mut store = Store::open(&root.path().join("coincide.sqlite")).unwrap();
        store
            .save_document("ui-state.json", &json!({"listWidth": 350., "other": true}))
            .unwrap();
        let engine: SharedEngine = std::sync::Arc::new(std::sync::Mutex::new(
            coincide_core::api::Engine::new(store),
        ));

        let guard = engine.lock().unwrap();
        let mut state = State::load(&engine);
        assert!(state.load_pending);
        assert!(state.take_error().is_none());
        drop(guard);
        assert!(state.retry(&engine));
        assert_eq!(state.requested, 350.);

        let guard = engine.lock().unwrap();
        let mut state = State::load(&engine);
        state.begin(500., 1200.);
        assert!(state.move_to(530., 1200.));
        let width = state.finish().unwrap();
        state.queue_save(width);
        assert!(!state.retry(&engine));
        drop(guard);
        assert!(state.retry(&engine));
        assert_eq!(state.requested, 318.);
        assert_eq!(
            engine
                .lock()
                .unwrap()
                .store
                .document("ui-state.json")
                .unwrap(),
            Some(json!({"listWidth": 318., "other": true}))
        );
    }
}
