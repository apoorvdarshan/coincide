//! "Sign in to github.com as octocat with your Bitwarden passkey?" and "Passkeys
//! aren't available" above the page, and their two settings, as the Swift app's
//! passkey sheet, `PreviewPasskeyBanner` and Settings › Browser › Passwords have
//! them. Native UI only: agents and pages can't click these.
use super::*;
use browser::passkeys::Preferences;
use gpui_kit::component::switch::Switch;
impl Coincide {
    pub(super) fn browser_passkey_banner(&mut self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let thread = self.selected.as_ref().map(|thread| text(thread, "id"))?;
        let browser = self.browser.as_ref()?;
        if let Some(prompt) = browser.passkey_prompt(&thread) {
            let (sign_in, cancel, id) = (prompt.id, prompt.id, prompt.id);
            return Some(
                div()
                    .id("browser-passkey-sign-in")
                    .flex()
                    .flex_col()
                    .flex_shrink_0()
                    .gap_2()
                    .p_3()
                    .border_b_1()
                    .border_color(self.color(0x364152))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(prompt.title))
                    .when(!prompt.detail.is_empty(), |pane| {
                        pane.child(div().text_sm().child(prompt.detail))
                    })
                    .when(!prompt.accounts.is_empty(), |pane| {
                        pane.child(
                            div().flex().flex_wrap().gap_1().children(
                                prompt
                                    .accounts
                                    .into_iter()
                                    .enumerate()
                                    .map(|(index, label)| {
                                        let chosen = index == prompt.selected;
                                        Button::new(SharedString::from(format!(
                                            "browser-passkey-account-{index}"
                                        )))
                                        .label(if chosen {
                                            format!("✓ {label}")
                                        } else {
                                            label
                                        })
                                        .disabled(prompt.busy)
                                        .on_click(
                                            cx.listener(move |this, _, _, cx| {
                                                if let Some(browser) = &mut this.browser {
                                                    browser.select_passkey_account(id, index);
                                                }
                                                cx.notify();
                                            }),
                                        )
                                    }),
                            ),
                        )
                    })
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                Button::new("browser-passkey-sign-in-button")
                                    .label("Sign In")
                                    .disabled(prompt.busy)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if let Some(browser) = &mut this.browser {
                                            browser.answer_passkey_prompt(sign_in, true);
                                        }
                                        cx.notify();
                                    })),
                            )
                            .child(
                                Button::new("browser-passkey-cancel")
                                    .label("Cancel")
                                    .disabled(prompt.busy)
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        if let Some(browser) = &mut this.browser {
                                            browser.answer_passkey_prompt(cancel, false);
                                        }
                                        cx.notify();
                                    })),
                            ),
                    )
                    .into_any_element(),
            );
        }
        let (message, action) = browser.passkey_notice(&thread)?;
        let open_thread = thread.clone();
        Some(
            div()
                .id("browser-passkey-notice")
                .flex()
                .flex_shrink_0()
                .gap_2()
                .p_3()
                .border_b_1()
                .border_color(self.color(0x364152))
                .child(
                    div()
                        .flex()
                        .flex_col()
                        .flex_1()
                        .min_w_0()
                        .gap_2()
                        .child(div().text_sm().child(message))
                        .when_some(action, |pane, action| {
                            pane.child(Button::new("browser-passkey-open").label(action).on_click(
                                cx.listener(move |this, _, _, cx| {
                                    if let Some(url) = this.browser.as_mut().and_then(|browser| {
                                        browser.open_passkey_notice(&open_thread)
                                    }) {
                                        cx.open_url(&url);
                                    }
                                    cx.notify();
                                }),
                            ))
                        }),
                )
                .child(
                    Button::new("browser-passkey-dismiss")
                        .label("×")
                        .tooltip("Dismiss")
                        .on_click(cx.listener(move |this, _, window, cx| {
                            if let Some(browser) = &mut this.browser {
                                browser.dismiss_passkey_notice(&thread);
                            }
                            // Once dismissed, the notice stays hidden in every browser.
                            this.change_setting(
                                Preferences::NOTICE_DISMISSED,
                                json!(true),
                                window,
                                cx,
                            );
                        })),
                )
                .into_any_element(),
        )
    }

    /// Settings › Browser › Passwords: "Use passkeys from Bitwarden" and "Confirm
    /// passkey sign-ins with Touch ID".
    pub(super) fn passkey_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let preferences = Preferences::from_settings(&self.settings);
        let support = browser::passkeys::support();
        let mut section = div()
            .id("passkey-settings")
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .child(div().font_weight(FontWeight::SEMIBOLD).child("Passkeys"));
        if support != "bitwarden-sign-in" {
            return section
                .child(div().text_sm().child(if support == "webview2-native" {
                    "Sites’ passkey requests go to Windows: Windows Hello, security keys and phones. Bitwarden passkeys need the Bitwarden command-line tool, which Coincide can’t run on Windows yet."
                } else {
                    "This system’s web engine (WebKitGTK) has no passkey support, so sites offer other ways to sign in. Fill passwords from your password manager instead."
                }))
                .into_any_element();
        }
        section = section.child(
            div()
                .flex()
                .items_center()
                .justify_between()
                .gap_3()
                .child(div().flex_1().min_w_0().child("Use passkeys from Bitwarden").child(
                    div().text_xs().whitespace_normal().child(
                        "Confirm each sign-in using a passkey in your unlocked Bitwarden account.",
                    ),
                ))
                .child(
                    Switch::new("passkeys-use-bitwarden")
                        .color(gpui_kit::rgb(0xe4e9f2))
                        .checked(preferences.uses_bitwarden)
                        .on_click(cx.listener(|this, checked, window, cx| {
                            this.change_setting(
                                Preferences::USES_BITWARDEN,
                                json!(*checked),
                                window,
                                cx,
                            )
                        })),
                ),
        );
        if preferences.uses_bitwarden {
            section = section.child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_3()
                    .child(
                        div()
                            .flex_1()
                            .child("Confirm passkey sign-ins with Touch ID")
                            .child(div().text_xs().whitespace_normal().child(
                                "Require Touch ID or your Mac password after you choose Sign In.",
                            )),
                    )
                    .child(
                        Switch::new("passkeys-confirm-touch-id")
                            .color(gpui_kit::rgb(0xe4e9f2))
                            .checked(preferences.always_verifies)
                            .on_click(cx.listener(|this, checked, window, cx| {
                                this.change_setting(
                                    Preferences::ALWAYS_VERIFIES,
                                    json!(*checked),
                                    window,
                                    cx,
                                )
                            })),
                    ),
            );
        }
        section.into_any_element()
    }
}
