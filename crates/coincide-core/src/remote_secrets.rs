//! Where Coincide Remote keeps its TLS identity and paired devices: the
//! operating system's secret store (Keychain, Credential Manager, Secret
//! Service), as the Mac keeps them in its login Keychain. Nothing is read until
//! Remote is turned on, so a default-off app never prompts for the store.
use anyhow::{Context, Result};
use keyring_core::{Entry, api::CredentialStoreApi};
use std::{path::Path, sync::Arc};
use zeroize::Zeroizing;

const SERVICE: &str = "com.apoorvdarshan.coincide.rust.remote.v1";

pub trait SecretBackend: Send + Sync {
    fn read(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>>;
    fn write(&self, id: &str, value: &[u8]) -> Result<()>;
    fn delete(&self, id: &str) -> Result<()>;
}

/// The OS store, scoped to one data directory so a second profile or a test
/// directory never shares (or resets) another one's certificate and devices.
pub struct OsSecrets {
    service: String,
}
impl OsSecrets {
    pub fn for_directory(directory: &Path) -> Arc<dyn SecretBackend> {
        let scope = super::crypto::sha256_hex(directory.to_string_lossy().as_bytes());
        Arc::new(Self {
            service: format!("{SERVICE}.{}", &scope[..16]),
        })
    }

    fn entry(&self, id: &str) -> Result<Entry> {
        anyhow::ensure!(
            !cfg!(test),
            "Unit tests must inject a synthetic remote secret backend"
        );
        #[cfg(target_os = "macos")]
        let store = apple_native_keyring_store::keychain::Store::new();
        #[cfg(target_os = "windows")]
        let store = windows_native_keyring_store::Store::new();
        #[cfg(target_os = "linux")]
        let store = zbus_secret_service_keyring_store::Store::new();
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
        {
            let store = store
                .map_err(|_| anyhow::anyhow!("The system secret store is unavailable or locked"))?;
            #[cfg(target_os = "windows")]
            let modifiers = Some(std::collections::HashMap::from([("persistence", "Local")]));
            #[cfg(not(target_os = "windows"))]
            let modifiers = None;
            store
                .build(&self.service, id, modifiers.as_ref())
                .map_err(|_| anyhow::anyhow!("The system secret store entry is unavailable"))
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
        {
            let _ = id;
            anyhow::bail!("No system secret store is available on this platform")
        }
    }
}
impl SecretBackend for OsSecrets {
    fn read(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        match self.entry(id)?.get_secret() {
            Ok(value) => Ok(Some(Zeroizing::new(value))),
            Err(keyring_core::Error::NoEntry) => Ok(None),
            Err(_) => anyhow::bail!("The system secret store didn’t return Coincide Remote’s data"),
        }
    }
    fn write(&self, id: &str, value: &[u8]) -> Result<()> {
        self.entry(id)?
            .set_secret(value)
            .ok()
            .context("The system secret store didn’t save Coincide Remote’s data")
    }
    fn delete(&self, id: &str) -> Result<()> {
        match self.entry(id)?.delete_credential() {
            Ok(()) | Err(keyring_core::Error::NoEntry) => Ok(()),
            Err(_) => anyhow::bail!("The system secret store didn’t remove Coincide Remote’s data"),
        }
    }
}

/// Paired devices as one secret entry, as the Mac keeps them as one Keychain item.
pub struct SecretDeviceStorage(pub Arc<dyn SecretBackend>);
impl super::pairing::DeviceStorage for SecretDeviceStorage {
    fn load(&self) -> Result<Vec<super::pairing::PairedDevice>> {
        Ok(match self.0.read("devices")? {
            Some(json) => serde_json::from_slice(&json)
                .context("Saved Remote devices are invalid and have been retained")?,
            None => Vec::new(),
        })
    }
    fn save(&self, devices: &[super::pairing::PairedDevice]) -> Result<()> {
        self.0.write("devices", &serde_json::to_vec(devices)?)
    }
}

/// An in-memory store for tests and fixtures.
#[derive(Default)]
pub struct MemorySecrets(pub std::sync::Mutex<std::collections::HashMap<String, Vec<u8>>>);
impl SecretBackend for MemorySecrets {
    fn read(&self, id: &str) -> Result<Option<Zeroizing<Vec<u8>>>> {
        Ok(self
            .0
            .lock()
            .map_err(|_| anyhow::anyhow!("poisoned"))?
            .get(id)
            .cloned()
            .map(Zeroizing::new))
    }
    fn write(&self, id: &str, value: &[u8]) -> Result<()> {
        self.0
            .lock()
            .map_err(|_| anyhow::anyhow!("poisoned"))?
            .insert(id.into(), value.to_vec());
        Ok(())
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.0
            .lock()
            .map_err(|_| anyhow::anyhow!("poisoned"))?
            .remove(id);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::pairing::DeviceStorage;
    #[test]
    fn malformed_device_credentials_are_retained_and_block_loading() {
        let secrets = Arc::new(MemorySecrets::default());
        secrets.write("devices", b"not-json").unwrap();
        assert!(SecretDeviceStorage(secrets.clone()).load().is_err());
        assert_eq!(&*secrets.read("devices").unwrap().unwrap(), b"not-json");
    }
}
