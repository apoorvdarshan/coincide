use super::{TransientEditError, TransientReplacement, TransientScope};
use crate::input::{InputEvent, Redo, TextareaState, Undo};
use gpui::{
    AppContext, Context, Entity, IntoElement, Render, Subscription, TestAppContext, Window,
    WindowHandle,
};
use std::{cell::Cell, rc::Rc};
struct Harness {
    input: Entity<TextareaState>,
    _changes: Subscription,
}
impl Render for Harness {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        self.input.clone()
    }
}
fn setup(
    cx: &mut TestAppContext,
) -> (
    Entity<TextareaState>,
    WindowHandle<Harness>,
    Rc<Cell<usize>>,
) {
    let changes = Rc::new(Cell::new(0));
    let mut input = None;
    let handle = cx.update(|cx| {
        cx.open_window(Default::default(), |window, cx| {
            cx.set_global(crate::Theme::default());
            crate::input::init(cx);
            let field = cx.new(|cx| TextareaState::new(window, cx));
            input = Some(field.clone());
            cx.new(|cx| {
                let counter = changes.clone();
                let subscription = cx.subscribe(&field, move |_, _, event, _| {
                    if matches!(event, InputEvent::Change) {
                        counter.set(counter.get() + 1);
                    }
                });
                Harness {
                    input: field,
                    _changes: subscription,
                }
            })
        })
        .unwrap()
    });
    (input.unwrap(), handle, changes)
}
#[gpui::test]
fn native_transient_preview_restores_original_and_keeps_one_final_undo(cx: &mut TestAppContext) {
    let (input, handle, changes) = setup(cx);
    handle
        .update(cx, |_, window, cx| {
            input.update(cx, |state, cx| {
                state.focus_handle.focus(window, cx);
                state.set_value("old", window, cx);
                state.replace_all("before 🦀 after", window, cx);
                state.set_selected_range(7..11, cx);
                let mut receipt = state.native_text_revision(cx);
                let mut end = 11;
                for text in ["合成", "合成 café", "合成 café 👩🏽‍💻"] {
                    let expected = state.value().to_string();
                    let previous_end = end;
                    end = 7 + text.len();
                    receipt = state
                        .replace_without_undo(
                            &receipt,
                            TransientReplacement {
                                expected: &expected,
                                range: 7..previous_end,
                                replacement: text,
                                selection_after: end..end,
                                reversed: false,
                            },
                            window,
                            cx,
                        )
                        .unwrap();
                    assert!(state.matches_native_text_revision(&receipt, cx));
                    assert!(state.focus_handle.is_focused(window));
                }
                let expected = state.value().to_string();
                state
                    .replace_without_undo(
                        &receipt,
                        TransientReplacement {
                            expected: &expected,
                            range: 7..end,
                            replacement: "🦀",
                            selection_after: 7..11,
                            reversed: false,
                        },
                        window,
                        cx,
                    )
                    .unwrap();
                assert_eq!(state.value(), "before 🦀 after");
                state.replace_all("before final after", window, cx);
                state.undo(&Undo, window, cx);
                assert_eq!(state.value(), "before 🦀 after");
                state.undo(&Undo, window, cx);
                assert_eq!(state.value(), "old");
                state.redo(&Redo, window, cx);
                assert_eq!(state.value(), "before 🦀 after");
                state.redo(&Redo, window, cx);
                assert_eq!(state.value(), "before final after");
                assert!(state.focus_handle.is_focused(window));
            })
        })
        .unwrap();
    assert_eq!(
        changes.get(),
        6,
        "transient edits must not emit user Change events or leave event delivery muted"
    );
}
#[gpui::test]
fn native_transient_source_roundtrip_readonly_ime_and_graphemes_are_rejected(
    cx: &mut TestAppContext,
) {
    let (input, handle, _) = setup(cx);
    handle
        .update(cx, |_, window, cx| {
            input.update(cx, |state, cx| {
                state.set_value("before 👩🏽‍💻 after", window, cx);
                state.set_selected_range(7..7, cx);
                let original = state.value().to_string();
                let receipt = state.native_text_revision(cx);
                assert!(matches!(
                    state.replace_without_undo(
                        &receipt,
                        TransientReplacement {
                            expected: &original,
                            range: 8..8,
                            replacement: "x",
                            selection_after: 9..9,
                            reversed: false
                        },
                        window,
                        cx
                    ),
                    Err(TransientEditError::Bounds)
                ));
                state.readonly = true;
                assert!(matches!(
                    state.replace_without_undo(
                        &receipt,
                        TransientReplacement {
                            expected: &original,
                            range: 7..7,
                            replacement: "x",
                            selection_after: 8..8,
                            reversed: false
                        },
                        window,
                        cx
                    ),
                    Err(TransientEditError::NotEditable)
                ));
                state.readonly = false;
                state.ime_marked_range = Some((7..7).into());
                state.ime_original_text = Some(state.text.clone());
                assert!(matches!(
                    state.replace_without_undo(
                        &receipt,
                        TransientReplacement {
                            expected: &original,
                            range: 7..7,
                            replacement: "x",
                            selection_after: 8..8,
                            reversed: false
                        },
                        window,
                        cx
                    ),
                    Err(TransientEditError::Composition)
                ));
                assert!(state.ime_marked_range.is_some());
                state.ime_marked_range = None;
                state.ime_original_text = None;
                state.replace_all("different", window, cx);
                state.replace_all(original.clone(), window, cx);
                state.set_selected_range(7..7, cx);
                assert!(matches!(
                    state.replace_without_undo(
                        &receipt,
                        TransientReplacement {
                            expected: &original,
                            range: 7..7,
                            replacement: "x",
                            selection_after: 8..8,
                            reversed: false
                        },
                        window,
                        cx
                    ),
                    Err(TransientEditError::Changed)
                ));
                assert_eq!(state.value(), original);
            })
        })
        .unwrap();
}
#[gpui::test]
fn native_transient_scope_restores_history_and_event_flags_on_unwind(cx: &mut TestAppContext) {
    let (input, handle, changes) = setup(cx);
    handle
        .update(cx, |_, window, cx| {
            input.update(cx, |state, cx| {
                state.set_value("first", window, cx);
                state.replace_all("second", window, cx);
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    let scope = TransientScope::new(state);
                    assert!(scope.undo_manager.is_ignoring());
                    assert!(!scope.emit_events);
                    panic!("synthetic transient unwind");
                }));
                assert!(result.is_err());
                assert!(!state.undo_manager.is_ignoring());
                assert!(state.emit_events);
                assert!(!state.silent_replace_text);
                state.undo(&Undo, window, cx);
                assert_eq!(state.value(), "first");
                state.replace_all("third", window, cx);
                state.undo(&Undo, window, cx);
                assert_eq!(state.value(), "first");
            })
        })
        .unwrap();
    assert_eq!(
        changes.get(),
        4,
        "ordinary changes/undo keep emitting after unwind"
    );
}

#[gpui::test]
fn native_transient_receipt_cannot_cross_entities_or_erase_token_metadata(cx: &mut TestAppContext) {
    let (input, handle, changes) = setup(cx);
    handle
        .update(cx, |_, window, cx| {
            let receipt = input.update(cx, |state, cx| {
                state.set_value("draft", window, cx);
                state.native_text_revision(cx)
            });
            let other = cx.new(|cx| TextareaState::new(window, cx));
            other.update(cx, |state, cx| {
                state.set_value("draft", window, cx);
                assert!(matches!(
                    state.replace_without_undo(
                        &receipt,
                        TransientReplacement {
                            expected: "draft",
                            range: 0..0,
                            replacement: "x",
                            selection_after: 1..1,
                            reversed: false
                        },
                        window,
                        cx
                    ),
                    Err(TransientEditError::Changed)
                ));
                assert_eq!(state.value(), "draft");
            });
            input.update(cx, |state, cx| {
                state
                    .replace_range_with_token(
                        0..5,
                        crate::input::InlineToken::new("fixture-file", "@file"),
                        window,
                        cx,
                    )
                    .unwrap();
                let expected = state.value().to_string();
                let spans = state.token_spans().to_vec();
                let receipt = state.native_text_revision(cx);
                assert!(matches!(
                    state.replace_without_undo(
                        &receipt,
                        TransientReplacement {
                            expected: &expected,
                            range: 0..5,
                            replacement: "x",
                            selection_after: 1..1,
                            reversed: false
                        },
                        window,
                        cx
                    ),
                    Err(TransientEditError::Unsupported)
                ));
                assert_eq!(state.value(), expected);
                assert_eq!(state.token_spans(), spans);
            });
        })
        .unwrap();
    assert_eq!(
        changes.get(),
        1,
        "only the ordinary token insertion emits Change"
    );
}
