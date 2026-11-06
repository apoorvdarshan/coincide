//! Terminal placement and split geometry use Swift's persisted UIState keys.
//! Moving the retained workspace never creates, closes or replaces its PTYs.
use super::*;
const PANEL_MIN: f64 = 320.;
const CHAT_MIN: f64 = 420.;
const HEIGHT_MIN: f64 = 120.;
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub(super) enum Placement {
    #[default]
    Bottom,
    Right,
}
pub(super) fn placement(settings: &Value) -> Placement {
    if settings["terminalPlacement"] == "right" {
        Placement::Right
    } else {
        Placement::Bottom
    }
}
fn fraction(value: f64) -> f64 {
    if value.is_finite() {
        value.clamp(0.05, 0.95)
    } else {
        0.5
    }
}
fn width(share: f64, available: f64) -> f64 {
    (fraction(share) * available.max(0.))
        .min(available - CHAT_MIN)
        .max(PANEL_MIN)
}
fn height(requested: f64, available: f64) -> f64 {
    requested.min(available - 200.).max(HEIGHT_MIN)
}
struct Drag {
    right: bool,
    pointer: f64,
    original: f64,
    rendered: f64,
    available: f64,
}
pub(super) struct State {
    share: f64,
    height: f64,
    drag: Option<Drag>,
    error: Option<String>,
}
impl Default for State {
    fn default() -> Self {
        Self {
            share: 0.5,
            height: 260.,
            drag: None,
            error: None,
        }
    }
}
impl State {
    pub(super) fn load(engine: &SharedEngine) -> Self {
        let result = (|| -> Result<Value> {
            Ok(try_state(engine)?
                .store
                .document("ui-state.json")?
                .unwrap_or_else(|| json!({})))
        })();
        match result.and_then(|value| {
            valid(&value)?;
            Ok(value)
        }) {
            Ok(value) => Self {
                share: value["inspectorFraction"]
                    .as_f64()
                    .map(fraction)
                    .unwrap_or(0.5),
                height: value["terminalHeight"].as_f64().unwrap_or(260.),
                ..Self::default()
            },
            Err(_) => Self {
                error: Some(
                    "Saved terminal geometry could not be read; its original values are retained."
                        .into(),
                ),
                ..Self::default()
            },
        }
    }
    fn begin(&mut self, right: bool, pointer: f64, available: f64) {
        if !pointer.is_finite() || !available.is_finite() || available <= 0. {
            return;
        }
        self.drag = Some(Drag {
            right,
            pointer,
            original: if right { self.share } else { self.height },
            rendered: if right {
                width(self.share, available)
            } else {
                height(self.height, available)
            },
            available,
        });
    }
    fn move_to(&mut self, pointer: f64) -> bool {
        let Some(drag) = &self.drag else {
            return false;
        };
        if !pointer.is_finite() {
            return false;
        }
        let wanted = drag.rendered - (pointer - drag.pointer);
        let shown = if drag.right {
            width(wanted / drag.available, drag.available)
        } else {
            height(wanted, drag.available)
        };
        let next = if (shown - drag.rendered).abs() < 0.5 {
            drag.original
        } else if drag.right {
            fraction(shown / drag.available)
        } else {
            shown
        };
        let current = if drag.right {
            &mut self.share
        } else {
            &mut self.height
        };
        if (*current - next).abs() < 0.0001 {
            return false;
        }
        *current = next;
        true
    }
    fn cancel(&mut self) {
        if let Some(drag) = self.drag.take() {
            if drag.right {
                self.share = drag.original;
            } else {
                self.height = drag.original;
            }
        }
    }
    fn finish(&mut self) -> Option<(&'static str, f64)> {
        let drag = self.drag.take()?;
        let (key, value) = if drag.right {
            ("inspectorFraction", self.share)
        } else {
            ("terminalHeight", self.height)
        };
        ((value - drag.original).abs() > 0.0001).then_some((key, value))
    }
}
fn valid(document: &Value) -> Result<()> {
    anyhow::ensure!(document.is_object(), "Saved interface state is malformed");
    for key in ["inspectorFraction", "terminalHeight"] {
        anyhow::ensure!(
            document[key].is_null()
                || document[key]
                    .as_f64()
                    .is_some_and(|n| n.is_finite() && (key != "terminalHeight" || n > 0.)),
            "Saved terminal geometry is malformed"
        );
    }
    Ok(())
}
fn persist(store: &mut Store, key: &str, value: f64) -> Result<()> {
    anyhow::ensure!(
        value.is_finite()
            && ((key == "inspectorFraction" && (0.05..=0.95).contains(&value))
                || (key == "terminalHeight" && value >= HEIGHT_MIN)),
        "Invalid terminal geometry"
    );
    valid(
        &store
            .document("ui-state.json")?
            .unwrap_or_else(|| json!({})),
    )?;
    let mut patch = json!({});
    patch[key] = json!(value);
    store.patch_document("ui-state.json", &patch)?;
    Ok(())
}
#[derive(Clone)]
struct ResizeTerminal {
    right: bool,
}
impl Render for ResizeTerminal {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        Empty
    }
}
impl Coincide {
    pub(super) fn terminal_on_right(&self) -> bool {
        placement(&self.settings) == Placement::Right
    }
    pub(super) fn terminal_available_width(&self, window: &Window) -> f64 {
        let total = f64::from(f32::from(window.viewport_size().width));
        total
            - 60.
            - if self.thread_list_open {
                self.sidebar_resize.visible(total)
            } else {
                0.
            }
    }
    pub(super) fn ensure_terminal_space(&self, window: &mut Window) {
        if self.terminal_on_right() && !window.is_fullscreen() && !window.is_maximized() {
            let available = self.terminal_available_width(window);
            if available < PANEL_MIN + CHAT_MIN {
                let size = window.viewport_size();
                window.resize(gpui_kit::size(
                    size.width + px((PANEL_MIN + CHAT_MIN - available) as f32),
                    size.height,
                ));
            }
        }
    }
    pub(super) fn terminal_surface(
        &self,
        right: bool,
        window: &Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let id = self.terminal_visible_thread.as_ref()?;
        if self.terminal_on_right() != right {
            return None;
        }
        let workspace = self.terminal_workspaces.get(id)?.clone();
        let parent = cx.entity().downgrade();
        let available = if right {
            self.terminal_available_width(window)
        } else {
            f64::from(f32::from(window.viewport_size().height)) - 44.
        };
        let handle = div()
            .role(Role::Splitter)
            .aria_label(if right {
                "Resize terminal panel width"
            } else {
                "Resize terminal panel height"
            })
            .id(if right {
                "terminal-right-resize"
            } else {
                "terminal-bottom-resize"
            })
            .flex_shrink_0()
            .bg(self.color(0x29303d))
            .when(right, |view| {
                view.w(px(4.)).h_full().cursor(CursorStyle::ResizeColumn)
            })
            .when(!right, |view| {
                view.h(px(4.)).w_full().cursor(CursorStyle::ResizeRow)
            })
            .on_drag(ResizeTerminal { right }, move |drag, _, window, cx| {
                let point = window.mouse_position();
                let pointer = if drag.right { point.x } else { point.y };
                let _ = parent.update(cx, |this, cx| {
                    if window.is_window_active()
                        && !this.media.close_requested
                        && !this.media.shutdown_requested
                    {
                        this.terminal_layout.begin(
                            drag.right,
                            f64::from(f32::from(pointer)),
                            available,
                        );
                        cx.notify();
                    }
                });
                cx.new(|_| drag.clone())
            });
        Some(
            div()
                .id(if right {
                    "terminal-right-surface"
                } else {
                    "terminal-workspace-surface"
                })
                .flex()
                .min_w_0()
                .min_h_0()
                .overflow_hidden()
                .when(right, |view| {
                    view.w(px(width(self.terminal_layout.share, available) as f32))
                        .h_full()
                        .flex_shrink_0()
                })
                .when(!right, |view| {
                    view.flex_col()
                        .h(px(height(self.terminal_layout.height, available) as f32))
                        .min_h(px(120.))
                        .w_full()
                        .flex_shrink_1()
                })
                .on_drag_move(
                    cx.listener(|this, event: &DragMoveEvent<ResizeTerminal>, _, cx| {
                        let pointer = if event.drag(cx).right {
                            event.event.position.x
                        } else {
                            event.event.position.y
                        };
                        if this.terminal_layout.move_to(f64::from(f32::from(pointer))) {
                            cx.notify();
                        }
                    }),
                )
                .on_mouse_up(
                    MouseButton::Left,
                    cx.listener(|this, _, _, cx| this.finish_terminal_resize(cx)),
                )
                .on_mouse_up_out(
                    MouseButton::Left,
                    cx.listener(|this, _, _, cx| this.finish_terminal_resize(cx)),
                )
                .child(handle)
                .child(div().flex_1().min_h_0().min_w_0().child(workspace))
                .when_some(self.terminal_layout.error.clone(), |view, error| {
                    view.child(div().text_xs().child(error))
                })
                .into_any_element(),
        )
    }
    fn finish_terminal_resize(&mut self, cx: &mut Context<Self>) {
        let Some((key, value)) = self.terminal_layout.finish() else {
            return;
        };
        let result = (|| -> Result<()> {
            let mut engine = try_state(&self.engine)?;
            anyhow::ensure!(!engine.admissions_frozen(), "App is closing");
            persist(&mut engine.store, key, value)
        })();
        self.terminal_layout.error=result.err().map(|_|"Terminal size is kept for this session but could not be saved. Drag again to retry.".into());
        cx.notify();
    }
    pub(super) fn sync_terminal_resize(&mut self, window: &Window) {
        if self
            .terminal_layout
            .drag
            .as_ref()
            .is_some_and(|drag| drag.right != self.terminal_on_right())
            || self.terminal_visible_thread.is_none()
            || !window.is_window_active()
            || self.media.close_requested
            || self.media.shutdown_requested
        {
            self.terminal_layout.cancel();
        }
    }
}
#[cfg(test)]
mod tests {
    use super::{State, fraction, height, persist, width};
    #[::core::prelude::v1::test]
    fn geometry_follows_swift_proportion_minimums_and_cancelled_drags_never_save() {
        assert_eq!(fraction(f64::NAN), 0.5);
        assert_eq!(width(0.5, 1000.), 500.);
        assert_eq!(width(0.9, 1000.), 580.);
        assert_eq!(width(0.1, 1000.), 320.);
        assert_eq!(height(260., 500.), 260.);
        let mut state = State::default();
        state.begin(true, 500., 600.);
        assert!(!state.move_to(500.));
        assert!(state.finish().is_none());
        state.begin(true, 500., 1000.);
        assert!(state.move_to(550.));
        assert_eq!(state.share, 0.45);
        state.cancel();
        assert_eq!(state.share, 0.5);
        assert!(state.finish().is_none());
        state.begin(false, 500., 500.);
        assert!(state.move_to(600.));
        assert_eq!(state.finish(), Some(("terminalHeight", 160.)));
        assert!(state.finish().is_none());
    }
    #[::core::prelude::v1::test]
    fn completed_resize_changes_only_swift_geometry_key_and_preserves_malformed_documents() {
        let root =
            std::env::temp_dir().join(format!("coincide-terminal-layout-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let mut store = coincide_core::store::Store::open(&root.join("state.sqlite")).unwrap();
        let original = serde_json::json!({"listWidth":288,"inspectorFraction":0.5,"terminalHeight":260,"future":{"keep":true}});
        store.save_document("ui-state.json", &original).unwrap();
        persist(&mut store, "terminalHeight", 300.).unwrap();
        let mut expected = original;
        expected["terminalHeight"] = serde_json::json!(300.);
        assert_eq!(store.document("ui-state.json").unwrap(), Some(expected));
        let malformed = serde_json::json!({"terminalHeight":"future","opaque":true});
        store.save_document("ui-state.json", &malformed).unwrap();
        assert!(persist(&mut store, "inspectorFraction", 0.6).is_err());
        assert_eq!(store.document("ui-state.json").unwrap(), Some(malformed));
        drop(store);
        std::fs::remove_dir_all(root).unwrap();
    }
}
