//! A native picker choice applies its source-bound plan on the existing worker.
//! Sign-in/key enrollment remains a separate explicit action, as in Swift.
use super::*;
impl Panel {
    pub(super) fn codex_auth_controls(
        &self,
        row: &Row,
        busy: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        div()
            .flex()
            .items_center()
            .gap_2()
            .child("Sign in with")
            .children(
                [(true, "Login"), (false, "API key")]
                    .into_iter()
                    .map(|(login, label)| {
                        let id = row.id.clone();
                        let revision = row.revision.clone();
                        let legacy = row.legacy;
                        Button::new(SharedString::from(format!(
                            "codex-account-auth-{id}-{login}"
                        )))
                        .label(label)
                        .disabled(busy || login == (row.authentication == Auth::Login))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.account_request(
                                "codex",
                                Request::CodexAuth {
                                    id: id.clone(),
                                    revision: revision.clone(),
                                    login,
                                    legacy,
                                },
                                cx,
                            )
                        }))
                    }),
            )
            .into_any_element()
    }
}
