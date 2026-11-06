//! Actual GPUI/Textarea dispatch, with the production capture wire, Keys and
//! Revision. This is not Coincide::new: that constructor installs native quit,
//! browser/computer-use/media adapters and polling. Scope's app-route flags and
//! listed ticket are explicit fixture inputs; full Root scope remains unproved.
use super::{capture, keys, mentions};
use gpui_kit::component::input::{InputEvent as TextEvent, Textarea, TextareaState};
use gpui_kit::{
    App, AppContext, Bounds, Context, Entity, EntityInputHandler, Focusable, InputEvent,
    InteractiveElement, IntoElement, KeyDownEvent, KeyUpEvent, Keystroke, Modifiers,
    ModifiersChangedEvent, ParentElement, Pixels, Render, Styled, Subscription, TestAppContext,
    VisualTestContext, Window, div, px,
};
use std::ops::Range;

// Plain Up preserves the column at a visual document edge. Give the real
// Textarea two logical rows so the unwired control must actually move upward.
const TEXT: &str = "PREVIOUS SYNTHETIC ROW\nSYNTHETIC 👩🏽‍💻 café 中文 @ suffix";
const CHILD: &str = "COINCIDE_HEADLESS_COMPOSER_DISPATCH_CHILD";

#[derive(Clone, Debug)]
struct Callback {
    source: &'static str,
    key: keys::Key,
    route: bool,
    focused: bool,
    editable: bool,
    ime: bool,
    modified: bool,
    stored_function: bool,
    stored_modifiers: Modifiers,
    same_trigger: bool,
    fresh_results: bool,
    revision: u64,
    ticket_revision: u64,
    generation: u64,
    listed_generation: Option<u64>,
    selection: Range<usize>,
    decision: keys::Decision,
}
#[derive(Clone, Debug)]
struct Snapshot {
    draft: String,
    selection: Range<usize>,
    revision: u64,
    callbacks: Vec<Callback>,
    activated: Vec<usize>,
    press_enter: usize,
    changes: usize,
    ticket_changes: usize,
    selected: Option<usize>,
    input_bounds: Bounds<Pixels>,
    cursor_layout: Option<(Bounds<Pixels>, Pixels)>,
    wrap_rows: usize,
}
struct Harness {
    input: Entity<TextareaState>,
    wired: bool,
    keys: keys::Keys,
    revision: mentions::Revision,
    ticket_revision: u64,
    ticket_selection: Range<usize>,
    thread: &'static str,
    listed_thread: &'static str,
    generation: u64,
    listed_generation: Option<u64>,
    opened: bool,
    route_allowed: bool,
    callbacks: Vec<Callback>,
    activated: Vec<usize>,
    press_enter: usize,
    changes: usize,
    ticket_changes: usize,
    _subscriptions: Vec<Subscription>,
}
impl Harness {
    fn new(wired: bool, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| TextareaState::new(window, cx).submit_on_enter(true));
        let observe = cx.observe(&input, |this, _, cx| {
            let input = this.input.read(cx);
            if this.revision.observe(
                input.value().to_string(),
                input.selected_range(),
                input.is_selection_reversed(),
            ) {
                // The production Picker::observe_composer uses this same
                // Revision result to invalidate an automatic ticket. Record
                // the actual native selection notification, without fabricating
                // a file list, Core authority or a production invalidate call.
                this.ticket_changes += 1;
            }
        });
        let events = cx.subscribe(&input, |this, _, event, _| match event {
            TextEvent::PressEnter { .. } => this.press_enter += 1,
            TextEvent::Change => this.changes += 1,
            _ => {}
        });
        Self {
            input,
            wired,
            keys: Default::default(),
            revision: Default::default(),
            ticket_revision: 0,
            ticket_selection: 0..0,
            thread: "synthetic-one",
            listed_thread: "synthetic-one",
            generation: 1,
            listed_generation: Some(1),
            opened: true,
            route_allowed: true,
            callbacks: Vec::new(),
            activated: Vec::new(),
            press_enter: 0,
            changes: 0,
            ticket_changes: 0,
            _subscriptions: vec![observe, events],
        }
    }
    fn arm(&mut self, cx: &App) {
        self.ticket_selection = self.input.read(cx).selected_range();
        self.ticket_revision = self.revision.get();
        self.keys.listed(3);
        self.callbacks.clear();
        self.press_enter = 0;
        self.changes = 0;
        self.ticket_changes = 0;
    }
    fn snapshot(&self, cx: &App) -> Snapshot {
        Snapshot {
            draft: self.input.read(cx).value().to_string(),
            selection: self.input.read(cx).selected_range(),
            revision: self.revision.get(),
            callbacks: self.callbacks.clone(),
            activated: self.activated.clone(),
            press_enter: self.press_enter,
            changes: self.changes,
            ticket_changes: self.ticket_changes,
            selected: self.keys.selected,
            input_bounds: self.input.read(cx).input_bounds(),
            cursor_layout: self.input.read(cx).cursor_layout(),
            wrap_rows: self.input.read(cx).display_map().wrap_row_count(),
        }
    }
    fn bound(&mut self, key: keys::Key, window: &mut Window, cx: &mut Context<Self>) {
        self.key("bound", key, false, window, cx);
    }
    fn raw(&mut self, key: keys::Key, modified: bool, window: &mut Window, cx: &mut Context<Self>) {
        self.key("raw", key, modified, window, cx);
    }
    fn release(&mut self, key: keys::Key, _: &mut Context<Self>) {
        self.keys.release(key);
    }
    fn key(
        &mut self,
        source: &'static str,
        key: keys::Key,
        modified: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let focused = self.input.read(cx).focus_handle(cx).is_focused(window);
        let selection = self.input.read(cx).selected_range();
        let (editable, ime) = self.input.update(cx, |input, cx| {
            (
                input.is_editable(),
                EntityInputHandler::marked_text_range(input, window, cx).is_some(),
            )
        });
        let scope = keys::Scope {
            thread: self.thread,
            route: window.is_window_active() && self.route_allowed,
            focused,
            editable,
            ime,
            modified,
            browser: false,
            terminal: false,
            automatic: self.opened,
            opened: self.opened,
            same_trigger: self.thread == self.listed_thread
                && self.revision.get() == self.ticket_revision
                && selection == self.ticket_selection,
            fresh_results: self.listed_generation == Some(self.generation),
            busy: false,
            count: 3,
        };
        // This is the production decision function, not a copied implementation.
        let decision = self.keys.decide(key, &scope);
        self.callbacks.push(Callback {
            source,
            key,
            route: scope.route,
            focused: scope.focused,
            editable,
            ime,
            modified,
            stored_function: window.modifiers().function,
            stored_modifiers: window.modifiers(),
            same_trigger: scope.same_trigger,
            fresh_results: scope.fresh_results,
            revision: self.revision.get(),
            ticket_revision: self.ticket_revision,
            generation: self.generation,
            listed_generation: self.listed_generation,
            selection,
            decision,
        });
        match decision {
            keys::Decision::Pass => return,
            keys::Decision::Activate(index) => {
                self.activated.push(index);
                self.opened = false;
            }
            keys::Decision::Dismiss => self.opened = false,
            keys::Decision::Consume | keys::Decision::Select(_) => {}
        }
        window.prevent_default();
        cx.stop_propagation();
    }
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let scope = if self.wired {
            capture::attach(div(), cx, Self::bound, Self::raw, Self::release)
        } else {
            div()
        };
        scope.w(px(560.)).h(px(180.)).child(
            div()
                .id("composer-image-drop")
                .w_full()
                .child(Textarea::new(&self.input).w_full().h(px(110.))),
        )
    }
}
fn setup(cx: &mut TestAppContext, wired: bool) -> (Entity<Harness>, &mut VisualTestContext) {
    assert_eq!(
        std::env::var(CHILD).as_deref(),
        Ok("1"),
        "run the private-child wrapper only"
    );
    cx.update(|cx| {
        gpui_kit::init(cx);
        super::init(cx);
    });
    let (view, cx) = cx.add_window_view(|window, cx| Harness::new(wired, window, cx));
    cx.update(|window, cx| {
        window.activate_window();
        view.update(cx, |this, cx| {
            this.input.update(cx, |input, cx| {
                input.set_value(TEXT, window, cx);
                let caret_utf16 = TEXT[..TEXT.find(" suffix").unwrap()].encode_utf16().count();
                EntityInputHandler::set_selected_text_range(
                    input,
                    caret_utf16..caret_utf16,
                    window,
                    cx,
                );
                input.focus(window, cx);
            });
        });
        render_frame(window, cx);
    });
    cx.run_until_parked();
    cx.update(render_frame);
    view.update(cx, |this, cx| this.arm(cx));
    let measured = read(&view, cx);
    assert!(
        measured.wrap_rows >= 2,
        "actual two-row layout: {measured:#?}"
    );
    assert!(measured.input_bounds.size.width > px(0.));
    assert!(measured.input_bounds.size.height > px(0.));
    let (caret_bounds, line_height) = measured
        .cursor_layout
        .expect("real Textarea must have measured caret geometry before key dispatch");
    assert!(line_height > px(0.) && caret_bounds.size.height > px(0.));
    assert!(measured.selection.start > TEXT.find('\n').unwrap());
    (view, cx)
}
fn read(view: &Entity<Harness>, cx: &VisualTestContext) -> Snapshot {
    view.read_with(cx, |this, cx| this.snapshot(cx))
}
fn assert_current_callback(
    after: &Snapshot,
    before: &Snapshot,
    key: keys::Key,
    decision: keys::Decision,
    native_fn: bool,
) {
    let callback = after
        .callbacks
        .iter()
        .find(|callback| callback.source == "bound" && callback.key == key)
        .unwrap_or_else(|| panic!("missing actual bound callback: {after:#?}"));
    assert!(callback.route && callback.focused && callback.editable);
    assert!(!callback.ime && !callback.modified);
    assert_eq!(callback.stored_function, native_fn);
    assert_eq!(callback.stored_modifiers.function, native_fn);
    assert!(callback.same_trigger && callback.fresh_results);
    assert_eq!(callback.revision, before.revision);
    assert_eq!(callback.ticket_revision, before.revision);
    assert_eq!(callback.listed_generation, Some(callback.generation));
    assert_eq!(callback.selection, before.selection);
    assert_eq!(callback.decision, decision);
}
fn render_frame(window: &mut Window, cx: &mut App) {
    // Public core draw API, also used by Kit's optional test helper. Enabling
    // that helper's feature would unnecessarily resolve its optional Fast tree.
    window.refresh();
    window.draw(cx).clear(cx);
}
fn press(cx: &mut VisualTestContext, key: &str, native_fn: bool) {
    cx.update(|window, cx| {
        if native_fn {
            // macOS stores Function on the window but strips it from normalized
            // arrow keystrokes. Exercise those actual public dispatch inputs.
            let modifiers = Modifiers {
                function: true,
                ..Default::default()
            };
            window.dispatch_event(
                ModifiersChangedEvent {
                    modifiers,
                    capslock: window.capslock(),
                }
                .to_platform_input(),
                cx,
            );
        }
        let keystroke = Keystroke::parse_with_os(key, cx.platform_info().os).unwrap();
        render_frame(window, cx);
        // Actual native control-key events: dispatch bindings without simulated
        // IME text insertion. Every press includes key-up to release custody.
        window.dispatch_event(
            KeyDownEvent {
                keystroke: keystroke.clone(),
                is_held: false,
                prefer_character_input: false,
            }
            .to_platform_input(),
            cx,
        );
        render_frame(window, cx);
        window.dispatch_event(KeyUpEvent { keystroke }.to_platform_input(), cx);
        if native_fn {
            window.dispatch_event(
                ModifiersChangedEvent {
                    modifiers: Default::default(),
                    capslock: window.capslock(),
                }
                .to_platform_input(),
                cx,
            );
        }
        render_frame(window, cx);
    });
    cx.run_until_parked();
}
fn key_down(cx: &mut VisualTestContext, key: &str, is_held: bool) {
    cx.update(|window, cx| {
        let keystroke = Keystroke::parse_with_os(key, cx.platform_info().os).unwrap();
        render_frame(window, cx);
        window.dispatch_event(
            KeyDownEvent {
                keystroke,
                is_held,
                prefer_character_input: false,
            }
            .to_platform_input(),
            cx,
        );
        render_frame(window, cx);
    });
    cx.run_until_parked();
}
fn key_up(cx: &mut VisualTestContext, key: &str) {
    cx.update(|window, cx| {
        let keystroke = Keystroke::parse_with_os(key, cx.platform_info().os).unwrap();
        window.dispatch_event(KeyUpEvent { keystroke }.to_platform_input(), cx);
        render_frame(window, cx);
    });
    cx.run_until_parked();
}

#[gpui_kit::test]
#[ignore = "invoked only by actual_textarea_capture_in_private_child with cleared environment"]
fn headless_unwired_control_moves_caret_and_revokes_revision(cx: &mut TestAppContext) {
    let (view, cx) = setup(cx, false);
    let before = read(&view, cx);
    press(cx, "up", false);
    let after = read(&view, cx);
    eprintln!("unwired native Up: {before:?} -> {after:?}");
    assert_ne!(
        after.selection, before.selection,
        "real Textarea must exercise MoveUp"
    );
    assert!(
        after.selection.end <= TEXT.find('\n').unwrap(),
        "native Up must reach the previous logical row: {after:#?}"
    );
    assert!(after.revision > before.revision);
    assert!(after.ticket_changes > 0);
    assert!(after.callbacks.is_empty());
    assert_eq!(after.draft, TEXT);
    assert_eq!(after.press_enter, 0);
}

#[gpui_kit::test]
#[ignore = "invoked only by actual_textarea_capture_in_private_child with cleared environment"]
fn headless_current_plain_and_native_fn_arrows_keep_actual_caret(cx: &mut TestAppContext) {
    for native_fn in [false, true] {
        let (view, cx) = setup(cx, true);
        let before = read(&view, cx);
        press(cx, "up", native_fn);
        let up = read(&view, cx);
        eprintln!("wired Up, native_fn={native_fn}: {up:#?}");
        assert_eq!(
            up.selection, before.selection,
            "capture must precede native MoveUp; {up:#?}"
        );
        assert_eq!(up.revision, before.revision);
        assert_eq!(up.ticket_changes, 0);
        assert_eq!(
            up.selected,
            Some(2),
            "Up must wrap using production Keys; {up:#?}"
        );
        assert_current_callback(
            &up,
            &before,
            keys::Key::Up,
            keys::Decision::Select(2),
            native_fn,
        );
        press(cx, "down", native_fn);
        let down = read(&view, cx);
        assert_eq!(down.selection, before.selection);
        assert_eq!(down.selected, Some(0));
        assert_eq!(down.draft, TEXT);
        assert_eq!(down.press_enter, 0);
        assert_eq!(down.changes, 0);
        assert_current_callback(
            &down,
            &before,
            keys::Key::Down,
            keys::Decision::Select(0),
            native_fn,
        );
    }
}

#[gpui_kit::test]
#[ignore = "invoked only by actual_textarea_capture_in_private_child with cleared environment"]
fn headless_enter_and_tab_capture_without_submit_or_native_edit(cx: &mut TestAppContext) {
    for key in ["enter", "tab"] {
        let (view, cx) = setup(cx, true);
        let before = read(&view, cx);
        press(cx, key, false);
        let after = read(&view, cx);
        eprintln!("wired activation {key}: {after:#?}");
        assert_eq!(
            after.activated,
            vec![0],
            "real input action must reach production capture wire"
        );
        assert_eq!(
            after.press_enter, 0,
            "capture must precede InputEvent::PressEnter"
        );
        assert_eq!(
            after.draft, TEXT,
            "wire harness never completes text or inserts tab/newline"
        );
        assert_eq!(after.selection, before.selection);
        assert_eq!(after.changes, 0);
        assert_eq!(after.revision, before.revision);
        assert_eq!(after.ticket_changes, 0);
        assert_current_callback(
            &after,
            &before,
            if key == "enter" {
                keys::Key::Enter
            } else {
                keys::Key::Tab
            },
            keys::Decision::Activate(0),
            false,
        );
    }
}

#[gpui_kit::test]
#[ignore = "invoked only by actual_textarea_capture_in_private_child with cleared environment"]
fn headless_stale_thread_generation_route_and_real_ime_do_not_take_keys(cx: &mut TestAppContext) {
    for stale in ["thread", "generation", "route", "ime"] {
        let (view, cx) = setup(cx, true);
        cx.update(|window, cx| {
            view.update(cx, |this, cx| match stale {
                "thread" => this.thread = "synthetic-other",
                "generation" => this.listed_generation = None,
                "route" => this.route_allowed = false,
                "ime" => this.input.update(cx, |input, cx| {
                    EntityInputHandler::replace_and_mark_text_in_range(
                        input,
                        None,
                        "候",
                        Some(1..1),
                        window,
                        cx,
                    )
                }),
                _ => unreachable!(),
            })
        });
        cx.run_until_parked();
        press(cx, "up", false);
        let after = read(&view, cx);
        eprintln!("ownership veto {stale}: {after:#?}");
        assert!(after.activated.is_empty());
        assert_eq!(after.selected, Some(0));
        assert!(
            !after.callbacks.is_empty(),
            "actual callback path must be recorded even for vetoes"
        );
        assert!(after.callbacks.iter().any(|callback| match stale {
            "thread" => !callback.same_trigger,
            "generation" => !callback.fresh_results,
            "route" => !callback.route,
            "ime" => callback.ime,
            _ => unreachable!(),
        }));
        assert!(
            after
                .callbacks
                .iter()
                .all(|c| c.decision == keys::Decision::Pass)
        );
        if stale == "ime" {
            assert!(
                after.callbacks.iter().any(|c| c.ime),
                "must use real marked-text input state"
            );
        }
    }
}

#[gpui_kit::test]
#[ignore = "invoked only by actual_textarea_capture_in_private_child with cleared environment"]
fn headless_event_arrows_are_independent_of_stale_cached_modifiers(cx: &mut TestAppContext) {
    // A genuinely modified event must retain native Textarea ownership. These
    // are public input bindings, not synthetic calls to Keys::decide.
    #[cfg(target_os = "macos")]
    let modified_keys: &[&str] = &["shift-up", "shift-down", "cmd-up", "cmd-down"];
    #[cfg(not(target_os = "macos"))]
    let modified_keys: &[&str] = &["shift-up", "shift-down"];
    for key in modified_keys {
        let (view, cx) = setup(cx, true);
        let before = read(&view, cx);
        press(cx, key, false);
        let after = read(&view, cx);
        eprintln!("actual modified native binding {key}: {before:#?} -> {after:#?}");
        assert_eq!(after.draft, TEXT);
        assert_eq!(after.selected, Some(0));
        assert!(after.activated.is_empty());
        assert!(
            after
                .callbacks
                .iter()
                .all(|c| c.decision == keys::Decision::Pass)
        );
        assert_ne!(after.selection, before.selection);
        assert!(after.revision > before.revision && after.ticket_changes > 0);
        assert_eq!(after.press_enter, 0);
    }

    // Keep every changed-state observation before asserting the desired
    // behavior, so the first failing cache condition does not hide the others.
    let mut observations = Vec::new();
    for (label, modifiers) in [
        (
            "cached-Command",
            Modifiers {
                platform: true,
                ..Default::default()
            },
        ),
        (
            "cached-Shift",
            Modifiers {
                shift: true,
                ..Default::default()
            },
        ),
    ] {
        for key in ["up", "down"] {
            let (view, cx) = setup(cx, true);
            let before = read(&view, cx);
            cx.update(|window, cx| {
                window.dispatch_event(
                    ModifiersChangedEvent {
                        modifiers,
                        capslock: window.capslock(),
                    }
                    .to_platform_input(),
                    cx,
                );
                render_frame(window, cx);
            });
            cx.run_until_parked();
            let seeded = read(&view, cx);
            assert_eq!(seeded.draft, before.draft);
            assert_eq!(seeded.selection, before.selection);
            assert_eq!(seeded.revision, before.revision);
            // Deliberately send an unmodified event without a clearing flags
            // event. The action matcher reads this event; Window retains the
            // earlier flags, matching the source seam under investigation.
            press(cx, key, false);
            let after = read(&view, cx);
            eprintln!("unmodified {key} with {label}: {before:#?} -> {after:#?}");
            observations.push((label, key, modifiers, before, after));
        }
    }
    for (label, key, modifiers, before, after) in observations {
        let (key, decision) = if key == "up" {
            (keys::Key::Up, keys::Decision::Select(2))
        } else {
            (keys::Key::Down, keys::Decision::Select(1))
        };
        assert!(
            after
                .callbacks
                .iter()
                .any(|c| c.source == "bound" && c.key == key && c.stored_modifiers == modifiers),
            "real cached flags must reach callback: {label} {after:#?}"
        );
        assert_current_callback(&after, &before, key, decision, false);
        assert_eq!(
            after.selection, before.selection,
            "plain event must be captured despite {label}"
        );
        assert_eq!(after.revision, before.revision);
        assert_eq!(after.ticket_changes, 0);
        assert_eq!(after.draft, TEXT);
        assert_eq!(after.press_enter, 0);
    }
}

#[gpui_kit::test]
#[ignore = "invoked only by actual_textarea_capture_in_private_child with cleared environment"]
fn headless_builtin_alias_programmatic_and_inactive_ime_fallbacks(cx: &mut TestAppContext) {
    use gpui_kit::component::input::{Enter, MoveUp};
    // An explicit alternate binding to the public Input action must not become
    // a file-suggestion action. Ctrl-P is a fixture alias, not a default claim.
    let (view, vcx) = setup(cx, true);
    vcx.update(|_, cx| cx.bind_keys([gpui_kit::KeyBinding::new("ctrl-p", MoveUp, Some("Input"))]));
    let before = read(&view, vcx);
    press(vcx, "ctrl-p", false);
    let alias = read(&view, vcx);
    eprintln!("alternate builtin MoveUp binding: {before:#?} -> {alias:#?}");
    assert!(alias.callbacks.is_empty());
    assert_eq!(alias.selected, Some(0));
    assert!(alias.activated.is_empty());
    assert!(alias.selection.end <= TEXT.find('\n').unwrap());
    assert!(alias.revision > before.revision);
    assert_eq!(alias.draft, TEXT);

    for enter in [false, true] {
        let (view, vcx) = setup(cx, true);
        let before = read(&view, vcx);
        vcx.update(|window, cx| {
            if enter {
                window.dispatch_action(
                    Box::new(Enter {
                        secondary: false,
                        shift: false,
                    }),
                    cx,
                );
            } else {
                window.dispatch_action(Box::new(MoveUp), cx);
            }
        });
        vcx.run_until_parked();
        vcx.update(render_frame);
        let after = read(&view, vcx);
        eprintln!("programmatic builtin action, enter={enter}: {before:#?} -> {after:#?}");
        assert!(after.callbacks.is_empty());
        assert!(after.activated.is_empty());
        assert_eq!(after.selected, Some(0));
        assert_eq!(after.draft, TEXT);
        if enter {
            assert_eq!(after.press_enter, 1);
            assert_eq!(after.selection, before.selection);
        } else {
            assert!(after.selection.end <= TEXT.find('\n').unwrap());
            assert!(after.revision > before.revision);
            assert_eq!(after.press_enter, 0);
        }
    }

    let (view, vcx) = setup(cx, true);
    let before = read(&view, vcx);
    vcx.deactivate_window();
    vcx.update(|window, cx| {
        assert!(
            !window.is_window_active(),
            "actual test-platform deactivation must precede input"
        );
        render_frame(window, cx);
    });
    press(vcx, "up", false);
    let inactive = read(&view, vcx);
    eprintln!("actual inactive Window fallback: {before:#?} -> {inactive:#?}");
    assert!(
        inactive
            .callbacks
            .iter()
            .any(|c| c.source == "bound" && !c.route)
    );
    assert!(
        inactive
            .callbacks
            .iter()
            .all(|c| c.decision == keys::Decision::Pass)
    );
    assert!(inactive.activated.is_empty());
    assert_eq!(inactive.selected, Some(0));
    assert!(inactive.selection.end <= TEXT.find('\n').unwrap());
    assert!(inactive.revision > before.revision);
    assert_eq!(inactive.draft, TEXT);

    // Compare wired IME fallback with the real unwired Textarea, avoiding an
    // invented caret/composition policy in the test harness.
    let mut ime = Vec::new();
    for wired in [false, true] {
        let (view, vcx) = setup(cx, wired);
        vcx.update(|window, cx| {
            view.update(cx, |this, cx| {
                this.input.update(cx, |input, cx| {
                    EntityInputHandler::replace_and_mark_text_in_range(
                        input,
                        None,
                        "候",
                        Some(1..1),
                        window,
                        cx,
                    )
                });
            })
        });
        vcx.run_until_parked();
        let before = read(&view, vcx);
        press(vcx, "up", false);
        let after = read(&view, vcx);
        eprintln!("real IME Input fallback, wired={wired}: {before:#?} -> {after:#?}");
        assert!(after.activated.is_empty());
        assert_eq!(after.selected, Some(0));
        if wired {
            assert!(after.callbacks.iter().any(|c| c.source == "bound" && c.ime));
            assert!(
                after
                    .callbacks
                    .iter()
                    .all(|c| c.decision == keys::Decision::Pass)
            );
        }
        ime.push((before, after));
    }
    assert_eq!(ime[0].0.draft, ime[1].0.draft);
    assert_eq!(ime[0].1.draft, ime[1].1.draft);
    assert_eq!(ime[0].1.selection, ime[1].1.selection);
    assert_eq!(
        ime[0].1.revision - ime[0].0.revision,
        ime[1].1.revision - ime[1].0.revision
    );
    assert_eq!(ime[0].1.press_enter, ime[1].1.press_enter);
}

#[gpui_kit::test]
#[ignore = "invoked only by actual_textarea_capture_in_private_child with cleared environment"]
fn headless_closed_pane_keeps_held_activation_until_real_key_up(cx: &mut TestAppContext) {
    for key in ["enter", "tab"] {
        let (view, vcx) = setup(cx, true);
        let before = read(&view, vcx);
        key_down(vcx, key, false);
        let chosen = read(&view, vcx);
        assert_eq!(chosen.activated, vec![0]);
        for _ in 0..3 {
            key_down(vcx, key, true);
        }
        let held = read(&view, vcx);
        eprintln!("held {key} through closed pane: {held:#?}");
        assert_eq!(held.activated, vec![0]);
        assert_eq!(held.press_enter, 0);
        assert_eq!(held.changes, 0);
        assert_eq!(held.draft, TEXT);
        assert_eq!(held.selection, before.selection);
        assert_eq!(held.revision, before.revision);
        assert!(
            held.callbacks
                .iter()
                .filter(|c| c.source == "bound" && c.decision == keys::Decision::Consume)
                .count()
                >= 3
        );
        key_up(vcx, key);
        // After physical release the still-closed pane must not keep the key:
        // Enter reaches PressEnter, Tab reaches the real native indent action.
        press(vcx, key, false);
        let released = read(&view, vcx);
        eprintln!("released {key} on closed pane: {released:#?}");
        assert_eq!(released.activated, vec![0]);
        if key == "enter" {
            assert_eq!(released.press_enter, 1);
            assert_eq!(released.draft, TEXT);
        } else {
            assert_ne!(released.draft, TEXT);
            assert!(released.changes > 0);
            assert_eq!(released.press_enter, 0);
        }
    }
}

#[::core::prelude::v1::test]
fn actual_textarea_capture_in_private_child() {
    use std::{fs, process::Command};
    let base = std::env::temp_dir().join(format!(
        "coincide-textarea-dispatch-{}",
        uuid::Uuid::new_v4()
    ));
    fs::create_dir(&base).unwrap();
    for name in ["home", "tmp", "empty-path"] {
        fs::create_dir(base.join(name)).unwrap();
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&base, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "composer_file_picker::dispatch_tests::headless_",
            "--nocapture",
            "--test-threads=1",
        ])
        .env_clear()
        .env(CHILD, "1")
        .env("HOME", base.join("home"))
        .env("TMPDIR", base.join("tmp"))
        .env("PATH", base.join("empty-path"))
        .env("LANG", "en_US.UTF-8")
        .current_dir(&base)
        .output()
        .unwrap();
    fs::remove_dir_all(&base).unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    print!("{stdout}");
    eprint!("{stderr}");
    assert!(
        output.status.success(),
        "actual headless dispatch child failed\n{stdout}\n{stderr}"
    );
    assert!(
        stdout.contains("7 passed"),
        "all seven actual-dispatch cases must run\n{stdout}\n{stderr}"
    );
}
