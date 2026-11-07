//! Passkeys in the embedded browser, as the Swift app has them
//! (`PreviewBitwardenPasskeys.swift`, `PreviewPasskeys.swift`): pages sign in with
//! the user's Bitwarden passkeys after they click Sign In, and a page asking for a
//! passkey nobody here can provide shows "Passkeys aren't available" and tells the
//! agent's `read`.
//!
//! macOS installs the Swift app's page scripts with WebKit page-world message
//! handlers; the origin is WebKit's record of the requesting main frame, never the
//! page's word. WebView2 and WebKitGTK get no Coincide script: WebView2 serves
//! passkeys itself (Windows Hello, security keys, phones), and WebKitGTK ships
//! without the WebAuthn API, so pages there never ask (see
//! docs/rust/PASSKEYS.md). The private key is read from `bw` on a worker for one
//! signature and never reaches the page, an agent API or a log.
use super::shutdown::{Callbacks, NativeLease};
use coincide_core::{
    credentials::Failure,
    passkeys::{
        BitwardenPasskey, GetRequest, NoticeState, PasskeyAssertion, PasskeyVault,
        PublicSuffixList, SignInPrompt, UserVerification, WebAuthnOrigin, WebAuthnReply, page_host,
        sign_in,
    },
};
use serde_json::{Map, Value};
use std::{
    cell::{Cell, RefCell},
    collections::{HashMap, VecDeque},
    rc::Rc,
    sync::{
        Arc,
        mpsc::{self, Receiver, Sender},
    },
    time::Instant,
};

#[cfg(target_os = "macos")]
#[path = "browser_passkeys_macos.rs"]
mod platform;
#[cfg(target_os = "macos")]
pub(super) use platform::{Bridge, install, platform_passkeys_available};

/// How this platform verifies the user after Sign In, as the prompt names it.
#[cfg(target_os = "macos")]
pub(super) const VERIFIER: Option<&str> = Some("Touch ID or your Mac password");
#[cfg(not(target_os = "macos"))]
pub(super) const VERIFIER: Option<&str> = None;

/// Where this platform's WebView answers passkey requests, for `tabs`.
pub(crate) fn support() -> &'static str {
    if cfg!(target_os = "macos") {
        "bitwarden-sign-in"
    } else if cfg!(windows) {
        "webview2-native"
    } else {
        "unavailable"
    }
}

type Verify =
    fn(&str, Box<dyn FnOnce(UserVerification) + Send>, NativeLease) -> Option<Box<dyn FnOnce()>>;

/// The platform's user verification, ending with `done` on any thread. Returns
/// how to cancel it while it is asking.
fn verify_user(
    reason: &str,
    done: Box<dyn FnOnce(UserVerification) + Send>,
    native_block: NativeLease,
) -> Option<Box<dyn FnOnce()>> {
    #[cfg(target_os = "macos")]
    {
        platform::verify_user(reason, done, native_block)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _held = native_block;
        let _ = reason;
        done(UserVerification::Unavailable);
        None
    }
}

/// One reply to the page script, sent at most once. Dropped unanswered, it refuses
/// the request, so the page's promise always settles.
type SendReply = Box<dyn FnOnce(Map<String, Value>)>;
pub(crate) struct PageReply(Option<SendReply>);
impl PageReply {
    pub(crate) fn new(send: impl FnOnce(Map<String, Value>) + 'static) -> Self {
        Self(Some(Box::new(send)))
    }
    fn send(mut self, reply: &WebAuthnReply) {
        if let Some(send) = self.0.take() {
            send(reply.message());
        }
    }
}
impl Drop for PageReply {
    fn drop(&mut self) {
        if let Some(send) = self.0.take() {
            send(WebAuthnReply::NOT_ALLOWED.message());
        }
    }
}

/// What a tab's page scripts reported, queued by its native handler.
pub(crate) enum Incoming {
    /// A frame of `tab`, on `host`, asked for a passkey (the detection script).
    Requested {
        tab: String,
        host: String,
    },
    /// The sign-in script forwarded `navigator.credentials.get` from the main
    /// frame on `origin`.
    Get {
        tab: String,
        origin: WebAuthnOrigin,
        body: Value,
        reply: PageReply,
    },
    Abort {
        tab: String,
        id: String,
    },
}

const MAX_QUEUED: usize = 64;

/// Shared by the controller and every tab's native handler, on the UI thread.
#[derive(Clone)]
pub(crate) struct Channel {
    queue: Rc<RefCell<VecDeque<Incoming>>>,
    available: Rc<Cell<bool>>,
    changed: Rc<dyn Fn()>,
}
impl Channel {
    pub(crate) fn new(changed: impl Fn() + 'static) -> Self {
        Self {
            queue: Rc::default(),
            available: Rc::default(),
            changed: Rc::new(changed),
        }
    }
    pub(crate) fn push(&self, incoming: Incoming) {
        let refused = {
            let mut queue = self.queue.borrow_mut();
            if queue.len() >= MAX_QUEUED {
                Some(incoming)
            } else {
                queue.push_back(incoming);
                None
            }
        };
        // A refused request's reply settles the page's promise; never under the
        // queue's borrow.
        drop(refused);
        (self.changed)();
    }
    /// Whether a sign-in could be offered now, for the script's `available`.
    pub(crate) fn available(&self) -> bool {
        self.available.get()
    }
}

/// Settings › Browser › Passwords, and the notice's ×, from settings.json.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Preferences {
    /// "Use passkeys from Bitwarden"; on by default.
    pub uses_bitwarden: bool,
    /// "Confirm passkey sign-ins with Touch ID"; off by default.
    pub always_verifies: bool,
    /// The notice was dismissed once; it then stays hidden in every browser.
    pub notice_dismissed: bool,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            uses_bitwarden: true,
            always_verifies: false,
            notice_dismissed: false,
        }
    }
}
impl Preferences {
    pub const USES_BITWARDEN: &'static str = "usesBitwardenPasskeys";
    pub const ALWAYS_VERIFIES: &'static str = "confirmsPasskeysWithTouchID";
    pub const NOTICE_DISMISSED: &'static str = "passkeysUnavailableDismissed";
    pub fn from_settings(settings: &Value) -> Self {
        let flag = |key, default| settings[key].as_bool().unwrap_or(default);
        let defaults = Self::default();
        Self {
            uses_bitwarden: flag(Self::USES_BITWARDEN, defaults.uses_bitwarden),
            always_verifies: flag(Self::ALWAYS_VERIFIES, defaults.always_verifies),
            notice_dismissed: flag(Self::NOTICE_DISMISSED, defaults.notice_dismissed),
        }
    }
}

/// A tab as the controller needs it each tick.
pub(crate) struct TabState<'a> {
    pub thread: &'a str,
    pub tab: &'a str,
    pub url: &'a str,
    /// The tab is the active one of the thread whose browser is on screen.
    pub shown: bool,
}

/// The sign-in prompt above the page, for the pane to draw.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PromptView {
    pub id: u64,
    pub title: String,
    pub detail: String,
    /// The account picker's entries; empty for a single account.
    pub accounts: Vec<String>,
    pub selected: usize,
    /// Sign In was clicked; the platform's verification or `bw` is working.
    pub busy: bool,
}

enum Stage {
    Listing,
    Prompt {
        prompt: SignInPrompt,
        selected: usize,
    },
    Verifying {
        choice: BitwardenPasskey,
        cancel: Option<Box<dyn FnOnce()>>,
    },
    Signing {
        client_data: Vec<u8>,
    },
}

/// One sign-in waiting on the vault or the user, one per tab.
struct SignIn {
    id: u64,
    thread: String,
    request: GetRequest,
    origin: WebAuthnOrigin,
    rp_id: String,
    reply: PageReply,
    stage: Stage,
    prompt: Option<SignInPrompt>,
    deadline: Instant,
}
impl Drop for SignIn {
    fn drop(&mut self) {
        // Stops the verification dialog of a sign-in that ended while it asked.
        if let Stage::Verifying { cancel, .. } = &mut self.stage
            && let Some(cancel) = cancel.take()
        {
            cancel();
        }
    }
}

enum Outcome {
    Listed(Result<Vec<BitwardenPasskey>, Failure>),
    Verified(UserVerification),
    Signed(Result<PasskeyAssertion, Failure>),
}
struct Done {
    id: u64,
    tab: String,
    outcome: Outcome,
}

type Vault = Arc<dyn PasskeyVault + Send + Sync>;

pub(crate) struct Passkeys {
    channel: Channel,
    vault: Option<Vault>,
    preferences: Preferences,
    verify: Verify,
    callbacks: Callbacks,
    sign_ins: HashMap<String, SignIn>,
    notices: HashMap<String, NoticeState>,
    next_id: u64,
    sender: Sender<Done>,
    results: Receiver<Done>,
    /// Why the last request went to the browser: reasons and counts only, never
    /// sites' values or vault contents.
    pub(crate) last_fallback: Option<String>,
}

impl Passkeys {
    pub(crate) fn new(changed: impl Fn() + 'static, callbacks: Callbacks) -> Self {
        let (sender, results) = mpsc::channel();
        let mut this = Self {
            channel: Channel::new(changed),
            vault: None,
            preferences: Preferences::default(),
            verify: verify_user,
            callbacks,
            sign_ins: HashMap::new(),
            notices: HashMap::new(),
            next_id: 0,
            sender,
            results,
            last_fallback: None,
        };
        this.refresh_available();
        this
    }
    pub(crate) fn channel(&self) -> &Channel {
        &self.channel
    }
    pub(crate) fn set_vault(&mut self, vault: Option<Vault>) {
        self.vault = vault;
        self.refresh_available();
    }
    /// Tests never reach the platform's verification dialog.
    #[cfg(test)]
    fn set_verify(&mut self, verify: Verify) {
        self.verify = verify;
    }
    /// True when the notice's visibility changed.
    pub(crate) fn set_preferences(&mut self, preferences: Preferences) -> bool {
        let changed = self.preferences.notice_dismissed != preferences.notice_dismissed;
        self.preferences = preferences;
        self.refresh_available();
        changed
    }
    fn refresh_available(&mut self) {
        self.channel.available.set(
            self.preferences.uses_bitwarden
                && self.vault.as_ref().is_some_and(|vault| vault.ready()),
        );
    }

    /// Handles what the pages and workers reported. `spawn` keeps each `bw` worker
    /// joinable at shutdown. True when anything the pane shows changed.
    pub(crate) fn poll(
        &mut self,
        tabs: &[TabState],
        spawn: &mut dyn FnMut(std::thread::JoinHandle<()>),
    ) -> bool {
        self.refresh_available();
        let mut changed = false;
        let incoming = {
            let mut queue = self.channel.queue.borrow_mut();
            queue.drain(..).collect::<Vec<_>>()
        };
        for incoming in incoming {
            match incoming {
                Incoming::Requested { tab, host } => {
                    if self.preferences.notice_dismissed {
                        continue;
                    }
                    if let Some(state) = tabs.iter().find(|state| state.tab == tab) {
                        changed |= self
                            .notices
                            .entry(state.thread.to_owned())
                            .or_default()
                            .requested(&tab, &host);
                    }
                }
                Incoming::Get {
                    tab,
                    origin,
                    body,
                    reply,
                } => changed |= self.start(tabs, &tab, origin, &body, reply, spawn),
                Incoming::Abort { tab, id } => {
                    if self
                        .sign_ins
                        .get(&tab)
                        .is_some_and(|sign_in| sign_in.request.id == id)
                    {
                        // Dropping it refuses the request; the page already gave up.
                        self.sign_ins.remove(&tab);
                        changed = true;
                    }
                }
            }
        }
        for done in self.results.try_iter().take(64).collect::<Vec<_>>() {
            changed |= self.finished(tabs, done, spawn);
        }
        // Leaving the page's origin, closing the tab or running out of time ends
        // the request, as a browser's does.
        let now = Instant::now();
        let ended: Vec<String> = self
            .sign_ins
            .iter()
            .filter(|(tab, sign_in)| {
                now >= sign_in.deadline
                    || tabs
                        .iter()
                        .find(|state| state.tab == *tab)
                        .is_none_or(|state| {
                            WebAuthnOrigin::from_url(state.url).as_ref() != Some(&sign_in.origin)
                        })
            })
            .map(|(tab, _)| tab.clone())
            .collect();
        for tab in ended {
            self.sign_ins.remove(&tab);
            changed = true;
        }
        changed
    }

    fn leave(&mut self, reason: String, reply: PageReply) -> bool {
        // Console-visible reason, as the Swift app's Passkeys log category has it.
        eprintln!("Passkey request left to the browser: {reason}");
        self.last_fallback = Some(reason);
        reply.send(&WebAuthnReply::Fallback);
        false
    }

    fn start(
        &mut self,
        tabs: &[TabState],
        tab: &str,
        origin: WebAuthnOrigin,
        body: &Value,
        reply: PageReply,
        spawn: &mut dyn FnMut(std::thread::JoinHandle<()>),
    ) -> bool {
        let Some(request) = GetRequest::from_message(body) else {
            return self.leave(
                format!("Coincide couldn't read it ({})", GetRequest::summary(body)),
                reply,
            );
        };
        let (true, Some(vault)) = (self.channel.available(), self.vault.clone()) else {
            return self.leave(
                "Bitwarden passkeys are off, or Bitwarden is locked or not set up in Coincide"
                    .into(),
                reply,
            );
        };
        let Some(state) = tabs.iter().find(|state| state.tab == tab && state.shown) else {
            return self.leave("the browser isn't on screen to ask".into(), reply);
        };
        if self.sign_ins.contains_key(tab) {
            reply.send(&WebAuthnReply::PENDING);
            return false;
        }
        let rp_id = match sign_in::start(&request, &origin, PublicSuffixList::bundled()) {
            sign_in::Start::Reply(answer) => {
                reply.send(&answer);
                return false;
            }
            sign_in::Start::Fallback(reason) => return self.leave(reason, reply),
            sign_in::Start::List { rp_id } => rp_id,
        };
        self.next_id += 1;
        let id = self.next_id;
        let sender = self.sender.clone();
        let worker_tab = tab.to_owned();
        spawn(std::thread::spawn(move || {
            let outcome = Outcome::Listed(vault.passkeys());
            let _ = sender.send(Done {
                id,
                tab: worker_tab,
                outcome,
            });
        }));
        let deadline = Instant::now() + request.wait_limit();
        self.sign_ins.insert(
            tab.to_owned(),
            SignIn {
                id,
                thread: state.thread.to_owned(),
                request,
                origin,
                rp_id,
                reply,
                stage: Stage::Listing,
                prompt: None,
                deadline,
            },
        );
        false
    }

    fn finished(
        &mut self,
        tabs: &[TabState],
        done: Done,
        spawn: &mut dyn FnMut(std::thread::JoinHandle<()>),
    ) -> bool {
        // A sign-in that ended meanwhile gets nothing.
        if self
            .sign_ins
            .get(&done.tab)
            .is_none_or(|sign_in| sign_in.id != done.id)
        {
            return false;
        }
        match done.outcome {
            Outcome::Listed(listed) => {
                let sign_in = self.sign_ins.get_mut(&done.tab).expect("current sign-in");
                if !matches!(sign_in.stage, Stage::Listing) {
                    return false;
                }
                match sign_in::offer(
                    &sign_in.request,
                    &sign_in.origin,
                    &sign_in.rp_id,
                    listed,
                    self.preferences.always_verifies,
                    VERIFIER,
                ) {
                    Ok(prompt) => {
                        sign_in.prompt = Some(prompt.clone());
                        sign_in.stage = Stage::Prompt {
                            prompt,
                            selected: 0,
                        };
                        true
                    }
                    Err(reason) => {
                        let sign_in = self.sign_ins.remove(&done.tab).expect("current sign-in");
                        let reply = Self::take_reply(sign_in);
                        self.leave(reason, reply);
                        true
                    }
                }
            }
            Outcome::Verified(outcome) => {
                let sign_in = self.sign_ins.get_mut(&done.tab).expect("current sign-in");
                let Stage::Verifying { choice, cancel } = &mut sign_in.stage else {
                    return false;
                };
                // Verification ended by itself; nothing left to cancel.
                cancel.take();
                let choice = choice.clone();
                match sign_in::verified(&sign_in.request, &choice, Some(outcome)) {
                    Ok(user_verified) => {
                        self.sign(&done.tab, choice, user_verified, spawn);
                    }
                    Err(refusal) => {
                        let sign_in = self.sign_ins.remove(&done.tab).expect("current sign-in");
                        Self::take_reply(sign_in).send(&refusal);
                    }
                }
                true
            }
            Outcome::Signed(signed) => {
                let sign_in = self.sign_ins.remove(&done.tab).expect("current sign-in");
                let Stage::Signing { client_data } = &sign_in.stage else {
                    return true;
                };
                let answer = sign_in::finish(client_data.clone(), signed);
                // A page that went away, or moved to another origin, gets nothing.
                let current =
                    tabs.iter()
                        .find(|state| state.tab == done.tab)
                        .is_some_and(|state| {
                            WebAuthnOrigin::from_url(state.url).as_ref() == Some(&sign_in.origin)
                        });
                let reply = Self::take_reply(sign_in);
                if current {
                    reply.send(&answer);
                }
                true
            }
        }
    }

    /// Moves the reply out of a sign-in that is ending, so dropping the rest
    /// doesn't refuse the request first.
    fn take_reply(mut sign_in: SignIn) -> PageReply {
        PageReply(sign_in.reply.0.take())
    }

    fn sign(
        &mut self,
        tab: &str,
        choice: BitwardenPasskey,
        user_verified: bool,
        spawn: &mut dyn FnMut(std::thread::JoinHandle<()>),
    ) {
        let Some(vault) = self.vault.clone() else {
            self.sign_ins.remove(tab);
            return;
        };
        let sign_in = self.sign_ins.get_mut(tab).expect("current sign-in");
        let client_data = sign_in::client_data(&sign_in.request, &sign_in.origin);
        let (id, rp_id, sender, worker_tab, data) = (
            sign_in.id,
            sign_in.rp_id.clone(),
            self.sender.clone(),
            tab.to_owned(),
            client_data.clone(),
        );
        sign_in.stage = Stage::Signing { client_data };
        spawn(std::thread::spawn(move || {
            let outcome = Outcome::Signed(vault.assertion(&choice, &rp_id, &data, user_verified));
            let _ = sender.send(Done {
                id,
                tab: worker_tab,
                outcome,
            });
        }));
    }

    /// The prompt for the tab the pane shows.
    pub fn prompt(&self, thread: &str, tab: &str) -> Option<PromptView> {
        let sign_in = self.sign_ins.get(tab).filter(|s| s.thread == thread)?;
        let prompt = sign_in.prompt.as_ref()?;
        let (selected, busy) = match &sign_in.stage {
            Stage::Prompt { selected, .. } => (*selected, false),
            Stage::Listing => return None,
            _ => (0, true),
        };
        Some(PromptView {
            id: sign_in.id,
            title: prompt.title(),
            detail: prompt.detail(),
            accounts: if prompt.choices.len() > 1 {
                prompt
                    .choices
                    .iter()
                    .map(|choice| prompt.label(choice))
                    .collect()
            } else {
                vec![]
            },
            selected,
            busy,
        })
    }

    pub fn select(&mut self, id: u64, index: usize) -> bool {
        for sign_in in self.sign_ins.values_mut() {
            if sign_in.id == id
                && let Stage::Prompt { prompt, selected } = &mut sign_in.stage
                && index < prompt.choices.len()
            {
                *selected = index;
                return true;
            }
        }
        false
    }

    /// Sign In (`accept`) or Cancel on the prompt `id`. Sign In is the user
    /// presence the assertion reports; verification follows when the setting, the
    /// site or the Bitwarden item asks for it.
    pub(crate) fn answer(
        &mut self,
        id: u64,
        accept: bool,
        spawn: &mut dyn FnMut(std::thread::JoinHandle<()>),
    ) -> bool {
        let Some(tab) = self
            .sign_ins
            .iter()
            .find(|(_, sign_in)| sign_in.id == id && matches!(sign_in.stage, Stage::Prompt { .. }))
            .map(|(tab, _)| tab.clone())
        else {
            return false;
        };
        if !accept {
            let sign_in = self.sign_ins.remove(&tab).expect("current sign-in");
            Self::take_reply(sign_in).send(&WebAuthnReply::NOT_ALLOWED);
            return true;
        }
        let sign_in = self.sign_ins.get_mut(&tab).expect("current sign-in");
        let Stage::Prompt { prompt, selected } = &sign_in.stage else {
            return false;
        };
        let choice = prompt.choices[*selected].clone();
        if !prompt.verifies_user {
            match sign_in::verified(&sign_in.request, &choice, None) {
                Ok(user_verified) => self.sign(&tab, choice, user_verified, spawn),
                Err(refusal) => {
                    let sign_in = self.sign_ins.remove(&tab).expect("current sign-in");
                    Self::take_reply(sign_in).send(&refusal);
                }
            }
            return true;
        }
        let reason = prompt.verification_reason();
        let (sender, worker_tab) = (self.sender.clone(), tab.clone());
        sign_in.stage = Stage::Verifying {
            choice,
            cancel: None,
        };
        let cancel = (self.verify)(
            &reason,
            Box::new(move |outcome| {
                let _ = sender.send(Done {
                    id,
                    tab: worker_tab,
                    outcome: Outcome::Verified(outcome),
                });
            }),
            self.callbacks.lifetimes().block(),
        );
        if let Some(sign_in) = self.sign_ins.get_mut(&tab)
            && let Stage::Verifying { cancel: slot, .. } = &mut sign_in.stage
        {
            *slot = cancel;
        }
        true
    }

    /// "Passkeys aren't available" for the tab the pane shows: its message and
    /// action, unless the user dismissed the notice.
    pub fn notice(&self, thread: &str, tab: &str) -> Option<(String, Option<&'static str>)> {
        if self.preferences.notice_dismissed {
            return None;
        }
        let notice = self.notices.get(thread)?.notice()?;
        (notice.tab_id == tab).then(|| NoticeState::content(notice))
    }

    /// "Open in Default Browser": returns the tab whose page to open, and moves the
    /// notice on.
    pub fn open_notice(&mut self, thread: &str) -> Option<String> {
        let state = self.notices.get_mut(thread)?;
        let tab = state.notice()?.tab_id.clone();
        state.opened_elsewhere();
        Some(tab)
    }

    /// The ×. The caller saves the dismissal, which hides the notice everywhere.
    pub fn dismiss_notice(&mut self, thread: &str) {
        if let Some(state) = self.notices.get_mut(thread) {
            state.dismiss();
        }
    }

    /// The tab committed a page on `url`.
    pub(crate) fn navigated(&mut self, thread: &str, tab: &str, url: &str) -> bool {
        let host = page_host(url).unwrap_or_default();
        self.notices
            .get_mut(thread)
            .is_some_and(|state| state.navigated(tab, &host))
    }

    pub(crate) fn closed(&mut self, thread: &str, tab: &str) {
        if let Some(state) = self.notices.get_mut(thread) {
            state.closed(tab);
        }
        // Dropping it refuses the request.
        self.sign_ins.remove(tab);
    }

    /// The browser is closing: every waiting page is refused now.
    pub(crate) fn shutdown(&mut self) {
        self.sign_ins.clear();
        self.channel.available.set(false);
        // Their replies settle pages' promises; never under the queue's borrow.
        let queued = self
            .channel
            .queue
            .borrow_mut()
            .drain(..)
            .collect::<Vec<_>>();
        drop(queued);
    }
}

#[cfg(test)]
#[path = "browser_passkeys_tests.rs"]
mod tests;
