//! The main window's side of the app shell, on its ordinary tick: Dock menu
//! requests, the Dock badge, a second copy's hand-off and the starter bots
//! Swift adds after the first provider check.
use super::*;

impl Coincide {
    pub(super) fn poll_app_shell(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        app_shell::update_menu(app_shell::recent_threads(&self.sidebar_all_threads), cx);
        for request in app_shell::take_requests(cx) {
            // Swift activates Coincide before opening the picked thread.
            cx.activate(true);
            window.activate_window();
            match request {
                app_shell::DockRequest::NewThread => self.new_thread(window, cx),
                app_shell::DockRequest::OpenThread(id) => self.select(&id, window, cx),
            }
        }
        let Ok(mut engine) = self.engine.try_lock() else {
            return;
        };
        let activate = std::mem::take(&mut engine.activation_requested);
        // Once, now that discovery knows which agents are installed.
        if !self.starter_bots_checked {
            match engine.add_starter_bots_if_needed() {
                Ok(None) => {}
                Ok(Some(_)) => self.starter_bots_checked = true,
                Err(error) => {
                    self.starter_bots_checked = true;
                    self.status = format!("Starter bots were not added: {error}");
                }
            }
        }
        drop(engine);
        if activate {
            cx.activate(true);
            window.activate_window();
        }
    }
}
