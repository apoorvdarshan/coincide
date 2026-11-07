//! Route an agent's saved-login request into native UI; no agent authorization,
//! manager command, secret, private permit or raw provider output crosses here.
use super::*;

impl Coincide {
    pub(super) fn request_browser_login(
        &mut self,
        request: coincide_core::browser_protocol::BrowserRequest,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let result = (|| -> Result<()> {
            let BrowserAction::FillLogin { item } = &request.action else {
                anyhow::bail!("Invalid native login request")
            };
            anyhow::ensure!(
                self.selected.as_ref().is_some_and(
                    |selected| selected["id"].as_str() == Some(request.thread_id.as_str())
                ),
                "Select this conversation before requesting native login approval"
            );
            anyhow::ensure!(
                self.credential_panel
                    .update(cx, |panel, _| panel.can_accept_browser_request()),
                "Finish the current native login request, or configure a password manager first"
            );
            let browser = self
                .browser
                .as_ref()
                .context("Native browser is unavailable")?;
            anyhow::ensure!(
                browser.credential_fill_available(),
                "Private credential filling is unavailable on this browser backend"
            );
            let page = browser
                .credential_page(&request.thread_id, cx)
                .context("Open a settled HTTPS page before requesting a saved login")?;
            anyhow::ensure!(
                request.tab.as_deref().is_none_or(|tab| tab == page.tab),
                "Select the requested browser tab before native login approval"
            );
            self.dismiss_palette(window, cx);
            self.settings_open = true;
            self.navigate_settings_section(settings::SettingsSection::Browser, window, cx);
            self.browser_settings_open = false;
            self.credentials_open = true;
            self.sync_credentials(cx);
            let accepted = self.credential_panel.update(cx, |panel, cx| {
                panel.request_from_browser(&request, item.clone(), cx)
            });
            anyhow::ensure!(accepted, "The native login approval context is unavailable");
            self.show_settings_window(cx);
            cx.notify();
            Ok(())
        })();
        if let Err(error) = result {
            // Every message above is fixed product text, never a vault/SDK error.
            self.browser_replies
                .push(coincide_core::browser_protocol::BrowserReply {
                    id: request.id,
                    thread_id: request.thread_id,
                    result: json!({"error":error.to_string()}),
                });
        }
    }
}
