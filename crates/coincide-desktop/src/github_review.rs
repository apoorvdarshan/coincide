//! Native, read-only GitHub PR metadata panel. Parent mounts this entity and calls
//! set_context on every thread/root change. Repository is explicitly entered by
//! the user. All Engine calls run in one background worker, never GPUI render.
use anyhow::{Context as _, Result, ensure};
use coincide_core::api::{SharedEngine, call};
use gpui_kit::{
    component::{
        button::*,
        input::{Input, InputState},
    },
    *,
};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::mpsc,
    time::{Duration, Instant},
};

const LIMIT: usize = 30;
const STATES: &[&str] = &["open", "closed", "merged", "all"];
#[derive(Clone, Debug, PartialEq, Eq)]
struct Binding {
    thread: String,
    root: String,
    repository: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum View {
    List(String),
    Detail { number: u64, head: String },
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Request {
    binding: Binding,
    view: View,
}
fn head(value: &str) -> bool {
    value.len() == 40 && value.bytes().all(|b| b.is_ascii_hexdigit())
}
fn repository(value: &str) -> bool {
    let pieces = value.split('/').collect::<Vec<_>>();
    pieces.len() == 2
        && pieces.iter().all(|s| {
            !s.is_empty()
                && s.len() <= 100
                && *s != "."
                && *s != ".."
                && !s.starts_with('-')
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
        })
}
fn validate_pr(pr: &Value, repo: &str) -> Result<()> {
    let number = pr["number"]
        .as_u64()
        .filter(|n| *n > 0)
        .context("Invalid PR number")?;
    for key in [
        "title",
        "url",
        "state",
        "headRefOid",
        "headRefName",
        "baseRefName",
    ] {
        ensure!(pr[key].is_string(), "Invalid PR {key}");
    }
    ensure!(
        pr["isDraft"].is_boolean() && head(pr["headRefOid"].as_str().unwrap_or("")),
        "Invalid PR head or draft state"
    );
    let expected = format!("https://github.com/{repo}/pull/{number}");
    ensure!(
        pr["url"]
            .as_str()
            .is_some_and(|url| url.eq_ignore_ascii_case(&expected)),
        "PR URL does not match repository/number"
    );
    Ok(())
}
fn validate_payload(request: &Request, payload: &Value) -> Result<()> {
    ensure!(
        payload["threadId"] == request.binding.thread
            && payload["expectedRoot"] == request.binding.root
            && payload["repository"] == request.binding.repository,
        "PR response belongs to another thread/root/repository"
    );
    match &request.view {
        View::List(_) => {
            ensure!(
                payload["kind"] == "list"
                    && payload["limit"].as_u64() == Some(LIMIT as u64)
                    && payload["truncated"].is_boolean(),
                "Invalid PR list envelope"
            );
            let rows = payload["pullRequests"]
                .as_array()
                .context("Missing PR list")?;
            ensure!(rows.len() <= LIMIT, "PR list exceeds requested limit");
            let mut numbers = std::collections::HashSet::new();
            for pr in rows {
                validate_pr(pr, &request.binding.repository)?;
                ensure!(
                    numbers.insert(pr["number"].as_u64()),
                    "Duplicate PR in list"
                );
            }
        }
        View::Detail { number, head } => {
            ensure!(
                payload["kind"] == "read" && payload["expectedHead"] == *head,
                "PR detail head binding changed"
            );
            let pr = &payload["pullRequest"];
            validate_pr(pr, &request.binding.repository)?;
            ensure!(
                pr["number"].as_u64() == Some(*number) && pr["headRefOid"] == *head,
                "PR head changed; refresh the list"
            );
            ensure!(
                pr["body"].is_string()
                    && pr["reviews"].is_array()
                    && pr["statusCheckRollup"].is_array(),
                "Incomplete PR detail"
            );
        }
    }
    Ok(())
}
fn fetch(api: &mut impl FnMut(&str, Value) -> Result<Value>, request: &Request) -> Result<Value> {
    let b = &request.binding;
    ensure!(
        !b.thread.is_empty()
            && b.thread.len() <= 128
            && Path::new(&b.root).is_absolute()
            && repository(&b.repository),
        "Choose a valid thread/root and owner/repository"
    );
    let mut params = json!({"threadId":b.thread,"expectedRoot":b.root,"repository":b.repository});
    let method = match &request.view {
        View::List(state) => {
            ensure!(STATES.contains(&state.as_str()), "Invalid PR state filter");
            params["state"] = json!(state);
            params["limit"] = json!(LIMIT);
            "github.pr.list"
        }
        View::Detail {
            number,
            head: expected,
        } => {
            ensure!(*number > 0 && head(expected), "Invalid PR number/head");
            params["number"] = json!(number);
            params["expectedHead"] = json!(expected);
            "github.pr.read"
        }
    };
    let start = api(method, params)?;
    let id = start["operationId"]
        .as_str()
        .context("Missing GitHub operation ID")?;
    let deadline = Instant::now() + Duration::from_secs(110);
    loop {
        let reply = api(
            "github.result",
            json!({"threadId":b.thread,"expectedRoot":b.root,"operationId":id}),
        )?;
        if reply["ready"] == true {
            let payload = reply["result"].clone();
            if let Some(error) = payload["error"].as_str() {
                anyhow::bail!(
                    "{}: {}",
                    payload["code"].as_str().unwrap_or("github_error"),
                    error
                );
            }
            validate_payload(request, &payload)?;
            return Ok(payload);
        }
        ensure!(reply["ready"] == false, "Invalid GitHub polling response");
        ensure!(
            Instant::now() < deadline,
            "GitHub read timed out; retry with Refresh"
        );
        std::thread::sleep(Duration::from_millis(80));
    }
}
fn current(generation: u64, request: &Request, active: Option<&(u64, Request)>) -> bool {
    active.is_some_and(|(g, r)| *g == generation && r == request)
}
fn text(value: &Value, key: &str) -> String {
    value[key]
        .as_str()
        .unwrap_or("Unknown / not supplied")
        .to_owned()
}
fn excerpt(value: &str, max: usize) -> String {
    let mut s = value.chars().take(max).collect::<String>();
    if value.chars().count() > max {
        s.push_str("… [display truncated]");
    }
    s
}

pub struct GitHubReviewPanel {
    engine: SharedEngine,
    scope: Option<(String, String)>,
    repository: Entity<InputState>,
    state: String,
    generation: u64,
    active: Option<(u64, Request)>,
    busy: bool,
    list: Vec<Value>,
    truncated: bool,
    selected: Option<(u64, String)>,
    detail: Option<Value>,
    notice: String,
    tx: mpsc::Sender<(u64, Request, Result<Value>)>,
    rx: mpsc::Receiver<(u64, Request, Result<Value>)>,
    _poll: Task<()>,
}
impl GitHubReviewPanel {
    pub fn new(engine: SharedEngine, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = mpsc::channel();
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this.update_in(cx, |this, _, cx| this.poll(cx)).is_err() {
                    break;
                }
            }
        });
        Self {
            engine,
            scope: None,
            repository: cx.new(|cx| {
                InputState::new(window, cx).placeholder("Explicit GitHub repository: owner/name")
            }),
            state: "open".into(),
            generation: 0,
            active: None,
            busy: false,
            list: Vec::new(),
            truncated: false,
            selected: None,
            detail: None,
            notice: "Choose a conversation and enter its GitHub repository.".into(),
            tx,
            rx,
            _poll: poll,
        }
    }
    /// root must be the canonical stored-thread working directory. No calls or
    /// filesystem I/O run here. Changing scope invalidates every visible PR/head.
    pub fn set_context(&mut self, scope: Option<(String, String)>, cx: &mut Context<Self>) {
        if self.scope == scope {
            return;
        }
        self.scope = scope;
        self.generation = self.generation.wrapping_add(1);
        self.active = None;
        self.list.clear();
        self.detail = None;
        self.selected = None;
        self.truncated = false;
        self.notice = if self.busy {
            "Waiting for the previous read; its result will be discarded."
        } else {
            "Enter owner/name and load pull requests for this context."
        }
        .into();
        cx.notify();
    }
    fn load_list(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some((thread, root)) = self.scope.clone() else {
            return;
        };
        let repository = self.repository.read(cx).value().trim().to_string();
        if !self::repository(&repository) {
            self.list.clear();
            self.detail = None;
            self.selected = None;
            self.active = None;
            self.truncated = false;
            self.notice = "Enter a GitHub repository as owner/name.".into();
            cx.notify();
            return;
        }
        self.list.clear();
        self.selected = None;
        self.detail = None;
        self.truncated = false;
        self.start(
            Request {
                binding: Binding {
                    thread,
                    root,
                    repository,
                },
                view: View::List(self.state.clone()),
            },
            cx,
        );
    }
    fn load_detail(&mut self, number: u64, head: String, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        let Some((_, active)) = &self.active else {
            return;
        };
        let binding = active.binding.clone();
        self.detail = None;
        self.selected = Some((number, head.clone()));
        self.start(
            Request {
                binding,
                view: View::Detail { number, head },
            },
            cx,
        );
    }
    fn start(&mut self, request: Request, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.active = Some((generation, request.clone()));
        self.busy = true;
        self.notice = "Loading GitHub metadata…".into();
        let engine = self.engine.clone();
        let tx = self.tx.clone();
        std::thread::spawn(move || {
            let result = fetch(
                &mut |method, params| call(&engine, method, params),
                &request,
            );
            let _ = tx.send((generation, request, result));
        });
        cx.notify();
    }
    fn poll(&mut self, cx: &mut Context<Self>) {
        let Ok((generation, request, result)) = self.rx.try_recv() else {
            return;
        };
        self.busy = false;
        if !current(generation, &request, self.active.as_ref()) {
            self.notice = "Previous result discarded. Load the current context when ready.".into();
            cx.notify();
            return;
        }
        match result {
            Ok(payload) => match request.view {
                View::List(_) => {
                    self.list = payload["pullRequests"]
                        .as_array()
                        .cloned()
                        .unwrap_or_default();
                    self.truncated = payload["truncated"] == true;
                    self.notice = format!(
                        "{} PRs loaded. Select a row for exact-head detail.",
                        self.list.len()
                    );
                }
                View::Detail { .. } => {
                    self.detail = Some(payload["pullRequest"].clone());
                    self.notice="Read-only detail loaded for the selected head. Refresh before relying on current server state.".into();
                }
            },
            Err(error) => {
                self.detail = None;
                self.notice = format!("{error}. Refresh the list to retry.");
            }
        }
        cx.notify();
    }
}
impl Render for GitHubReviewPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut pane = div()
            .id("github-review-panel")
            .size_full()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .child("GitHub pull requests")
            .child(div().text_sm().child(
                "Read-only. My PRs / Review requested filters and mutations are unavailable.",
            ))
            .child(Input::new(&self.repository))
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .children(STATES.iter().map(|state| {
                        let state = *state;
                        Button::new(SharedString::from(format!("github-state-{state}")))
                            .label(if self.state == state {
                                format!("• {state}")
                            } else {
                                state.to_owned()
                            })
                            .disabled(self.busy)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.state = state.into();
                                this.load_list(cx);
                            }))
                    })),
            )
            .child(
                Button::new("github-refresh")
                    .label("Load / refresh PR list")
                    .disabled(self.busy || self.scope.is_none())
                    .on_click(cx.listener(|this, _, _, cx| this.load_list(cx))),
            )
            .child(div().text_sm().child(self.notice.clone()));
        if let Some((_, request)) = &self.active {
            pane = pane.child(div().text_sm().child(format!(
                "Repository: {}\nRoot: {}",
                request.binding.repository, request.binding.root
            )));
        }
        let mut body = div()
            .id("github-review-scroll")
            .flex_1()
            .min_h_0()
            .overflow_y_scroll()
            .flex()
            .flex_col()
            .gap_2();
        if self.selected.is_some() {
            body = body.child(
                Button::new("github-back")
                    .label("Back to PR list")
                    .disabled(self.busy)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.selected = None;
                        this.detail = None;
                        cx.notify();
                    })),
            );
        }
        if let Some(pr) = &self.detail {
            let number = pr["number"].as_u64().unwrap_or(0);
            let full_head = text(pr, "headRefOid");
            body = body
                .child(format!("#{number} {}", text(pr, "title")))
                .child(format!(
                    "{}{} · author {}",
                    text(pr, "state"),
                    if pr["isDraft"] == true {
                        " (Draft)"
                    } else {
                        ""
                    },
                    pr["author"]["login"]
                        .as_str()
                        .unwrap_or("Unknown / deleted account")
                ))
                .child(format!(
                    "{} → {}\nHead: {full_head}",
                    text(pr, "headRefName"),
                    text(pr, "baseRefName")
                ))
                .child(format!(
                    "Updated: {}\nReview decision: {}\nMergeability: {} · {}",
                    text(pr, "updatedAt"),
                    text(pr, "reviewDecision"),
                    text(pr, "mergeable"),
                    text(pr, "mergeStateStatus")
                ));
            if pr["additions"].is_number() && pr["deletions"].is_number() {
                body = body.child(format!(
                    "+{} / -{} · changed files {}",
                    pr["additions"],
                    pr["deletions"],
                    pr["changedFiles"]
                        .as_u64()
                        .map(|n| n.to_string())
                        .unwrap_or_else(|| "Unknown".into())
                ));
            }
            let url = text(pr, "url");
            let copied = url.clone();
            body=body.child(div().text_sm().child(url)).child(Button::new("github-copy-url").label("Copy PR URL").on_click(move |_,_,cx|cx.write_to_clipboard(ClipboardItem::new_string(copied.clone()))))
                .child(div().flex().flex_wrap().gap_2().children(["Approve","Request changes","Comment","Merge","Check out"].into_iter().enumerate().map(|(index,label)|Button::new(SharedString::from(format!("github-unavailable-{index}"))).label(label).disabled(true))))
                .child("Review submission, merge, checkout, My PRs and Review requested filters are unavailable in this read-only panel.")
                .child("Checks");
            let checks = pr["statusCheckRollup"].as_array();
            if checks.is_none_or(|checks| checks.is_empty()) {
                body = body.child("No checks were reported; this is not proof of passing checks.");
            }
            for (index, check) in checks.into_iter().flatten().take(100).enumerate() {
                body = body.child(
                    div()
                        .id(SharedString::from(format!("github-check-{number}-{index}")))
                        .text_sm()
                        .child(format!(
                            "{} · status {} · conclusion {}",
                            check["name"]
                                .as_str()
                                .or(check["context"].as_str())
                                .unwrap_or("Unnamed check"),
                            check["status"]
                                .as_str()
                                .or(check["state"].as_str())
                                .unwrap_or("Unknown"),
                            check["conclusion"].as_str().unwrap_or("Not supplied")
                        )),
                );
            }
            if checks.is_some_and(|v| v.len() > 100) {
                body = body.child("Showing first 100 checks.");
            }
            body = body
                .child("Description (Markdown source)")
                .child(excerpt(pr["body"].as_str().unwrap_or(""), 30_000))
                .child("Reviews");
            let reviews = pr["reviews"].as_array();
            if reviews.is_none_or(|reviews| reviews.is_empty()) {
                body = body.child(
                    "No review records were reported. Inline review threads are not included.",
                );
            }
            for (index, review) in reviews.into_iter().flatten().take(100).enumerate() {
                let commit = review["commit"]["oid"].as_str();
                body = body.child(
                    div()
                        .id(SharedString::from(format!(
                            "github-review-{number}-{index}"
                        )))
                        .p_2()
                        .border_1()
                        .child(format!(
                            "{} · {} · {}",
                            review["author"]["login"]
                                .as_str()
                                .unwrap_or("Unknown / deleted account"),
                            text(review, "state"),
                            text(review, "submittedAt")
                        ))
                        .child(format!(
                            "Review commit: {}{}",
                            commit.unwrap_or("Not supplied"),
                            if commit.is_some_and(|oid| oid != full_head) {
                                " (different from selected PR head)"
                            } else {
                                ""
                            }
                        ))
                        .child(excerpt(review["body"].as_str().unwrap_or(""), 8000)),
                );
            }
            if reviews.is_some_and(|v| v.len() > 100) {
                body = body.child("Showing first 100 reviews.");
            }
        } else if self.selected.is_some() {
            body=body.child("Detail is not available for this selection. Refresh the list after errors or head changes.");
        } else {
            if self.list.is_empty() && !self.busy {
                body = body.child("No pull requests loaded for this filter.");
            }
            for pr in &self.list {
                let number = pr["number"].as_u64().unwrap_or(0);
                let head = text(pr, "headRefOid");
                body = body.child(
                    Button::new(SharedString::from(format!("github-pr-{number}")))
                        .label(format!(
                            "#{number} {} · {}{}\n{} → {}",
                            excerpt(&text(pr, "title"), 180),
                            text(pr, "state"),
                            if pr["isDraft"] == true {
                                " / Draft"
                            } else {
                                ""
                            },
                            text(pr, "headRefName"),
                            text(pr, "baseRefName")
                        ))
                        .disabled(self.busy)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.load_detail(number, head.clone(), cx)
                        })),
                );
            }
            if self.truncated {
                body=body.child("List may be truncated at 30 pull requests. Use a narrower state filter; pagination is unavailable.");
            }
        }
        pane.child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::{Binding, LIMIT, Request, View, current, fetch, repository, validate_payload};
    use anyhow::Result;
    use serde_json::{Value, json};
    fn request(view: View) -> Request {
        Request {
            binding: Binding {
                thread: "thread-a".into(),
                root: std::env::temp_dir().to_str().unwrap().into(),
                repository: "fixture/repo".into(),
            },
            view,
        }
    }
    fn pr() -> Value {
        json!({"number":42,"title":"Unicode café 中文","url":"https://github.com/fixture/repo/pull/42","state":"OPEN","isDraft":false,"headRefOid":"a".repeat(40),"headRefName":"feature/test","baseRefName":"main","body":"# Description\n\nActual metadata.","author":null,"updatedAt":null,"additions":null,"deletions":null,"changedFiles":null,"mergeable":null,"mergeStateStatus":null,"reviewDecision":null,"reviews":[],"statusCheckRollup":[]})
    }
    fn payload(r: &Request) -> Value {
        let b = &r.binding;
        match &r.view {
            View::List(_) => {
                json!({"kind":"list","threadId":b.thread,"expectedRoot":b.root,"repository":b.repository,"pullRequests":[pr()],"limit":LIMIT,"truncated":false})
            }
            View::Detail { head, .. } => {
                json!({"kind":"read","threadId":b.thread,"expectedRoot":b.root,"repository":b.repository,"expectedHead":head,"pullRequest":pr()})
            }
        }
    }
    #[test]
    fn list_uses_chosen_contract_and_polls_with_same_thread_root() {
        let request = request(View::List("open".into()));
        let result = payload(&request);
        let mut calls = Vec::new();
        let got = fetch(
            &mut |method, params| -> Result<Value> {
                calls.push((method.to_owned(), params));
                Ok(if method == "github.pr.list" {
                    json!({"operationId":"op-list"})
                } else {
                    json!({"ready":true,"result":result})
                })
            },
            &request,
        )
        .unwrap();
        assert_eq!(got["pullRequests"][0]["title"], "Unicode café 中文");
        assert_eq!(calls.len(), 2);
        assert_eq!(
            calls[0],
            (
                "github.pr.list".into(),
                json!({"threadId":request.binding.thread,"expectedRoot":request.binding.root,"repository":"fixture/repo","state":"open","limit":30})
            )
        );
        assert_eq!(
            calls[1],
            (
                "github.result".into(),
                json!({"threadId":request.binding.thread,"expectedRoot":request.binding.root,"operationId":"op-list"})
            )
        );
    }
    #[test]
    fn read_binds_selected_list_head_and_preserves_nullable_review_metadata() {
        let request = request(View::Detail {
            number: 42,
            head: "a".repeat(40),
        });
        let mut result = payload(&request);
        result["pullRequest"]["reviews"] = json!([{"id":"review-1","state":"COMMENTED","body":"  café 中文\n","author":null,"commit":{"oid":"b".repeat(40)},"submittedAt":null}]);
        let mut calls = Vec::new();
        let got = fetch(
            &mut |method, p| -> Result<Value> {
                calls.push((method.to_owned(), p));
                Ok(if method == "github.pr.read" {
                    json!({"operationId":"op-read"})
                } else {
                    json!({"ready":true,"result":result})
                })
            },
            &request,
        )
        .unwrap();
        assert_eq!(calls[0].1["expectedHead"], "a".repeat(40));
        assert_eq!(calls[0].1["number"], 42);
        assert!(got["pullRequest"]["reviewDecision"].is_null());
        assert!(got["pullRequest"]["reviews"][0]["author"].is_null());
        assert_eq!(got["pullRequest"]["reviews"][0]["body"], "  café 中文\n");
    }
    #[test]
    fn head_changed_error_is_returned_once_without_detail_or_retry() {
        let request = request(View::Detail {
            number: 42,
            head: "a".repeat(40),
        });
        let mut calls = 0;
        let error = fetch(
            &mut |method, _| -> Result<Value> {
                calls += 1;
                Ok(if method == "github.pr.read" {
                    json!({"operationId":"op"})
                } else {
                    json!({"ready":true,"result":{"code":"head_changed","error":"PR head changed"}})
                })
            },
            &request,
        )
        .unwrap_err();
        assert!(error.to_string().contains("head_changed"));
        assert_eq!(calls, 2);
    }
    #[test]
    fn wrong_thread_root_repository_number_or_head_never_becomes_detail() {
        let request = request(View::Detail {
            number: 42,
            head: "a".repeat(40),
        });
        for (key, value) in [
            ("threadId", json!("thread-b")),
            ("expectedRoot", json!("/other")),
            ("repository", json!("fixture/other")),
            ("expectedHead", json!("b".repeat(40))),
        ] {
            let mut result = payload(&request);
            result[key] = value;
            assert!(validate_payload(&request, &result).is_err(), "{key}");
        }
        for (key, value) in [
            ("number", json!(43)),
            ("headRefOid", json!("b".repeat(40))),
            ("url", json!("https://github.com/fixture/other/pull/42")),
        ] {
            let mut result = payload(&request);
            result["pullRequest"][key] = value;
            assert!(validate_payload(&request, &result).is_err(), "{key}");
        }
    }
    #[test]
    fn generation_and_full_selection_identity_reject_stale_completion() {
        let first = request(View::Detail {
            number: 42,
            head: "a".repeat(40),
        });
        let active = (7, first.clone());
        assert!(current(7, &first, Some(&active)));
        assert!(!current(6, &first, Some(&active)));
        assert!(!current(7, &first, None));
        for other in [
            request(View::Detail {
                number: 43,
                head: "a".repeat(40),
            }),
            request(View::Detail {
                number: 42,
                head: "b".repeat(40),
            }),
            Request {
                binding: Binding {
                    repository: "fixture/other".into(),
                    ..first.binding.clone()
                },
                view: first.view.clone(),
            },
            Request {
                binding: Binding {
                    thread: "thread-b".into(),
                    ..first.binding.clone()
                },
                view: first.view.clone(),
            },
        ] {
            assert!(!current(7, &other, Some(&active)));
        }
    }
    #[test]
    fn state_and_list_bounds_reject_unsupported_or_incomplete_data() {
        let r = request(View::List("all".into()));
        let mut result = payload(&r);
        result["truncated"] = json!(true);
        validate_payload(&r, &result).unwrap();
        result["pullRequests"] = json!(vec![pr(); 31]);
        assert!(validate_payload(&r, &result).is_err());
        result = payload(&r);
        result["pullRequests"][0]["headRefOid"] = Value::Null;
        assert!(validate_payload(&r, &result).is_err());
        let r = request(View::List("mine".into()));
        let mut called = false;
        assert!(
            fetch(
                &mut |_, _| -> Result<Value> {
                    called = true;
                    Ok(Value::Null)
                },
                &r
            )
            .is_err()
        );
        assert!(!called);
    }
    #[test]
    fn repository_input_is_explicit_and_not_a_url_or_shell_fragment() {
        assert!(repository("owner/repo-name"));
        for invalid in [
            "",
            "owner",
            "a/b/c",
            "https://github.com/a/b",
            "a/b;id",
            "-owner/repo",
            "../repo",
            "a/..",
            "a/b\n",
        ] {
            assert!(!repository(invalid), "{invalid}");
        }
    }
}
