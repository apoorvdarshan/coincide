//! Native account secret operations. Constructing/rendering account metadata
//! never opens a vault. Every operation here is an explicit native action or an
//! owned launch; no JSON API exposes this module and no file fallback exists.
use super::*;
use keyring_core::{Entry, api::CredentialStoreApi};
use std::sync::Arc;
use zeroize::Zeroizing;
const SERVICE: &str = "com.apoorvdarshan.coincide.rust.provider-account.v1";
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SecretPurpose {
    ApiKey,
    AdminKey,
}
/// Signed registry metadata only; it never contains a secret value.
#[derive(Clone, Serialize, Deserialize)]
pub struct SecretSlot {
    namespace: String,
    id: String,
    provider: String,
    account: String,
    purpose: SecretPurpose,
    tag: String,
}
pub struct PreparedSecret {
    slot: SecretSlot,
    value: Zeroizing<Vec<u8>>,
}
pub(super) trait Backend: Send + Sync {
    fn write(&self, service: &str, id: &str, value: &[u8]) -> Result<()>;
    fn read(&self, service: &str, id: &str) -> Result<Zeroizing<Vec<u8>>>;
    fn delete(&self, service: &str, id: &str) -> Result<()>;
}
#[derive(Debug)]
struct MissingSecret;
impl std::fmt::Display for MissingSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("The saved account secret is missing")
    }
}
impl std::error::Error for MissingSecret {}
struct OsBackend;
fn sdk_error_category(error: &keyring_core::Error) -> &'static str {
    use keyring_core::Error;
    match error {
        Error::NoEntry => "missing-entry",
        Error::NoStorageAccess(_) => "storage-access",
        Error::PlatformFailure(_) => "platform-failure",
        Error::NoDefaultStore => "missing-default-store",
        Error::Ambiguous(_) => "ambiguous-entry",
        Error::Invalid(_, _) => "invalid-entry",
        Error::TooLong(_, _) => "entry-limit",
        Error::BadEncoding(_) | Error::BadDataFormat(_, _) | Error::BadStoreFormat(_) => {
            "invalid-data"
        }
        Error::NotSupportedByStore(_) => "unsupported-store",
        _ => "unknown-sdk-error",
    }
}
fn entry(service: &str, id: &str) -> Result<Entry> {
    // Unit tests must never unlock a developer's OS store accidentally. The
    // separately gated hosted-runner integration binary compiles the library
    // without cfg(test) and may exercise its own unique synthetic entries.
    ensure!(
        !cfg!(test),
        "Unit tests must inject a synthetic native secret backend"
    );
    // Store initialization is deliberately lazy: even a presence query must not
    // cause a Secret Service/Keychain unlock prompt.
    #[cfg(target_os = "macos")]
    let store = apple_native_keyring_store::keychain::Store::new();
    #[cfg(target_os = "windows")]
    let store = windows_native_keyring_store::Store::new();
    #[cfg(target_os = "linux")]
    let store = zbus_secret_service_keyring_store::Store::new();
    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    {
        let store = store.map_err(|_| {
            anyhow::anyhow!("The operating system secret store is unavailable or locked")
        })?;
        #[cfg(target_os = "windows")]
        let modifiers = Some(std::collections::HashMap::from([("persistence", "Local")]));
        #[cfg(not(target_os = "windows"))]
        let modifiers = None;
        store
            .build(service, id, modifiers.as_ref())
            .map_err(|_| anyhow::anyhow!("The operating system secret entry is unavailable"))
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        let _ = (service, id);
        anyhow::bail!("No native secret store is available on this platform")
    }
}
impl Backend for OsBackend {
    fn write(&self, service: &str, id: &str, value: &[u8]) -> Result<()> {
        entry(service, id)?.set_secret(value).map_err(|_| {
            anyhow::anyhow!("The operating system did not confirm saving the account secret")
        })
    }
    fn read(&self, service: &str, id: &str) -> Result<Zeroizing<Vec<u8>>> {
        match entry(service, id)?.get_secret() {
            Ok(value) => Ok(Zeroizing::new(value)),
            Err(keyring_core::Error::NoEntry) => Err(MissingSecret.into()),
            Err(error) => anyhow::bail!(
                "The saved account secret is unavailable ({}); unlock the system secret store or replace the key",
                sdk_error_category(&error)
            ),
        }
    }
    fn delete(&self, service: &str, id: &str) -> Result<()> {
        match entry(service, id)?.delete_credential() {
            Ok(()) | Err(keyring_core::Error::NoEntry) => Ok(()),
            Err(_) => anyhow::bail!(
                "Secret removal was not confirmed; retain the cleanup receipt and retry"
            ),
        }
    }
}
pub struct NativeSecretStore {
    service: String,
    namespace: String,
    key: hmac::Key,
    backend: Arc<dyn Backend>,
}
impl Engine {
    pub fn native_account_secret_store(&self) -> Result<NativeSecretStore> {
        self.require_admissions()?;
        let owner =
            Private::open(&self.store, true)?.context("Native account authority unavailable")?;
        NativeSecretStore::from_owner(&owner)
    }
}
impl NativeSecretStore {
    #[cfg(test)]
    pub(super) fn with_backend(mut self, backend: Arc<dyn Backend>) -> Self {
        self.backend = backend;
        self
    }
    pub(super) fn from_owner(owner: &Private) -> Result<Self> {
        let namespace = crate::digest_hex::lower_hex(
            hmac::sign(&owner.key, &serde_json::to_vec(&owner.source)?).as_ref(),
        );
        Ok(NativeSecretStore {
            service: format!("{SERVICE}.{namespace}"),
            namespace,
            key: owner.key.clone(),
            backend: Arc::new(OsBackend),
        })
    }
    /// Allocate a new immutable slot. The registry owner must durably retain
    /// this plan's cleanup receipt before calling write; a failed CAS must never
    /// overwrite the old account's slot.
    pub fn prepare(
        &self,
        provider: &str,
        account: &str,
        purpose: SecretPurpose,
        value: &str,
    ) -> Result<PreparedSecret> {
        provider_id(provider)?;
        ensure!(
            Uuid::parse_str(account)?.to_string() == account,
            "Invalid native account identity"
        );
        let value = value.trim();
        ensure!(
            !value.is_empty() && value.len() <= 16 * 1024 && !value.chars().any(char::is_control),
            "Enter a valid account key"
        );
        let mut slot = SecretSlot {
            namespace: self.namespace.clone(),
            id: Uuid::new_v4().to_string(),
            provider: provider.into(),
            account: account.into(),
            purpose,
            tag: String::new(),
        };
        slot.tag = self.tag(&slot, value.as_bytes())?;
        Ok(PreparedSecret {
            slot,
            value: Zeroizing::new(value.as_bytes().to_vec()),
        })
    }
    fn tag(&self, slot: &SecretSlot, value: &[u8]) -> Result<String> {
        let mut context = serde_json::to_vec(
            &json!({"namespace":slot.namespace,"id":slot.id,"provider":slot.provider,"account":slot.account,"purpose":slot.purpose}),
        )?;
        context.extend_from_slice(value);
        let tag = crate::digest_hex::lower_hex(hmac::sign(&self.key, &context).as_ref());
        zeroize::Zeroize::zeroize(&mut context);
        Ok(tag)
    }
    fn validate(&self, slot: &SecretSlot) -> Result<()> {
        ensure!(
            slot.namespace == self.namespace
                && Uuid::parse_str(&slot.id)?.to_string() == slot.id
                && slot.tag.len() == 64,
            "Account secret receipt belongs to another source"
        );
        provider_id(&slot.provider)?;
        Uuid::parse_str(&slot.account)?;
        Ok(())
    }
    pub fn write(&self, plan: &PreparedSecret) -> Result<SecretSlot> {
        self.validate(&plan.slot)?;
        ensure!(
            self.tag(&plan.slot, &plan.value)? == plan.slot.tag,
            "Native secret plan changed"
        );
        self.backend
            .write(&self.service, &plan.slot.id, &plan.value)?;
        Ok(plan.slot.clone())
    }
    pub fn read(&self, slot: &SecretSlot) -> Result<Zeroizing<Vec<u8>>> {
        self.validate(slot)?;
        let value = self.backend.read(&self.service, &slot.id)?;
        ensure!(
            value.len() <= 16 * 1024,
            "The saved account key exceeds its limit"
        );
        ensure!(
            self.tag(slot, &value)? == slot.tag,
            "The saved account secret changed; replace it before use"
        );
        Ok(value)
    }
    /// Explicit native operation, never a render-time presence query. Only the
    /// SDK's typed NoEntry maps to None; locked/unavailable/tampered stay errors.
    pub fn read_optional(&self, slot: &SecretSlot) -> Result<Option<Zeroizing<Vec<u8>>>> {
        match self.read(slot) {
            Ok(value) => Ok(Some(value)),
            Err(error) if error.is::<MissingSecret>() => Ok(None),
            Err(error) => Err(error),
        }
    }
    /// Call only after registry revocation/tombstoning. Failure leaves the
    /// receipt usable for cleanup, never a restored account execution grant.
    pub fn delete(&self, slot: &SecretSlot) -> Result<()> {
        self.validate(slot)?;
        self.backend.delete(&self.service, &slot.id)
    }
}
impl PreparedSecret {
    pub fn cleanup_receipt(&self) -> SecretSlot {
        self.slot.clone()
    }
}

impl SecretSlot {
    pub(super) fn id(&self) -> &str {
        &self.id
    }
    pub(super) fn belongs_to(&self, provider: &str, account: &str, purpose: SecretPurpose) -> bool {
        self.provider == provider && self.account == account && self.purpose == purpose
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    #[derive(Default)]
    struct Fake {
        values: Mutex<BTreeMap<(String, String), Vec<u8>>>,
        calls: AtomicUsize,
    }
    impl Backend for Fake {
        fn write(&self, service: &str, id: &str, value: &[u8]) -> Result<()> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.values
                .lock()
                .unwrap()
                .insert((service.into(), id.into()), value.into());
            Ok(())
        }
        fn read(&self, service: &str, id: &str) -> Result<Zeroizing<Vec<u8>>> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.values
                .lock()
                .unwrap()
                .get(&(service.into(), id.into()))
                .cloned()
                .map(Zeroizing::new)
                .ok_or_else(|| anyhow::Error::new(MissingSecret))
        }
        fn delete(&self, service: &str, id: &str) -> Result<()> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.values
                .lock()
                .unwrap()
                .remove(&(service.into(), id.into()));
            Ok(())
        }
    }
    #[test]
    fn immutable_slots_do_not_replace_previous_key_and_preparation_never_opens_vault() {
        let (_root, engine, _binary) = super::super::tests::fixture();
        let mut store = engine.native_account_secret_store().unwrap();
        let fake = Arc::new(Fake::default());
        store.backend = fake.clone();
        let account = Uuid::new_v4().to_string();
        let first = store
            .prepare("claude", &account, SecretPurpose::ApiKey, "synthetic-first")
            .unwrap();
        assert_eq!(fake.calls.load(Ordering::SeqCst), 0);
        let old = store.write(&first).unwrap();
        let next = store
            .prepare("claude", &account, SecretPurpose::ApiKey, "synthetic-next")
            .unwrap();
        let new = store.write(&next).unwrap();
        assert_ne!(old.id, new.id);
        assert_eq!(store.read(&old).unwrap().as_slice(), b"synthetic-first");
        store.delete(&new).unwrap();
        assert!(store.read(&new).is_err());
        assert!(store.read_optional(&new).unwrap().is_none());
        assert_eq!(store.read(&old).unwrap().as_slice(), b"synthetic-first");
    }
    #[test]
    fn foreign_source_and_modified_secret_fail_without_credential_fallback() {
        let (_root, engine, _binary) = super::super::tests::fixture();
        let (_other, other, _binary) = super::super::tests::fixture();
        let mut store = engine.native_account_secret_store().unwrap();
        let fake = Arc::new(Fake::default());
        store.backend = fake.clone();
        let plan = store
            .prepare(
                "opencode",
                &Uuid::new_v4().to_string(),
                SecretPurpose::ApiKey,
                "synthetic-original",
            )
            .unwrap();
        let slot = store.write(&plan).unwrap();
        assert!(
            other
                .native_account_secret_store()
                .unwrap()
                .read(&slot)
                .is_err()
        );
        fake.values.lock().unwrap().insert(
            (store.service.clone(), slot.id.clone()),
            b"synthetic-tampered".to_vec(),
        );
        assert!(store.read(&slot).is_err());
        assert!(store.read_optional(&slot).is_err());
        let json = serde_json::to_string(&slot).unwrap();
        assert!(!json.contains("synthetic-original"));
    }
    #[test]
    fn sdk_error_categories_never_include_platform_payload_or_secret_bytes() {
        use keyring_core::Error;
        let errors = [
            Error::PlatformFailure(std::io::Error::other("synthetic-private-payload").into()),
            Error::NoStorageAccess(std::io::Error::other("synthetic-private-payload").into()),
            Error::BadEncoding(b"synthetic-private-payload".to_vec()),
            Error::Invalid("synthetic-private-payload".into(), "private".into()),
            Error::NoEntry,
        ];
        let categories: Vec<_> = errors.iter().map(sdk_error_category).collect();
        assert_eq!(
            categories,
            [
                "platform-failure",
                "storage-access",
                "invalid-data",
                "invalid-entry",
                "missing-entry"
            ]
        );
    }
}
