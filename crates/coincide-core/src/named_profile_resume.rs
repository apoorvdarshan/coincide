//! Owned named-profile continuation authority. Thread JSON stays descriptive;
//! only the private authenticated journal can carry joined-worker authority
//! across restart, subject to fresh runtime/catalog admission.
#[path = "named_profile_resume_journal.rs"]
mod journal;
use crate::{
    agent::{self, WorkerCompletion, WorkerThreadStatus},
    codex_login_profiles::LaunchContext,
    composer_policy::Policy,
    model_catalog::NamedBinding,
};
use anyhow::{Context as _, Result, ensure};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{collections::HashMap, io::Write, path::Path};
use uuid::Uuid;

const MAX_RECEIPTS: usize = 128;
const MAX_PREFIX_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
struct Context {
    owner: Uuid,
    binding: NamedBinding,
    selection: Value,
    access: Option<Value>,
    interaction: Option<Value>,
    policy: Policy,
}
impl Context {
    fn durable(&self) -> Result<Value> {
        self.validate()?;
        // A restart may obtain a NEW private proof only through normal catalog
        // admission. Arc identity/revocation is never serialized or recreated.
        // Within one Engine, the original full Context equality still applies.
        Ok(
            serde_json::json!({"binding":serde_json::to_value(&self.binding)?,
            "selection":self.selection,"access":self.access,"accessPresent":self.access.is_some(),
            "interaction":self.interaction,"interactionPresent":self.interaction.is_some(),
            "effectiveEffort":self.policy.codex_effort(),"effectiveSpeed":self.policy.codex_speed()}),
        )
    }
    fn validate(&self) -> Result<()> {
        self.binding.validate()?;
        self.policy.preflight()
    }
    fn validate_launch(&self, profile: &LaunchContext, cwd: &Path, policy: &Policy) -> Result<()> {
        self.validate()?;
        ensure!(
            self.binding == NamedBinding::capture(profile.clone(), self.binding.thread(), cwd)?
                && &self.policy == policy,
            "Named resume context changed before launch"
        );
        Ok(())
    }
}

/// Only Registry creates this captured launch authority. Optional continuation
/// is consumed before a new turn; failure/cancellation cannot reuse its receipt.
#[derive(Clone)]
pub(crate) struct Authority {
    context: Context,
    previous: Option<Receipt>,
}
impl Authority {
    pub(crate) fn session(&self) -> Option<&str> {
        self.previous
            .as_ref()
            .map(|receipt| receipt.native.as_str())
    }
    pub(crate) fn seen(&self) -> usize {
        self.previous
            .as_ref()
            .map_or(0, |receipt| receipt.items.count)
    }
    pub(crate) fn validate_launch(
        &self,
        profile: &LaunchContext,
        cwd: &Path,
        policy: &Policy,
        session: Option<&str>,
    ) -> Result<()> {
        self.context.validate_launch(profile, cwd, policy)?;
        ensure!(
            session == self.session(),
            "Named resume session authority changed"
        );
        Ok(())
    }
    pub(crate) fn acknowledge(&self, result: &Value) -> Result<Acknowledged> {
        self.context.validate()?;
        let native = result["thread"]["id"]
            .as_str()
            .context("Missing owned session ID")?;
        ensure!(
            !native.is_empty() && native.len() <= 512 && !native.chars().any(char::is_control),
            "Invalid owned named session ID"
        );
        let resolved = result["model"]
            .as_str()
            .context("Named session did not resolve a model")?;
        // A resume receipt must meet the same actual-model contract as the
        // turn policy, including trimmed, nonblank and non-default identity.
        crate::composer_policy::ResolvedCodexModel::from_thread_result(native, result)?;
        if let Some(previous) = &self.previous {
            ensure!(
                native == previous.native && resolved == previous.resolved,
                "Named resume acknowledged another session or resolved model"
            );
        }
        Ok(Acknowledged {
            context: self.context.clone(),
            native: native.into(),
            resolved: resolved.into(),
        })
    }
}

/// Constructed only from the actual captured worker's matching thread ACK.
/// The worker publishes it only after a completed (not interrupted) turn.
pub(crate) struct Acknowledged {
    context: Context,
    native: String,
    resolved: String,
}
impl Acknowledged {
    pub(crate) fn validate(&self) -> Result<()> {
        self.context.validate()
    }
}

#[derive(Clone)]
struct Receipt {
    context: Context,
    native: String,
    resolved: String,
    items: Items,
}
impl Receipt {
    fn durable(&self) -> Result<Value> {
        Ok(
            serde_json::json!({"context":self.context.durable()?,"native":self.native,
            "resolved":self.resolved,"items":serde_json::to_value(&self.items)?}),
        )
    }
    fn restore(value: Value, context: &Context) -> Result<Self> {
        ensure!(
            value["context"] == context.durable()?,
            "Durable continuation context changed"
        );
        let native = value["native"]
            .as_str()
            .context("Invalid durable session")?
            .to_owned();
        let resolved = value["resolved"]
            .as_str()
            .context("Invalid durable resolved model")?
            .to_owned();
        crate::composer_policy::ResolvedCodexModel::from_thread_result(
            &native,
            &serde_json::json!({"thread":{"id":native},"model":resolved}),
        )?;
        let items: Items = serde_json::from_value(value["items"].clone())?;
        Ok(Self {
            context: context.clone(),
            native,
            resolved,
            items,
        })
    }
}
struct Pending {
    receipt: Receipt,
    worker: WorkerCompletion,
}
pub(crate) struct Registry {
    owner: Uuid,
    pending: HashMap<String, Pending>,
    ready: HashMap<String, Receipt>,
    journal: Option<journal::Journal>,
}
impl Default for Registry {
    fn default() -> Self {
        Self {
            owner: Uuid::new_v4(),
            pending: HashMap::new(),
            ready: HashMap::new(),
            journal: None,
        }
    }
}
impl Registry {
    pub(crate) fn for_store(store: &crate::store::Store) -> Self {
        Self {
            journal: journal::Journal::open(store).ok(),
            ..Self::default()
        }
    }
    pub(crate) fn poll(&mut self) {
        let completed: Vec<_> = self
            .pending
            .iter()
            .filter(|(_, pending)| pending.worker.status() != WorkerThreadStatus::Running)
            .map(|(id, _)| id.clone())
            .collect();
        for id in completed {
            let pending = self.pending.remove(&id).unwrap();
            // No semantic Finished, panic or unclassified observer can mint
            // authority. Actual Rust join must have acknowledged return.
            if pending.worker.status() == WorkerThreadStatus::Returned
                && pending.receipt.context.owner == self.owner
                && pending.receipt.context.validate().is_ok()
            {
                if let Some(journal) = &mut self.journal {
                    // A failed durable save grants no restart authority. The
                    // independent same-Engine receipt can remain usable.
                    let record = pending.receipt.durable();
                    if record.and_then(|record| journal.put(&id, &record)).is_err() {
                        self.journal = None;
                    }
                }
                self.ready.insert(id, pending.receipt);
            }
        }
    }
    pub(crate) fn prepare(
        &mut self,
        thread: &Value,
        profile: LaunchContext,
        cwd: &Path,
        policy: Policy,
    ) -> Result<Authority> {
        self.poll();
        let id = thread["id"]
            .as_str()
            .context("Missing named thread identity")?;
        ensure!(
            !self.pending.contains_key(id),
            "Wait for the previous named worker to finish cleanup"
        );
        let context = Context {
            owner: self.owner,
            binding: NamedBinding::capture(profile, id, cwd)?,
            selection: thread["selection"].clone(),
            access: thread.get("accessMode").cloned(),
            interaction: thread.get("interactionMode").cloned(),
            policy,
        };
        context.validate()?;
        // Consume disk authority first, even for a same-Engine continuation.
        // Launch is forbidden if consumption cannot be durably committed.
        let durable = match &mut self.journal {
            Some(journal) => journal.take(id)?,
            None => None,
        };
        let in_memory = self.ready.remove(id);
        let previous = if let Some(receipt) = in_memory {
            Some(receipt).filter(|receipt| receipt.context == context)
        } else {
            durable.and_then(|value| Receipt::restore(value, &context).ok())
        }
        .filter(|receipt| {
            receipt.context == context
                && agent::provider_session(thread, "codex").as_deref()
                    == Some(receipt.native.as_str())
                && receipt.items.matches(thread)
        });
        Ok(Authority { context, previous })
    }
    /// Called only after the final successful transcript save. A pending record
    /// is not a resume receipt until poll observes this exact worker's join.
    pub(crate) fn persisted(
        &mut self,
        ack: Acknowledged,
        thread: &Value,
        worker: WorkerCompletion,
    ) {
        let id = ack.context.binding.thread().to_owned();
        self.ready.remove(&id);
        self.pending.remove(&id);
        if self.ready.len() + self.pending.len() >= MAX_RECEIPTS {
            self.ready.clear();
            // Pending workers retain their independent Engine ownership. Only
            // their optional continuation opportunity is discarded here.
            self.pending.clear();
        }
        let Ok(items) = Items::capture(thread, None) else {
            return;
        };
        if ack.context.owner != self.owner
            || ack.validate().is_err()
            || thread["id"] != id
            || thread["selection"] != ack.context.selection
            || thread.get("accessMode") != ack.context.access.as_ref()
            || thread.get("interactionMode") != ack.context.interaction.as_ref()
            || agent::provider_session(thread, "codex").as_deref() != Some(ack.native.as_str())
        {
            return;
        }
        self.pending.insert(
            id,
            Pending {
                receipt: Receipt {
                    context: ack.context,
                    native: ack.native,
                    resolved: ack.resolved,
                    items,
                },
                worker,
            },
        );
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
struct Items {
    count: usize,
    digest: [u8; 32],
}
impl Items {
    fn capture(thread: &Value, count: Option<usize>) -> Result<Self> {
        let items = thread["items"].as_array().context("Missing transcript")?;
        let count = count.unwrap_or(items.len());
        ensure!(
            count <= items.len(),
            "Named resume transcript was truncated"
        );
        let mut writer = PrefixDigest {
            bytes: 0,
            digest: Sha256::new(),
        };
        serde_json::to_writer(&mut writer, &items[..count])?;
        Ok(Self {
            count,
            digest: writer.digest.finalize().into(),
        })
    }
    fn matches(&self, thread: &Value) -> bool {
        Self::capture(thread, Some(self.count)).is_ok_and(|current| current.digest == self.digest)
    }
}
struct PrefixDigest {
    bytes: usize,
    digest: Sha256,
}
impl Write for PrefixDigest {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let count = self
            .bytes
            .checked_add(bytes.len())
            .filter(|count| *count <= MAX_PREFIX_BYTES)
            .ok_or_else(|| std::io::Error::other("Named resume prefix exceeds its bound"))?;
        self.digest.update(bytes);
        self.bytes = count;
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[cfg(unix)]
    #[test]
    fn acknowledgement_requires_the_actual_resolved_model_contract() {
        use std::{fs, os::unix::fs::PermissionsExt};
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root = dir.path().canonicalize().unwrap();
        let account = Uuid::new_v4().to_string();
        crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
        let profile =
            LaunchContext::capture(&root, &account, &std::env::current_exe().unwrap()).unwrap();
        let thread = json!({"id":Uuid::new_v4().to_string(),"selection":{"provider":"codex","accountID":account,"modelID":"default"},"accessMode":"approval","interactionMode":"build","items":[]});
        let policy =
            Policy::parse_named(&thread, crate::composer_policy::Origin::Ordinary, None).unwrap();
        let mut registry = Registry::default();
        let authority = registry.prepare(&thread, profile, &root, policy).unwrap();
        assert!(authority.session().is_none());
        for model in [
            None,
            Some(Value::Null),
            Some(json!(17)),
            Some(json!("")),
            Some(json!("   ")),
            Some(json!(" model-actual")),
            Some(json!("model-actual ")),
            Some(json!("default")),
            Some(json!(" default ")),
        ] {
            let mut result = json!({"thread":{"id":"native-owned"}});
            if let Some(model) = model {
                result["model"] = model;
            }
            assert!(
                authority.acknowledge(&result).is_err(),
                "Invalid resolved model must not create completion authority: {result}"
            );
            assert!(registry.ready.is_empty() && registry.pending.is_empty());
        }
        let result = json!({"thread":{"id":"native-owned"},"model":"model-actual"});
        let ack = authority.acknowledge(&result).unwrap();
        assert_eq!(ack.native, "native-owned");
        assert_eq!(ack.resolved, "model-actual");
        assert!(
            registry.ready.is_empty() && registry.pending.is_empty(),
            "Even a valid ACK alone cannot mint a resume receipt"
        );
    }

    #[cfg(unix)]
    #[test]
    fn semantic_finished_cannot_mint_until_exact_owned_worker_join() {
        use std::{
            fs,
            os::unix::fs::PermissionsExt,
            sync::mpsc,
            time::{Duration, Instant},
        };
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root = dir.path().canonicalize().unwrap();
        let account = Uuid::new_v4().to_string();
        crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
        let profile =
            LaunchContext::capture(&root, &account, &std::env::current_exe().unwrap()).unwrap();
        let thread = json!({"id":Uuid::new_v4().to_string(),"selection":{"provider":"codex","accountID":account,"modelID":"default"},"accessMode":"approval","interactionMode":"build","items":[{"kind":"user","text":"owned prefix"}],"sessions":{"codex":{"accountID":account,"sessionID":"native-owned","seenItemCount":99999}}});
        let policy =
            Policy::parse_named(&thread, crate::composer_policy::Origin::Ordinary, None).unwrap();
        let mut registry = Registry::default();
        let authority = registry
            .prepare(&thread, profile.clone(), &root, policy.clone())
            .unwrap();
        assert!(authority.session().is_none());
        assert!(
            authority
                .acknowledge(&json!({"thread":{"id":"native-owned"}}))
                .is_err()
        );
        let ack = authority
            .acknowledge(&json!({"thread":{"id":"native-owned"},"model":"actual-model"}))
            .unwrap();
        let (release, held) = mpsc::channel();
        let session = agent::Session::fixture_worker(move |_, events| {
            events.send(agent::Event::Finished).unwrap();
            held.recv().unwrap();
        });
        assert!(matches!(
            session
                .events
                .recv_timeout(Duration::from_secs(10))
                .unwrap(),
            agent::Event::Finished
        ));
        let worker = session.worker_completion();
        registry.persisted(ack, &thread, worker.clone());
        registry.poll();
        assert!(registry.ready.is_empty());
        assert!(
            registry
                .prepare(&thread, profile.clone(), &root, policy.clone())
                .is_err()
        );
        release.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        while worker.status() == WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
        assert_eq!(worker.status(), WorkerThreadStatus::Returned);
        registry.poll();
        let resumed = registry
            .prepare(&thread, profile.clone(), &root, policy.clone())
            .unwrap();
        assert_eq!(resumed.session(), Some("native-owned"));
        assert_eq!(resumed.seen(), 1, "Never trust JSON seenItemCount");
        assert!(
            registry
                .prepare(&thread, profile.clone(), &root, policy.clone())
                .unwrap()
                .session()
                .is_none(),
            "A receipt is consumed once"
        );
        assert!(
            Registry::default()
                .prepare(&thread, profile, &root, policy)
                .unwrap()
                .session()
                .is_none(),
            "Another Engine cannot restore authority from the same JSON"
        );
    }

    #[cfg(unix)]
    #[test]
    fn mode_presence_changes_consume_receipt_even_with_identical_effective_policy() {
        use std::{
            fs,
            os::unix::fs::PermissionsExt,
            time::{Duration, Instant},
        };
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root = dir.path().canonicalize().unwrap();
        let account = Uuid::new_v4().to_string();
        crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
        let profile =
            LaunchContext::capture(&root, &account, &std::env::current_exe().unwrap()).unwrap();
        let baseline = json!({"id":Uuid::new_v4().to_string(),"selection":{"provider":"codex","accountID":account,"modelID":"default"},"accessMode":"approval","interactionMode":"build","items":[{"kind":"user","text":"preserved owned prefix","future":42}],"sessions":{"codex":{"accountID":account,"sessionID":"native-owned","seenItemCount":99999}},"future":{"preserve":true}});
        for (field, text) in [("accessMode", "approval"), ("interactionMode", "build")] {
            for (captured, current) in [
                (None, Some(Value::Null)),
                (Some(Value::Null), None),
                (None, Some(json!(text))),
                (Some(json!(text)), None),
                (Some(Value::Null), Some(json!(text))),
                (Some(json!(text)), Some(Value::Null)),
            ] {
                let mut original = baseline.clone();
                match captured {
                    Some(value) => {
                        original[field] = value;
                    }
                    None => {
                        original.as_object_mut().unwrap().remove(field);
                    }
                }
                let mut changed = original.clone();
                match current {
                    Some(value) => {
                        changed[field] = value;
                    }
                    None => {
                        changed.as_object_mut().unwrap().remove(field);
                    }
                }
                let policy =
                    Policy::parse_named(&original, crate::composer_policy::Origin::Ordinary, None)
                        .unwrap();
                let current_policy =
                    Policy::parse_named(&changed, crate::composer_policy::Origin::Ordinary, None)
                        .unwrap();
                assert_eq!(
                    policy, current_policy,
                    "This regression must change shape, not effective permissions"
                );
                let mut registry = Registry::default();
                let authority = registry
                    .prepare(&original, profile.clone(), &root, policy.clone())
                    .unwrap();
                let ack = authority
                    .acknowledge(&json!({"thread":{"id":"native-owned"},"model":"actual-model"}))
                    .unwrap();
                let worker = WorkerCompletion::observe(std::thread::spawn(|| {}));
                let deadline = Instant::now() + Duration::from_secs(10);
                while worker.status() == WorkerThreadStatus::Running {
                    assert!(Instant::now() < deadline);
                    std::thread::sleep(Duration::from_millis(2));
                }
                assert_eq!(worker.status(), WorkerThreadStatus::Returned);
                registry.persisted(ack, &original, worker.clone());
                registry.poll();
                assert_eq!(registry.ready.len(), 1);
                let before = changed.clone();
                let fresh = registry
                    .prepare(&changed, profile.clone(), &root, current_policy.clone())
                    .unwrap();
                assert!(fresh.session().is_none());
                assert_eq!(fresh.seen(), 0);
                assert_eq!(
                    changed, before,
                    "Receipt validation must not normalize stored metadata"
                );
                assert!(
                    registry.ready.is_empty(),
                    "A mismatched receipt is consumed"
                );
                assert!(
                    registry
                        .prepare(&original, profile.clone(), &root, policy.clone())
                        .unwrap()
                        .session()
                        .is_none(),
                    "Restoring an old shape cannot resurrect consumed authority"
                );
                // A presence change before the final save also prevents the
                // pending candidate from entering the ready registry at all.
                let mut pending = Registry::default();
                let authority = pending
                    .prepare(&original, profile.clone(), &root, policy)
                    .unwrap();
                let ack = authority
                    .acknowledge(&json!({"thread":{"id":"native-owned"},"model":"actual-model"}))
                    .unwrap();
                pending.persisted(ack, &changed, worker);
                pending.poll();
                assert!(pending.ready.is_empty() && pending.pending.is_empty());
                assert!(
                    pending
                        .prepare(&changed, profile.clone(), &root, current_policy)
                        .unwrap()
                        .session()
                        .is_none()
                );
            }
        }
    }

    #[test]
    fn owned_prefix_rejects_edit_and_truncation_but_replays_appended_items() {
        let mut thread = json!({"items":[{"kind":"user","text":"one","future":42},{"kind":"assistant","text":"two"}]});
        let items = Items::capture(&thread, None).unwrap();
        thread["items"]
            .as_array_mut()
            .unwrap()
            .push(json!({"kind":"notice","text":"new"}));
        assert!(items.matches(&thread));
        assert_eq!(items.count, 2);
        thread["items"][0]["future"] = json!(43);
        assert!(!items.matches(&thread));
        thread["items"] = json!([]);
        assert!(!items.matches(&thread));
        let oversized = json!({"items":[{"text":"x".repeat(MAX_PREFIX_BYTES)}]});
        assert!(Items::capture(&oversized, None).is_err());
    }
}
