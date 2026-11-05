//! Native explicit GitHub write confirmation, mounted separately from read UI.
//! Transport MUST validate authoritative stored roots, and run prepare outside
//! any Engine lock. This entity never owns/locks Engine or executes gh itself.
use anyhow::{Context as _, Result, ensure};
use coincide_core::github_write::{WriteShutdownStatus, WriteWorkers};
use gpui_kit::{
    base::Disableable,
    component::{
        button::*,
        input::{Textarea, TextareaState},
    },
    *,
};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::{Arc, mpsc},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

pub type WriteTransport = Arc<dyn Fn(&str, Value) -> Result<Value> + Send + Sync>;
const NOTICE: &str = "Reviews target the specified commit; GitHub does not atomically require it to remain the current PR head.";
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn oid(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
}
fn uuid(s: &str) -> bool {
    Uuid::parse_str(s).is_ok_and(|id| id.to_string() == s)
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActionScope {
    thread: String,
    root: String,
    repository: String,
    number: u64,
    head: String,
}
impl ActionScope {
    pub fn new(
        thread: String,
        canonical_root: String,
        repository: String,
        number: u64,
        expected_head: String,
    ) -> Result<Self> {
        let parts = repository.split('/').collect::<Vec<_>>();
        ensure!(
            !thread.is_empty()
                && thread.len() <= 128
                && Path::new(&canonical_root).is_absolute()
                && number > 0
                && oid(&expected_head),
            "Invalid GitHub action scope"
        );
        ensure!(
            parts.len() == 2
                && parts.iter().all(|v| !v.is_empty()
                    && v.len() <= 100
                    && !v.starts_with('-')
                    && *v != "."
                    && *v != ".."
                    && v.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))),
            "Invalid GitHub repository"
        );
        Ok(Self {
            thread,
            root: canonical_root,
            repository,
            number,
            head: expected_head.to_ascii_lowercase(),
        })
    }
    fn params(&self) -> Value {
        json!({"threadId":self.thread,"expectedRoot":self.root,"repository":self.repository,"number":self.number,"expectedHead":self.head})
    }
    fn history_params(&self) -> Value {
        let mut p = self.params();
        p.as_object_mut().unwrap().remove("expectedHead");
        p
    }
    fn echoes(&self, v: &Value) -> bool {
        v["threadId"] == self.thread
            && v["expectedRoot"] == self.root
            && v["repository"] == self.repository
            && v["number"].as_u64() == Some(self.number)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum Action {
    Comment(String),
    Merge(String),
}
impl Action {
    fn value(&self) -> Result<Value> {
        Ok(match self {
            Self::Comment(body) => {
                ensure!(
                    !body.trim().is_empty() && body.len() <= 32768 && !body.contains('\0'),
                    "Comment must be nonblank, contain no NUL bytes, and be at most 32768 UTF-8 bytes"
                );
                json!({"kind":"review","event":"COMMENT","body":body})
            }
            Self::Merge(method) => {
                ensure!(
                    ["merge", "squash", "rebase"].contains(&method.as_str()),
                    "Invalid merge method"
                );
                json!({"kind":"merge","method":method})
            }
        })
    }
    fn label(&self) -> String {
        match self {
            Self::Comment(body) => format!("Post COMMENT review with exact body:\n{body}"),
            Self::Merge(method) => format!(
                "Merge using {method}. No queue, automatic merge, branch deletion or admin bypass requested."
            ),
        }
    }
}
struct Confirmation {
    scope: ActionScope,
    action: Action,
    baseline: String,
    fingerprint: String,
    expires: u64,
    received: Instant,
    mutation: String,
    snapshot: Value,
    availability: Value,
}
impl Confirmation {
    fn parse(scope: ActionScope, action: Action, v: Value, time: u64) -> Result<Self> {
        action.value()?;
        ensure!(
            scope.echoes(&v) && v["expectedHead"] == scope.head,
            "Prepared action scope changed"
        );
        let baseline = v["baselineId"]
            .as_str()
            .context("Missing baseline")?
            .to_owned();
        ensure!(uuid(&baseline), "Invalid baseline ID");
        let fingerprint = v["fingerprint"]
            .as_str()
            .context("Missing fingerprint")?
            .to_owned();
        ensure!(
            fingerprint.len() == 64 && fingerprint.bytes().all(|b| b.is_ascii_hexdigit()),
            "Invalid baseline fingerprint"
        );
        let expires = v["expiresAt"].as_u64().context("Missing expiry")?;
        ensure!(
            expires > time && expires <= time.saturating_add(61),
            "Prepared action expired or invalid TTL"
        );
        let pr = &v["snapshot"];
        let parsed = coincide_core::workspace_github::parse_snapshot(&serde_json::to_vec(pr)?)?;
        ensure!(
            parsed.number == scope.number
                && parsed.head_ref_oid == scope.head
                && parsed.url.eq_ignore_ascii_case(&format!(
                    "https://github.com/{}/pull/{}",
                    scope.repository, scope.number
                )),
            "Prepared PR identity/head changed"
        );
        let availability = &v["availability"];
        ensure!(
            availability["notice"] == NOTICE,
            "Missing review head-race disclosure"
        );
        match &action {
            Action::Comment(_) => ensure!(
                availability["review"]["COMMENT"]["available"] == true,
                "COMMENT is unavailable: {}",
                availability["review"]["COMMENT"]["reason"]
                    .as_str()
                    .unwrap_or("not enabled")
            ),
            Action::Merge(method) => {
                ensure!(
                    availability["merge"]["available"] == true
                        && availability["merge"]["methods"]
                            .as_array()
                            .is_some_and(|v| v.iter().any(|m| m == method)),
                    "Merge method is unavailable"
                );
                ensure!(
                    parsed.preflight(&scope.head)?["eligible"] == true,
                    "Fresh snapshot is not eligible for merge"
                );
            }
        }
        Ok(Self {
            scope,
            action,
            baseline,
            fingerprint,
            expires,
            received: Instant::now(),
            mutation: Uuid::new_v4().to_string(),
            snapshot: pr.clone(),
            availability: availability.clone(),
        })
    }
    fn valid(&self, scope: &ActionScope, time: u64, elapsed: Duration) -> bool {
        &self.scope == scope && time < self.expires && elapsed < Duration::from_secs(60)
    }
    fn submit_params(&self) -> Result<Value> {
        let mut p = self.scope.params();
        p["baselineId"] = json!(self.baseline);
        p["mutationId"] = json!(self.mutation);
        p["action"] = self.action.value()?;
        Ok(p)
    }
}
fn status(v: &Value, id: &str, scope: &ActionScope) -> Result<()> {
    ensure!(
        uuid(id) && v["mutationId"] == id,
        "Mutation result identity changed"
    );
    let state = v["status"].as_str().context("Missing mutation status")?;
    ensure!(
        ["pending", "succeeded", "rejected", "uncertain"].contains(&state),
        "Unknown write outcome; do not retry"
    );
    if state == "succeeded" {
        let result = &v["result"];
        match result["kind"].as_str() {
            Some("review") => ensure!(
                result["reviewId"].as_u64().is_some_and(|n| n > 0)
                    && result["commit"] == scope.head
                    && result["state"] == "COMMENTED"
                    && result["url"]
                        .as_str()
                        .is_some_and(|u| u.to_ascii_lowercase().starts_with(&format!(
                            "https://github.com/{}/pull/{}#",
                            scope.repository.to_ascii_lowercase(),
                            scope.number
                        ))),
                "Review success is not verified for this commit"
            ),
            Some("merge") => ensure!(
                result["merged"] == true && result["commit"].as_str().is_some_and(oid),
                "Merge success is not verified"
            ),
            _ => anyhow::bail!("Missing verified write result"),
        }
    }
    Ok(())
}
fn history(scope: &ActionScope, v: &Value) -> Result<()> {
    ensure!(
        scope.echoes(v) && v["blocked"].is_boolean() && v["truncated"].is_boolean(),
        "History scope/shape changed"
    );
    let mut ids = std::collections::HashSet::new();
    let rows = v["mutations"]
        .as_array()
        .context("Missing durable mutation history")?;
    ensure!(rows.len() <= 4096, "History exceeds ledger bound");
    for row in rows {
        let id = row["mutationId"]
            .as_str()
            .context("Missing history mutation ID")?;
        ensure!(ids.insert(id), "Duplicate history ID");
        let mut original = scope.clone();
        original.head = row["expectedHead"]
            .as_str()
            .filter(|s| oid(s))
            .context("Missing history head")?
            .into();
        status(row, id, &original)?;
    }
    Ok(())
}
fn blocked(v: &Value) -> bool {
    v["blocked"] != false
        || v["mutations"].as_array().is_none_or(|rows| {
            rows.iter()
                .any(|r| matches!(r["status"].as_str(), Some("pending" | "uncertain")))
        })
}

// A missing formerly unresolved ID is not evidence that submission was safe to
// repeat. Keep the local warning until the durable ledger returns its outcome.
fn retain_unresolved(previous: &Value, mut fresh: Value) -> Value {
    let Some(rows) = fresh["mutations"].as_array_mut() else {
        return fresh;
    };
    for old in previous["mutations"].as_array().into_iter().flatten() {
        if matches!(old["status"].as_str(), Some("pending" | "uncertain"))
            && !rows
                .iter()
                .any(|row| row["mutationId"] == old["mutationId"])
        {
            rows.push(old.clone());
        }
    }
    if rows
        .iter()
        .any(|row| matches!(row["status"].as_str(), Some("pending" | "uncertain")))
    {
        fresh["blocked"] = json!(true);
    }
    fresh
}
enum Work {
    History(ActionScope),
    Prepare(ActionScope, Action),
    Submit(Box<Confirmation>),
    Result {
        display: ActionScope,
        original: ActionScope,
        id: String,
    },
}
impl Work {
    fn scope(&self) -> &ActionScope {
        match self {
            Self::History(s) | Self::Prepare(s, _) => s,
            Self::Submit(c) => &c.scope,
            Self::Result { display, .. } => display,
        }
    }
}
enum Reply {
    History(Value),
    Prepared(Box<Confirmation>),
    Mutation {
        id: String,
        head: String,
        value: Value,
        sent_body: Option<String>,
    },
}
fn execute(api: &mut impl FnMut(&str, Value) -> Result<Value>, work: Work) -> Result<Reply> {
    match work {
        Work::History(scope) => {
            let v = api("github.write.history", scope.history_params())?;
            history(&scope, &v)?;
            Ok(Reply::History(v))
        }
        Work::Prepare(scope, action) => {
            // Always recover/check durable history before making a new baseline.
            let records = api("github.write.history", scope.history_params())?;
            history(&scope, &records)?;
            ensure!(
                !blocked(&records),
                "Unresolved prior write; query its mutation ID instead of preparing a new write"
            );
            let value = api("github.write.prepare", scope.params())?;
            Ok(Reply::Prepared(Box::new(Confirmation::parse(
                scope,
                action,
                value,
                now(),
            )?)))
        }
        Work::Submit(c) => {
            ensure!(
                c.valid(&c.scope, now(), c.received.elapsed()),
                "Confirmation expired; reload the baseline"
            );
            let sent_body = match &c.action {
                Action::Comment(body) => Some(body.clone()),
                Action::Merge(_) => None,
            };
            let value = api("github.write.submit", c.submit_params()?)?;
            status(&value, &c.mutation, &c.scope)?;
            if value["status"] == "succeeded" {
                let expected_kind = match &c.action {
                    Action::Comment(_) => "review",
                    Action::Merge(_) => "merge",
                };
                ensure!(
                    value["result"]["kind"] == expected_kind,
                    "Write result does not match confirmed action"
                );
            }
            Ok(Reply::Mutation {
                id: c.mutation,
                head: c.scope.head,
                value,
                sent_body,
            })
        }
        Work::Result { original, id, .. } => {
            let mut p = original.params();
            p["mutationId"] = json!(id);
            let value = api("github.write.result", p)?;
            status(&value, &id, &original)?;
            Ok(Reply::Mutation {
                id,
                head: original.head,
                value,
                sent_body: None,
            })
        }
    }
}

pub struct GitHubActions {
    transport: WriteTransport,
    workers: WriteWorkers,
    scope: Option<ActionScope>,
    generation: u64,
    busy: bool,
    history_known: bool,
    locked: bool,
    records: Value,
    confirmation: Option<Box<Confirmation>>,
    body: Entity<TextareaState>,
    content_scroll: ScrollHandle,
    confirmation_scroll: ScrollHandle,
    notice: String,
    tx: mpsc::Sender<(u64, ActionScope, bool, Result<Reply>)>,
    rx: mpsc::Receiver<(u64, ActionScope, bool, Result<Reply>)>,
    _poll: Task<()>,
}
impl GitHubActions {
    pub fn new(transport: WriteTransport, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(150))
                    .await;
                if this
                    .update_in(cx, |this, window, cx| this.poll(window, cx))
                    .is_err()
                {
                    break;
                }
            }
        });
        Self {
            transport,
            workers: WriteWorkers::default(),
            scope: None,
            generation: 0,
            busy: false,
            history_known: false,
            locked: true,
            records: json!({}),
            confirmation: None,
            body: cx.new(|cx| {
                TextareaState::new(window, cx)
                    .placeholder("Comment review body")
                    .submit_on_enter(false)
            }),
            content_scroll: ScrollHandle::new(),
            confirmation_scroll: ScrollHandle::new(),
            notice: "Select an exact PR head to load durable write history.".into(),
            tx,
            rx,
            _poll: poll,
        }
    }
    pub fn request_shutdown(&mut self, cx: &mut Context<Self>) {
        self.workers.request_shutdown();
        self.confirmation = None;
        self.locked = true;
        self.notice =
            "GitHub actions are closing. Dispatched writes are not cancelled or retried.".into();
        cx.notify();
    }
    pub fn shutdown_status(&self) -> WriteShutdownStatus {
        self.workers.status()
    }
    pub fn set_scope(&mut self, scope: Option<ActionScope>, cx: &mut Context<Self>) {
        if self.scope == scope {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        self.scope = scope;
        self.confirmation = None;
        self.history_known = false;
        self.locked = true;
        self.records = json!({});
        self.notice = "Loading history before enabling writes…".into();
        if !self.busy
            && let Some(scope) = self.scope.clone()
        {
            self.start(Work::History(scope), cx);
        }
        cx.notify();
    }
    /// Parent calls on every PR detail reload, even when the head is unchanged.
    /// A confirmation prepared before reload must not survive that transition.
    pub fn invalidate(&mut self, cx: &mut Context<Self>) {
        self.generation = self.generation.wrapping_add(1);
        self.confirmation = None;
        self.locked = true;
        self.history_known = false;
        self.notice = "Baseline invalidated by reload; loading durable history.".into();
        if !self.busy
            && let Some(scope) = self.scope.clone()
        {
            self.start(Work::History(scope), cx);
        }
        cx.notify();
    }
    fn start(&mut self, work: Work, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Ok(_admission) = self.workers.begin() else {
            return;
        };
        let scope = work.scope().clone();
        let submitting = matches!(&work, Work::Submit(_));
        let generation = self.generation;
        let api = self.transport.clone();
        let tx = self.tx.clone();
        self.busy = true;
        let worker = std::thread::spawn(move || {
            let result = execute(&mut |method, p| api(method, p), work);
            let _ = tx.send((generation, scope, submitting, result));
        });
        self.workers.track(worker);
        cx.notify();
    }
    fn prepare(&mut self, action: Action, cx: &mut Context<Self>) {
        if self.busy || !self.history_known || self.locked {
            return;
        }
        if let Err(error) = action.value() {
            self.notice = error.to_string();
            cx.notify();
            return;
        }
        if let Some(scope) = self.scope.clone() {
            self.confirmation = None;
            self.confirmation_scroll.set_offset(point(px(0.), px(0.)));
            self.notice = "Reading fresh PR/check/review baseline…".into();
            self.start(Work::Prepare(scope, action), cx);
        }
    }
    fn confirm(&mut self, cx: &mut Context<Self>) {
        if self.busy || self.locked || !self.history_known {
            return;
        }
        let Some(c) = self.confirmation.take() else {
            return;
        };
        if !self
            .scope
            .as_ref()
            .is_some_and(|scope| c.valid(scope, now(), c.received.elapsed()))
        {
            self.notice = "Scope changed or confirmation expired. Prepare again.".into();
            cx.notify();
            return;
        }
        // Lock and record the ID before calling transport. Even a synchronous
        // transport error can follow a dispatched write; never resubmit it.
        self.locked = true;
        self.history_known = false;
        self.records = json!({"blocked":true,"mutations":[{"mutationId":c.mutation,"expectedHead":c.scope.head,"status":"uncertain","result":null,"error":{"code":"awaiting_result","message":"Do not resubmit; query durable history/result"}}]});
        self.notice = format!("Submitting once. Mutation ID: {}", c.mutation);
        self.start(Work::Submit(c), cx);
    }
    fn poll(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Ok((generation, scope, submitting, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        if generation != self.generation || self.scope.as_ref() != Some(&scope) {
            if let Some(scope) = self.scope.clone() {
                self.start(Work::History(scope), cx);
            }
            cx.notify();
            return;
        }
        match result {
            Ok(Reply::History(v)) => {
                let v = retain_unresolved(&self.records, v);
                self.locked = blocked(&v);
                self.history_known = true;
                self.records = v;
                self.notice=if self.locked {"Prior pending/uncertain write blocks this PR. Query its existing ID; do not post again."}else{"Durable history loaded. Prepare a fresh confirmation to write."}.into();
            }
            Ok(Reply::Prepared(c)) => {
                self.confirmation = Some(c);
                self.notice =
                    "Review the fresh summary and exact action below. Confirm within 60 seconds."
                        .into();
            }
            Ok(Reply::Mutation {
                id,
                head,
                value,
                sent_body,
            }) => {
                let state = value["status"].as_str().unwrap_or("uncertain").to_owned();
                let mut record = value;
                record["expectedHead"] = json!(head);
                let rows = self.records["mutations"].as_array_mut();
                if let Some(rows) = rows {
                    if let Some(old) = rows.iter_mut().find(|r| r["mutationId"] == id) {
                        *old = record;
                    } else {
                        rows.push(record);
                    }
                }
                self.confirmation = None;
                self.locked = true;
                self.history_known = false;
                self.notice = format!(
                    "Mutation {id}: {state}. Refresh durable history before another write; uncertain outcomes must be reconciled."
                );
                if state == "succeeded"
                    && sent_body
                        .as_ref()
                        .is_some_and(|sent| self.body.read(cx).value().as_str() == sent.as_str())
                {
                    self.body
                        .update(cx, |input, cx| input.set_value("", window, cx));
                }
            }
            Err(error) => {
                self.confirmation = None;
                self.locked = true;
                self.history_known = false;
                self.notice = if submitting {
                    format!(
                        "{error}. Outcome may be unknown. Refresh history/query the existing ID; never retry submission automatically."
                    )
                } else {
                    format!(
                        "Read/recovery failed: {error}. No new submission was made by this read. Existing outcomes remain unresolved until history/result confirms them."
                    )
                };
            }
        }
        if self.workers.status().closed {
            self.confirmation = None;
            self.locked = true;
            self.history_known = false;
        }
        cx.notify();
    }
}
impl Render for GitHubActions {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let disabled = self.workers.status().closed
            || self.busy
            || !self.history_known
            || self.locked
            || self.scope.is_none();
        // Confirmation owns the remaining panel; the editor/history cannot
        // push its decision controls below the viewport. Only the full snapshot
        // and exact action body scroll, with a persistent native scroll handle.
        if let Some(c) = &self.confirmation {
            let expired = !self
                .scope
                .as_ref()
                .is_some_and(|scope| c.valid(scope, now(), c.received.elapsed()));
            let pr = &c.snapshot;
            let summary = format!(
                "{} PR #{}: {}\nRoot: {}\nThread: {}\nExact head: {}\n{} → {}\nState: {} / draft {}\nReview decision: {}\nMergeability: {} / {}\nBaseline fingerprint: {}\nExpires Unix seconds: {}",
                c.scope.repository,
                c.scope.number,
                pr["title"].as_str().unwrap_or(""),
                c.scope.root,
                c.scope.thread,
                c.scope.head,
                pr["headRefName"].as_str().unwrap_or(""),
                pr["baseRefName"].as_str().unwrap_or(""),
                pr["state"],
                pr["isDraft"],
                pr["reviewDecision"],
                pr["mergeable"],
                pr["mergeStateStatus"],
                c.fingerprint,
                c.expires
            );
            return div().id("github-write-actions").size_full().min_h_0().min_w_0().overflow_hidden()
                .flex().flex_col().gap_2().p_3()
                .child(div().flex_none().child("Confirm prepared GitHub action"))
                .child(div().id("github-write-confirmation-notice").flex_none().max_h(px(64.)).overflow_y_scroll().text_sm().child(self.notice.clone()))
                .child(div().id("github-write-confirmation-actions").flex_none().flex().flex_wrap().gap_2()
                    .child(Button::new("github-write-confirm").label(if expired {"Expired — prepare again"}else{"Confirm this exact action"})
                        .disabled(self.busy || expired || disabled).on_click(cx.listener(|this,_,_,cx|this.confirm(cx))))
                    .child(Button::new("github-write-cancel").label("Cancel confirmation").disabled(self.busy)
                        .on_click(cx.listener(|this,_,_,cx|{this.confirmation=None;this.notice="Confirmation cancelled; draft preserved.".into();cx.notify();})))
                    .child(Button::new("github-copy-confirmation").label("Copy full prepared summary")
                        .on_click(cx.listener(|this,_,_,cx|{if let Some(c)=&this.confirmation{cx.write_to_clipboard(ClipboardItem::new_string(json!({"scope":c.scope.params(),"snapshot":c.snapshot,"availability":c.availability,"action":c.action.value().ok(),"fingerprint":c.fingerprint,"expiresAt":c.expires}).to_string()));}}))))
                .child(div().id("github-write-confirmation").flex_1().flex_basis(px(0.)).min_h_0().min_w_0()
                    .overflow_y_scroll().track_scroll(&self.confirmation_scroll)
                    .child(div().id("github-write-confirmation-summary").flex_none().min_w_0().flex().flex_col().gap_2()
                        .child(summary)
                        .child(format!("Checks (fresh snapshot): {}\nReviews (fresh snapshot): {}",pr["statusCheckRollup"],pr["reviews"]))
                        .child(c.action.label()).child(NOTICE)))
                .into_any_element();
        }
        let content = div()
            .id("github-write-editor-content")
            .flex_none()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_2()
            .child(
                Button::new("github-write-history")
                    .label("Refresh durable history / recover IDs")
                    .disabled(self.busy || self.scope.is_none())
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(scope) = this.scope.clone() {
                            this.confirmation = None;
                            this.locked = true;
                            this.history_known = false;
                            this.start(Work::History(scope), cx);
                        }
                    })),
            )
            .child(Textarea::new(&self.body).h(px(110.)))
            .child(
                Button::new("github-prepare-comment")
                    .label("Prepare COMMENT review…")
                    .disabled(disabled)
                    .on_click(cx.listener(|this, _, _, cx| {
                        let body = this.body.read(cx).value().to_string();
                        this.prepare(Action::Comment(body), cx);
                    })),
            )
            .child(
                div()
                    .flex()
                    .gap_2()
                    .child(
                        Button::new("github-approve-unavailable")
                            .label("Approve (unavailable)")
                            .disabled(true),
                    )
                    .child(
                        Button::new("github-request-changes-unavailable")
                            .label("Request changes (unavailable)")
                            .disabled(true),
                    ),
            )
            .child(div().text_sm().child(NOTICE))
            .child(div().flex().flex_wrap().gap_2().children(
                ["merge", "squash", "rebase"].into_iter().map(|method| {
                    Button::new(SharedString::from(format!("github-prepare-{method}")))
                        .label(format!("Prepare {method}…"))
                        .disabled(disabled)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.prepare(Action::Merge(method.into()), cx)
                        }))
                }),
            ));
        let mut records = div()
            .id("github-write-records")
            .flex_none()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_2();
        if self.records["truncated"] == true {
            records=records.child("Recent completed history is truncated; all pending/uncertain records are included.");
        }
        for row in self.records["mutations"].as_array().into_iter().flatten() {
            let id = row["mutationId"].as_str().unwrap_or("").to_owned();
            let head = row["expectedHead"].as_str().unwrap_or("").to_owned();
            let copied = id.clone();
            records = records.child(
                div()
                    .p_2()
                    .border_1()
                    .child(format!(
                        "Mutation {id}\nHead {head}\nStatus {}\nResult {}\nError {}",
                        row["status"], row["result"], row["error"]
                    ))
                    .child(
                        Button::new(SharedString::from(format!("github-write-query-{id}")))
                            .label("Query this existing mutation ID")
                            .disabled(self.busy)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(display) = this.scope.clone() {
                                    let mut original = display.clone();
                                    original.head = head.clone();
                                    this.start(
                                        Work::Result {
                                            display,
                                            original,
                                            id: id.clone(),
                                        },
                                        cx,
                                    );
                                }
                            })),
                    )
                    .child(
                        Button::new(SharedString::from(format!("github-write-copy-{copied}")))
                            .label("Copy mutation ID")
                            .on_click(move |_, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(copied.clone()))
                            }),
                    ),
            );
        }
        div()
            .id("github-write-actions")
            .size_full()
            .min_h_0()
            .min_w_0()
            .overflow_hidden()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .child(div().flex_none().child("GitHub explicit actions"))
            .child(
                div()
                    .id("github-write-editor-notice")
                    .flex_none()
                    .max_h(px(80.))
                    .overflow_y_scroll()
                    .text_sm()
                    .child(self.notice.clone()),
            )
            .child(
                div()
                    .id("github-write-editor-scroll")
                    .flex_1()
                    .flex_basis(px(0.))
                    .min_h_0()
                    .min_w_0()
                    .overflow_y_scroll()
                    .track_scroll(&self.content_scroll)
                    .child(content.child(records)),
            )
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        Action, ActionScope, Confirmation, NOTICE, Reply, Work, blocked, execute, history, now,
        status,
    };
    use anyhow::Result;
    use serde_json::{Value, json};
    use std::time::Duration;
    use uuid::Uuid;
    fn scope() -> ActionScope {
        ActionScope::new(
            "fixture-thread".into(),
            std::env::temp_dir().to_str().unwrap().into(),
            "fixture/repo".into(),
            42,
            "a".repeat(40),
        )
        .unwrap()
    }
    fn clean(s: &ActionScope) -> Value {
        let mut v = s.history_params();
        v["mutations"] = json!([]);
        v["blocked"] = json!(false);
        v["truncated"] = json!(false);
        v
    }
    fn prepared(s: &ActionScope) -> Value {
        let mut v = s.params();
        v["baselineId"] = json!(Uuid::new_v4().to_string());
        v["fingerprint"] = json!("f".repeat(64));
        v["expiresAt"] = json!(now() + 60);
        v["snapshot"] = json!({"number":42,"title":"Fixture PR","url":"https://github.com/fixture/repo/pull/42","state":"OPEN","isDraft":false,"headRefOid":s.head,"headRefName":"fixture","baseRefName":"main","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"APPROVED","reviews":[],"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]});
        v["availability"] = json!({"review":{"COMMENT":{"available":true,"reason":null},"APPROVE":{"available":false,"reason":"No atomic current-head assertion"},"REQUEST_CHANGES":{"available":false,"reason":"No atomic current-head assertion"}},"merge":{"available":true,"reason":null,"methods":["merge","squash","rebase"]},"notice":NOTICE});
        v
    }
    #[::core::prelude::v1::test]
    fn history_then_prepare_then_exact_confirmed_submit_preserves_body_and_id() {
        let s = scope();
        let body = "  café 中文\n".to_owned();
        let mut calls = Vec::new();
        let reply = execute(
            &mut |method, p| -> Result<Value> {
                calls.push((method.to_owned(), p));
                Ok(if method == "github.write.history" {
                    clean(&s)
                } else {
                    prepared(&s)
                })
            },
            Work::Prepare(s.clone(), Action::Comment(body.clone())),
        )
        .unwrap();
        assert_eq!(calls[0].0, "github.write.history");
        assert!(calls[0].1.get("expectedHead").is_none());
        assert_eq!(calls[1].0, "github.write.prepare");
        let Reply::Prepared(c) = reply else {
            panic!("no confirmation")
        };
        let id = c.mutation.clone();
        let baseline = c.baseline.clone();
        let reply = execute(
            &mut |method, p| -> Result<Value> {
                assert_eq!(method, "github.write.submit");
                assert_eq!(p["mutationId"], id);
                assert_eq!(p["baselineId"], baseline);
                assert_eq!(p["expectedHead"], s.head);
                assert_eq!(
                    p["action"],
                    json!({"kind":"review","event":"COMMENT","body":body})
                );
                Ok(json!({"mutationId":id,"status":"pending","result":null,"error":null}))
            },
            Work::Submit(c),
        )
        .unwrap();
        assert!(matches!(reply,Reply::Mutation {value,..} if value["status"]=="pending"));
    }
    #[::core::prelude::v1::test]
    fn prepared_context_expiry_and_merge_availability_are_mandatory() {
        let s = scope();
        let c = Confirmation::parse(
            s.clone(),
            Action::Merge("squash".into()),
            prepared(&s),
            now(),
        )
        .unwrap();
        assert!(c.valid(&s, now(), Duration::ZERO));
        assert!(!c.valid(&s, c.expires, Duration::ZERO));
        assert!(!c.valid(&s, now(), Duration::from_secs(60)));
        let mut changed = s.clone();
        changed.head = "b".repeat(40);
        assert!(!c.valid(&changed, now(), Duration::ZERO));
        for field in ["threadId", "expectedRoot", "repository", "expectedHead"] {
            let mut v = prepared(&s);
            v[field] = json!("changed");
            assert!(
                Confirmation::parse(s.clone(), Action::Comment("body".into()), v, now()).is_err(),
                "{field}"
            );
        }
        let mut v = prepared(&s);
        v["availability"]["merge"]["available"] = json!(false);
        assert!(Confirmation::parse(s.clone(), Action::Merge("merge".into()), v, now()).is_err());
        let mut v = prepared(&s);
        v["snapshot"]["statusCheckRollup"][0]["conclusion"] = json!("FAILURE");
        assert!(Confirmation::parse(s.clone(), Action::Merge("merge".into()), v, now()).is_err());
        let mut v = prepared(&s);
        v["availability"]["notice"] = json!("");
        assert!(Confirmation::parse(s, Action::Comment("body".into()), v, now()).is_err());
    }
    #[::core::prelude::v1::test]
    fn old_head_uncertain_history_blocks_new_prepare_after_reconstruction() {
        let s = scope();
        let id = Uuid::new_v4().to_string();
        let mut records = clean(&s);
        records["mutations"] = json!([{"mutationId":id,"expectedHead":"b".repeat(40),"status":"uncertain","result":null,"error":{"code":"timeout","message":"uncertain"}}]);
        history(&s, &records).unwrap();
        assert!(blocked(&records));
        let mut calls = 0;
        assert!(
            execute(
                &mut |method, _| -> Result<Value> {
                    calls += 1;
                    assert_eq!(method, "github.write.history");
                    Ok(records.clone())
                },
                Work::Prepare(s, Action::Comment("never post".into()))
            )
            .is_err()
        );
        assert_eq!(calls, 1);
    }
    #[::core::prelude::v1::test]
    fn history_failure_is_not_safe_to_write() {
        let s = scope();
        let mut calls = 0;
        assert!(
            execute(
                &mut |method, _| -> Result<Value> {
                    calls += 1;
                    assert_eq!(method, "github.write.history");
                    anyhow::bail!("ledger unavailable")
                },
                Work::Prepare(s, Action::Comment("body".into()))
            )
            .is_err()
        );
        assert_eq!(calls, 1);
    }
    #[::core::prelude::v1::test]
    fn uncertain_submit_is_called_once_and_recovery_only_queries_original_id_head() {
        let s = scope();
        let c = Confirmation::parse(
            s.clone(),
            Action::Comment("body".into()),
            prepared(&s),
            now(),
        )
        .unwrap();
        let id = c.mutation.clone();
        let mut calls = 0;
        assert!(
            execute(
                &mut |method, _| -> Result<Value> {
                    calls += 1;
                    assert_eq!(method, "github.write.submit");
                    anyhow::bail!("connection lost after dispatch")
                },
                Work::Submit(Box::new(c))
            )
            .is_err()
        );
        assert_eq!(calls, 1);
        let mut current = s.clone();
        current.head = "b".repeat(40);
        let reply=execute(&mut |method,p|->Result<Value>{assert_eq!(method,"github.write.result");assert_eq!(p["mutationId"],id);assert_eq!(p["expectedHead"],s.head);Ok(json!({"mutationId":id,"status":"uncertain","result":null,"error":{"code":"timeout","message":"unknown"}}))},Work::Result {display:current,original:s.clone(),id:id.clone()}).unwrap();
        assert!(matches!(reply,Reply::Mutation {value,..} if value["status"]=="uncertain"));
    }
    #[::core::prelude::v1::test]
    fn comment_utf8_byte_limit_and_merge_method_allowlist() {
        assert!(Action::Comment(" \n".into()).value().is_err());
        assert!(Action::Comment("text\0text".into()).value().is_err());
        assert!(Action::Comment("中".repeat(10923)).value().is_err());
        assert!(Action::Comment("x".repeat(32768)).value().is_ok());
        assert!(Action::Merge("admin".into()).value().is_err());
        assert_eq!(
            Action::Merge("rebase".into()).value().unwrap(),
            json!({"kind":"merge","method":"rebase"})
        );
    }
    #[::core::prelude::v1::test]
    fn success_requires_verified_matching_review_or_merged_result() {
        let s = scope();
        let id = Uuid::new_v4().to_string();
        let mut v = json!({"mutationId":id,"status":"succeeded","result":null,"error":null});
        assert!(status(&v, &id, &s).is_err());
        v["result"] = json!({"kind":"review","reviewId":123,"url":"https://github.com/fixture/repo/pull/42#pullrequestreview-123","commit":s.head,"state":"COMMENTED"});
        status(&v, &id, &s).unwrap();
        v["result"]["commit"] = json!("b".repeat(40));
        assert!(status(&v, &id, &s).is_err());
        v["result"] = json!({"kind":"merge","merged":true,"commit":"c".repeat(40)});
        status(&v, &id, &s).unwrap();
        v["status"] = json!("unknown");
        assert!(status(&v, &id, &s).is_err());
    }
    #[::core::prelude::v1::test]
    fn expired_confirmation_never_reaches_submit_transport() {
        let s = scope();
        let mut c = Confirmation::parse(
            s.clone(),
            Action::Comment("body".into()),
            prepared(&s),
            now(),
        )
        .unwrap();
        c.received = std::time::Instant::now() - Duration::from_secs(61);
        let mut called = false;
        assert!(
            execute(
                &mut |_, _| -> Result<Value> {
                    called = true;
                    Ok(Value::Null)
                },
                Work::Submit(Box::new(c))
            )
            .is_err()
        );
        assert!(!called);
    }
    #[::core::prelude::v1::test]
    fn missing_unresolved_mutation_is_not_a_retry_safe_empty_history() {
        let s = scope();
        let id = Uuid::new_v4().to_string();
        let prior =
            json!({"mutations":[{"mutationId":id,"expectedHead":s.head,"status":"uncertain"}]});
        let fresh = super::retain_unresolved(&prior, clean(&s));
        assert!(blocked(&fresh));
        assert_eq!(fresh["mutations"][0]["mutationId"], id);
    }
}
