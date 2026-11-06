//! Named-profile observations have their own ledger and never mint model proof.
use super::*;

#[derive(Clone, Debug, PartialEq)]
pub(crate) struct LimitsBinding {
    named: NamedBinding,
    selection: Value,
    access: Value,
    interaction: Value,
}
impl LimitsBinding {
    pub(crate) fn capture(named: NamedBinding, thread: &Value) -> Self {
        Self {
            named,
            selection: thread["selection"].clone(),
            access: thread["accessMode"].clone(),
            interaction: thread["interactionMode"].clone(),
        }
    }
}
#[derive(Default)]
pub(super) struct Owner {
    binding: Option<LimitsBinding>,
    inner: limits::Owner,
}
impl Owner {
    pub(super) fn context(&mut self, binding: Option<LimitsBinding>) -> bool {
        if self.binding == binding {
            return false;
        }
        self.binding = binding;
        self.inner.invalidate();
        true
    }
    fn refresh(&mut self, binding: LimitsBinding) -> Result<Value> {
        binding.named.validate()?;
        self.context(Some(binding.clone()));
        let named = binding.named.clone();
        let response = self.inner.refresh_with(
            Some(named.profile.executable().into()),
            move |_, cancelled| read(&named, cancelled),
        )?;
        self.scoped(response, &binding)
    }
    fn scoped(&self, mut response: Value, binding: &LimitsBinding) -> Result<Value> {
        binding.named.validate()?;
        ensure!(
            self.binding.as_ref() == Some(binding),
            "Codex limits scope changed; refresh explicitly"
        );
        response["accountScope"] = json!("named_codex_profile");
        response["accountId"] = json!(binding.named.account());
        response["threadId"] = json!(binding.named.thread());
        response["expectedSelection"] = binding.selection.clone();
        // This proves subscription authentication for this private runtime, not
        // a human identity inferred from email or local profile display names.
        response["authenticationChecked"] = json!(response["state"] == "ready");
        Ok(response)
    }
    pub(super) fn poll(&mut self) -> bool {
        let invalid = self
            .binding
            .as_ref()
            .is_some_and(|binding| binding.named.validate().is_err());
        let changed = invalid && self.context(None);
        self.inner.poll() | changed
    }
    pub(super) fn request_shutdown(&mut self) {
        self.binding = None;
        self.inner.request_shutdown();
    }
    pub(super) fn shutdown_status(&mut self) -> ShutdownStatus {
        self.poll();
        self.inner.shutdown_status()
    }
}
impl ModelCatalog {
    pub(crate) fn has_named_limits_context(&self) -> bool {
        self.named_limits.binding.is_some()
    }
    pub(crate) fn named_limits_context(&mut self, binding: Option<LimitsBinding>) -> bool {
        self.named_limits.context(binding)
    }
    pub(crate) fn refresh_named_limits(&mut self, binding: LimitsBinding) -> Result<Value> {
        ensure!(!self.shutdown.closed, "Model catalog is shutting down");
        self.poll();
        ensure!(
            self.workers.len()
                + self.limits.shutdown_status().running
                + self.named_limits.shutdown_status().running
                < MAX_ACTIVE,
            "Read-only provider workers are still draining"
        );
        self.named_limits.refresh(binding)
    }
    pub(crate) fn named_limits_status(&self, id: &str, binding: &LimitsBinding) -> Result<Value> {
        self.named_limits
            .scoped(self.named_limits.inner.status(id)?, binding)
    }
}
#[cfg(any(unix, windows))]
fn read(
    binding: &NamedBinding,
    cancelled: &AtomicBool,
) -> Result<limits::Snapshot, limits::Failure> {
    use limits::Failure;
    if cancelled.load(Ordering::Acquire) {
        return Err(Failure::Cancelled);
    }
    let work = || -> Result<Value> {
        binding.validate()?;
        let mut rpc = ProcessRpc::spawn_scoped(
            "codex",
            binding.profile.executable().into(),
            DEADLINE,
            cancelled,
            Some(binding),
        )?;
        codex_initialize(&mut rpc)?;
        const ACCOUNT: u64 = 4_000_000_001;
        rpc.write(&json!({"id":ACCOUNT,"method":"account/read","params":{"refreshToken":false}}))?;
        binding.profile.admit_account(&rpc.response(ACCOUNT)?)?;
        rpc.named_account_admitted = true;
        rpc.write(&json!({"id":2,"method":"account/rateLimits/read","params":{}}))?;
        let value = rpc.response(2)?;
        binding.validate()?;
        Ok(value)
    };
    // Keep provider messages and identity fields out of the public failure.
    let result = work().map_err(|_| Failure::ReadFailed).and_then(|value| {
        // Parsing retains only reported fields and the existing strict bounds.
        let mut snapshot = limits::parse(&value)?;
        snapshot.account_scope = "named_codex_profile".into();
        Ok(snapshot)
    });
    if cancelled.load(Ordering::Acquire) {
        Err(Failure::Cancelled)
    } else {
        result
    }
}
#[cfg(not(any(unix, windows)))]
fn read(_: &NamedBinding, _: &AtomicBool) -> Result<limits::Snapshot, limits::Failure> {
    Err(limits::Failure::UnsupportedPlatform)
}
