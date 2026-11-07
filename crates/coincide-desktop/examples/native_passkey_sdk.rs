//! Fresh-runner-only native passkey acceptance. Not a production command or approval route.
//! Run explicitly with COINCIDE_SYNTHETIC_PASSKEY_SDK=1 on an isolated GitHub runner.
//!
//! macOS: a real WKWebView with the production page scripts, WebKit handlers and
//! controller signs a simulated https page in with a synthetic key generated here;
//! no Bitwarden, `bw`, Keychain, Touch ID or network is involved, and the "click"
//! on the production prompt is this fixture's. Requests the controller hands back
//! reach a stub of WebKit's own API, never the system passkey sheet.
//!
//! Windows and Linux: the platform's WebView is probed for the WebAuthn API on an
//! owned https fixture page, proving the support the browser reports in `tabs`.
#[allow(dead_code)] // Reuse the production boundary without its unrelated app callers.
#[path = "../src/browser_passkeys.rs"]
mod browser_passkeys;

use gpui_kit::{
    App, AppContext, Context, Entity, IntoElement, ParentElement, Render, Styled, Window, div,
};
use serde_json::Value;
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex, mpsc},
    time::{Duration, Instant},
};

const URL: &str = "https://passkey-fixture.example/login.html";
const HTML: &str = "<!doctype html><meta charset=utf-8><title>Owned synthetic passkey fixture</title><p>fixture</p>";
const PROBE: &str = r#"JSON.stringify({ready: document.readyState === 'complete', href: location.href,
    secure: isSecureContext, publicKeyCredential: typeof PublicKeyCredential,
    credentialsContainer: typeof CredentialsContainer,
    coincide: !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.coincideBitwardenPasskey)})"#;

#[cfg(target_os = "macos")]
mod sign_in {
    //! The page's side and the checks a relying party makes.
    use super::browser_passkeys::{Passkeys, TabState};
    use coincide_core::{
        credentials::Failure,
        passkeys::{
            BitwardenPasskey, PasskeyAssertion, PasskeyVault, assertion, base64url, synthetic,
        },
    };
    use serde_json::Value;
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    };

    pub const RP_ID: &str = "passkey-fixture.example";
    pub const THREAD: &str = "fixture-thread";
    pub const TAB: &str = "fixture-tab";

    /// Signs for real with a key generated for this run, as `bw get item` would
    /// let the production vault.
    pub struct SigningVault {
        pub key: synthetic::Key,
        pub lists: AtomicUsize,
    }
    impl SigningVault {
        pub fn passkey() -> BitwardenPasskey {
            BitwardenPasskey {
                item_id: "synthetic-item".into(),
                item_name: "Fixture".into(),
                user_name: "synthetic-user".into(),
                user_display_name: String::new(),
                rp_id: RP_ID.into(),
                stored_credential_id: "b64.AQIDBA".into(),
                credential_id: vec![1, 2, 3, 4],
                user_handle: Some(vec![0xa1, 0xb2]),
                counter: 0,
                discoverable: true,
                requires_reprompt: false,
            }
        }
    }
    impl PasskeyVault for SigningVault {
        fn passkeys(&self) -> Result<Vec<BitwardenPasskey>, Failure> {
            self.lists.fetch_add(1, Ordering::AcqRel);
            Ok(vec![Self::passkey()])
        }
        fn assertion(
            &self,
            passkey: &BitwardenPasskey,
            rp_id: &str,
            client_data_json: &[u8],
            user_verified: bool,
        ) -> Result<PasskeyAssertion, Failure> {
            let mut flags =
                assertion::USER_PRESENT | assertion::BACKUP_ELIGIBLE | assertion::BACKED_UP;
            if user_verified {
                flags |= assertion::USER_VERIFIED;
            }
            let data = assertion::authenticator_data(rp_id, flags, 0);
            let signature = assertion::signature(&data, client_data_json, &self.key.pkcs8)?;
            Ok(PasskeyAssertion {
                credential_id: passkey.credential_id.clone(),
                authenticator_data: data,
                signature,
                user_handle: passkey.user_handle.clone(),
            })
        }
    }

    /// Stands in for WebKit's own `get` and `create`, so requests handed back to
    /// the browser never reach the system's passkey API: each rejects as it does
    /// without the entitlement, and counts the call. Installed before the
    /// production scripts, as the Swift app's page tests do.
    pub const BROWSER_STUB: &str = r#"(() => {
        window.__browserCalls = 0;
        for (const name of ['get', 'create']) {
            const stub = {[name](options) { window.__browserCalls++; return Promise.reject(new DOMException('stub', 'NotAllowedError')); }}[name];
            Object.defineProperty(CredentialsContainer.prototype, name, {value: stub, writable: true, configurable: true, enumerable: true});
        }
    })();"#;

    /// One request from the page's own world; the outcome lands in `window.__out`.
    pub fn request(options: &str) -> String {
        format!(
            r#"(() => {{ window.__out = undefined; (async () => {{
                const out = {{}};
                try {{
                    const credential = await navigator.credentials.get({{publicKey: {{challenge: new Uint8Array(32).fill(5), userVerification: 'preferred', {options}}}}});
                    const b64 = buffer => btoa(String.fromCharCode(...new Uint8Array(buffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
                    out.isCredential = credential instanceof PublicKeyCredential;
                    out.isAssertion = credential.response instanceof AuthenticatorAssertionResponse;
                    out.id = credential.id;
                    out.rawId = b64(credential.rawId);
                    out.type = credential.type;
                    out.attachment = credential.authenticatorAttachment;
                    out.clientDataJSON = b64(credential.response.clientDataJSON);
                    out.authenticatorData = b64(credential.response.authenticatorData);
                    out.signature = b64(credential.response.signature);
                    out.userHandle = b64(credential.response.userHandle);
                    out.extensions = JSON.stringify(credential.getClientExtensionResults());
                    out.json = JSON.stringify(credential);
                }} catch (error) {{
                    out.error = error.name;
                    out.isDOMException = error instanceof DOMException;
                }}
                out.browserCalls = window.__browserCalls;
                window.__out = JSON.stringify(out);
            }})(); return true; }})()"#
        )
    }

    pub const ALLOWED: &str = "rpId: 'passkey-fixture.example', allowCredentials: [{type: 'public-key', id: new Uint8Array([1, 2, 3, 4]), transports: ['internal']}]";
    pub const CLAIM: &str = "rpId: 'github.com'";
    pub const UNMATCHED: &str = "allowCredentials: [{type: 'public-key', id: new Uint8Array([9])}]";

    /// A same-origin child frame posting to the handler itself, which WebKit
    /// reports as not the main frame.
    pub const FRAME: &str = r#"(() => { window.__out = undefined;
        const frame = document.createElement('iframe');
        frame.srcdoc = "<script>const handler = window.webkit.messageHandlers.coincideBitwardenPasskey;" +
            "Promise.all([handler.postMessage({kind: 'available'}), handler.postMessage({kind: 'get', id: 'frame1', publicKey: {challenge: 'BQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQU', rpId: 'passkey-fixture.example'}})])" +
            ".then(([available, reply]) => { parent.__out = JSON.stringify({frame: available + ' ' + reply.status}); });<\/script>";
        document.body.appendChild(frame); return true; })()"#;

    pub const STATICS: &str = r#"(() => { window.__out = undefined; (async () => {
        window.__out = JSON.stringify({uv: await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable(),
            conditional: await PublicKeyCredential.isConditionalMediationAvailable()});
    })(); return true; })()"#;

    /// The checks of a successful sign-in, as the relying party makes them.
    pub fn check_credential(out: &Value, vault: &SigningVault) -> Result<(), String> {
        let text = |key: &str| out[key].as_str().unwrap_or_default().to_owned();
        if out["isCredential"] != true || out["isAssertion"] != true {
            return Err(format!("not a PublicKeyCredential assertion: {out}"));
        }
        if text("id") != "AQIDBA"
            || text("rawId") != "AQIDBA"
            || text("type") != "public-key"
            || text("attachment") != "platform"
            || text("userHandle") != "obI"
            || text("extensions") != "{}"
            || out["browserCalls"] != 0
        {
            return Err(format!("unexpected credential fields: {out}"));
        }
        let client = base64url::decode(&text("clientDataJSON")).ok_or("client data")?;
        if client != assertion::client_data_json(&[5; 32], "https://passkey-fixture.example") {
            return Err(format!(
                "client data names another origin or challenge: {}",
                String::from_utf8_lossy(&client)
            ));
        }
        let data = base64url::decode(&text("authenticatorData")).ok_or("authenticator data")?;
        // User present, backup eligible and backed up; not verified.
        if data != assertion::authenticator_data(RP_ID, 0x19, 0) {
            return Err("authenticator data isn't the RP ID hash, flags and counter".into());
        }
        let signature = base64url::decode(&text("signature")).ok_or("signature")?;
        if !vault.key.verifies(&data, &client, &signature) {
            return Err("the signature doesn't verify against the synthetic public key".into());
        }
        let json: Value = serde_json::from_str(&text("json")).map_err(|e| e.to_string())?;
        if json["rawId"] != "AQIDBA" || json["response"]["signature"] != text("signature") {
            return Err(format!("toJSON differs: {json}"));
        }
        Ok(())
    }

    /// The production controller, ticked as the browser ticks it, with this
    /// fixture's click on its prompt.
    pub struct Driver {
        pub passkeys: Passkeys,
        pub vault: Arc<SigningVault>,
        pub workers: Vec<std::thread::JoinHandle<()>>,
        pub accept: bool,
        pub prompts: Arc<Mutex<Vec<String>>>,
        pub navigation: Arc<AtomicU64>,
        pub requested: Arc<AtomicU64>,
    }
    impl Driver {
        pub fn tick(&mut self) {
            let tabs = [TabState {
                thread: THREAD,
                tab: TAB,
                url: super::URL,
                shown: true,
            }];
            let workers = &mut self.workers;
            self.passkeys
                .poll(&tabs, &mut |worker| workers.push(worker));
            if let Some(prompt) = self.passkeys.prompt(THREAD, TAB)
                && !prompt.busy
            {
                self.prompts.lock().unwrap().push(prompt.title.clone());
                let workers = &mut self.workers;
                self.passkeys
                    .answer(prompt.id, self.accept, &mut |worker| workers.push(worker));
            }
            let mut index = 0;
            while index < self.workers.len() {
                if self.workers[index].is_finished() {
                    let _ = self.workers.remove(index).join();
                } else {
                    index += 1;
                }
            }
        }
        /// The notice the pane would show, and the `read` note's flag.
        pub fn noticed(&self) -> bool {
            self.passkeys.notice(THREAD, TAB).is_some()
                && self.requested.load(Ordering::Acquire)
                    == self.navigation.load(Ordering::Acquire) + 1
        }
    }
}

// The sign-in stages, and their bookkeeping, are macOS's.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
struct Fixture {
    view: Entity<gpui_webview::WebView>,
    _context: wry::WebContext,
    #[cfg(target_os = "macos")]
    _bridge: Option<browser_passkeys::Bridge>,
    #[cfg(target_os = "macos")]
    driver: sign_in::Driver,
    read: Option<mpsc::Receiver<Value>>,
    /// The current stage's request was sent to the page.
    dispatched: bool,
    stage: usize,
    stage_started: Instant,
    started: Instant,
    evidence: Arc<Mutex<Vec<String>>>,
    result: Arc<Mutex<Option<Result<(), String>>>>,
}

impl Fixture {
    fn new(
        root: &Path,
        evidence: Arc<Mutex<Vec<String>>>,
        result: Arc<Mutex<Option<Result<(), String>>>>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let mut context = wry::WebContext::new(Some(root.join("runtime")));
        let builder = wry::WebViewBuilder::new_with_web_context(&mut context)
            .with_incognito(true)
            .with_devtools(false)
            .with_clipboard(false)
            .with_autoplay(false)
            // The frame stage's child document is `about:srcdoc`.
            .with_navigation_handler(|url| {
                matches!(url.as_str(), URL | "about:blank" | "about:srcdoc")
            })
            .with_url("about:blank");
        #[cfg(target_os = "macos")]
        let (builder, bridge, driver) = macos::configure(builder, evidence.clone());
        let view = gpui_webview::WebView::build(builder, window, cx)
            .expect("synthetic native view construction failed");
        load_fixture(view.raw(), root).expect("owned fixture page setup failed");
        let view = cx.new(|_| view);
        cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(25))
                    .await;
                if this.update(cx, |this, cx| this.poll(cx)).unwrap_or(true) {
                    break;
                }
            }
        })
        .detach();
        Self {
            view,
            _context: context,
            #[cfg(target_os = "macos")]
            _bridge: bridge,
            #[cfg(target_os = "macos")]
            driver,
            read: None,
            dispatched: false,
            stage: 0,
            stage_started: Instant::now(),
            started: Instant::now(),
            evidence,
            result,
        }
    }

    /// Evaluates `script` in the page's world; its JSON result arrives in `read`.
    fn evaluate(&mut self, script: &str, cx: &App) {
        let (sender, receiver) = mpsc::sync_channel(1);
        self.read = Some(receiver);
        let sent = self
            .view
            .read(cx)
            .raw()
            .evaluate_script_with_callback(script, move |value| {
                let _ = sender.try_send(serde_json::from_str(&value).unwrap_or(Value::Null));
            });
        if sent.is_err() {
            self.finish(Err("evaluation could not be dispatched".into()));
        }
    }

    /// The evaluation's value, once it has arrived.
    fn value(&mut self) -> Option<Value> {
        let value = self.read.as_ref()?.try_recv().ok()?;
        self.read = None;
        Some(value)
    }

    fn next(&mut self) {
        self.stage += 1;
        self.dispatched = false;
        self.stage_started = Instant::now();
    }

    fn finish(&mut self, outcome: Result<(), String>) {
        let mut result = self.result.lock().unwrap();
        if result.is_none() {
            *result = Some(outcome);
        }
    }

    fn poll(&mut self, cx: &mut Context<Self>) -> bool {
        if self.result.lock().unwrap().is_some() {
            cx.quit();
            return true;
        }
        if self.started.elapsed() > Duration::from_secs(90) {
            self.finish(Err(format!("deadline exceeded at stage {}", self.stage)));
            return false;
        }
        #[cfg(target_os = "macos")]
        self.driver.tick();
        // Stage 0 waits for the owned page on every platform.
        if self.stage == 0 {
            match self.value() {
                None if self.read.is_none() => self.evaluate(PROBE, cx),
                None => {}
                Some(value) => {
                    let probe: Value = value
                        .as_str()
                        .and_then(|text| serde_json::from_str(text).ok())
                        .unwrap_or(Value::Null);
                    if probe["ready"] == true && probe["href"] == URL {
                        self.evidence.lock().unwrap().push(format!("probe {probe}"));
                        match platform_check(&probe) {
                            Ok(true) => self.next(),
                            Ok(false) => self.finish(Ok(())),
                            Err(error) => self.finish(Err(error)),
                        }
                    }
                }
            }
            return false;
        }
        #[cfg(target_os = "macos")]
        self.sign_in_stages(cx);
        false
    }
}

/// What each platform's WebView must report on an owned https page, matching the
/// support the browser reports. True when the sign-in stages follow.
fn platform_check(probe: &Value) -> Result<bool, String> {
    if probe["secure"] != true {
        return Err(format!(
            "the owned https fixture isn't a secure context: {probe}"
        ));
    }
    match browser_passkeys::support() {
        // Coincide's scripts and handler are installed; the page has WebKit's API.
        "bitwarden-sign-in"
            if probe["publicKeyCredential"] == "function" && probe["coincide"] == true =>
        {
            Ok(true)
        }
        // WebView2 answers passkey requests itself; Coincide installs nothing.
        "webview2-native"
            if probe["publicKeyCredential"] == "function" && probe["coincide"] == false =>
        {
            Ok(false)
        }
        // WebKitGTK has no WebAuthn API, so pages never ask; nothing to serve.
        "unavailable"
            if probe["publicKeyCredential"] == "undefined" && probe["coincide"] == false =>
        {
            Ok(false)
        }
        support => Err(format!(
            "the WebView doesn't match the reported passkey support {support}: {probe}"
        )),
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::{Fixture, browser_passkeys, sign_in};
    use objc2::{MainThreadMarker, MainThreadOnly, rc::Retained};
    use objc2_foundation::NSString;
    use objc2_web_kit::{
        WKContentWorld, WKUserScript, WKUserScriptInjectionTime, WKWebViewConfiguration,
        WKWebsiteDataStore,
    };
    use serde_json::Value;
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    };
    use wry::WebViewBuilderExtMacos;

    pub fn configure(
        builder: wry::WebViewBuilder<'_>,
        evidence: Arc<Mutex<Vec<String>>>,
    ) -> (
        wry::WebViewBuilder<'_>,
        Option<browser_passkeys::Bridge>,
        sign_in::Driver,
    ) {
        let mtm = MainThreadMarker::new().expect("UI thread");
        let vault = Arc::new(sign_in::SigningVault {
            key: coincide_core::passkeys::synthetic::Key::generate(),
            lists: AtomicUsize::new(0),
        });
        let mut passkeys = browser_passkeys::Passkeys::new(|| {});
        passkeys.set_vault(Some(vault.clone()));
        let (navigation, requested) = (Arc::new(AtomicU64::new(1)), Arc::new(AtomicU64::new(0)));
        // SAFETY: main thread; a fresh configuration with an ephemeral store, used
        // by this one view.
        let (configuration, bridge) = unsafe {
            let configuration = WKWebViewConfiguration::new(mtm);
            configuration.setWebsiteDataStore(&WKWebsiteDataStore::nonPersistentDataStore(mtm));
            let stub = WKUserScript::initWithSource_injectionTime_forMainFrameOnly_inContentWorld(
                WKUserScript::alloc(mtm),
                &NSString::from_str(sign_in::BROWSER_STUB),
                WKUserScriptInjectionTime::AtDocumentStart,
                false,
                &WKContentWorld::pageWorld(mtm),
            );
            configuration.userContentController().addUserScript(&stub);
            let bridge = browser_passkeys::install(
                &configuration,
                sign_in::TAB,
                passkeys.channel(),
                navigation.clone(),
                requested.clone(),
            );
            (configuration, bridge)
        };
        assert!(bridge.is_some(), "WebKit content worlds unavailable");
        evidence.lock().unwrap().push(format!(
            "platform passkey entitlement: {}",
            browser_passkeys::platform_passkeys_available()
        ));
        let driver = sign_in::Driver {
            passkeys,
            vault,
            workers: vec![],
            accept: true,
            prompts: Arc::default(),
            navigation,
            requested,
        };
        (
            builder.with_webview_configuration(configuration),
            bridge,
            driver,
        )
    }

    impl Fixture {
        /// Each request in turn: run it, wait for its outcome, check it.
        pub(super) fn sign_in_stages(&mut self, cx: &mut gpui_kit::Context<Self>) {
            const STAGES: [&str; 6] = [
                "sign-in",
                "cancel",
                "claim",
                "unmatched",
                "frame",
                "statics",
            ];
            let Some(&name) = STAGES.get(self.stage - 1) else {
                self.finish(Ok(()));
                return;
            };
            if self.stage_started.elapsed() > std::time::Duration::from_secs(20) {
                self.finish(Err(format!("stage {name} timed out")));
                return;
            }
            // Dispatch once, then poll `window.__out` until the page sets it.
            if !self.dispatched {
                self.dispatched = true;
                self.driver.accept = name != "cancel";
                let script = match name {
                    "sign-in" | "cancel" => sign_in::request(sign_in::ALLOWED),
                    "claim" => sign_in::request(sign_in::CLAIM),
                    "unmatched" => sign_in::request(sign_in::UNMATCHED),
                    "frame" => sign_in::FRAME.to_owned(),
                    _ => sign_in::STATICS.to_owned(),
                };
                self.evaluate(&script, cx);
                self.evidence
                    .lock()
                    .unwrap()
                    .push(format!("dispatch {name}"));
                return;
            }
            match self.value() {
                None if self.read.is_none() => {
                    self.evaluate("window.__out === undefined ? null : window.__out", cx)
                }
                None => {}
                Some(Value::String(text)) => {
                    let out: Value = serde_json::from_str(&text).unwrap_or(Value::Null);
                    match self.check(name, &out) {
                        Ok(()) => {
                            self.evidence.lock().unwrap().push(format!("{name}: ok"));
                            self.next();
                        }
                        Err(error) => self.finish(Err(format!("{name}: {error}"))),
                    }
                }
                // Dispatch acknowledged, or not answered yet.
                Some(_) => {}
            }
        }

        fn check(&self, name: &str, out: &Value) -> Result<(), String> {
            let lists = self.driver.vault.lists.load(Ordering::Acquire);
            let prompts = self.driver.prompts.lock().unwrap().clone();
            match name {
                "sign-in" => {
                    sign_in::check_credential(out, &self.driver.vault)?;
                    if prompts
                        != [
                            "Sign in to passkey-fixture.example as synthetic-user with your Bitwarden passkey?",
                        ]
                    {
                        return Err(format!("unexpected prompts {prompts:?}"));
                    }
                    if self.driver.noticed() {
                        return Err("an answered request showed the notice".into());
                    }
                    Ok(())
                }
                "cancel" => (out["error"] == "NotAllowedError"
                    && out["isDOMException"] == true
                    && out["browserCalls"] == 0
                    && prompts.len() == 2)
                    .then_some(())
                    .ok_or(format!("cancelling didn't reject like a browser: {out}")),
                "claim" => (out["error"] == "SecurityError" && lists == 2 && prompts.len() == 2)
                    .then_some(())
                    .ok_or(format!(
                        "another site's RP ID wasn't refused before the vault: {out}"
                    )),
                // Handed back to the browser, which failed it, and noticed.
                "unmatched" => (out["error"] == "NotAllowedError"
                    && out["browserCalls"] == 1
                    && lists == 3
                    && prompts.len() == 2
                    && self.driver.noticed())
                .then_some(())
                .ok_or(format!(
                    "an unmatched request wasn't handed back and noticed: {out}"
                )),
                "frame" => (out["frame"] == "false fallback" && lists == 3)
                    .then_some(())
                    .ok_or(format!("a child frame reached the vault: {out}")),
                _ => (out["uv"] == true && out["conditional"] == false)
                    .then_some(())
                    .ok_or(format!("capability answers differ: {out}")),
            }
        }
    }

    pub fn load(view: &wry::WebView) -> anyhow::Result<()> {
        use objc2_foundation::{NSURL, NSURLRequest};
        use objc2_web_kit::WKWebView;
        use wry::WebViewExtMacOS;
        let native: Retained<WKWebView> = view.webview().into_super();
        let url = NSURL::URLWithString(&NSString::from_str(super::URL))
            .ok_or_else(|| anyhow::anyhow!("fixed HTTPS URL unavailable"))?;
        let request = NSURLRequest::requestWithURL(&url);
        // A simulated response: a real https document URL and origin, no network.
        unsafe {
            let _: Option<Retained<objc2::runtime::AnyObject>> = objc2::msg_send![
                &*native,
                loadSimulatedRequest: &*request,
                responseHTMLString: &*NSString::from_str(super::HTML)
            ];
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
fn load_fixture(view: &wry::WebView, _: &Path) -> anyhow::Result<()> {
    macos::load(view)
}
#[cfg(target_os = "linux")]
fn load_fixture(view: &wry::WebView, _: &Path) -> anyhow::Result<()> {
    use webkit2gtk::WebViewExt;
    use wry::WebViewExtUnix;
    view.webview().load_html(HTML, Some(URL));
    Ok(())
}
#[cfg(target_os = "windows")]
fn load_fixture(view: &wry::WebView, root: &Path) -> anyhow::Result<()> {
    use webview2_com::Microsoft::Web::WebView2::Win32::{
        COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS, ICoreWebView2_3,
    };
    use windows::core::{HSTRING, Interface};
    use wry::WebViewExtWindows;
    std::fs::write(root.join("login.html"), HTML)?;
    let native: ICoreWebView2_3 = view.webview().cast()?;
    unsafe {
        native.SetVirtualHostNameToFolderMapping(
            &HSTRING::from("passkey-fixture.example"),
            &HSTRING::from(root.to_string_lossy().as_ref()),
            COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS,
        )?;
    }
    view.load_url(URL)?;
    Ok(())
}

impl Render for Fixture {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        div().size_full().child(self.view.clone())
    }
}

fn fresh_runner_root() -> anyhow::Result<PathBuf> {
    anyhow::ensure!(
        std::env::var("COINCIDE_SYNTHETIC_PASSKEY_SDK").as_deref() == Ok("1")
            && std::env::var("GITHUB_ACTIONS").as_deref() == Ok("true")
            && std::env::var("RUNNER_ENVIRONMENT").as_deref() == Ok("github-hosted"),
        "explicit fresh GitHub-hosted fixture opt-in required"
    );
    // Never a real vault, even if a runner image carried one.
    anyhow::ensure!(
        std::env::var_os("BW_SESSION").is_none(),
        "a Bitwarden session must not be present"
    );
    let runner = std::fs::canonicalize(
        std::env::var_os("RUNNER_TEMP").ok_or_else(|| anyhow::anyhow!("runner temp required"))?,
    )?;
    let root = tempfile::Builder::new()
        .prefix("owned-synthetic-passkey-")
        .tempdir_in(&runner)?;
    // The runner's destruction cleans this owned scaffold after process return.
    Ok(root.keep())
}

fn main() -> anyhow::Result<()> {
    let root = fresh_runner_root()?;
    let evidence = Arc::new(Mutex::new(Vec::new()));
    let result = Arc::new(Mutex::new(None));
    let (observed, log) = (result.clone(), evidence.clone());
    #[cfg(target_os = "linux")]
    let app = gpui_kit::platform::linux(gpui_kit::WindowingModes::X11);
    #[cfg(not(target_os = "linux"))]
    let app = gpui_kit::application();
    app.run(move |cx| {
        gpui_kit::init(cx);
        gpui_kit::open_window(Default::default(), cx, |window, cx| {
            cx.new(|cx| Fixture::new(&root, evidence, result, window, cx))
        })
        .expect("owned fixture window unavailable");
        cx.activate(true);
    });
    for line in log.lock().unwrap().iter() {
        println!("{line}");
    }
    let outcome = observed.lock().unwrap().clone();
    match outcome {
        Some(Ok(())) => {
            println!(
                "synthetic native passkeys: PASS ({})",
                browser_passkeys::support()
            );
            Ok(())
        }
        Some(Err(error)) => anyhow::bail!("synthetic native passkeys failed: {error}"),
        None => anyhow::bail!("synthetic native passkeys ended without an outcome"),
    }
}
