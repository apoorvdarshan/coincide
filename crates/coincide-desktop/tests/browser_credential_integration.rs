// Compile the private sink against the real credential handoff module while
// keeping main.rs registration with the coordinator. No live vault/browser.
// Keep the same real lifetime seam as production browser::{shutdown,
// credential_bridge}; the native child resolves it through its parent root.
#[path = "../src/browser_credentials.rs"]
mod browser_credentials;
#[path = "../src/credentials.rs"]
mod credentials;
#[path = "../src/browser_shutdown.rs"]
mod shutdown;

use browser_credentials::BrowserCredentialSink;
use coincide_core::credentials::{Failure, Login, Manager, PageBinding, Vault, VaultCommand};
use credentials::{deliver_fill, private_fill_channel};
use std::time::Duration;

struct SyntheticVault;
impl VaultCommand for SyntheticVault {
    fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
        let response = match args {
            [
                "list",
                "items",
                "--url",
                "https://example.test",
                "--nointeraction",
            ] => {
                r#"[{"id":"fixture","type":1,"name":"Synthetic","login":{"uris":[{"uri":"https://example.test"}]}}]"#
            }
            ["get", "item", "fixture", "--nointeraction"] => {
                r#"{"login":{"username":"synthetic-user","password":"synthetic-only-password","uris":[{"uri":"https://example.test"}]}}"#
            }
            _ => return Err(Failure::Unavailable),
        };
        Ok(response.as_bytes().to_vec())
    }
}
fn page(navigation: u64) -> PageBinding {
    PageBinding::new("synthetic-tab".into(), navigation, "https://example.test").unwrap()
}

#[test]
fn actual_private_channel_denies_unsupported_or_changed_document_and_acknowledges_worker() {
    for mode in 0..3 {
        let (mut sink, jobs) = private_fill_channel();
        let worker = std::thread::spawn(move || {
            let vault = Vault::new(Manager::Bitwarden, SyntheticVault);
            // Synthetic consent solely for channel-boundary testing. Production
            // approval is unavailable while credential_fill_available is false.
            let approved = vault
                .approve(
                    &page(1),
                    &Login {
                        id: "fixture".into(),
                        title: "Synthetic".into(),
                        username: "synthetic-user".into(),
                    },
                    true,
                )
                .unwrap();
            vault.fill(approved, &page(1), &mut sink)
        });
        let job = jobs.recv_timeout(Duration::from_secs(2)).unwrap();
        let calls = std::cell::Cell::new(0);
        let mut hook = BrowserCredentialSink::new(|_: &str| {
            calls.set(calls.get() + 1);
            // Mode 2 changes between deliver_fill's first check and the sink's
            // recheck, exercising the native private-channel boundary.
            Ok(page(if mode == 1 || (mode == 2 && calls.get() >= 2) {
                2
            } else {
                1
            }))
        });
        deliver_fill(job, &mut hook);
        assert_eq!(
            worker.join().unwrap(),
            Err(if mode != 0 {
                Failure::StalePage
            } else {
                Failure::Unavailable
            })
        );
        assert!(jobs.try_recv().is_err());
    }
}
