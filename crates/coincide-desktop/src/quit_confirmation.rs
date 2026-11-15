//! Swift `AppDelegate.applicationShouldTerminate`: Quit asks first while
//! agents work or terminal commands run, as Terminal does for running
//! processes. Quitting any other way (the API's `app.quit`) is not held up.
use super::*;

/// The alert's text, or None when nothing would stop.
pub(super) fn reasons(agents: usize, commands: usize) -> Option<String> {
    if agents == 0 && commands == 0 {
        return None;
    }
    let mut reasons = Vec::new();
    match agents {
        0 => {}
        1 => reasons.push("An agent is still working.".to_owned()),
        count => reasons.push(format!("{count} agents are still working.")),
    }
    match commands {
        0 => {}
        1 => reasons.push("A command is still running in a terminal.".to_owned()),
        count => reasons.push(format!("{count} commands are still running in terminals.")),
    }
    reasons.push("Quitting stops them.".into());
    Some(reasons.join(" "))
}

fn work_to_stop(engine: &SharedEngine) -> Option<(usize, usize)> {
    engine
        .try_lock()
        .ok()
        .map(|engine| (engine.running_thread_count(), engine.busy_terminal_count()))
}

impl Coincide {
    /// A Quit request from the menu, its shortcut or the OS: asks first when
    /// work would stop, then continues with the ordinary quit checks.
    pub(super) fn request_quit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.quit_confirmation.is_some() {
            return;
        }
        // A reopened window may not have received its first status snapshot.
        // Use the Engine itself, and retry instead of guessing if it is busy.
        let (agents, commands) = match work_to_stop(&self.engine) {
            Some(work) => work,
            None => {
                self.quit_requested
                    .store(true, std::sync::atomic::Ordering::Release);
                return;
            }
        };
        let Some(detail) = reasons(agents, commands) else {
            self.continue_quit(window, cx);
            return;
        };
        window.activate_window();
        let answer = window.prompt(
            PromptLevel::Warning,
            "Quit Coincide?",
            Some(&detail),
            &["Quit", "Cancel"],
            cx,
        );
        self.quit_confirmation = Some(cx.spawn_in(window, async move |this, cx| {
            let answer = answer.await.unwrap_or(1);
            this.update_in(cx, |this, window, cx| {
                this.quit_confirmation = None;
                if answer == 0 {
                    this.continue_quit(window, cx);
                } else {
                    if let Some(guard) = &this.native_quit {
                        guard.cancel_request();
                    }
                    this.native_quit_observed = false;
                }
                cx.notify();
            })
            .ok();
        }));
    }
    pub(super) fn continue_quit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pending_follow_up.is_some()
            || !self.pending_follow_up_backlog.is_empty()
            || self.ordinary_sends_inflight > 0
            || self.restore_composer.is_some()
        {
            // Keep normal admission open until submitted messages are in the
            // durable queue. Freezing it first would strand the buffer.
            self.quit_after_pending_sends = true;
            self.status = "Saving submitted messages before quitting…".into();
            return;
        }
        if self.instructions_panel.read(cx).has_unsaved_edits(cx) {
            self.prompt_instruction_close(true, window, cx);
        } else {
            self.media.shutdown_requested = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{reasons, work_to_stop};
    use coincide_core::{api::Engine, store::Store};
    use std::sync::{Arc, Mutex};

    #[::core::prelude::v1::test]
    fn the_prompt_names_working_agents_and_running_commands() {
        assert_eq!(reasons(0, 0), None);
        assert_eq!(
            reasons(1, 0).as_deref(),
            Some("An agent is still working. Quitting stops them.")
        );
        assert_eq!(
            reasons(3, 1).as_deref(),
            Some(
                "3 agents are still working. A command is still running in a terminal. Quitting stops them."
            )
        );
        assert_eq!(
            reasons(0, 2).as_deref(),
            Some("2 commands are still running in terminals. Quitting stops them.")
        );
    }

    #[::core::prelude::v1::test]
    fn quit_work_check_retries_while_the_engine_is_busy() {
        let dir = tempfile::tempdir().unwrap();
        let engine = Arc::new(Mutex::new(Engine::new(
            Store::open(&dir.path().join("state.sqlite")).unwrap(),
        )));
        let held = engine.lock().unwrap();
        assert_eq!(work_to_stop(&engine), None);
        drop(held);
        assert_eq!(work_to_stop(&engine), Some((0, 0)));
    }
}
