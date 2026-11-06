//! Swift QuitShortcutGuard parity. Only exact native keyboard events are gated;
//! admitted requests enter the existing menu signal and normal quit/drain path.
//! The GPUI interceptor runs before key bindings (vendor/window.rs dispatch_key_event).
use gpui_kit::{
    AnyElement, App, BorrowAppContext, Context, Empty, Global, InteractiveElement, IntoElement,
    KeyUpEvent, Modifiers, ParentElement, Render, Styled, Window, WindowId,
    base::{Root, RootPlugin},
    div, px, relative, rgb,
};
use serde_json::Value;
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
const HOLD: Duration = Duration::from_secs(1);
const DOUBLE: Duration = Duration::from_millis(1500);
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum Phase {
    #[default]
    Idle,
    Holding(Duration),
    Released(Duration),
    Quitting,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Action {
    None,
    ShowHint,
    HideHint,
    Quit,
}
#[derive(Default)]
struct Decision {
    phase: Phase,
}
impl Decision {
    fn shows_hint(&self) -> bool {
        matches!(self.phase, Phase::Holding(_) | Phase::Released(_))
    }
    fn progress(&self, now: Duration) -> f32 {
        match self.phase {
            Phase::Holding(since) => {
                (now.saturating_sub(since).as_secs_f32() / HOLD.as_secs_f32()).clamp(0., 1.)
            }
            _ => 0.,
        }
    }
    fn quit(&mut self) -> Action {
        self.phase = Phase::Quitting;
        Action::Quit
    }
    fn down(&mut self, now: Duration, repeat: bool) -> Action {
        match self.phase {
            Phase::Quitting if repeat => Action::None,
            Phase::Holding(since) => {
                if now.saturating_sub(since) >= HOLD {
                    self.quit()
                } else {
                    Action::None
                }
            }
            Phase::Released(first) if !repeat && now.saturating_sub(first) <= DOUBLE => self.quit(),
            _ => {
                self.phase = Phase::Holding(now);
                Action::ShowHint
            }
        }
    }
    fn up(&mut self, now: Duration) -> Action {
        match self.phase {
            Phase::Holding(since) if now.saturating_sub(since) >= HOLD => self.quit(),
            Phase::Holding(since) => {
                self.phase = Phase::Released(since);
                Action::None
            }
            Phase::Quitting => {
                self.phase = Phase::Idle;
                Action::None
            }
            _ => Action::None,
        }
    }
    fn tick(&mut self, now: Duration) -> Action {
        match self.phase {
            Phase::Holding(since) if now.saturating_sub(since) >= HOLD => self.quit(),
            Phase::Released(first) if now.saturating_sub(first) > DOUBLE => self.cancel(),
            _ => Action::None,
        }
    }
    fn cancel(&mut self) -> Action {
        let showing = self.shows_hint();
        self.phase = Phase::Idle;
        if showing {
            Action::HideHint
        } else {
            Action::None
        }
    }
}
struct Gate {
    decision: Decision,
    enabled: bool,
    owner: Option<WindowId>,
    origin: Instant,
    requested: Arc<AtomicBool>,
}
impl Global for Gate {}
impl Gate {
    fn apply(&self, action: Action) {
        if action == Action::Quit {
            self.requested.store(true, Ordering::Release);
        }
    }
    fn cancel(&mut self) {
        self.decision.cancel();
        self.owner = None;
    }
}
fn now(cx: &App) -> Duration {
    cx.background_executor()
        .now()
        .saturating_duration_since(cx.global::<Gate>().origin)
}
fn primary(modifiers: Modifiers) -> bool {
    if cfg!(target_os = "macos") {
        modifiers.platform
    } else {
        modifiers.control
    }
}
fn exact_quit(key: &gpui_kit::Keystroke) -> bool {
    key.key.eq_ignore_ascii_case("q")
        && primary(key.modifiers)
        && !key.modifiers.alt
        && !key.modifiers.shift
        && !key.modifiers.function
        && if cfg!(target_os = "macos") {
            !key.modifiers.control
        } else {
            !key.modifiers.platform
        }
}
pub(super) fn configure(settings: &Value, cx: &mut App) {
    let enabled = settings["holdToQuit"].as_bool().unwrap_or(true);
    if cx.has_global::<Gate>() {
        let gate = cx.global_mut::<Gate>();
        gate.enabled = enabled;
        if !enabled {
            gate.cancel();
        }
    }
    cx.refresh_windows();
}
pub(super) fn cancel(cx: &mut App) {
    if cx.has_global::<Gate>() {
        let gate = cx.global_mut::<Gate>();
        // An external menu/native request must hide the HUD without allowing a
        // still-held keyboard repeat to create a second shutdown admission.
        gate.decision.phase = Phase::Quitting;
        gate.owner = None;
    }
    cx.refresh_windows();
}
pub(super) fn install(requested: Arc<AtomicBool>, cx: &mut App) {
    cx.set_global(Gate {
        decision: Decision::default(),
        enabled: true,
        owner: None,
        origin: cx.background_executor().now(),
        requested,
    });
    cx.intercept_keystrokes(|event, window, cx| {
        if !window.is_window_active()
            || !exact_quit(&event.keystroke)
            || event.is_held.is_none()
            || !cx.global::<Gate>().enabled
        {
            return;
        }
        let at = now(cx);
        let owner = window.window_handle().window_id();
        cx.update_global::<Gate, _>(|gate, _| {
            if gate.owner.is_some_and(|previous| previous != owner) {
                gate.cancel();
            }
            gate.owner = Some(owner);
            let action = gate.decision.down(at, event.is_held.unwrap());
            gate.apply(action);
        });
        window.prevent_default();
        cx.stop_propagation();
        cx.refresh_windows();
    })
    .detach();
    Root::register_plugin(cx, |window, cx| {
        cx.observe_window_activation(window, |_, window, cx| {
            if !window.is_window_active() {
                let owner = window.window_handle().window_id();
                cx.update_global::<Gate, _>(|gate, _| {
                    if gate.owner == Some(owner) {
                        gate.cancel();
                    }
                });
                cx.notify();
            }
        })
        .detach();
        Hint
    });
}
struct Hint;
impl RootPlugin for Hint {
    fn decorate(
        &self,
        surface: AnyElement,
        _: &Root,
        _: &mut Window,
        _: &mut App,
    ) -> impl IntoElement {
        div()
            .size_full()
            .capture_key_up(|event: &KeyUpEvent, window, cx| {
                if event.keystroke.key.eq_ignore_ascii_case("q") {
                    release(window, cx);
                }
            })
            .on_modifiers_changed(|event, window, cx| {
                if !primary(event.modifiers) {
                    release(window, cx);
                }
            })
            .child(surface)
    }
}
fn release(window: &mut Window, cx: &mut App) {
    let owner = window.window_handle().window_id();
    let at = now(cx);
    cx.update_global::<Gate, _>(|gate, _| {
        if gate.owner == Some(owner) {
            let action = gate.decision.up(at);
            gate.apply(action);
        }
    });
    cx.refresh_windows();
}
impl Render for Hint {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let owner = window.window_handle().window_id();
        let at = now(cx);
        cx.update_global::<Gate, _>(|gate, _| {
            if gate.owner == Some(owner) {
                if !window.is_window_active() || !gate.enabled {
                    gate.cancel();
                } else {
                    if matches!(gate.decision.phase, Phase::Holding(_))
                        && !primary(window.modifiers())
                    {
                        let action = gate.decision.up(at);
                        gate.apply(action);
                    }
                    let action = gate.decision.tick(at);
                    gate.apply(action);
                }
            }
        });
        let gate = cx.global::<Gate>();
        if gate.owner != Some(owner) || !gate.decision.shows_hint() {
            return Empty.into_any_element();
        }
        let progress = gate.decision.progress(at);
        window.request_animation_frame();
        // No focus handle, mouse handler, occlusion, or text input: the HUD is
        // presentation only and cannot steal the active editor or terminal.
        div()
            .absolute()
            .top(px(38.))
            .left(relative(0.5))
            .ml(px(-140.))
            .w(px(280.))
            .p_4()
            .rounded_lg()
            .bg(rgb(0x232733))
            .text_color(rgb(0xffffff))
            .child(if cfg!(target_os = "macos") {
                "Hold ⌘Q to quit"
            } else {
                "Hold Ctrl+Q to quit"
            })
            .child(
                div()
                    .mt_2()
                    .h(px(3.))
                    .w_full()
                    .bg(rgb(0x454b59))
                    .child(div().h_full().w(relative(progress)).bg(rgb(0x8caaff))),
            )
            .child(div().mt_2().text_sm().child("Or press it again to quit"))
            .into_any_element()
    }
}
#[cfg(test)]
#[path = "quit_shortcut_tests.rs"]
mod tests;
