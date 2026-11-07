//! Native Voice credentials have a dedicated OS secret-store purpose. No agent
//! account, environment, settings document, file fallback or vault CLI is used.
use super::transcription::Provider;
use keyring_core::{Entry, api::CredentialStoreApi};
use std::sync::Arc;
use zeroize::Zeroizing;
const SERVICE: &str = "com.apoorvdarshan.coincide.rust.voice-transcription.v1";
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    InvalidKey,
    Unavailable,
    NotFound,
    SaveUnconfirmed,
    DeleteUnconfirmed,
}
/// No Debug/Serialize or plaintext accessor outside the transcription boundary.
pub struct Credential {
    id: uuid::Uuid,
    provider: Provider,
    key: Zeroizing<String>,
}
impl Credential {
    pub fn id(&self) -> uuid::Uuid {
        self.id
    }
    pub fn provider(&self) -> Provider {
        self.provider
    }
    pub(super) fn key(&self) -> &str {
        &self.key
    }
}
pub trait Backend: Send + Sync {
    fn read(&self, provider: Provider) -> Result<Zeroizing<String>, Failure>;
    fn write(&self, provider: Provider, key: &str) -> Result<(), Failure>;
    fn delete(&self, provider: Provider) -> Result<(), Failure>;
}
struct Os;
fn entry(provider: Provider) -> Result<Entry, Failure> {
    #[cfg(target_os = "macos")]
    let store = apple_native_keyring_store::keychain::Store::new();
    #[cfg(target_os = "windows")]
    let store = windows_native_keyring_store::Store::new();
    #[cfg(target_os = "linux")]
    let store = zbus_secret_service_keyring_store::Store::new();
    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    {
        let store = store.map_err(|_| Failure::Unavailable)?;
        #[cfg(target_os = "windows")]
        let modifiers = Some(std::collections::HashMap::from([("persistence", "Local")]));
        #[cfg(not(target_os = "windows"))]
        let modifiers = None;
        store
            .build(
                SERVICE,
                match provider {
                    Provider::OpenAi => "openai",
                    Provider::Groq => "groq",
                },
                modifiers.as_ref(),
            )
            .map_err(|_| Failure::Unavailable)
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    {
        let _ = provider;
        Err(Failure::Unavailable)
    }
}
impl Backend for Os {
    fn read(&self, provider: Provider) -> Result<Zeroizing<String>, Failure> {
        let bytes = Zeroizing::new(entry(provider)?.get_secret().map_err(|error| match error {
            keyring_core::Error::NoEntry => Failure::NotFound,
            _ => Failure::Unavailable,
        })?);
        let value = std::str::from_utf8(&bytes).map_err(|_| Failure::InvalidKey)?;
        validate(value)?;
        Ok(Zeroizing::new(value.to_owned()))
    }
    fn write(&self, provider: Provider, key: &str) -> Result<(), Failure> {
        entry(provider)?
            .set_secret(key.as_bytes())
            .map_err(|_| Failure::SaveUnconfirmed)
    }
    fn delete(&self, provider: Provider) -> Result<(), Failure> {
        match entry(provider)?.delete_credential() {
            Ok(()) | Err(keyring_core::Error::NoEntry) => Ok(()),
            Err(_) => Err(Failure::DeleteUnconfirmed),
        }
    }
}
fn validate(value: &str) -> Result<(), Failure> {
    if value.is_empty() || value.len() > 4096 || !value.bytes().all(|b| b.is_ascii_graphic()) {
        Err(Failure::InvalidKey)
    } else {
        Ok(())
    }
}
/// Construction is inert. Read/Save/Delete belong exclusively to explicit
/// native actions on an owned worker, including OS unlock UI completion.
#[derive(Clone)]
pub struct VoiceSecrets {
    backend: Arc<dyn Backend>,
}
impl Default for VoiceSecrets {
    fn default() -> Self {
        Self {
            backend: Arc::new(Os),
        }
    }
}
impl VoiceSecrets {
    /// Inject a native private adapter; never expose this through JSON/control.
    pub fn with_backend(backend: Arc<dyn Backend>) -> Self {
        Self { backend }
    }
    pub fn load(&self, provider: Provider) -> Result<Arc<Credential>, Failure> {
        let key = self.backend.read(provider)?;
        validate(&key)?;
        Ok(Arc::new(Credential {
            id: uuid::Uuid::new_v4(),
            provider,
            key,
        }))
    }
    pub fn save(
        &self,
        provider: Provider,
        key: Zeroizing<String>,
    ) -> Result<Arc<Credential>, Failure> {
        validate(&key)?;
        self.backend.write(provider, &key)?;
        let confirmed = self.load(provider).map_err(|_| Failure::SaveUnconfirmed)?;
        if confirmed.key.as_str() != key.as_str() {
            return Err(Failure::SaveUnconfirmed);
        }
        Ok(confirmed)
    }
    pub fn delete(&self, provider: Provider) -> Result<(), Failure> {
        self.backend.delete(provider)
    }
}
#[cfg(test)]
mod tests {
    use super::{Backend, Failure, Provider, VoiceSecrets};
    use std::sync::{Arc, Mutex};
    use zeroize::Zeroizing;
    #[derive(Default)]
    struct Fake {
        values: Mutex<[Option<String>; 2]>,
        calls: Mutex<Vec<&'static str>>,
    }
    fn index(p: Provider) -> usize {
        if p == Provider::OpenAi { 0 } else { 1 }
    }
    impl Backend for Fake {
        fn read(&self, p: Provider) -> Result<Zeroizing<String>, Failure> {
            self.calls.lock().unwrap().push("read");
            self.values.lock().unwrap()[index(p)]
                .clone()
                .map(Zeroizing::new)
                .ok_or(Failure::NotFound)
        }
        fn write(&self, p: Provider, key: &str) -> Result<(), Failure> {
            self.calls.lock().unwrap().push("write");
            self.values.lock().unwrap()[index(p)] = Some(key.into());
            Ok(())
        }
        fn delete(&self, p: Provider) -> Result<(), Failure> {
            self.calls.lock().unwrap().push("delete");
            self.values.lock().unwrap()[index(p)] = None;
            Ok(())
        }
    }
    #[test]
    fn distinct_voice_purposes_are_inert_until_explicit_actions_and_never_cross_providers() {
        let fake = Arc::new(Fake::default());
        let store = VoiceSecrets {
            backend: fake.clone(),
        };
        assert!(fake.calls.lock().unwrap().is_empty());
        let openai = store
            .save(
                Provider::OpenAi,
                Zeroizing::new("synthetic-openai-voice-fixture".into()),
            )
            .unwrap();
        assert_eq!(openai.provider(), Provider::OpenAi);
        assert!(matches!(store.load(Provider::Groq), Err(Failure::NotFound)));
        let groq = store
            .save(
                Provider::Groq,
                Zeroizing::new("synthetic-groq-voice-fixture".into()),
            )
            .unwrap();
        assert_ne!(openai.id(), groq.id());
        store.delete(Provider::OpenAi).unwrap();
        assert!(matches!(
            store.load(Provider::OpenAi),
            Err(Failure::NotFound)
        ));
        assert!(store.load(Provider::Groq).is_ok());
        let count = fake.calls.lock().unwrap().len();
        assert!(matches!(
            store.save(Provider::Groq, Zeroizing::new("invalid\nheader".into())),
            Err(Failure::InvalidKey)
        ));
        assert_eq!(fake.calls.lock().unwrap().len(), count);
    }
}
