//! Native server receipts stay bound to the exact server instance and thread.
//! A changed server never receives another instance's replacement/close ID.
use crate::notifications::{Backend, Payload, Permission};
use anyhow::{Result, bail, ensure};
use coincide_core::platform_host::notifications::Delivery;
use std::collections::{BTreeMap, BTreeSet};
use uuid::Uuid;
const LIMIT: usize = 4096;
pub(super) trait Server {
    fn owner(&mut self) -> Result<String>;
    fn notify(&mut self, owner: &str, replace: u32, payload: &Payload) -> Result<u32>;
    fn close(&mut self, owner: &str, id: u32) -> Result<()>;
}
struct Receipt {
    owner: String,
    id: u32,
    thread: Uuid,
}
pub(super) struct NativeServer<S> {
    server: S,
    receipts: BTreeMap<(String, String), Receipt>,
    uncertain: BTreeSet<(Uuid, String, String)>,
}
impl<S> NativeServer<S> {
    pub(super) fn new(server: S) -> Self {
        Self {
            server,
            receipts: BTreeMap::new(),
            uncertain: BTreeSet::new(),
        }
    }
}
impl<S: Server> Backend for NativeServer<S> {
    fn permission(&mut self) -> Result<Permission> {
        let owner = self.server.owner()?;
        ensure!(
            !owner.is_empty() && owner.len() <= 256,
            "Notification service identity unavailable"
        );
        Ok(Permission::Authorized)
    }
    fn request_permission(&mut self) -> Result<Permission> {
        self.permission()
    }
    fn post(&mut self, payload: &Payload) -> Delivery {
        if payload.id.len() > 256
            || payload.title.len() > 4096
            || payload.body.as_ref().is_some_and(|body| body.len() > 32768)
            || self
                .uncertain
                .iter()
                .any(|(thread, id, _)| *thread == payload.thread && id == &payload.id)
        {
            return Delivery::Unavailable;
        }
        let Ok(owner) = self.server.owner() else {
            return Delivery::Unavailable;
        };
        if owner.is_empty() || owner.len() > 256 {
            return Delivery::Unavailable;
        }
        let key = (payload.id.clone(), owner.clone());
        if (!self.receipts.contains_key(&key)
            && self.receipts.len() + self.uncertain.len() >= LIMIT)
            || self
                .receipts
                .iter()
                .any(|((id, _), receipt)| id == &payload.id && receipt.thread != payload.thread)
        {
            return Delivery::Unavailable;
        }
        let replacement = self
            .receipts
            .get(&key)
            .filter(|receipt| receipt.owner == owner && receipt.thread == payload.thread)
            .map_or(0, |receipt| receipt.id);
        match self.server.notify(&owner, replacement, payload) {
            Ok(id) if id > 0 => {
                self.receipts.insert(
                    key,
                    Receipt {
                        owner,
                        id,
                        thread: payload.thread,
                    },
                );
                Delivery::Accepted
            }
            _ => {
                self.uncertain
                    .insert((payload.thread, payload.id.clone(), owner));
                Delivery::Uncertain
            }
        }
    }
    fn clear_thread(&mut self, thread: Uuid) -> Result<()> {
        let keys = self
            .receipts
            .iter()
            .filter(|(_, receipt)| receipt.thread == thread)
            .map(|(key, _)| key.clone())
            .collect::<Vec<_>>();
        let mut failed = false;
        for key in keys {
            let receipt = &self.receipts[&key];
            if self.server.close(&receipt.owner, receipt.id).is_ok() {
                self.receipts.remove(&key);
            } else {
                failed = true;
            }
        }
        if failed || self.uncertain.iter().any(|(owner, _, _)| *owner == thread) {
            bail!("Some notifications have no confirmed close receipt");
        }
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Fake {
        owner: String,
        calls: Vec<(String, u32)>,
        closes: Vec<(String, u32)>,
        fail_notify: bool,
        fail_close: bool,
    }
    impl Server for Fake {
        fn owner(&mut self) -> Result<String> {
            Ok(self.owner.clone())
        }
        fn notify(&mut self, owner: &str, replace: u32, _: &Payload) -> Result<u32> {
            self.calls.push((owner.into(), replace));
            if self.fail_notify {
                bail!("synthetic lost acknowledgement");
            }
            Ok(self.calls.len() as u32)
        }
        fn close(&mut self, owner: &str, id: u32) -> Result<()> {
            self.closes.push((owner.into(), id));
            if self.fail_close {
                bail!("synthetic lost close");
            }
            Ok(())
        }
    }
    fn payload(thread: Uuid, id: &str) -> Payload {
        Payload {
            id: id.into(),
            thread,
            title: "Synthetic notice".into(),
            body: None,
        }
    }
    #[::core::prelude::v1::test]
    fn replacement_and_close_never_cross_server_or_thread_receipts() {
        let mut native = NativeServer::new(Fake {
            owner: "server-one".into(),
            ..Fake::default()
        });
        let first = Uuid::new_v4();
        let other = Uuid::new_v4();
        assert!(native.server.calls.is_empty());
        assert_eq!(native.post(&payload(first, "first")), Delivery::Accepted);
        assert_eq!(native.post(&payload(first, "first")), Delivery::Accepted);
        native.server.owner = "server-two".into();
        assert_eq!(native.post(&payload(first, "first")), Delivery::Accepted);
        assert_eq!(native.post(&payload(other, "other")), Delivery::Accepted);
        assert_eq!(
            native.server.calls,
            vec![
                ("server-one".into(), 0),
                ("server-one".into(), 1),
                ("server-two".into(), 0),
                ("server-two".into(), 0)
            ]
        );
        native.clear_thread(first).unwrap();
        assert_eq!(
            native.server.closes,
            vec![("server-one".into(), 2), ("server-two".into(), 3)]
        );
        assert_eq!(native.receipts.len(), 1);
    }
    #[::core::prelude::v1::test]
    fn lost_reply_is_uncertain_and_cannot_be_reposted_or_reported_cleared() {
        let mut native = NativeServer::new(Fake {
            owner: "server-one".into(),
            fail_notify: true,
            ..Fake::default()
        });
        let thread = Uuid::new_v4();
        assert_eq!(native.post(&payload(thread, "first")), Delivery::Uncertain);
        native.server.fail_notify = false;
        assert_eq!(
            native.post(&payload(thread, "first")),
            Delivery::Unavailable
        );
        assert!(native.clear_thread(thread).is_err());
        assert_eq!(native.server.calls.len(), 1);
    }
    #[::core::prelude::v1::test]
    fn failed_close_retains_exact_owned_receipt_for_explicit_retry() {
        let mut native = NativeServer::new(Fake {
            owner: "server-one".into(),
            ..Fake::default()
        });
        let thread = Uuid::new_v4();
        native.post(&payload(thread, "first"));
        native.server.fail_close = true;
        assert!(native.clear_thread(thread).is_err());
        assert_eq!(native.receipts.len(), 1);
        native.server.fail_close = false;
        native.clear_thread(thread).unwrap();
        assert!(native.receipts.is_empty());
        native.clear_thread(thread).unwrap();
        assert_eq!(native.server.closes.len(), 2);
    }
}
