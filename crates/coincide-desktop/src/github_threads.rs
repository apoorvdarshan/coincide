//! Native read-only inline review browser. Injected transport executes only on
//! one background worker; the parent supplies authoritative thread/root context.
use anyhow::{Context as _, Result, bail, ensure};
use coincide_core::github_threads::{InlineComment, Page, ReviewThread, Scope};
use gpui_kit::{
    App, AppContext, ClipboardItem, Context, Entity, InteractiveElement, IntoElement,
    ParentElement, Render, SharedString, StatefulInteractiveElement, Styled, Subscription, Task,
    VisualContext, Window,
    base::Disableable,
    component::{
        button::Button,
        input::{Input, InputEvent, InputState},
    },
    div, px,
};
use serde_json::{Value, json};
use std::{
    collections::HashSet,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
pub type ThreadsTransport = Arc<dyn Fn(&str, Value) -> Result<Value> + Send + Sync>;
const MAX_UI_BYTES: usize = 16 * 1024 * 1024;
#[derive(Clone, Debug, PartialEq, Eq)]
enum Read {
    Threads { cursor: Option<String> },
    Comments { id: String, cursor: Option<String> },
}
#[derive(Clone, Debug, PartialEq, Eq)]
struct Request {
    scope: Scope,
    read: Read,
}
impl Request {
    fn params(&self) -> Value {
        let mut p = self.scope.params();
        match &self.read {
            Read::Threads { cursor } => p["cursor"] = json!(cursor),
            Read::Comments { id, cursor } => {
                p["reviewThreadId"] = json!(id);
                p["cursor"] = json!(cursor);
            }
        }
        p
    }
    fn cursor(&self) -> Option<&str> {
        match &self.read {
            Read::Threads { cursor } | Read::Comments { cursor, .. } => cursor.as_deref(),
        }
    }
}
fn validate(request: &Request, page: &Page) -> Result<()> {
    ensure!(
        page.scope == request.scope && page.cursor.as_deref() == request.cursor(),
        "Inline review page belongs to another scope/cursor"
    );
    ensure!(
        page.has_next_page == page.next_cursor.is_some(),
        "Inconsistent pagination state"
    );
    ensure!(
        !page.has_next_page
            || (page.next_cursor.is_some() && page.next_cursor.as_deref() != request.cursor()),
        "Pagination cursor failed to advance"
    );
    ensure!(
        page.next_cursor
            .as_ref()
            .is_none_or(|c| !c.is_empty() && c.len() <= 1024),
        "Invalid next cursor"
    );
    ensure!(
        serde_json::to_vec(page)?.len() <= 3 * 1024 * 1024,
        "Inline review response exceeds budget"
    );
    match &request.read {
        Read::Threads { .. } => {
            ensure!(
                page.kind == "threads"
                    && page.review_thread_id.is_none()
                    && page.comments.is_empty()
                    && page.threads.len() <= 10,
                "Invalid review-thread page"
            );
            let mut ids = HashSet::new();
            for thread in &page.threads {
                ensure!(
                    !thread.id.is_empty() && ids.insert(&thread.id) && thread.comments.len() <= 20,
                    "Duplicate or oversized thread"
                );
            }
        }
        Read::Comments { id, .. } => ensure!(
            page.kind == "comments"
                && page.review_thread_id.as_ref() == Some(id)
                && page.threads.is_empty()
                && page.comments.len() <= 20,
            "Invalid comment page"
        ),
    }
    Ok(())
}
fn fetch(transport: &ThreadsTransport, request: &Request, cancel: &AtomicBool) -> Result<Page> {
    request.scope.validate()?;
    ensure!(!cancel.load(Ordering::Acquire), "Read cancelled");
    let method = match request.read {
        Read::Threads { .. } => "github.threads.list",
        Read::Comments { .. } => "github.threads.comments",
    };
    let accepted = transport(method, request.params())?;
    let id = accepted["operationId"]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 128)
        .context("Missing inline review operation")?;
    let mut params = request.scope.params();
    params["operationId"] = json!(id);
    let deadline = Instant::now() + Duration::from_secs(25);
    loop {
        if cancel.load(Ordering::Acquire) || Instant::now() >= deadline {
            let _ = transport("github.threads.cancel", params.clone());
            bail!("Inline review read cancelled or timed out");
        }
        let reply = transport("github.threads.result", params.clone())?;
        if reply["ready"] == true {
            let result = &reply["result"];
            if result.get("error").is_some() {
                let code = result["code"].as_str().unwrap_or("read_failed");
                ensure!(code.len() <= 100, "Invalid error envelope");
                bail!("{code}: refresh the selected PR or retry the read");
            }
            let page: Page = serde_json::from_value(result.clone())?;
            validate(request, &page)?;
            return Ok(page);
        }
        ensure!(
            reply["ready"] == false,
            "Invalid inline review polling envelope"
        );
        std::thread::sleep(Duration::from_millis(80));
    }
}
#[derive(Default)]
struct State {
    scope: Option<Scope>,
    threads: Vec<ReviewThread>,
    next: Option<String>,
    selected: Option<String>,
    limit_reached: bool,
}
impl State {
    fn clear(&mut self) {
        *self = Self::default();
    }
    fn apply(&mut self, request: &Request, page: Page) -> Result<()> {
        validate(request, &page)?;
        ensure!(
            self.scope.as_ref() == Some(&request.scope),
            "Scope changed before display"
        );
        let mut candidate = self.threads.clone();
        let mut next = self.next.clone();
        match &request.read {
            Read::Threads { cursor } => {
                ensure!(
                    self.next.as_deref() == cursor.as_deref(),
                    "Thread cursor is stale"
                );
                for thread in page.threads {
                    ensure!(
                        !candidate.iter().any(|old| old.id == thread.id),
                        "Duplicate thread across pages; refresh"
                    );
                    candidate.push(thread);
                }
                ensure!(
                    candidate.len() <= 100,
                    "Display limit reached (100 threads)"
                );
                next = page.next_cursor;
            }
            Read::Comments { id, cursor } => {
                let thread = candidate
                    .iter_mut()
                    .find(|t| &t.id == id)
                    .context("Selected review thread disappeared")?;
                ensure!(thread.next_cursor == *cursor, "Comment cursor is stale");
                let mut ids: HashSet<String> =
                    thread.comments.iter().map(|c| c.id.clone()).collect();
                for comment in page.comments {
                    ensure!(
                        ids.insert(comment.id.clone()),
                        "Duplicate comment across pages; refresh"
                    );
                    thread.comments.push(comment);
                }
                ensure!(
                    thread.comments.len() <= 500,
                    "Display limit reached (500 comments per thread)"
                );
                thread.next_cursor = page.next_cursor;
                thread.has_next_page = page.has_next_page;
            }
        }
        ensure!(
            serde_json::to_vec(&candidate)?.len() <= MAX_UI_BYTES,
            "Display byte budget reached; refresh or narrow pages"
        );
        self.threads = candidate;
        self.next = next;
        if self.selected.is_none() {
            self.selected = self.threads.first().map(|t| t.id.clone());
        }
        Ok(())
    }
}
fn visible(thread: &ReviewThread, filter: &str, mention: &str) -> bool {
    let state = match filter {
        "unresolved" => !thread.is_resolved,
        "resolved" => thread.is_resolved,
        "outdated" => thread.is_outdated,
        _ => true,
    };
    state
        && (mention.is_empty()
            || thread.comments.iter().any(|c| {
                c.mentions
                    .iter()
                    .any(|m| m.text.eq_ignore_ascii_case(mention))
            }))
}
fn short(text: &str, max: usize) -> String {
    let mut s: String = text.chars().take(max).collect();
    if text.chars().count() > max {
        s.push_str("… [display excerpt; Copy comment for loaded text]");
    }
    s
}
type Completion = (u64, Request, Result<Page>);
pub struct GitHubThreadsPanel {
    transport: ThreadsTransport,
    context: Option<(String, String)>,
    repository: Entity<InputState>,
    number: Entity<InputState>,
    head: Entity<InputState>,
    mention: Entity<InputState>,
    state: State,
    filter: String,
    notice: String,
    generation: u64,
    active: Option<(u64, Request)>,
    cancel: Option<Arc<AtomicBool>>,
    busy: bool,
    sender: mpsc::SyncSender<Completion>,
    receiver: mpsc::Receiver<Completion>,
    _poll: Task<()>,
    _subscriptions: Vec<Subscription>,
}
impl GitHubThreadsPanel {
    pub fn new(transport: ThreadsTransport, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let repository =
            cx.new(|cx| InputState::new(window, cx).placeholder("Explicit owner/repository"));
        let number = cx.new(|cx| InputState::new(window, cx).placeholder("PR number"));
        let head =
            cx.new(|cx| InputState::new(window, cx).placeholder("Full 40-character head SHA"));
        let mention = cx.new(|cx| {
            InputState::new(window, cx).placeholder("Mention text filter, e.g. @octocat")
        });
        let mut subscriptions = Vec::new();
        for field in [&repository, &number, &head] {
            subscriptions.push(cx.subscribe(field, |this, _, event, cx| {
                if matches!(event, InputEvent::Change) {
                    this.invalidate(cx);
                }
            }));
        }
        subscriptions.push(cx.subscribe(&mention, |_, _, _: &InputEvent, cx| cx.notify()));
        let (sender, receiver) = mpsc::sync_channel(1);
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(80))
                    .await;
                if this.update_in(cx, |this, _, cx| this.poll(cx)).is_err() {
                    break;
                }
            }
        });
        Self {
            transport,
            context: None,
            repository,
            number,
            head,
            mention,
            state: State::default(),
            filter: "all".into(),
            notice: "Choose a thread and enter an explicit repository, PR number and full head."
                .into(),
            generation: 0,
            active: None,
            cancel: None,
            busy: false,
            sender,
            receiver,
            _poll: poll,
            _subscriptions: subscriptions,
        }
    }
    pub fn set_context(&mut self, context: Option<(String, String)>, cx: &mut Context<Self>) {
        if self.context != context {
            self.context = context;
            self.invalidate(cx);
        }
    }
    /// Optional parent selection hook. No network/Engine lock here. Inputs remain
    /// usable when the existing read panel has no public selection accessor.
    pub fn set_pr(
        &mut self,
        repository: String,
        number: u64,
        head: String,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.repository.read(cx).value().to_string() == repository
            && self.number.read(cx).value().to_string() == number.to_string()
            && self.head.read(cx).value().to_string() == head
        {
            return;
        }
        self.repository
            .update(cx, |input, cx| input.set_value(repository, window, cx));
        self.number.update(cx, |input, cx| {
            input.set_value(number.to_string(), window, cx)
        });
        self.head
            .update(cx, |input, cx| input.set_value(head, window, cx));
        self.invalidate(cx);
    }
    fn invalidate(&mut self, cx: &mut Context<Self>) {
        if let Some(cancel) = &self.cancel {
            cancel.store(true, Ordering::Release);
        }
        self.generation = self.generation.wrapping_add(1);
        self.active = None;
        self.state.clear();
        self.notice =
            "Context changed. Load this PR's current full head to read inline reviews.".into();
        cx.notify();
    }
    fn input_scope(&self, cx: &App) -> Result<Scope> {
        let (thread, root) = self
            .context
            .clone()
            .context("Choose a conversation first")?;
        let scope = Scope {
            thread_id: thread,
            expected_root: root,
            repository: self.repository.read(cx).value().trim().to_string(),
            number: self.number.read(cx).value().trim().parse()?,
            expected_head: self.head.read(cx).value().trim().to_string(),
        };
        scope.validate()?;
        Ok(scope)
    }
    fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        match self.input_scope(cx) {
            Ok(scope) => {
                self.state.clear();
                self.state.scope = Some(scope.clone());
                self.start(
                    Request {
                        scope,
                        read: Read::Threads { cursor: None },
                    },
                    cx,
                );
            }
            Err(error) => {
                self.notice = error.to_string();
                cx.notify();
            }
        }
    }
    fn start(&mut self, request: Request, cx: &mut Context<Self>) {
        if self.busy {
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.active = Some((generation, request.clone()));
        let cancel = Arc::new(AtomicBool::new(false));
        self.cancel = Some(cancel.clone());
        self.busy = true;
        self.notice = "Loading inline review page…".into();
        let transport = self.transport.clone();
        let sender = self.sender.clone();
        std::thread::spawn(move || {
            let result = fetch(&transport, &request, &cancel);
            let _ = sender.try_send((generation, request, result));
        });
        cx.notify();
    }
    fn poll(&mut self, cx: &mut Context<Self>) {
        let Ok((generation, request, result)) = self.receiver.try_recv() else {
            return;
        };
        self.busy = false;
        self.cancel = None;
        if self
            .active
            .as_ref()
            .is_none_or(|(g, r)| *g != generation || *r != request)
        {
            self.notice = "Old inline review result discarded; load the current context.".into();
            cx.notify();
            return;
        }
        match result.and_then(|page| self.state.apply(&request, page)) {
            Ok(()) => {
                self.notice = format!(
                    "{} threads loaded. Filters apply to loaded pages; refresh for newer server state.",
                    self.state.threads.len()
                )
            }
            Err(error) => {
                let message = error.to_string();
                self.state.limit_reached = message.contains("Display");
                if message.contains("head_changed") {
                    self.state.clear();
                }
                self.notice = message;
            }
        }
        cx.notify();
    }
}
impl Drop for GitHubThreadsPanel {
    fn drop(&mut self) {
        if let Some(cancel) = &self.cancel {
            cancel.store(true, Ordering::Release);
        }
    }
}

fn comment_label(comment: &InlineComment) -> String {
    format!(
        "{} · {} · commit {}",
        comment
            .author
            .as_ref()
            .map(|a| a.login.as_str())
            .unwrap_or("Deleted/unknown author"),
        comment.updated_at,
        comment
            .commit
            .as_deref()
            .map(|value| value.chars().take(12).collect::<String>())
            .unwrap_or_else(|| "unknown".into())
    )
}
impl Render for GitHubThreadsPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mention = self.mention.read(cx).value().trim().to_string();
        let mut header=div().flex().flex_col().gap_2()
   .child("GitHub inline review threads")
   .child(div().text_sm().child("Read-only loaded snapshot. Mention text is unverified; no account/authentication status is inferred. Reply and resolution writes are unavailable."))
   .child(div().flex().gap_2().child(Input::new(&self.repository)).child(Input::new(&self.number)))
   .child(Input::new(&self.head))
   .child(div().flex().gap_2()
    .child(Button::new("github-threads-load").label("Load / Refresh threads").disabled(self.busy||self.context.is_none()).on_click(cx.listener(|this,_,_,cx|this.refresh(cx))))
    .child(Button::new("github-threads-cancel").label("Cancel read").disabled(!self.busy).on_click(cx.listener(|this,_,_,cx|{if let Some(cancel)=&this.cancel{cancel.store(true,Ordering::Release);}this.notice="Cancellation requested…".into();cx.notify();}))))
   .child(Input::new(&self.mention));
        let mut filters = div().flex().gap_2();
        for filter in ["all", "unresolved", "resolved", "outdated"] {
            filters = filters.child(
                Button::new(SharedString::from(format!("github-thread-filter-{filter}")))
                    .label(if self.filter == filter {
                        format!("• {filter}")
                    } else {
                        filter.into()
                    })
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.filter = filter.into();
                        cx.notify();
                    })),
            );
        }
        header = header.child(filters).child(
            div()
                .text_sm()
                .child(SharedString::from(self.notice.clone())),
        );
        let mut rows = div()
            .id("github-thread-list")
            .flex()
            .flex_col()
            .gap_1()
            .w(px(250.))
            .flex_shrink_0()
            .overflow_y_scroll();
        for thread in self
            .state
            .threads
            .iter()
            .filter(|t| visible(t, &self.filter, &mention))
        {
            let id = thread.id.clone();
            let title = format!(
                "{} {}:{} · {} comments{}",
                if thread.is_resolved {
                    "Resolved"
                } else {
                    "Unresolved"
                },
                thread.path,
                thread
                    .line
                    .or(thread.original_line)
                    .map(|n| n.to_string())
                    .unwrap_or("file".into()),
                thread.comments.len(),
                if thread.is_outdated {
                    " · outdated"
                } else {
                    ""
                }
            );
            rows = rows.child(
                Button::new(SharedString::from(format!("github-thread-{}", thread.id)))
                    .label(short(&title, 100))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.state.selected = Some(id.clone());
                        cx.notify();
                    })),
            );
        }
        if let Some(cursor) = self.state.next.clone() {
            rows = rows.child(
                Button::new("github-threads-more")
                    .label("Load more threads")
                    .disabled(
                        self.busy || self.state.limit_reached || self.state.threads.len() >= 100,
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        if let Some(scope) = this.state.scope.clone() {
                            this.start(
                                Request {
                                    scope,
                                    read: Read::Threads {
                                        cursor: Some(cursor.clone()),
                                    },
                                },
                                cx,
                            );
                        }
                    })),
            );
        }
        if self.state.threads.is_empty() {
            rows = rows.child("No loaded threads.");
        }
        let mut detail = div()
            .id("github-thread-detail")
            .flex()
            .flex_col()
            .flex_1()
            .min_w_0()
            .gap_3()
            .overflow_y_scroll();
        if let Some(thread) = self.state.threads.iter().find(|t| {
            Some(&t.id) == self.state.selected.as_ref() && visible(t, &self.filter, &mention)
        }) {
            detail = detail
                .child(SharedString::from(format!(
                    "{} · {} side · line {}",
                    thread.path,
                    thread.diff_side,
                    thread
                        .line
                        .or(thread.original_line)
                        .map(|n| n.to_string())
                        .unwrap_or("not supplied".into())
                )))
                .child(SharedString::from(format!(
                    "{}{}{}",
                    if thread.is_resolved {
                        "Resolved"
                    } else {
                        "Unresolved"
                    },
                    if thread.is_outdated {
                        " · Outdated diff"
                    } else {
                        ""
                    },
                    thread
                        .resolved_by
                        .as_ref()
                        .map(|a| format!(" · resolved by {}", a.login))
                        .unwrap_or_default()
                )));
            for comment in &thread.comments {
                let copied_body = comment.body.clone();
                let copied_url = comment.url.clone();
                let mut target = self
                    .state
                    .scope
                    .as_ref()
                    .map(Scope::params)
                    .unwrap_or(Value::Null);
                target["reviewThreadId"] = json!(thread.id);
                target["commentId"] = json!(comment.id);
                target["databaseId"] = json!(comment.database_id);
                target["replyTo"] = json!(comment.reply_to);
                target["commit"] = json!(comment.commit);
                let copied_target = target.to_string();
                let mut card = div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .p_2()
                    .border_1()
                    .child(SharedString::from(comment_label(comment)))
                    .child(div().text_sm().child(SharedString::from(
                        if let Some(reply) = &comment.reply_to {
                            format!(
                                "Reply to {} (database ID {})",
                                reply.node_id,
                                reply
                                    .database_id
                                    .map(|n| n.to_string())
                                    .unwrap_or("not supplied".into())
                            )
                        } else {
                            "Thread root comment".into()
                        },
                    )))
                    .child(SharedString::from(short(&comment.body, 5000)))
                    .child(div().text_sm().child(SharedString::from(format!(
                            "Mention text: {}",
                            comment
                                .mentions
                                .iter()
                                .map(|m| m.text.as_str())
                                .collect::<Vec<_>>()
                                .join(" ")
                        ))));
                if comment.body_truncated || comment.diff_hunk_truncated {
                    card =
                        card.child("Server text exceeded read budget; loaded text is truncated.");
                }
                if !comment.diff_hunk.is_empty() {
                    card = card.child(
                        div()
                            .text_sm()
                            .font_family("monospace")
                            .child(SharedString::from(short(&comment.diff_hunk, 1500))),
                    );
                }
                card = card.child(
                    div()
                        .flex()
                        .flex_wrap()
                        .gap_2()
                        .child(
                            Button::new(SharedString::from(format!(
                                "github-inline-copy-{}",
                                comment.id
                            )))
                            .label("Copy comment")
                            .on_click(cx.listener(
                                move |_, _, _, cx| {
                                    cx.write_to_clipboard(ClipboardItem::new_string(
                                        copied_body.clone(),
                                    ))
                                },
                            )),
                        )
                        .child(
                            Button::new(SharedString::from(format!(
                                "github-inline-url-{}",
                                comment.id
                            )))
                            .label("Copy permalink")
                            .on_click(cx.listener(
                                move |_, _, _, cx| {
                                    cx.write_to_clipboard(ClipboardItem::new_string(
                                        copied_url.clone(),
                                    ))
                                },
                            )),
                        )
                        .child(
                            Button::new(SharedString::from(format!(
                                "github-inline-target-{}",
                                comment.id
                            )))
                            .label("Copy reply target")
                            .on_click(cx.listener(
                                move |this, _, _, cx| {
                                    cx.write_to_clipboard(ClipboardItem::new_string(
                                        copied_target.clone(),
                                    ));
                                    this.notice =
                                    "Copied scoped reply-target metadata. No reply was submitted."
                                        .into();
                                    cx.notify();
                                },
                            )),
                        ),
                );
                detail = detail.child(card);
            }
            if thread.has_next_page {
                let id = thread.id.clone();
                let cursor = thread.next_cursor.clone();
                detail = detail.child(
                    Button::new("github-thread-more-comments")
                        .label("Load more comments / replies")
                        .disabled(
                            self.busy || self.state.limit_reached || thread.comments.len() >= 500,
                        )
                        .on_click(cx.listener(move |this, _, _, cx| {
                            if let Some(scope) = this.state.scope.clone() {
                                this.start(
                                    Request {
                                        scope,
                                        read: Read::Comments {
                                            id: id.clone(),
                                            cursor: cursor.clone(),
                                        },
                                    },
                                    cx,
                                );
                            }
                        })),
                );
            }
        } else {
            detail = detail.child("Select a loaded thread. Filters apply only to loaded comments.");
        }
        div()
            .id("github-threads-panel")
            .size_full()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .child(header)
            .child(
                div()
                    .flex()
                    .flex_1()
                    .min_h_0()
                    .gap_3()
                    .child(rows)
                    .child(detail),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::github_threads::{Actor, Mention};
    fn scope() -> Scope {
        Scope {
            thread_id: "00000000-0000-4000-8000-000000000007".into(),
            expected_root: "/synthetic".into(),
            repository: "owner/project".into(),
            number: 7,
            expected_head: "a".repeat(40),
        }
    }
    fn thread(id: &str) -> ReviewThread {
        ReviewThread {
            id: id.into(),
            path: "src/file.rs".into(),
            line: Some(7),
            start_line: None,
            original_line: Some(6),
            diff_side: "RIGHT".into(),
            is_resolved: false,
            is_outdated: false,
            resolved_by: None,
            comments: vec![comment("root")],
            next_cursor: Some("reply-1".into()),
            has_next_page: true,
        }
    }
    fn comment(id: &str) -> InlineComment {
        InlineComment {
            id: id.into(),
            database_id: Some(11),
            body: "Hello @octocat".into(),
            body_truncated: false,
            diff_hunk: "@@ -1 +1 @@".into(),
            diff_hunk_truncated: false,
            author: Some(Actor {
                login: "fixture".into(),
            }),
            url: "https://github.com/owner/project/pull/7#discussion_r11".into(),
            created_at: "now".into(),
            updated_at: "now".into(),
            commit: Some("a".repeat(40)),
            reply_to: None,
            mentions: vec![Mention {
                text: "@octocat".into(),
                kind: "user".into(),
            }],
        }
    }
    fn page() -> Page {
        Page {
            kind: "threads".into(),
            scope: scope(),
            review_thread_id: None,
            cursor: None,
            next_cursor: Some("thread-1".into()),
            has_next_page: true,
            threads: vec![thread("thread-a")],
            comments: vec![],
        }
    }
    fn request() -> Request {
        Request {
            scope: scope(),
            read: Read::Threads { cursor: None },
        }
    }
    #[test]
    fn append_pages_and_replies_preserves_scope_selection_and_distinct_reply_targets() {
        let mut state = State {
            scope: Some(scope()),
            ..State::default()
        };
        state.apply(&request(), page()).unwrap();
        assert_eq!(state.selected.as_deref(), Some("thread-a"));
        let request = Request {
            scope: scope(),
            read: Read::Comments {
                id: "thread-a".into(),
                cursor: Some("reply-1".into()),
            },
        };
        let mut reply = page();
        reply.kind = "comments".into();
        reply.review_thread_id = Some("thread-a".into());
        reply.cursor = Some("reply-1".into());
        reply.threads.clear();
        reply.comments = vec![comment("reply")];
        reply.comments[0].reply_to = Some(coincide_core::github_threads::ReplyTarget {
            node_id: "root".into(),
            database_id: Some(11),
        });
        reply.next_cursor = None;
        reply.has_next_page = false;
        state.apply(&request, reply).unwrap();
        assert_eq!(state.threads[0].comments.len(), 2);
        assert_eq!(
            state.threads[0].comments[1]
                .reply_to
                .as_ref()
                .unwrap()
                .node_id,
            "root"
        );
        assert!(!state.threads[0].has_next_page);
    }
    #[test]
    fn stale_heads_roots_cursors_and_duplicate_pages_never_replace_loaded_state() {
        let mut state = State {
            scope: Some(scope()),
            ..State::default()
        };
        state.apply(&request(), page()).unwrap();
        let original = serde_json::to_value(&state.threads).unwrap();
        let next = Request {
            scope: scope(),
            read: Read::Threads {
                cursor: Some("thread-1".into()),
            },
        };
        let mut duplicate = page();
        duplicate.cursor = Some("thread-1".into());
        duplicate.next_cursor = Some("thread-2".into());
        assert!(state.apply(&next, duplicate).is_err());
        assert_eq!(serde_json::to_value(&state.threads).unwrap(), original);
        for bad in 0..3 {
            let mut wrong = page();
            match bad {
                0 => wrong.scope.expected_head = "b".repeat(40),
                1 => wrong.scope.expected_root = "/other".into(),
                _ => wrong.cursor = Some("wrong".into()),
            };
            assert!(state.apply(&request(), wrong).is_err());
            assert_eq!(serde_json::to_value(&state.threads).unwrap(), original);
        }
    }
    #[test]
    fn filters_distinguish_resolved_outdated_and_unverified_loaded_mentions() {
        let mut row = thread("thread-a");
        assert!(visible(&row, "unresolved", "@Octocat"));
        assert!(!visible(&row, "resolved", ""));
        assert!(!visible(&row, "all", "@missing"));
        row.is_resolved = true;
        row.is_outdated = true;
        assert!(visible(&row, "resolved", ""));
        assert!(visible(&row, "outdated", "@octocat"));
        assert!(!visible(&row, "unresolved", ""));
    }
    #[test]
    fn cancellation_after_start_calls_only_cancel_and_never_collects_or_retries() {
        let cancel = Arc::new(AtomicBool::new(false));
        let calls = Arc::new(std::sync::Mutex::new(Vec::new()));
        let observed = calls.clone();
        let trigger = cancel.clone();
        let transport: ThreadsTransport = Arc::new(move |method, _| {
            observed.lock().unwrap().push(method.to_owned());
            if method == "github.threads.list" {
                trigger.store(true, Ordering::Release);
                Ok(json!({"operationId":"synthetic-operation"}))
            } else {
                ensure!(
                    method == "github.threads.cancel",
                    "Unexpected polling after cancellation"
                );
                Ok(json!({"cancelled":true}))
            }
        });
        assert!(fetch(&transport, &request(), &cancel).is_err());
        assert_eq!(
            *calls.lock().unwrap(),
            vec!["github.threads.list", "github.threads.cancel"]
        );
    }
    #[test]
    fn payload_and_pagination_failures_cannot_install_partial_data() {
        let mut invalid = page();
        invalid.has_next_page = true;
        invalid.next_cursor = None;
        assert!(validate(&request(), &invalid).is_err());
        invalid = page();
        invalid.threads[0].comments[0].body = "x".repeat(3 * 1024 * 1024);
        assert!(validate(&request(), &invalid).is_err());
        let transport: ThreadsTransport = Arc::new(|method, _| {
            Ok(if method == "github.threads.list" {
                json!({"operationId":"fixture"})
            } else {
                json!({"ready":true,"result":{"code":"head_changed","error":"untrusted detail"}})
            })
        });
        let error = fetch(&transport, &request(), &AtomicBool::new(false))
            .unwrap_err()
            .to_string();
        assert!(error.contains("head_changed") && !error.contains("untrusted detail"));
    }
    #[cfg(unix)]
    #[test]
    fn injected_transport_runs_real_fake_gh_service_and_populates_ui_model() {
        use coincide_core::{github_api::GhRunner, github_threads::GithubThreadsService};
        use std::{fs, os::unix::fs::PermissionsExt};
        struct Cleanup(std::path::PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let root =
            std::env::temp_dir().join(format!("coincide-thread-ui-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        let _cleanup = Cleanup(root.clone());
        let root = root.canonicalize().unwrap();
        let exe = root.join("fake-gh");
        fs::write(
            &exe,
            include_str!("../../coincide-core/tests/fixtures/github_threads_gh.py"),
        )
        .unwrap();
        fs::set_permissions(&exe, fs::Permissions::from_mode(0o700)).unwrap();
        let service = Arc::new(std::sync::Mutex::new(GithubThreadsService::new(
            GhRunner::new(exe).unwrap(),
        )));
        let mut scope = scope();
        scope.expected_root = root.to_str().unwrap().into();
        let server = service.clone();
        let server_scope = scope.clone();
        let transport: ThreadsTransport = Arc::new(move |method, p| {
            let mut s = server.lock().unwrap();
            match method {
                "github.threads.list" | "github.threads.comments" => {
                    s.start(&server_scope.thread_id, &root, method, &p)
                }
                "github.threads.result" => s.result(&server_scope.thread_id, &root, &p),
                "github.threads.cancel" => s.cancel(&server_scope.thread_id, &root, &p),
                _ => bail!("Unexpected method"),
            }
        });
        let request = Request {
            scope: scope.clone(),
            read: Read::Threads { cursor: None },
        };
        let page = fetch(&transport, &request, &AtomicBool::new(false)).unwrap();
        let mut state = State {
            scope: Some(scope),
            ..State::default()
        };
        state.apply(&request, page).unwrap();
        assert_eq!(state.threads[0].comments[0].mentions[0].text, "@octocat");
        assert!(!state.threads[0].is_resolved);
        assert_eq!(state.selected.as_deref(), Some("fixture-thread-1"));
        let mut next = request.clone();
        next.read = Read::Threads {
            cursor: state.next.clone(),
        };
        let page = fetch(&transport, &next, &AtomicBool::new(false)).unwrap();
        state.apply(&next, page).unwrap();
        assert!(state.threads[1].is_resolved && state.threads[1].is_outdated);
        let reply = Request {
            scope: request.scope.clone(),
            read: Read::Comments {
                id: "fixture-thread-1".into(),
                cursor: state.threads[0].next_cursor.clone(),
            },
        };
        let page = fetch(&transport, &reply, &AtomicBool::new(false)).unwrap();
        state.apply(&reply, page).unwrap();
        assert!(visible(&state.threads[0], "unresolved", "@org/team"));
        assert_eq!(
            state.threads[0].comments[1]
                .reply_to
                .as_ref()
                .unwrap()
                .database_id,
            Some(101)
        );
    }
}
