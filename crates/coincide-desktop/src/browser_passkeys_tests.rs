//! The controller with a fake vault, fake verification and recorded page replies.
//! No WebView, `bw`, environment, Touch ID dialog or real passkey is used.
use super::*;
use coincide_core::passkeys::base64url;
use serde_json::json;
use std::sync::Mutex;

struct FakeVault {
    list: Vec<BitwardenPasskey>,
    signed: Mutex<Vec<(String, bool)>>,
    locked: bool,
}

impl PasskeyVault for FakeVault {
    fn ready(&self) -> bool {
        !self.locked
    }
    fn passkeys(&self) -> Result<Vec<BitwardenPasskey>, Failure> {
        Ok(self.list.clone())
    }
    fn assertion(
        &self,
        passkey: &BitwardenPasskey,
        rp_id: &str,
        _client_data_json: &[u8],
        user_verified: bool,
    ) -> Result<PasskeyAssertion, Failure> {
        self.signed
            .lock()
            .unwrap()
            .push((rp_id.to_owned(), user_verified));
        Ok(PasskeyAssertion {
            credential_id: passkey.credential_id.clone(),
            authenticator_data: vec![1],
            signature: vec![2],
            user_handle: None,
        })
    }
}

fn octocat() -> BitwardenPasskey {
    BitwardenPasskey {
        item_id: "a".into(),
        item_name: "GitHub".into(),
        user_name: "octocat".into(),
        user_display_name: String::new(),
        rp_id: "github.com".into(),
        stored_credential_id: "b64.AQ".into(),
        credential_id: vec![1],
        user_handle: None,
        counter: 0,
        discoverable: true,
        requires_reprompt: false,
    }
}

fn never_verifies(
    _: &str,
    _: Box<dyn FnOnce(UserVerification) + Send>,
) -> Option<Box<dyn FnOnce()>> {
    panic!("no verification was asked for");
}
fn verify_unavailable(
    _: &str,
    done: Box<dyn FnOnce(UserVerification) + Send>,
) -> Option<Box<dyn FnOnce()>> {
    done(UserVerification::Unavailable);
    None
}
fn verify_failed(
    _: &str,
    done: Box<dyn FnOnce(UserVerification) + Send>,
) -> Option<Box<dyn FnOnce()>> {
    done(UserVerification::Failed);
    None
}

struct Fixture {
    passkeys: Passkeys,
    vault: Arc<FakeVault>,
    workers: Vec<std::thread::JoinHandle<()>>,
    replies: Rc<RefCell<Vec<Map<String, Value>>>>,
    url: String,
    shown: bool,
}

impl Fixture {
    fn new(verify: Verify) -> Self {
        let vault = Arc::new(FakeVault {
            list: vec![octocat()],
            signed: Mutex::default(),
            locked: false,
        });
        let mut passkeys = Passkeys::new(|| {});
        passkeys.set_verify(verify);
        passkeys.set_vault(Some(vault.clone()));
        Self {
            passkeys,
            vault,
            workers: vec![],
            replies: Rc::default(),
            url: "https://github.com/login".into(),
            shown: true,
        }
    }
    fn reply(&self) -> PageReply {
        let replies = self.replies.clone();
        PageReply::new(move |message| replies.borrow_mut().push(message))
    }
    fn get(&self, body: Value) {
        self.passkeys.channel().push(Incoming::Get {
            tab: "tab".into(),
            origin: WebAuthnOrigin::from_url(&self.url).unwrap(),
            body,
            reply: self.reply(),
        });
    }
    /// Polls until every worker it started has reported back.
    fn poll(&mut self) -> bool {
        let tabs = [TabState {
            thread: "thread",
            tab: "tab",
            url: &self.url,
            shown: self.shown,
        }];
        let workers = &mut self.workers;
        let mut changed = self
            .passkeys
            .poll(&tabs, &mut |worker| workers.push(worker));
        while !self.workers.is_empty() {
            for worker in self.workers.drain(..) {
                worker.join().unwrap();
            }
            let workers = &mut self.workers;
            changed |= self
                .passkeys
                .poll(&tabs, &mut |worker| workers.push(worker));
        }
        changed
    }
    fn answer(&mut self, accept: bool) {
        let id = self.passkeys.prompt("thread", "tab").expect("a prompt").id;
        let workers = &mut self.workers;
        assert!(
            self.passkeys
                .answer(id, accept, &mut |worker| workers.push(worker))
        );
        self.poll();
    }
    fn statuses(&self) -> Vec<String> {
        self.replies
            .borrow()
            .iter()
            .map(|reply| {
                format!(
                    "{}{}",
                    reply["status"].as_str().unwrap(),
                    reply
                        .get("name")
                        .map(|name| format!(":{}", name.as_str().unwrap()))
                        .unwrap_or_default()
                )
            })
            .collect()
    }
}

fn body(rp_id: Option<&str>) -> Value {
    let mut body =
        json!({"kind":"get","id":"r1","publicKey":{"challenge":base64url::encode(&[9; 32])}});
    if let Some(rp_id) = rp_id {
        body["publicKey"]["rpId"] = json!(rp_id);
    }
    body
}

#[test]
fn signs_in_once_after_sign_in_with_the_frames_origin() {
    let mut fixture = Fixture::new(never_verifies);
    assert!(fixture.passkeys.channel().available());
    fixture.get(body(Some("github.com")));
    assert!(fixture.poll());
    let prompt = fixture.passkeys.prompt("thread", "tab").unwrap();
    assert_eq!(
        prompt.title,
        "Sign in to github.com as octocat with your Bitwarden passkey?"
    );
    assert!(prompt.accounts.is_empty() && !prompt.busy);
    // Another thread's pane doesn't show it.
    assert!(fixture.passkeys.prompt("other", "tab").is_none());
    assert!(fixture.replies.borrow().is_empty());
    fixture.answer(true);
    assert_eq!(fixture.statuses(), ["ok"]);
    let reply = &fixture.replies.borrow()[0];
    assert_eq!(reply["id"], "AQ");
    let client = base64url::decode(reply["clientDataJSON"].as_str().unwrap()).unwrap();
    assert!(
        String::from_utf8(client)
            .unwrap()
            .contains(r#""origin":"https://github.com""#)
    );
    assert_eq!(
        fixture.vault.signed.lock().unwrap().as_slice(),
        [("github.com".to_owned(), false)]
    );
    assert!(fixture.passkeys.prompt("thread", "tab").is_none());
}

#[test]
fn cancel_abort_navigation_close_and_shutdown_refuse_the_request() {
    let scenarios: [fn(&mut Fixture); 5] = [
        |f| f.answer(false),
        |f| {
            f.passkeys.channel().push(Incoming::Abort {
                tab: "tab".into(),
                id: "r1".into(),
            });
            f.poll();
        },
        |f| {
            // Leaving the page's origin ends it, as a browser's does.
            f.url = "https://evil.test/".into();
            f.poll();
        },
        |f| {
            f.passkeys.closed("thread", "tab");
            f.poll();
        },
        |f| f.passkeys.shutdown(),
    ];
    for scenario in scenarios {
        let mut fixture = Fixture::new(never_verifies);
        fixture.get(body(None));
        fixture.poll();
        assert!(fixture.passkeys.prompt("thread", "tab").is_some());
        scenario(&mut fixture);
        assert_eq!(fixture.statuses(), ["error:NotAllowedError"]);
        assert!(fixture.vault.signed.lock().unwrap().is_empty());
        assert!(fixture.passkeys.prompt("thread", "tab").is_none());
    }
    // An abort naming another request leaves this one waiting.
    let mut fixture = Fixture::new(never_verifies);
    fixture.get(body(None));
    fixture.poll();
    fixture.passkeys.channel().push(Incoming::Abort {
        tab: "tab".into(),
        id: "other".into(),
    });
    fixture.poll();
    assert!(fixture.passkeys.prompt("thread", "tab").is_some());
    // Same-origin navigation keeps it too.
    fixture.url = "https://github.com/sessions/two-factor".into();
    fixture.poll();
    assert!(fixture.passkeys.prompt("thread", "tab").is_some());
}

#[test]
fn a_second_request_waits_and_what_coincide_cant_answer_goes_to_the_browser() {
    let mut fixture = Fixture::new(never_verifies);
    fixture.get(body(None));
    fixture.poll();
    fixture.get(body(None));
    fixture.poll();
    assert_eq!(fixture.statuses(), ["error:NotAllowedError"]);
    assert_eq!(
        fixture.replies.borrow()[0]["message"],
        "A request is already pending."
    );
    for (prepare, request, expected) in [
        (
            (|f: &mut Fixture| {
                f.passkeys.set_preferences(Preferences {
                    uses_bitwarden: false,
                    ..Preferences::default()
                });
            }) as fn(&mut Fixture),
            body(None),
            "fallback",
        ),
        (|f| f.passkeys.set_vault(None), body(None), "fallback"),
        (|f| f.shown = false, body(None), "fallback"),
        (|_| {}, json!({"kind":"get","id":"r1"}), "fallback"),
        (|_| {}, body(Some("gitlab.com")), "error:SecurityError"),
        (
            |f| f.url = "https://gitlab.com/".into(),
            body(None),
            "fallback",
        ),
    ] {
        let mut fixture = Fixture::new(never_verifies);
        prepare(&mut fixture);
        fixture.get(request);
        fixture.poll();
        assert_eq!(fixture.statuses(), [expected]);
        assert!(fixture.passkeys.last_fallback.is_some() == (expected == "fallback"));
    }
    // The script's `available` follows the setting, the vault and its session.
    let mut fixture = Fixture::new(never_verifies);
    fixture.passkeys.set_vault(Some(Arc::new(FakeVault {
        list: vec![octocat()],
        signed: Mutex::default(),
        locked: true,
    })));
    assert!(!fixture.passkeys.channel().available());
    fixture.get(body(None));
    fixture.poll();
    assert_eq!(fixture.statuses(), ["fallback"]);
}

#[test]
fn verification_follows_the_setting_and_its_outcome() {
    let mut fixture = Fixture::new(verify_unavailable);
    fixture.passkeys.set_preferences(Preferences {
        always_verifies: true,
        ..Preferences::default()
    });
    fixture.get(body(None));
    fixture.poll();
    assert!(
        fixture
            .passkeys
            .prompt("thread", "tab")
            .unwrap()
            .detail
            .contains("next")
    );
    fixture.answer(true);
    // This computer couldn't verify, and the site didn't require it.
    assert_eq!(fixture.statuses(), ["ok"]);
    assert!(!fixture.vault.signed.lock().unwrap()[0].1);

    let mut fixture = Fixture::new(verify_failed);
    fixture.passkeys.set_preferences(Preferences {
        always_verifies: true,
        ..Preferences::default()
    });
    fixture.get(body(None));
    fixture.poll();
    fixture.answer(true);
    assert_eq!(fixture.statuses(), ["error:NotAllowedError"]);
    assert!(fixture.vault.signed.lock().unwrap().is_empty());
}

#[test]
fn the_notice_follows_requests_dismissal_and_navigation() {
    let mut fixture = Fixture::new(never_verifies);
    fixture.passkeys.channel().push(Incoming::Requested {
        tab: "tab".into(),
        host: "accounts.google.com".into(),
    });
    assert!(fixture.poll());
    let (message, action) = fixture.passkeys.notice("thread", "tab").unwrap();
    assert!(message.starts_with("Passkeys aren’t available"));
    assert_eq!(action, Some("Open in Default Browser"));
    assert!(fixture.passkeys.notice("thread", "another-tab").is_none());
    assert_eq!(
        fixture.passkeys.open_notice("thread").as_deref(),
        Some("tab")
    );
    let (message, action) = fixture.passkeys.notice("thread", "tab").unwrap();
    assert!(message.contains("google.com") && action.is_none());
    assert!(
        !fixture
            .passkeys
            .navigated("thread", "tab", "https://mail.google.com/")
    );
    assert!(
        fixture
            .passkeys
            .navigated("thread", "tab", "https://github.com/")
    );
    assert!(fixture.passkeys.notice("thread", "tab").is_none());
    // Once dismissed, it stays hidden for every site.
    assert!(fixture.passkeys.set_preferences(Preferences {
        notice_dismissed: true,
        ..Preferences::default()
    }));
    fixture.passkeys.channel().push(Incoming::Requested {
        tab: "tab".into(),
        host: "github.com".into(),
    });
    fixture.poll();
    assert!(fixture.passkeys.notice("thread", "tab").is_none());
}

#[test]
fn a_full_queue_refuses_more_requests_at_once() {
    let fixture = Fixture::new(never_verifies);
    for _ in 0..=MAX_QUEUED {
        fixture.get(body(None));
    }
    assert_eq!(fixture.statuses(), ["error:NotAllowedError"]);
    assert_eq!(
        Preferences::from_settings(&json!({"usesBitwardenPasskeys":false})),
        Preferences {
            uses_bitwarden: false,
            ..Preferences::default()
        }
    );
    assert_eq!(
        Preferences::from_settings(&json!({})),
        Preferences::default()
    );
}
