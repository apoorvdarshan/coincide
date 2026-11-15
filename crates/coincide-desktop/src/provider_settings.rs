//! Legacy Codex account settings; Antigravity uses native API-key accounts.
use super::*;
#[path = "account_settings.rs"]
mod account_settings;

pub(super) struct ProviderSettings {
    pub open: bool,
    codex_open: bool,
    codex: account_settings::AccountSettings,
}

impl ProviderSettings {
    pub fn new(window: &mut Window, cx: &mut Context<Coincide>) -> Self {
        Self {
            open: false,
            codex_open: false,
            codex: account_settings::AccountSettings::new(window, cx),
        }
    }

    pub fn subscriptions(&self, cx: &mut Context<Coincide>) -> Vec<Subscription> {
        self.codex.subscriptions(cx)
    }
}

impl Coincide {
    pub(super) fn open_antigravity_settings(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.settings_open = true;
        self.schedules_open = false;
        self.navigate_settings_section(
            settings::SettingsSection::Provider(
                coincide_core::provider_catalog::ProviderId::Antigravity,
            ),
            window,
            cx,
        );
    }

    pub(super) fn antigravity_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        self.codex_account_settings(cx)
    }
}
