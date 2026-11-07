//! Edit › Undo for inbox operations, as Swift's `MainWindow` and `ThreadInbox`:
//! with no text field to undo in, Command-Z (Control-Z elsewhere) undoes the
//! latest thread archive, settle, bulk change, move or deletion, wherever the
//! focus is. Each operation keeps its own Core receipt; this only orders them.
//! Redo is not offered: Core receipts are single-use and scoped to the change
//! they undo, so a repeat needs a fresh review.
use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// A stamp later than every earlier one, for the receipt just made.
pub(super) fn stamp() -> u64 {
    SEQUENCE.fetch_add(1, Ordering::Relaxed) + 1
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Receipt {
    Bulk,
    Lifecycle,
    Settle,
    Archive,
}

/// The most recent of the receipts that are still available.
fn latest(available: &[(Receipt, Option<u64>)]) -> Option<Receipt> {
    available
        .iter()
        .filter_map(|(receipt, stamp)| stamp.map(|stamp| (stamp, *receipt)))
        .max_by_key(|(stamp, _)| *stamp)
        .map(|(_, receipt)| receipt)
}

/// One conversation archived or restored from its row, the toolbar or the menu.
struct Archived {
    id: String,
    archived: bool,
    stamp: u64,
}

#[derive(Default)]
pub(super) struct State {
    archived: Option<Archived>,
    pub(super) settle_stamp: u64,
}

/// Command-Z alone, the platform's Undo, not a text field's.
fn is_undo(key: &Keystroke) -> bool {
    let command = if cfg!(target_os = "macos") {
        key.modifiers.platform && !key.modifiers.control
    } else {
        key.modifiers.control && !key.modifiers.platform
    };
    command && !key.modifiers.alt && !key.modifiers.shift && key.key.eq_ignore_ascii_case("z")
}

impl Coincide {
    /// Records an archive or restore so Command-Z can put it back.
    pub(super) fn remember_archive(&mut self, id: &str, archived: bool) {
        self.inbox_undo.archived = Some(Archived {
            id: id.to_owned(),
            archived,
            stamp: stamp(),
        });
    }
    /// Command-Z outside text fields and the terminal: undoes the latest inbox
    /// operation. Returns whether it handled the key.
    pub(super) fn inbox_undo_shortcut(
        &mut self,
        event: &KeyDownEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if event.is_held || !window.is_window_active() || !is_undo(&event.keystroke) {
            return false;
        }
        // A focused text field, the composer included, undoes its own typing.
        if window
            .context_stack()
            .iter()
            .any(|context| context.contains("Input"))
        {
            return false;
        }
        let terminal_owns = self
            .terminal_visible_thread
            .as_ref()
            .and_then(|id| self.terminal_workspaces.get(id))
            .is_some_and(|workspace| workspace.read(cx).is_focused(window));
        if terminal_owns
            || self.command_palette.read(cx).is_open()
            || self.media.close_requested
            || self.media.shutdown_requested
        {
            return false;
        }
        let receipt = latest(&[
            (Receipt::Bulk, self.thread_bulk.undo_stamp()),
            (Receipt::Lifecycle, self.sidebar_lifecycle.undo_stamp()),
            (
                Receipt::Settle,
                self.sidebar_settle_undo
                    .is_some()
                    .then_some(self.inbox_undo.settle_stamp),
            ),
            (
                Receipt::Archive,
                self.inbox_undo
                    .archived
                    .as_ref()
                    .map(|archived| archived.stamp),
            ),
        ]);
        match receipt {
            Some(Receipt::Bulk) => self.undo_bulk(cx),
            Some(Receipt::Lifecycle) => self.undo_sidebar_lifecycle(window, cx),
            Some(Receipt::Settle) => self.undo_sidebar_settle(cx),
            Some(Receipt::Archive) => self.undo_archive(cx),
            None => return false,
        }
        cx.stop_propagation();
        true
    }
    fn undo_archive(&mut self, cx: &mut Context<Self>) {
        let Some(archived) = self.inbox_undo.archived.take() else {
            return;
        };
        let current = self
            .sidebar_all_threads
            .iter()
            .find(|thread| thread.id.eq_ignore_ascii_case(&archived.id));
        // Only the change it recorded: a later restore or archive wins, and an
        // undo never archives a conversation that started new work since.
        let unchanged = current.is_some_and(|thread| thread.archived == archived.archived);
        if !unchanged || (!archived.archived && self.running.contains(&archived.id)) {
            self.status = "Conversation changed since then; Undo was not applied.".into();
            cx.notify();
            return;
        }
        self.patch_navigation(
            &archived.id,
            json!({"isArchived":!archived.archived}),
            if archived.archived {
                "Conversation restored."
            } else {
                "Conversation archived."
            },
            cx,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn the_latest_available_receipt_is_undone_first() {
        let first = stamp();
        let second = stamp();
        assert!(second > first);
        assert_eq!(
            latest(&[
                (Receipt::Bulk, Some(first)),
                (Receipt::Archive, Some(second)),
                (Receipt::Settle, None),
            ]),
            Some(Receipt::Archive)
        );
        assert_eq!(
            latest(&[(Receipt::Lifecycle, Some(first)), (Receipt::Archive, None)]),
            Some(Receipt::Lifecycle)
        );
        assert_eq!(latest(&[(Receipt::Bulk, None)]), None);
    }

    #[::core::prelude::v1::test]
    fn only_the_platform_undo_chord_is_claimed() {
        let parse = |text: &'static str| Keystroke::parse(text).unwrap();
        let undo = if cfg!(target_os = "macos") {
            "cmd-z"
        } else {
            "ctrl-z"
        };
        assert!(is_undo(&parse(undo)));
        for other in [
            if cfg!(target_os = "macos") {
                "cmd-shift-z"
            } else {
                "ctrl-shift-z"
            },
            if cfg!(target_os = "macos") {
                "cmd-alt-z"
            } else {
                "ctrl-alt-z"
            },
            "z",
            if cfg!(target_os = "macos") {
                "cmd-y"
            } else {
                "ctrl-y"
            },
        ] {
            assert!(!is_undo(&parse(other)), "{other}");
        }
    }
}
