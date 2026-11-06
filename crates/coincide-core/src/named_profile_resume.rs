//! Owned named-profile continuation authority. Thread JSON stays descriptive;
//! only the private authenticated journal can carry joined-worker authority
//! across restart, subject to fresh runtime/catalog admission.
#[path = "named_profile_resume_journal.rs"]
mod journal;
use crate::{
    agent::{self, WorkerCompletion, WorkerThreadStatus},
    codex_login_profiles::LaunchContext,
    composer_policy::Policy,
    model_catalog::{NamedBinding, NamedCatalogFence, NamedResumeAdmission},
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
            serde_json::json!({"schema":2,"owner":self.context.owner,"context":self.context.durable()?,"native":self.native,
            "resolved":self.resolved,"items":serde_json::to_value(&self.items)?}),
        )
    }
    fn restore(value: Value, context: &Context) -> Result<Self> {
        ensure!(value["schema"] == 2, "Invalid continuation receipt schema");
        ensure!(
            value["owner"]
                .as_str()
                .is_some_and(|owner| owner != context.owner.to_string()),
            "Current Engine receipts require their exact in-memory proof"
        );
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
struct Parked {
    receipt: Receipt,
    stable: Value,
    fence: Option<NamedCatalogFence>,
}
fn slot(thread: &str, account: &str) -> Result<String> {
    Ok(format!(
        "slot-v2/{}/{}",
        Uuid::parse_str(thread)?,
        Uuid::parse_str(account)?
    ))
}
struct Pending {
    receipt: Receipt,
    worker: WorkerCompletion,
}
pub(crate) struct Registry {
    owner: Uuid,
    pending: HashMap<String, Pending>,
    ready: HashMap<String, Receipt>,
    parked: HashMap<String, Parked>,
    journal: Option<journal::Journal>,
    storage_failure: Option<&'static str>,
    last_mint_error: Option<&'static str>,
}
impl Default for Registry {
    fn default() -> Self {
        Self {
            owner: Uuid::new_v4(),
            pending: HashMap::new(),
            ready: HashMap::new(),
            parked: HashMap::new(),
            journal: None,
            storage_failure: None,
            last_mint_error: None,
        }
    }
}
impl Registry {
    pub(crate) fn for_store(store: &crate::store::Store) -> Self {
        let mut registry = match journal::Journal::open(store) {
            Ok(journal) => Self {
                journal: Some(journal),
                ..Self::default()
            },
            Err(_) => Self {
                storage_failure: Some("private_storage_unavailable"),
                ..Self::default()
            },
        };
        // Consume authenticated legacy tickets before rewriting their canonical
        // private binding slot. A crash during migration only loses an option.
        if let Some(journal) = &mut registry.journal {
            let migration = (|| -> Result<()> {
                for key in journal.keys()? {
                    if key.starts_with("slot-v2/") {
                        continue;
                    }
                    let thread = Uuid::parse_str(&key)?;
                    let Some(mut value) = journal.take(&key)? else {
                        continue;
                    };
                    ensure!(
                        value.get("schema").is_none(),
                        "Unknown legacy continuation schema"
                    );
                    let binding_thread = value["context"]["binding"]["thread"]
                        .as_str()
                        .context("Missing legacy bound thread")?;
                    let binding_account = value["context"]["binding"]["profile"]["account"]
                        .as_str()
                        .context("Missing legacy bound account")?;
                    ensure!(
                        Uuid::parse_str(binding_thread)? == thread,
                        "Legacy receipt thread mismatch"
                    );
                    let target = slot(binding_thread, binding_account)?;
                    ensure!(
                        value["context"]["selection"]["accountID"] == binding_account
                            && value["context"]["selection"]["provider"] == "codex",
                        "Legacy receipt account mismatch"
                    );
                    Uuid::parse_str(value["owner"].as_str().context("Invalid legacy owner")?)?;
                    value["schema"] = serde_json::json!(2);
                    journal.put(&target, &value)?;
                }
                Ok(())
            })();
            if migration.is_err() {
                registry.journal = None;
                registry.storage_failure = Some("private_storage_migration_failed");
            }
        }
        registry
    }
    /// Consume only the selected account's denied native context. Other parked
    /// accounts are independent capabilities and remain untouched.
    pub(crate) fn invalidate_account(
        &mut self,
        thread: &str,
        account: &str,
        store: &crate::store::Store,
    ) -> Result<()> {
        let key = slot(thread, account)?;
        self.ready.remove(&key);
        self.pending.remove(&key);
        self.parked.remove(&key);
        if self.journal.is_none() {
            self.journal = Some(journal::Journal::open(store)?);
        }
        if let Some(value) = self.journal.as_mut().unwrap().take(&key)? {
            ensure!(
                value["schema"] == 2
                    && value["context"]["binding"]["thread"]
                        .as_str()
                        .is_some_and(
                            |value| Uuid::parse_str(value).ok() == Uuid::parse_str(thread).ok()
                        )
                    && value["context"]["binding"]["profile"]["account"]
                        .as_str()
                        .is_some_and(
                            |value| Uuid::parse_str(value).ok() == Uuid::parse_str(account).ok()
                        ),
                "Invalid authenticated continuation slot binding"
            );
        }
        Ok(())
    }
    /// Deny-only return values for native Delete/Undo. Revoke every parked
    /// account, including private IDs absent from descriptive thread JSON.
    pub(crate) fn invalidate_threads(
        &mut self,
        ids: &[String],
        store: &crate::store::Store,
    ) -> Result<Vec<(String, String)>> {
        let targets = ids
            .iter()
            .map(|id| Uuid::parse_str(id))
            .collect::<std::result::Result<std::collections::HashSet<_>, _>>()?;
        let mut denied = Vec::new();
        let mut capture = |receipt: &Receipt| -> Result<()> {
            let id = Uuid::parse_str(receipt.context.binding.thread())?;
            if targets.contains(&id) {
                denied.push((id.to_string(), receipt.native.clone()));
            }
            Ok(())
        };
        for receipt in self.ready.values() {
            capture(receipt)?;
        }
        for parked in self.parked.values() {
            capture(&parked.receipt)?;
        }
        for pending in self.pending.values() {
            capture(&pending.receipt)?;
        }
        self.ready.retain(|_, r| {
            !Uuid::parse_str(r.context.binding.thread()).is_ok_and(|id| targets.contains(&id))
        });
        self.parked.retain(|_, r| {
            !Uuid::parse_str(r.receipt.context.binding.thread())
                .is_ok_and(|id| targets.contains(&id))
        });
        self.pending.retain(|_, r| {
            !Uuid::parse_str(r.receipt.context.binding.thread())
                .is_ok_and(|id| targets.contains(&id))
        });
        if self.journal.is_none() {
            self.journal = Some(journal::Journal::open(store)?);
            self.storage_failure = None;
        }
        let journal = self.journal.as_mut().unwrap();
        for key in journal.keys()? {
            let parts = key.split('/').collect::<Vec<_>>();
            ensure!(
                parts.len() == 3 && parts[0] == "slot-v2",
                "Invalid continuation slot identity"
            );
            let thread = Uuid::parse_str(parts[1])?;
            let account = Uuid::parse_str(parts[2])?;
            ensure!(
                slot(parts[1], parts[2])? == key,
                "Noncanonical continuation slot"
            );
            if !targets.contains(&thread) {
                continue;
            }
            if let Some(value) = journal.take(&key)? {
                ensure!(
                    value["schema"] == 2
                        && value["context"]["binding"]["thread"]
                            .as_str()
                            .is_some_and(|s| Uuid::parse_str(s).ok() == Some(thread))
                        && value["context"]["binding"]["profile"]["account"]
                            .as_str()
                            .is_some_and(|s| Uuid::parse_str(s).ok() == Some(account)),
                    "Invalid authenticated continuation slot binding"
                );
                let native = value["native"]
                    .as_str()
                    .context("Invalid private native ID")?;
                ensure!(
                    !native.is_empty()
                        && native.len() <= 512
                        && !native.chars().any(char::is_control),
                    "Invalid private native ID"
                );
                denied.push((thread.to_string(), native.into()));
            }
        }
        denied.sort();
        denied.dedup();
        ensure!(denied.len() <= 256, "Too many private native IDs to revoke");
        Ok(denied)
    }
    /// Static support and actual metadata readiness are distinct from minted
    /// authority. Status never writes or exposes private paths/raw errors.
    pub(crate) fn durable_status(&self) -> Value {
        let ready = self
            .journal
            .as_ref()
            .is_some_and(|journal| journal.readiness().is_ok());
        serde_json::json!({"crossRestartResumeSupported":cfg!(any(unix,windows)),
            "storageReady":ready,"storageError":if ready{None}else{self.storage_failure.or(Some("private_storage_validation_failed"))},
            "lastMintError":self.last_mint_error,
            "authority":"saved_turn_actual_join_authenticated_one_attempt",
            "requiresFreshAccountRead":true,"requiresFreshPrivateCatalogForExplicitModel":true,"requiresFreshPrivateCatalogForDefaultModel":true})
    }
    /// Deny-only queue readiness. Semantic completion cannot dispatch the next
    /// named turn before this account's exact previous owned worker joined.
    pub(crate) fn waiting_for_join(&mut self, thread: &Value) -> bool {
        self.poll();
        thread["selection"]["provider"] == "codex"
            && thread["selection"]["accountID"]
                .as_str()
                .and_then(|account| slot(thread["id"].as_str()?, account).ok())
                .is_some_and(|key| self.pending.contains_key(&key))
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
                        self.last_mint_error = Some("receipt_persistence_failed");
                        self.storage_failure = Some("private_storage_disabled_after_mint_failure");
                        self.journal = None;
                    }
                }
                self.ready.insert(id, pending.receipt);
            }
        }
    }
    /// Deny-only readiness hint for ordinary account restoration. A cached job
    /// preceding explicit departure cannot re-admit a parked completion. Active
    /// exact contexts are left alone, including pure restoreCurrent warmups.
    pub(crate) fn catalog_refresh_required(
        &self,
        binding: &NamedBinding,
        latest: &NamedCatalogFence,
    ) -> Result<bool> {
        let key = slot(binding.thread(), binding.account())?;
        Ok(self
            .parked
            .get(&key)
            .and_then(|parked| parked.fence.as_ref())
            .is_some_and(|fence| latest.is_actor(fence)))
    }
    /// Explicit departure is the only same-owner projection into a dormant
    /// capability. Capture it before cancelling the account's catalog owner.
    pub(crate) fn departure_binding(&mut self, thread: &Value) -> Result<Option<NamedBinding>> {
        self.poll();
        let Some(account) = thread["selection"]["accountID"].as_str() else {
            return Ok(None);
        };
        let key = slot(
            thread["id"].as_str().context("Missing thread identity")?,
            account,
        )?;
        ensure!(
            !self.pending.contains_key(&key),
            "Wait for the previous named worker to finish cleanup"
        );
        Ok(self.ready.get(&key).map(|r| r.context.binding.clone()))
    }
    pub(crate) fn park_departure(
        &mut self,
        thread: &Value,
        fence: Option<NamedCatalogFence>,
    ) -> Result<()> {
        let Some(account) = thread["selection"]["accountID"].as_str() else {
            return Ok(());
        };
        let key = slot(
            thread["id"].as_str().context("Missing thread identity")?,
            account,
        )?;
        self.poll();
        ensure!(
            !self.pending.contains_key(&key),
            "Wait for the previous named worker to finish cleanup"
        );
        let Some(receipt) = self.ready.remove(&key) else {
            return Ok(());
        };
        if receipt.context.owner != self.owner
            || receipt.context.selection != thread["selection"]
            || receipt.context.access.as_ref() != thread.get("accessMode")
            || receipt.context.interaction.as_ref() != thread.get("interactionMode")
            || agent::provider_session(thread, "codex").as_deref() != Some(receipt.native.as_str())
            || !receipt.items.matches(thread)
        {
            return Ok(());
        }
        // durable() validates the still-live exact proof before its deliberate
        // retirement. A revoked arbitrary refresh can never create this state.
        let Ok(stable) = receipt.context.durable() else {
            return Ok(());
        };
        self.parked.insert(
            key,
            Parked {
                receipt,
                stable,
                fence,
            },
        );
        Ok(())
    }
    #[cfg(test)]
    pub(crate) fn prepare(
        &mut self,
        thread: &Value,
        profile: LaunchContext,
        cwd: &Path,
        policy: Policy,
    ) -> Result<Authority> {
        self.prepare_admitted(thread, profile, cwd, policy, None)
    }
    pub(crate) fn prepare_admitted(
        &mut self,
        thread: &Value,
        profile: LaunchContext,
        cwd: &Path,
        policy: Policy,
        admission: Option<NamedResumeAdmission>,
    ) -> Result<Authority> {
        self.poll();
        let id = thread["id"]
            .as_str()
            .context("Missing named thread identity")?;
        let key = slot(id, profile.account())?;
        ensure!(
            !self.pending.contains_key(&key),
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
        // A cold slot can carry completed authority, including Provider default
        // selections that have no explicit model proof. Wait for current private
        // admission before consuming it; presence itself never reads/grants an
        // ID. Same-owner eviction still fails Receipt::restore after consumption.
        if !self.ready.contains_key(&key)
            && !self.parked.contains_key(&key)
            && self
                .journal
                .as_ref()
                .map(|journal| journal.has_ticket(&key))
                .transpose()?
                .unwrap_or(false)
        {
            admission
                .as_ref()
                .context("Refresh this selected account's private catalog before resuming")?
                .validate(&context.binding, &context.selection, None)?;
        }
        // A parked opportunity must wait for an ordinary fresh authenticated
        // catalog; missing readiness neither launches nor consumes its ticket.
        if let Some(parked) = self.parked.get(&key) {
            admission
                .as_ref()
                .context("Refresh this selected account's private catalog before resuming")?
                .validate(
                    &context.binding,
                    &context.selection,
                    // A changed stable context can never reuse this receipt.
                    // Require current authenticated admission, then consume it
                    // and start fresh rather than waiting on an obsolete fence.
                    if parked.stable == context.durable()? {
                        parked.fence.as_ref()
                    } else {
                        None
                    },
                )?;
        }
        let durable = match &mut self.journal {
            Some(journal) => journal.take(&key)?,
            None => None,
        };
        let active = self.ready.remove(&key);
        let parked = self.parked.remove(&key);
        let previous = if let Some(receipt) = active {
            Some(receipt).filter(|receipt| receipt.context == context)
        } else if let Some(parked) = parked {
            (parked.stable == context.durable()?).then(|| Receipt {
                context: context.clone(),
                ..parked.receipt
            })
        } else {
            durable.and_then(|value| {
                admission
                    .as_ref()?
                    .validate(&context.binding, &context.selection, None)
                    .ok()?;
                Receipt::restore(value, &context).ok()
            })
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
        let thread_id = ack.context.binding.thread().to_owned();
        let Ok(id) = slot(&thread_id, ack.context.binding.account()) else {
            return;
        };
        self.parked.remove(&id);
        self.ready.remove(&id);
        self.pending.remove(&id);
        if self.ready.len() + self.pending.len() + self.parked.len() >= MAX_RECEIPTS {
            self.parked.clear();
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
            || thread["id"] != thread_id
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
    #[cfg(any(unix, windows))]
    #[test]
    fn invalidating_one_uncertain_account_preserves_the_other_parked_private_slot() {
        use std::time::{Duration, Instant};
        let dir = tempfile::tempdir().unwrap();
        let private = dir.path().join("private");
        crate::native_file::private_directory(&private).unwrap();
        let root = private.canonicalize().unwrap();
        let mut store = crate::store::Store::open(&root.join("state.sqlite")).unwrap();
        let id = Uuid::new_v4().to_string();
        let accounts = [Uuid::new_v4().to_string(), Uuid::new_v4().to_string()];
        let mut registry = Registry::for_store(&store);
        let mut threads = Vec::new();
        let mut profiles = Vec::new();
        for (index, account) in accounts.iter().enumerate() {
            crate::codex_login_profiles::managed_home(&root, account, true).unwrap();
            let profile =
                LaunchContext::capture(&root, account, &std::env::current_exe().unwrap()).unwrap();
            let native = format!("synthetic-native-{index}");
            let thread = json!({"id":id,"selection":{"provider":"codex","modelID":"default","accountID":account},"items":[{"kind":"user","text":"synthetic prefix"}],"sessions":{"codex":{"accountID":account,"sessionID":native}}});
            let policy =
                Policy::parse_named(&thread, crate::composer_policy::Origin::Ordinary, None)
                    .unwrap();
            let ack = registry
                .prepare(&thread, profile.clone(), &root, policy)
                .unwrap()
                .acknowledge(&json!({"thread":{"id":native},"model":"synthetic-model"}))
                .unwrap();
            let worker = WorkerCompletion::observe(std::thread::spawn(|| {}));
            let deadline = Instant::now() + Duration::from_secs(5);
            while worker.status() == WorkerThreadStatus::Running {
                assert!(Instant::now() < deadline);
                std::thread::yield_now();
            }
            store.save(&thread).unwrap();
            registry.persisted(ack, &thread, worker);
            registry.poll();
            threads.push(thread);
            profiles.push(profile);
        }
        let binding = registry.departure_binding(&threads[1]).unwrap().unwrap();
        let mut catalog = crate::model_catalog::ModelCatalog::default();
        catalog.fixture_resume_job(binding.clone(), "before-departure");
        registry
            .park_departure(&threads[1], catalog.named_catalog_fence(&binding))
            .unwrap();
        registry
            .invalidate_account(&id, &accounts[0], &store)
            .unwrap();
        assert!(registry.ready.is_empty());
        assert_eq!(registry.parked.len(), 1);
        assert!(
            !registry
                .journal
                .as_ref()
                .unwrap()
                .has_ticket(&slot(&id, &accounts[0]).unwrap())
                .unwrap()
        );
        assert!(
            registry
                .journal
                .as_ref()
                .unwrap()
                .has_ticket(&slot(&id, &accounts[1]).unwrap())
                .unwrap()
        );
        catalog.fixture_resume_job(binding.clone(), "fresh-return");
        let admission = catalog
            .named_resume_admission(&threads[1], &binding)
            .unwrap();
        let policy =
            Policy::parse_named(&threads[1], crate::composer_policy::Origin::Ordinary, None)
                .unwrap();
        let resumed = registry
            .prepare_admitted(
                &threads[1],
                profiles[1].clone(),
                &root,
                policy,
                Some(admission),
            )
            .unwrap();
        assert_eq!(resumed.session(), Some("synthetic-native-1"));
        assert_eq!(resumed.seen(), 1);
    }
    #[cfg(any(unix, windows))]
    #[test]
    fn independent_account_slots_require_explicit_park_and_fresh_catalog_actor() {
        use std::{
            fs,
            time::{Duration, Instant},
        };
        let dir = tempfile::tempdir().unwrap();
        let private_root = dir.path().join("private-data");
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&private_root)
                .unwrap();
        }
        #[cfg(windows)]
        crate::private_fs::windows::create_directory(&private_root).unwrap();
        let root = private_root.canonicalize().unwrap();
        let mut store = crate::store::Store::open(&root.join("state.sqlite")).unwrap();
        let id = Uuid::new_v4().to_string();
        let accounts = [Uuid::new_v4().to_string(), Uuid::new_v4().to_string()];
        let mut registry = Registry::for_store(&store);
        let mut threads = Vec::new();
        let mut profiles = Vec::new();
        for (index, account) in accounts.iter().enumerate() {
            crate::codex_login_profiles::managed_home(&root, account, true).unwrap();
            let profile =
                LaunchContext::capture(&root, account, &std::env::current_exe().unwrap()).unwrap();
            let native = format!("private-{index}");
            let thread = json!({"id":id,"selection":{"provider":"codex","modelID":"default","accountID":account},"items":[{"kind":"user","text":"prefix"}],"sessions":{"codex":{"accountID":account,"sessionID":native}}});
            let policy =
                Policy::parse_named(&thread, crate::composer_policy::Origin::Ordinary, None)
                    .unwrap();
            let authority = registry
                .prepare(&thread, profile.clone(), &root, policy)
                .unwrap();
            let ack = authority
                .acknowledge(&json!({"thread":{"id":native},"model":"actual-model"}))
                .unwrap();
            let worker = WorkerCompletion::observe(std::thread::spawn(|| {}));
            let deadline = Instant::now() + Duration::from_secs(10);
            while worker.status() == WorkerThreadStatus::Running {
                assert!(Instant::now() < deadline);
                std::thread::yield_now();
            }
            store.save(&thread).unwrap();
            registry.persisted(ack, &thread, worker);
            registry.poll();
            threads.push(thread);
            profiles.push(profile);
        }
        assert_eq!(registry.ready.len(), 2, "B must never replace A's receipt");
        let binding = registry.departure_binding(&threads[0]).unwrap().unwrap();
        let mut catalog = crate::model_catalog::ModelCatalog::default();
        catalog.fixture_resume_job(binding.clone(), "old");
        let old = catalog
            .named_resume_admission(&threads[0], &binding)
            .unwrap();
        registry
            .park_departure(&threads[0], catalog.named_catalog_fence(&binding))
            .unwrap();
        assert!(
            registry
                .catalog_refresh_required(&binding, &catalog.named_catalog_fence(&binding).unwrap())
                .unwrap()
        );
        let policy = || {
            Policy::parse_named(&threads[0], crate::composer_policy::Origin::Ordinary, None)
                .unwrap()
        };
        assert!(
            registry
                .prepare_admitted(&threads[0], profiles[0].clone(), &root, policy(), None)
                .is_err()
        );
        assert!(
            registry
                .prepare_admitted(&threads[0], profiles[0].clone(), &root, policy(), Some(old))
                .is_err()
        );
        assert_eq!(
            registry.parked.len(),
            1,
            "not-ready admission cannot consume parked authority"
        );
        catalog.fixture_resume_job(binding.clone(), "fresh");
        let fresh = catalog
            .named_resume_admission(&threads[0], &binding)
            .unwrap();
        assert!(
            !registry
                .catalog_refresh_required(&binding, &catalog.named_catalog_fence(&binding).unwrap())
                .unwrap()
        );
        let resumed = registry
            .prepare_admitted(
                &threads[0],
                profiles[0].clone(),
                &root,
                policy(),
                Some(fresh),
            )
            .unwrap();
        assert_eq!(resumed.session(), Some("private-0"));
        assert_eq!(resumed.seen(), 1);
        assert_eq!(registry.ready.len(), 1, "A consumes only A's slot");
        assert!(
            registry
                .prepare(&threads[0], profiles[0].clone(), &root, policy())
                .unwrap()
                .session()
                .is_none()
        );
        let p = Policy::parse_named(&threads[1], crate::composer_policy::Origin::Ordinary, None)
            .unwrap();
        let resumed_b = registry
            .prepare(&threads[1], profiles[1].clone(), &root, p)
            .unwrap();
        assert_eq!(resumed_b.session(), Some("private-1"));
        let ack = resumed_b
            .acknowledge(&json!({"thread":{"id":"private-1"},"model":"actual-model"}))
            .unwrap();
        let worker = WorkerCompletion::observe(std::thread::spawn(|| {}));
        let deadline = Instant::now() + Duration::from_secs(10);
        while worker.status() == WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        store.save(&threads[1]).unwrap();
        registry.persisted(ack, &threads[1], worker);
        registry.poll();
        registry.ready.clear(); // actual resident eviction, durable ticket remains
        assert_eq!(registry.journal.as_ref().unwrap().keys().unwrap().len(), 1);
        let p = || {
            Policy::parse_named(&threads[1], crate::composer_policy::Origin::Ordinary, None)
                .unwrap()
        };
        assert!(
            registry
                .prepare(&threads[1], profiles[1].clone(), &root, p())
                .is_err(),
            "A disk ticket cannot be consumed before current admission"
        );
        let binding = NamedBinding::capture(profiles[1].clone(), &id, &root).unwrap();
        catalog.fixture_resume_job(binding.clone(), "fresh-b");
        let admission = catalog
            .named_resume_admission(&threads[1], &binding)
            .unwrap();
        let fresh = registry
            .prepare_admitted(
                &threads[1],
                profiles[1].clone(),
                &root,
                p(),
                Some(admission),
            )
            .unwrap();
        assert!(
            fresh.session().is_none(),
            "Current-owner eviction cannot regain authority from its own disk receipt"
        );
        assert_eq!(fresh.seen(), 0);
        assert!(
            registry
                .journal
                .as_ref()
                .unwrap()
                .keys()
                .unwrap()
                .is_empty()
        );
    }
    #[cfg(any(unix, windows))]
    #[test]
    fn parked_changed_context_waits_for_current_admission_then_consumes_and_starts_fresh() {
        use std::{
            fs,
            time::{Duration, Instant},
        };
        for changed in ["auth", "executable", "cwd", "mode-presence"] {
            let dir = tempfile::tempdir().unwrap();
            let private_root = dir.path().join("private-data");
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                fs::DirBuilder::new()
                    .mode(0o700)
                    .create(&private_root)
                    .unwrap();
            }
            #[cfg(windows)]
            crate::private_fs::windows::create_directory(&private_root).unwrap();
            let root = private_root.canonicalize().unwrap();
            let store = crate::store::Store::open(&root.join("state.sqlite")).unwrap();
            let account = Uuid::new_v4().to_string();
            let home = crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
            let executable = root.join("synthetic-executable");
            fs::write(&executable, b"synthetic metadata only").unwrap();
            let profile = LaunchContext::capture(&root, &account, &executable).unwrap();
            let thread = json!({"id":Uuid::new_v4().to_string(),"selection":{"provider":"codex","modelID":"default","accountID":account},"items":[{"kind":"user","text":"owned prefix"}],"sessions":{"codex":{"accountID":account,"sessionID":"old-private-native"}}});
            let policy = |thread: &Value| {
                Policy::parse_named(thread, crate::composer_policy::Origin::Ordinary, None).unwrap()
            };
            let mut registry = Registry::for_store(&store);
            let authority = registry
                .prepare(&thread, profile.clone(), &root, policy(&thread))
                .unwrap();
            let ack = authority
                .acknowledge(&json!({"thread":{"id":"old-private-native"},"model":"actual-model"}))
                .unwrap();
            let worker = WorkerCompletion::observe(std::thread::spawn(|| {}));
            let deadline = Instant::now() + Duration::from_secs(10);
            while worker.status() == WorkerThreadStatus::Running {
                assert!(Instant::now() < deadline);
                std::thread::yield_now();
            }
            registry.persisted(ack, &thread, worker);
            registry.poll();
            let binding = registry.departure_binding(&thread).unwrap().unwrap();
            let mut catalog = crate::model_catalog::ModelCatalog::default();
            catalog.fixture_resume_job(binding.clone(), "old");
            registry
                .park_departure(&thread, catalog.named_catalog_fence(&binding))
                .unwrap();
            let mut current = thread.clone();
            let mut cwd = root.clone();
            let mut selected_executable = executable;
            match changed {
                "auth" => {
                    #[cfg(windows)]
                    {
                        let mut file =
                            crate::private_fs::windows::open_file(&home.join("auth.json"), true)
                                .unwrap();
                        file.write_all(b"synthetic fixture only").unwrap();
                        file.sync_all().unwrap();
                    }
                    #[cfg(unix)]
                    fs::write(home.join("auth.json"), b"synthetic fixture only").unwrap();
                    #[cfg(unix)]
                    {
                        use std::os::unix::fs::PermissionsExt;
                        fs::set_permissions(
                            home.join("auth.json"),
                            fs::Permissions::from_mode(0o600),
                        )
                        .unwrap();
                    }
                }
                "executable" => {
                    selected_executable = root.join("different-executable");
                    fs::write(&selected_executable, b"different synthetic metadata").unwrap();
                }
                "cwd" => {
                    cwd = root.join("different-project");
                    fs::create_dir(&cwd).unwrap();
                }
                "mode-presence" => current["accessMode"] = Value::Null,
                _ => unreachable!(),
            }
            let profile = LaunchContext::capture(&root, &account, &selected_executable).unwrap();
            assert!(
                registry
                    .prepare_admitted(&current, profile.clone(), &cwd, policy(&current), None)
                    .is_err(),
                "{changed}"
            );
            assert_eq!(registry.parked.len(), 1);
            assert_eq!(
                registry.journal.as_ref().unwrap().keys().unwrap().len(),
                1,
                "Missing current admission must not consume {changed}"
            );
            let binding =
                NamedBinding::capture(profile.clone(), thread["id"].as_str().unwrap(), &cwd)
                    .unwrap();
            catalog.fixture_resume_job(binding.clone(), "current");
            let admitted = catalog.named_resume_admission(&current, &binding).unwrap();
            let fresh = registry
                .prepare_admitted(
                    &current,
                    profile.clone(),
                    &cwd,
                    policy(&current),
                    Some(admitted),
                )
                .unwrap();
            assert!(
                fresh.session().is_none(),
                "Changed {changed} must never resume old native"
            );
            assert_eq!(fresh.seen(), 0);
            assert!(registry.parked.is_empty());
            assert!(
                registry
                    .journal
                    .as_ref()
                    .unwrap()
                    .keys()
                    .unwrap()
                    .is_empty(),
                "Old ticket must be durably consumed for {changed}"
            );
            let next = registry
                .prepare(&current, profile, &cwd, policy(&current))
                .unwrap();
            assert!(
                next.session().is_none(),
                "Descriptive old sessionID cannot regain {changed} authority"
            );
        }
    }
    #[cfg(unix)]
    #[test]
    fn durable_status_validates_metadata_without_minting_or_rewriting() {
        use std::{fs, os::unix::fs::PermissionsExt};
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let store = crate::store::Store::open(&dir.path().join("data/state.sqlite")).unwrap();
        let registry = Registry::for_store(&store);
        let key = store
            .data_directory()
            .unwrap()
            .join(".state.sqlite.native-resume-v1/authority.key");
        let before = fs::read(&key).unwrap();
        let status = registry.durable_status();
        assert_eq!(status["crossRestartResumeSupported"], true);
        assert_eq!(status["storageReady"], true);
        assert!(status["lastMintError"].is_null());
        assert!(registry.ready.is_empty() && registry.pending.is_empty());
        assert_eq!(fs::read(&key).unwrap(), before);
        fs::set_permissions(&key, fs::Permissions::from_mode(0o644)).unwrap();
        let unavailable = registry.durable_status();
        assert_eq!(unavailable["storageReady"], false);
        assert_eq!(
            unavailable["storageError"],
            "private_storage_validation_failed"
        );
        assert_eq!(fs::read(&key).unwrap(), before);
        assert!(registry.ready.is_empty() && registry.pending.is_empty());
        assert!(
            !unavailable
                .to_string()
                .contains(&dir.path().display().to_string())
        );
    }
    #[cfg(unix)]
    #[test]
    fn native_deletion_revokes_saved_joined_receipt_even_after_restart() {
        use std::{
            fs,
            os::unix::fs::PermissionsExt,
            time::{Duration, Instant},
        };
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let store = crate::store::Store::open(&dir.path().join("data/state.sqlite")).unwrap();
        let root = store.data_directory().unwrap();
        let account = Uuid::new_v4().to_string();
        let id = Uuid::new_v4().to_string();
        crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
        let profile =
            LaunchContext::capture(&root, &account, &std::env::current_exe().unwrap()).unwrap();
        let thread = json!({"id":id,"selection":{"provider":"codex","accountID":account,"modelID":"default"},"accessMode":"approval","interactionMode":"build","items":[],"sessions":{"codex":{"accountID":account,"sessionID":"synthetic-deleted-native"}}});
        let policy =
            Policy::parse_named(&thread, crate::composer_policy::Origin::Ordinary, None).unwrap();
        let mut registry = Registry::for_store(&store);
        let authority = registry
            .prepare(&thread, profile.clone(), &root, policy.clone())
            .unwrap();
        let ack = authority
            .acknowledge(
                &json!({"thread":{"id":"synthetic-deleted-native"},"model":"synthetic-actual"}),
            )
            .unwrap();
        let worker = WorkerCompletion::observe(std::thread::spawn(|| {}));
        let deadline = Instant::now() + Duration::from_secs(10);
        while worker.status() == WorkerThreadStatus::Running {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(2));
        }
        registry.persisted(ack, &thread, worker);
        registry.poll();
        assert_eq!(registry.ready.len(), 1);
        registry.invalidate_threads(&[id], &store).unwrap();
        assert!(registry.ready.is_empty() && registry.pending.is_empty());
        drop(registry);
        assert!(
            Registry::for_store(&store)
                .prepare(&thread, profile, &root, policy)
                .unwrap()
                .session()
                .is_none()
        );
    }
    #[cfg(unix)]
    #[test]
    fn restart_readmission_preserves_mode_presence_and_same_engine_proof_identity() {
        use std::{fs, os::unix::fs::PermissionsExt};
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let root = dir.path().canonicalize().unwrap();
        let account = Uuid::new_v4().to_string();
        crate::codex_login_profiles::managed_home(&root, &account, true).unwrap();
        let profile =
            LaunchContext::capture(&root, &account, &std::env::current_exe().unwrap()).unwrap();
        let baseline = json!({"id":Uuid::new_v4().to_string(),"selection":{"provider":"codex","accountID":account,"modelID":"default"},"items":[{"kind":"user","text":"owned prefix","future":42}]});
        let context = |thread: &Value, owner| Context {
            owner,
            binding: NamedBinding::capture(profile.clone(), thread["id"].as_str().unwrap(), &root)
                .unwrap(),
            selection: thread["selection"].clone(),
            access: thread.get("accessMode").cloned(),
            interaction: thread.get("interactionMode").cloned(),
            policy: Policy::parse_named(thread, crate::composer_policy::Origin::Ordinary, None)
                .unwrap(),
        };
        for field in ["accessMode", "interactionMode"] {
            for saved in [
                None,
                Some(Value::Null),
                Some(json!(if field == "accessMode" {
                    "approval"
                } else {
                    "build"
                })),
            ] {
                let mut original = baseline.clone();
                if let Some(value) = &saved {
                    original[field] = value.clone();
                }
                let captured = context(&original, Uuid::new_v4());
                let receipt = Receipt {
                    context: captured.clone(),
                    native: "native-owned".into(),
                    resolved: "actual-model".into(),
                    items: Items::capture(&original, None).unwrap(),
                };
                let record = receipt.durable().unwrap();
                assert!(
                    Receipt::restore(record.clone(), &captured).is_err(),
                    "Disk cannot bypass a current Engine's Arc proof equality after memory eviction"
                );
                assert!(
                    Receipt::restore(record.clone(), &context(&original, Uuid::new_v4())).is_ok()
                );
                for current in [
                    None,
                    Some(Value::Null),
                    Some(json!(if field == "accessMode" {
                        "approval"
                    } else {
                        "build"
                    })),
                ] {
                    let mut changed = baseline.clone();
                    if let Some(value) = &current {
                        changed[field] = value.clone();
                    }
                    assert_eq!(
                        Receipt::restore(record.clone(), &context(&changed, Uuid::new_v4()))
                            .is_ok(),
                        saved == current,
                        "Presence-aware durable context must never normalize missing/null/explicit mode shapes"
                    );
                }
            }
        }
    }
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
            registry.waiting_for_join(&thread),
            "Queue must retain its pending claim until actual previous worker join"
        );
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
        assert!(!registry.waiting_for_join(&thread));
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
