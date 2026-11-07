//! Anthropic reporting controls share the provider panel's actual worker owner.
use super::*;
pub(super) fn admin_eligible(row: &NativeProviderAccount) -> bool {
    matches!(row.provider.as_str(), "claude" | "opencode")
        && row.authentication == Auth::ApiKey
        && row.key_variable.as_deref() == Some("ANTHROPIC_API_KEY")
}
fn report_view(
    report: &coincide_core::provider_configuration::NativeAdminUsageReport,
) -> AnyElement {
    let scope = report
        .token_key_name
        .as_ref()
        .map(|name| format!("Key “{name}”"))
        .unwrap_or_else(|| "Organization".into());
    let cost = |value: Option<f64>| {
        value
            .map(|value| format!("${value:.2}"))
            .unwrap_or_else(|| "Unavailable".into())
    };
    div()
        .flex()
        .flex_col()
        .gap_1()
        .text_sm()
        .child(format!(
            "{scope} tokens today (UTC): {}",
            report.today.total()
        ))
        .child(format!(
            "{scope} tokens this month (UTC): {}",
            report.month.total()
        ))
        .child(format!(
            "Organization cost today: {} · This month: {}",
            cost(report.cost_today_usd),
            cost(report.cost_month_usd)
        ))
        .child("Costs cover the organization and do not show a prepaid balance.")
        .children(report.models.iter().map(|model| {
            div().child(format!(
                "{} · {scope} tokens: {} · Organization cost: {}",
                model.name,
                model.tokens.total(),
                cost(model.organization_cost_usd)
            ))
        }))
        .child(format!("Last successful read: {}", report.checked_at))
        .into_any_element()
}
impl Panel {
    pub(super) fn save_account_admin_key(
        &mut self,
        provider: &str,
        id: &str,
        cx: &mut Context<Self>,
    ) {
        let Some(editor) = self.accounts.editors.get(provider) else {
            return;
        };
        let Some(row) = editor.rows.iter().find(|row| row.id == id) else {
            return;
        };
        let Some(draft) = editor.drafts.get(id) else {
            return;
        };
        let value = draft.admin_key.read(cx).value().to_string();
        if value.trim().is_empty() {
            return;
        }
        self.account_request(
            provider,
            Request::SaveAdmin {
                id: id.into(),
                revision: row.revision.clone(),
                value,
            },
            cx,
        );
    }
    pub(super) fn admin_controls(
        &self,
        provider: &str,
        row: &NativeProviderAccount,
        draft: &Draft,
        busy: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let p = provider.to_owned();
        let id = row.id.clone();
        let revision = row.revision.clone();
        div().flex().flex_col().gap_1()
            .child("Admin API key (optional)")
            .child(div().flex().items_center().gap_2()
                .child(Input::new(&draft.admin_key).flex_1())
                .child(Button::new(SharedString::from(format!("account-admin-save-{id}")))
                    .label(if row.has_admin_key { "Replace" } else { "Save" })
                    .disabled(busy || draft.admin_key.read(cx).value().trim().is_empty())
                    .on_click(cx.listener({let p=p.clone();let id=id.clone();let revision=revision.clone();move|this,_,_,cx| {
                        let Some(editor)=this.accounts.editors.get(&p) else{return};
                        let Some(draft)=editor.drafts.get(&id) else{return};
                        let value=draft.admin_key.read(cx).value().to_string();
                        if !value.trim().is_empty(){this.account_request(&p,Request::SaveAdmin{id:id.clone(),revision:revision.clone(),value},cx);}
                    }})))
                .when(row.has_admin_key, |line| line.child(Button::new(SharedString::from(format!("account-admin-remove-{id}")))
                    .label("Remove Admin Key").disabled(busy)
                    .on_click(cx.listener({let p=p.clone();let id=id.clone();let revision=revision.clone();move|this,_,_,cx|this.account_request(&p,Request::RemoveAdmin{id:id.clone(),revision:revision.clone()},cx)})))))
            .child(div().text_sm().child("Read-only organization usage and cost reports. Kept in the OS secret store and sent only to Anthropic. Refresh explicitly in Usage; no report is read when this page opens."))
            .into_any_element()
    }
    /// Metadata-only lists. The sole report request is the explicit button.
    pub fn admin_usage_view(&self, cx: &mut Context<Self>) -> AnyElement {
        let busy = self.pending.is_some() || !self.workers.can_start();
        let mut pane=div().flex().flex_col().gap_3().p_3().rounded_md().border_1().border_color(rgb(0x29303d))
            .child(div().font_weight(FontWeight::SEMIBOLD).child("Anthropic organization reports"))
            .child(div().text_sm().child("Claude and OpenCode Anthropic API accounts can use a separate Admin key. UTC reports are read only when you choose Refresh."));
        let mut count = 0;
        for provider in ["claude", "opencode"] {
            let Some(editor) = self.accounts.editors.get(provider) else {
                continue;
            };
            for row in editor.rows.iter().filter(|row| admin_eligible(row)) {
                count += 1;
                let p = provider.to_owned();
                let id = row.id.clone();
                let revision = row.revision.clone();
                let mut card = div()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .border_t_1()
                    .border_color(rgb(0x29303d))
                    .py_2()
                    .child(format!(
                        "{} · {}",
                        if provider == "claude" {
                            "Claude"
                        } else {
                            "OpenCode"
                        },
                        row.name
                    ))
                    .child(
                        Button::new(SharedString::from(format!(
                            "admin-usage-refresh-{provider}-{id}"
                        )))
                        .label("Refresh organization report")
                        .disabled(busy || !row.has_admin_key)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.account_request(
                                &p,
                                Request::ReadAdmin {
                                    id: id.clone(),
                                    revision: revision.clone(),
                                },
                                cx,
                            )
                        })),
                    );
                if !row.has_admin_key {
                    card = card.child(
                        div()
                            .text_sm()
                            .child("Add an Admin key in this provider’s account settings."),
                    );
                }
                if let Some(report) = editor.admin_reports.get(&row.id) {
                    card = card.child(report_view(report));
                }
                pane = pane.child(card);
            }
            if !editor.notice.is_empty() {
                pane = pane.child(div().text_sm().child(editor.notice.clone()));
            }
        }
        if count == 0 {
            pane = pane
                .child("No Anthropic API accounts loaded. Add one in Claude or OpenCode settings.");
        }
        pane.into_any_element()
    }
}
