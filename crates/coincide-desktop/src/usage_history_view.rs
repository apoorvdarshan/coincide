//! Saved usage only. Parent owns the read-only transport and source selection.
use coincide_core::local_usage::{
    CaptureCoverage, CounterSummary, Figure, Query, Report, Source, since_days,
};
use gpui_kit::prelude::FluentBuilder;
use gpui_kit::{
    base::Disableable,
    component::{
        ActiveTheme, Selectable,
        button::{Button, ButtonVariants},
    },
    *,
};

pub enum UsageHistoryEvent {
    Load(Query),
}
pub struct UsageHistoryView {
    report: Option<Report>,
    error: Option<String>,
    loading: bool,
    selected: Option<String>,
    scroll: ScrollHandle,
    period: Option<u16>,
    pending_period: Option<Option<u16>>,
}
impl EventEmitter<UsageHistoryEvent> for UsageHistoryView {}
fn figure<T: std::fmt::Display>(value: &Figure<T>) -> String {
    match value {
        Figure::Missing => "Not reported".into(),
        Figure::Null => "Not reported (null)".into(),
        Figure::Invalid => "Invalid saved value".into(),
        Figure::Reported(value) => value.to_string(),
    }
}
fn total(value: &CounterSummary, records: usize) -> String {
    if value.overflow {
        return format!(
            "Unavailable: saved counters exceed range ({} reports)",
            value.reported
        );
    }
    match value.reported_sum {
        Some(sum) => format!("{sum} · {}/{records} turns reported", value.reported),
        None => format!("Not reported · 0/{records} turns"),
    }
}
impl UsageHistoryView {
    pub fn new() -> Self {
        Self {
            report: None,
            error: None,
            loading: false,
            selected: None,
            scroll: ScrollHandle::new(),
            period: None,
            pending_period: None,
        }
    }
    /// Root calls after a bounded saved-history read, never after live refresh.
    pub fn set_snapshot(&mut self, result: Result<Report, String>, cx: &mut Context<Self>) {
        self.loading = false;
        match result {
            Ok(report) => {
                if let Some(period) = self.pending_period.take() {
                    self.period = period;
                }
                if self
                    .selected
                    .as_ref()
                    .is_some_and(|id| !report.rows.iter().any(|row| &row.id == id))
                {
                    self.selected = None;
                }
                self.report = Some(report);
                self.error = None;
            }
            Err(error) => {
                self.pending_period = None;
                self.error = Some(error.chars().take(1024).collect());
            }
        }
        cx.notify();
    }
    fn request(&mut self, query: Query, cx: &mut Context<Self>) {
        if self.loading {
            return;
        }
        self.loading = true;
        self.error = None;
        cx.emit(UsageHistoryEvent::Load(query));
        cx.notify();
    }
    fn period(&mut self, days: Option<u16>, cx: &mut Context<Self>) {
        if self.loading {
            return;
        }
        let mut query = self
            .report
            .as_ref()
            .map(|report| report.query.clone())
            .unwrap_or_default();
        query.offset = 0;
        query.since = match days {
            None => None,
            Some(days) => {
                let result = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .ok()
                    .and_then(|value| i64::try_from(value.as_secs()).ok())
                    .ok_or_else(|| "Local clock is unavailable".to_owned())
                    .and_then(|now| {
                        since_days(now, days)
                            .map_err(|_| "Local usage period is unavailable".to_owned())
                    });
                match result {
                    Ok(since) => Some(since),
                    Err(error) => {
                        self.error = Some(error);
                        cx.notify();
                        return;
                    }
                }
            }
        };
        self.pending_period = Some(days);
        self.request(query, cx);
    }
}
impl Default for UsageHistoryView {
    fn default() -> Self {
        Self::new()
    }
}
impl Render for UsageHistoryView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let query = self
            .report
            .as_ref()
            .map(|report| report.query.clone())
            .unwrap_or_default();
        let reload = Button::new("usage-reload")
            .compact()
            .label(if self.loading {
                "Loading…"
            } else if self.report.is_some() {
                "Reload"
            } else {
                "Load reports"
            })
            .disabled(self.loading)
            .on_click(cx.listener(|this, _, _, cx| {
                let query = this
                    .report
                    .as_ref()
                    .map(|report| report.query.clone())
                    .unwrap_or_default();
                this.request(query, cx);
            }));
        let mut controls = div().flex().flex_wrap().items_center().gap_1();
        if self.report.is_some() {
            controls = controls
                .child(
                    Button::new("usage-all-dates")
                        .ghost()
                        .compact()
                        .selected(self.period.is_none())
                        .label("All dates")
                        .disabled(self.loading)
                        .on_click(cx.listener(|this, _, _, cx| this.period(None, cx))),
                )
                .child(
                    Button::new("usage-seven-days")
                        .ghost()
                        .compact()
                        .selected(self.period == Some(7))
                        .label("7 days (UTC)")
                        .disabled(self.loading)
                        .on_click(cx.listener(|this, _, _, cx| this.period(Some(7), cx))),
                )
                .child(
                    Button::new("usage-thirty-days")
                        .ghost()
                        .compact()
                        .selected(self.period == Some(30))
                        .label("30 days (UTC)")
                        .disabled(self.loading)
                        .on_click(cx.listener(|this, _, _, cx| this.period(Some(30), cx))),
                );
            let mut all = query.clone();
            all.provider = None;
            all.offset = 0;
            controls = controls.child(
                Button::new("usage-all-providers")
                    .ghost()
                    .compact()
                    .selected(query.provider.is_none())
                    .label("All providers")
                    .disabled(self.loading)
                    .on_click(cx.listener(move |this, _, _, cx| this.request(all.clone(), cx))),
            );
            if let Some(report) = &self.report {
                for (index, provider) in report.available_providers.iter().take(12).enumerate() {
                    let mut next = query.clone();
                    next.provider = Some(provider.clone());
                    next.offset = 0;
                    controls = controls.child(
                        Button::new(("usage-provider", index))
                            .ghost()
                            .compact()
                            .selected(query.provider.as_deref() == Some(provider.as_str()))
                            .label(
                                if crate::usage_dashboard_ui::provider_id(provider).is_some() {
                                    crate::usage_dashboard_ui::provider_name(provider).to_owned()
                                } else {
                                    provider.clone()
                                },
                            )
                            .disabled(self.loading)
                            .on_click(
                                cx.listener(move |this, _, _, cx| this.request(next.clone(), cx)),
                            ),
                    );
                }
            }
        }
        let mut body = div()
            .id("saved-usage-scroll")
            .max_h(px(340.))
            .track_scroll(&self.scroll)
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        if let Some(report) = &self.report {
            body = body.child(div().font_weight(FontWeight::MEDIUM).child(format!(
                    "{} matching turns · {} saved · showing {}–{}",
                    report.matched_records, report.stored_records,
                    if report.rows.is_empty() { 0 } else { report.query.offset + 1 },
                    report.query.offset + report.rows.len()
                )))
                .child(div().text_xs().text_color(cx.theme().muted_foreground).child(match report.source {Source::LocalDocument=>"Local saved usage history",Source::CapturedOriginal=>"Captured historical usage document"}))
                .child(div().text_xs().text_color(cx.theme().muted_foreground).child(match report.capture {CaptureCoverage::NotConnected=>"New Rust turns do not currently record usage in this build.",CaptureCoverage::CodexRequestSnapshots=>"New Rust turns record Codex request snapshots only. Other providers are not recorded yet."}))
                .child(div().text_xs().text_color(cx.theme().muted_foreground).child(format!("Reported turn counters: input {} · cache read {} · cache write {} · output {}",total(&report.totals.input,report.matched_records),total(&report.totals.cache_read,report.matched_records),total(&report.totals.cache_write,report.matched_records),total(&report.totals.output,report.matched_records))));
            if report.query.project_id.is_some() || report.query.account_id.is_some() {
                body = body.child(
                    div()
                        .text_xs()
                        .text_color(cx.theme().muted_foreground)
                        .child(format!(
                            "Project: {} · Account: {}",
                            report.query.project_id.as_deref().unwrap_or("all"),
                            report.query.account_id.as_deref().unwrap_or("all")
                        )),
                );
            }
            if report.missing_date_excluded > 0 {
                body = body.child(format!(
                    "{} saved turns have no valid date and are excluded by this period.",
                    report.missing_date_excluded
                ));
            }
            if report.rows.is_empty() {
                body = body.child(
                    "No saved usage reports match these filters. Missing usage is not zero.",
                );
            }
            for (index, row) in report.rows.iter().enumerate() {
                let id = row.id.clone();
                let expanded = self.selected.as_deref() == Some(id.as_str());
                let mut item = div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .py_2()
                    .border_t_1()
                    .border_color(cx.theme().border)
                    .child(
                        Button::new(("saved-usage-row", index))
                            .ghost()
                            .compact()
                            .w_full()
                            .label(format!(
                                "{} · {} · {}",
                                figure(&row.finished_at),
                                figure(&row.provider),
                                figure(&row.model_id)
                            ))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.selected = if this.selected.as_ref() == Some(&id) {
                                    None
                                } else {
                                    Some(id.clone())
                                };
                                cx.notify();
                            })),
                    )
                    .child(
                        div()
                            .text_xs()
                            .text_color(cx.theme().muted_foreground)
                            .child(format!(
                                "Outcome: {} · Input/context snapshot: {} · Output snapshot: {}",
                                figure(&row.outcome),
                                figure(&row.usage.input_tokens),
                                figure(&row.usage.output_tokens)
                            )),
                    );
                if expanded {
                    item=item.child(format!("Project ID: {} · Account ID: {}",figure(&row.project_id),figure(&row.account_id)))
                        .child("An unrecorded account may mean the provider default or an older record; it is not a verified account identity.")
                        .child(format!("Provider provenance: {} · Scope: {}",figure(&row.provenance.kind),figure(&row.provenance.scope)))
                        .child(format!("Cached input snapshot: {} · Context window: {} · Provider-reported USD cost snapshot: {}",figure(&row.usage.cached_input_tokens),figure(&row.usage.context_window),figure(&row.usage.cost_usd)))
                        .child(format!("Turn counters: input {} · cache read {} · cache write {} · output {}",figure(&row.usage.turn_input),figure(&row.usage.turn_cache_read),figure(&row.usage.turn_cache_write),figure(&row.usage.turn_output)))
                        .child(format!("Reported subsets: long cache write {} · reasoning {} (not added again)",figure(&row.usage.turn_cache_write_long),figure(&row.usage.turn_reasoning)));
                }
                body = body.child(item);
            }
            let mut previous = query.clone();
            previous.offset = previous.offset.saturating_sub(previous.limit);
            let mut next = query.clone();
            next.offset = next.offset.saturating_add(next.limit);
            body = body.child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("usage-previous")
                            .label("Previous page")
                            .disabled(self.loading || query.offset == 0)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.request(previous.clone(), cx)
                            })),
                    )
                    .child(
                        Button::new("usage-next")
                            .label("Next page")
                            .disabled(
                                self.loading
                                    || next.offset >= report.matched_records
                                    || next.offset > 10_000,
                            )
                            .on_click(
                                cx.listener(move |this, _, _, cx| this.request(next.clone(), cx)),
                            ),
                    ),
            );
        } else {
            body = body.child(
                div()
                    .text_sm()
                    .text_color(cx.theme().muted_foreground)
                    .child("Load saved reports to inspect individual turns."),
            );
        }
        div()
            .w_full()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_3()
            .p_4()
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .child(
                        div()
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("Saved turn reports"),
                    )
                    .child(reload),
            )
            .child(
                div()
                    .text_xs()
                    .text_color(cx.theme().muted_foreground)
                    .child(
                        "Local per-turn snapshots. They aren’t billing totals or live plan limits.",
                    ),
            )
            .when(self.report.is_some(), |view| view.child(controls))
            .when_some(self.error.clone(), |view, error| {
                view.child(div().text_color(cx.theme().danger).child(error))
            })
            .child(body)
    }
}
