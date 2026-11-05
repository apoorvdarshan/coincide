//! Native-only approval and acknowledged credential handoff. Never register these
//! methods as agent/browser JSON commands. See docs/rust/CREDENTIAL_HOOKS.md.
use coincide_core::credentials::{
    Failure, Login, PageBinding, PrivateFillSink, Secret, Vault, VaultCommand,
};
use gpui_kit::{
    Context, IntoElement, ParentElement, Render, SharedString, Styled, Window,
    component::{Disableable, button::Button},
    div,
};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
    mpsc::{self, Receiver, SyncSender},
};
use std::time::{Duration, Instant};
use uuid::Uuid;

/// Contains metadata only. UUID is generated locally, never supplied by a page.
#[derive(Clone)]
pub struct ApprovalPrompt {
    pub id: Uuid,
    pub page: PageBinding,
    pub item: Login,
    issued: Instant,
}
impl ApprovalPrompt {
    pub fn new(page: PageBinding, item: Login) -> Self {
        Self {
            id: Uuid::new_v4(),
            page,
            item,
            issued: Instant::now(),
        }
    }
    pub fn expired(&self) -> bool {
        self.issued.elapsed() >= Duration::from_secs(300)
    }
}
/// This receiver stays inside the native controller. Never accept decisions from
/// the agent API, page IPC, persisted settings, or imported Swift approvals.
pub struct NativeDecision {
    id: Uuid,
    allow: bool,
}
pub struct ApprovalView {
    prompt: ApprovalPrompt,
    decisions: SyncSender<NativeDecision>,
    answered: bool,
}
impl ApprovalView {
    pub fn new(prompt: ApprovalPrompt) -> (Self, Receiver<NativeDecision>) {
        let (decisions, receiver) = mpsc::sync_channel(1);
        (
            Self {
                prompt,
                decisions,
                answered: false,
            },
            receiver,
        )
    }
    fn answer(&mut self, allow: bool, cx: &mut Context<Self>) {
        if self.answered {
            return;
        }
        let _ = self.decisions.try_send(NativeDecision {
            id: self.prompt.id,
            allow: allow && !self.prompt.expired(),
        });
        self.answered = true;
        cx.notify();
    }
}
impl Render for ApprovalView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let disabled = self.answered || self.prompt.expired();
        div()
            .flex()
            .flex_col()
            .gap_2()
            .p_4()
            .child("Allow saved login to be filled?")
            .child(SharedString::from(self.prompt.page.origin().to_owned()))
            .child(SharedString::from(format!(
                "{} ({})",
                self.prompt.item.title, self.prompt.item.username
            )))
            .child("The website will receive this login. Your agent receives no password or code.")
            .child(
                Button::new("credential-deny")
                    .label("Deny")
                    .disabled(disabled)
                    .on_click(cx.listener(|this, _, _, cx| this.answer(false, cx))),
            )
            .child(
                Button::new("credential-allow-once")
                    .label("Allow once")
                    .disabled(disabled)
                    .on_click(cx.listener(|this, _, _, cx| this.answer(true, cx))),
            )
    }
}

/// Background worker entry after receiving a decision. Returning Ok means the
/// browser confirmed the fill, never merely that the job was queued.
pub fn complete_approval<R: VaultCommand>(
    vault: &Vault<R>,
    prompt: ApprovalPrompt,
    decision: NativeDecision,
    current: &PageBinding,
    sink: &mut impl PrivateFillSink,
) -> Result<(), Failure> {
    if decision.id != prompt.id || !decision.allow || prompt.expired() {
        return Err(Failure::ApprovalRequired);
    }
    if prompt.page != *current {
        return Err(Failure::StalePage);
    }
    let approved = vault.approve(current, &prompt.item, true)?;
    vault.fill(approved, current, sink)
}

/// No Debug/Serialize: secret payload is memory-only and private to native code.
pub struct FillJob {
    binding: PageBinding,
    username: String,
    password: String,
    totp: Option<String>,
    permit: FillPermit,
    reply: SyncSender<Result<(), Failure>>,
}
/// Browser callbacks must retain this permit and check it immediately before
/// changing fields. A worker timeout revokes it even after UI dispatch.
#[derive(Clone)]
pub struct FillPermit {
    deadline: Instant,
    cancelled: Arc<AtomicBool>,
}
impl FillPermit {
    pub fn is_valid(&self) -> bool {
        Instant::now() < self.deadline && !self.cancelled.load(Ordering::Acquire)
    }
}
pub struct QueuedSink {
    jobs: SyncSender<FillJob>,
}
pub fn private_fill_channel() -> (QueuedSink, Receiver<FillJob>) {
    let (jobs, receiver) = mpsc::sync_channel(1);
    (QueuedSink { jobs }, receiver)
}
impl PrivateFillSink for QueuedSink {
    fn fill(&mut self, binding: &PageBinding, secret: &Secret) -> Result<(), Failure> {
        let (reply, receiver) = mpsc::sync_channel(1);
        let permit = FillPermit {
            deadline: Instant::now() + Duration::from_secs(9),
            cancelled: Arc::new(AtomicBool::new(false)),
        };
        self.jobs
            .try_send(FillJob {
                binding: binding.clone(),
                username: secret.username().into(),
                password: secret.password().into(),
                totp: secret.totp().map(str::to_owned),
                permit: permit.clone(),
                reply,
            })
            .map_err(|_| Failure::FillFailed)?;
        let result = receiver
            .recv_timeout(Duration::from_secs(10))
            .map_err(|_| Failure::FillFailed)
            .and_then(|result| result);
        permit.cancelled.store(true, Ordering::Release);
        result
    }
}
/// Browser owner implements on its UI thread. This hook MUST atomically validate
/// binding and fill in the SAME document. No default implementation pretends
/// wry's ordinary async evaluate_script can supply that guarantee.
///
/// Only a confirmed field update may call completion(Ok). Navigation, closed tab,
/// unsupported platform, missing fields, cancellation and script failure return
/// Err. Do not return/log field values, source, DOM snapshots or provider errors.
pub trait PrivateBrowserHook {
    fn current_binding(&self, tab: &str) -> Result<PageBinding, Failure>;
    fn fill_bound_document(
        &mut self,
        binding: &PageBinding,
        permit: FillPermit,
        username: &str,
        password: &str,
        totp: Option<&str>,
        completion: Box<dyn FnOnce(Result<(), Failure>)>,
    );
}
/// Drain on the browser UI thread. A timed-out queued job must never later fill.
pub fn deliver_fill(job: FillJob, hook: &mut impl PrivateBrowserHook) {
    if !job.permit.is_valid() {
        let _ = job.reply.try_send(Err(Failure::FillFailed));
        return;
    }
    if hook.current_binding(&job.binding.tab).as_ref() != Ok(&job.binding) {
        let _ = job.reply.try_send(Err(Failure::StalePage));
        return;
    }
    let reply = job.reply;
    hook.fill_bound_document(
        &job.binding,
        job.permit,
        &job.username,
        &job.password,
        job.totp.as_deref(),
        Box::new(move |result| {
            let _ = reply.try_send(result);
        }),
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture;
    impl VaultCommand for Fixture {
        fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
            let text = match args {
                [
                    "list",
                    "items",
                    "--url",
                    "https://example.test",
                    "--nointeraction",
                ] => {
                    r#"[{"id":"fixture","type":1,"login":{"uris":[{"uri":"https://example.test"}]}}]"#
                }
                ["get", "item", "fixture", "--nointeraction"] => {
                    r#"{"login":{"username":"synthetic-user","password":"synthetic-password","uris":[{"uri":"https://example.test"}]}}"#
                }
                _ => return Err(Failure::Unavailable),
            };
            Ok(text.as_bytes().to_vec())
        }
    }
    fn page() -> PageBinding {
        PageBinding::new("synthetic-tab".into(), 1, "https://example.test").unwrap()
    }
    fn prompt() -> ApprovalPrompt {
        ApprovalPrompt::new(
            page(),
            Login {
                id: "fixture".into(),
                title: "Fixture".into(),
                username: "synthetic-user".into(),
            },
        )
    }
    struct Hook {
        page: PageBinding,
        called: bool,
    }
    impl PrivateBrowserHook for Hook {
        fn current_binding(&self, _: &str) -> Result<PageBinding, Failure> {
            Ok(self.page.clone())
        }
        fn fill_bound_document(
            &mut self,
            binding: &PageBinding,
            permit: FillPermit,
            username: &str,
            password: &str,
            totp: Option<&str>,
            completion: Box<dyn FnOnce(Result<(), Failure>)>,
        ) {
            assert!(permit.is_valid());
            assert_eq!(*binding, self.page);
            assert_eq!(username, "synthetic-user");
            assert_eq!(password, "synthetic-password");
            assert_eq!(totp, None);
            self.called = true;
            completion(Ok(()));
        }
    }
    #[test]
    fn approved_worker_waits_for_confirmed_native_fill() {
        let (mut sink, jobs) = private_fill_channel();
        let prompt = prompt();
        let decision = NativeDecision {
            id: prompt.id,
            allow: true,
        };
        let worker = std::thread::spawn(move || {
            complete_approval(
                &Vault::new(coincide_core::credentials::Manager::Bitwarden, Fixture),
                prompt,
                decision,
                &page(),
                &mut sink,
            )
        });
        let job = jobs.recv_timeout(Duration::from_secs(2)).unwrap();
        let permit = job.permit.clone();
        let mut hook = Hook {
            page: page(),
            called: false,
        };
        deliver_fill(job, &mut hook);
        assert_eq!(worker.join().unwrap(), Ok(()));
        assert!(hook.called);
        assert!(!permit.is_valid());
    }
    #[test]
    fn stale_or_expired_jobs_do_not_reach_hook() {
        for expired in [false, true] {
            let (reply, result) = mpsc::sync_channel(1);
            let mut binding = page();
            if !expired {
                binding.navigation += 1;
            }
            let permit = FillPermit {
                deadline: if expired {
                    Instant::now() - Duration::from_secs(1)
                } else {
                    Instant::now() + Duration::from_secs(9)
                },
                cancelled: Arc::new(AtomicBool::new(false)),
            };
            let job = FillJob {
                binding,
                permit,
                username: "synthetic-user".into(),
                password: "synthetic-password".into(),
                totp: None,
                reply,
            };
            let mut hook = Hook {
                page: page(),
                called: false,
            };
            deliver_fill(job, &mut hook);
            assert!(result.recv().unwrap().is_err());
            assert!(!hook.called);
        }
    }
    #[test]
    fn denial_and_wrong_prompt_do_not_fetch_credentials() {
        struct Never;
        impl VaultCommand for Never {
            fn run(&self, _: &[&str]) -> Result<Vec<u8>, Failure> {
                panic!("denial must not query vault")
            }
        }
        let vault = Vault::new(coincide_core::credentials::Manager::Bitwarden, Never);
        for allow in [false, true] {
            let prompt = prompt();
            let (view, decisions) = ApprovalView::new(prompt.clone());
            drop(view);
            assert!(decisions.try_recv().is_err());
            let decision = NativeDecision {
                id: if allow { Uuid::new_v4() } else { prompt.id },
                allow,
            };
            let (mut sink, _) = private_fill_channel();
            assert_eq!(
                complete_approval(&vault, prompt, decision, &page(), &mut sink),
                Err(Failure::ApprovalRequired)
            );
        }
    }
}
