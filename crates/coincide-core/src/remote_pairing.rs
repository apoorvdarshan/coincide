//! Pairing and authentication for the remote server, as the Mac's
//! `RemotePairing` does them.
//!
//! "Pair iPhone or iPad…" makes a one-time secret that the QR code carries. It
//! expires after `SECRET_LIFETIME`, works once, and is thrown away after
//! `MAX_FAILURES_PER_SECRET` wrong guesses. A phone that presents it gets a
//! device id and a random 256-bit token, which it keeps in its Keychain; this
//! side keeps only the token's SHA-256, in the operating system's secret store.
//!
//! Each address may fail pairing or authentication `MAX_FAILURES_PER_WINDOW`
//! times per `FAILURE_WINDOW`, and all addresses together
//! `MAX_GLOBAL_FAILURES_PER_WINDOW` times, before further attempts are refused
//! without checking.
use super::crypto;
use super::protocol::{Device, ErrorCode, RemoteError};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use uuid::Uuid;

pub const SECRET_LIFETIME: f64 = 5. * 60.;
pub const MAX_FAILURES_PER_SECRET: u32 = 5;
pub const FAILURE_WINDOW: f64 = 60.;
pub const MAX_FAILURES_PER_WINDOW: usize = 5;
pub const MAX_GLOBAL_FAILURES_PER_WINDOW: usize = 20;

/// A paired phone as this side keeps it: never the token, only its hash.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairedDevice {
    pub device: Device,
    pub token_hash: String,
}

/// Where paired devices are kept: the OS secret store in the app, memory in tests.
pub trait DeviceStorage: Send {
    fn load(&self) -> anyhow::Result<Vec<PairedDevice>>;
    fn save(&self, devices: &[PairedDevice]) -> anyhow::Result<()>;
}

#[derive(Default)]
pub struct MemoryDeviceStorage(pub std::sync::Mutex<Vec<PairedDevice>>);
impl DeviceStorage for MemoryDeviceStorage {
    fn load(&self) -> anyhow::Result<Vec<PairedDevice>> {
        Ok(self
            .0
            .lock()
            .map_err(|_| anyhow::anyhow!("poisoned"))?
            .clone())
    }
    fn save(&self, devices: &[PairedDevice]) -> anyhow::Result<()> {
        *self.0.lock().map_err(|_| anyhow::anyhow!("poisoned"))? = devices.to_vec();
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Secret {
    pub value: String,
    /// Milliseconds since 1970.
    pub expires_at: f64,
    failures: u32,
}

/// Milliseconds since 1970 on the system clock.
pub fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
        * 1000.
}

pub struct Pairing {
    storage: Box<dyn DeviceStorage>,
    now: Box<dyn Fn() -> f64 + Send>,
    secret: Option<Secret>,
    devices: Vec<PairedDevice>,
    failures: HashMap<String, Vec<f64>>,
    global_failures: Vec<f64>,
    /// Why the last save to the secret store failed, for Settings.
    pub storage_error: Option<String>,
}

fn rate_limited() -> RemoteError {
    RemoteError::new(
        ErrorCode::RateLimited,
        "Too many attempts. Wait a minute and try again.",
    )
}

impl Pairing {
    pub fn new(storage: Box<dyn DeviceStorage>) -> anyhow::Result<Self> {
        Self::with_clock(storage, Box::new(now_ms))
    }

    pub fn with_clock(
        storage: Box<dyn DeviceStorage>,
        now: Box<dyn Fn() -> f64 + Send>,
    ) -> anyhow::Result<Self> {
        let devices = storage.load()?;
        Ok(Self {
            storage,
            now,
            secret: None,
            devices,
            failures: HashMap::new(),
            global_failures: Vec::new(),
            storage_error: None,
        })
    }

    /// Newest first, as Settings lists them.
    pub fn paired_devices(&self) -> Vec<Device> {
        let mut devices = self
            .devices
            .iter()
            .map(|d| d.device.clone())
            .collect::<Vec<_>>();
        devices.sort_by(|a, b| b.paired_at.total_cmp(&a.paired_at));
        devices
    }

    /// A new one-time secret, replacing any earlier one.
    pub fn make_secret(&mut self) -> Secret {
        let secret = Secret {
            value: crypto::random_token(24),
            expires_at: (self.now)() + SECRET_LIFETIME * 1000.,
            failures: 0,
        };
        self.secret = Some(secret.clone());
        secret
    }

    pub fn cancel_secret(&mut self) {
        self.secret = None;
    }

    pub fn has_live_secret(&self) -> bool {
        self.secret
            .as_ref()
            .is_some_and(|s| s.expires_at > (self.now)())
    }

    /// Trades the secret for a device and its token. `peer` is the address, for
    /// rate limiting.
    pub fn pair(
        &mut self,
        candidate: &str,
        device_name: &str,
        peer: &str,
    ) -> Result<(Device, String), RemoteError> {
        if self.is_limited(peer) {
            return Err(rate_limited());
        }
        let now = (self.now)();
        let Some(mut current) = self.secret.clone().filter(|s| s.expires_at > now) else {
            self.secret = None;
            self.note_failure(peer);
            return Err(RemoteError::new(
                ErrorCode::PairingFailed,
                "This pairing code has expired. Show a new one on the Mac.",
            ));
        };
        if !crypto::constant_time_equals(candidate, &current.value) {
            current.failures += 1;
            self.secret = (current.failures < MAX_FAILURES_PER_SECRET).then_some(current);
            self.note_failure(peer);
            return Err(RemoteError::new(
                ErrorCode::PairingFailed,
                "The pairing code didn’t match. Show a new one on the Mac.",
            ));
        }
        // Single use.
        self.secret = None;
        let token = crypto::random_token(32);
        let name = device_name.trim();
        let device = Device {
            id: Uuid::new_v4().to_string().to_uppercase(),
            name: if name.is_empty() {
                "iPhone".into()
            } else {
                name.chars().take(80).collect()
            },
            paired_at: now,
            last_seen_at: Some(now),
        };
        self.devices.push(PairedDevice {
            device: device.clone(),
            token_hash: crypto::sha256_hex(token.as_bytes()),
        });
        self.persist();
        if self.storage_error.is_some() {
            // Never report a durable pairing when its credential was not saved.
            self.devices.retain(|saved| saved.device.id != device.id);
            return Err(RemoteError::failed(
                "Coincide couldn’t save this pairing. Unlock the system secret store and pair again.",
            ));
        }
        Ok((device, token))
    }

    /// The device the token belongs to. A success marks it as seen now.
    pub fn authenticate(
        &mut self,
        device_id: &str,
        token: &str,
        peer: &str,
    ) -> Result<Device, RemoteError> {
        if self.is_limited(peer) {
            return Err(rate_limited());
        }
        let hash = crypto::sha256_hex(token.as_bytes());
        let Some(index) = self.devices.iter().position(|d| {
            d.device.id == device_id && crypto::constant_time_equals(&d.token_hash, &hash)
        }) else {
            self.note_failure(peer);
            return Err(RemoteError::new(
                ErrorCode::Unauthorized,
                "This Mac no longer knows this device. Pair it again.",
            ));
        };
        self.devices[index].device.last_seen_at = Some((self.now)());
        self.persist();
        Ok(self.devices[index].device.clone())
    }

    pub fn is_paired(&self, device_id: &str) -> bool {
        self.devices.iter().any(|d| d.device.id == device_id)
    }

    pub fn revoke(&mut self, device_id: &str) {
        self.devices.retain(|d| d.device.id != device_id);
        self.persist();
    }

    pub fn revoke_all(&mut self) {
        self.devices.clear();
        self.persist();
    }

    fn persist(&mut self) {
        // The error says only that saving failed; never what was being saved.
        self.storage_error =
            self.storage.save(&self.devices).err().map(|_| {
                "Coincide couldn’t save paired devices to the system secret store.".into()
            });
    }

    pub fn is_limited(&mut self, peer: &str) -> bool {
        self.prune();
        self.failures.get(peer).map_or(0, Vec::len) >= MAX_FAILURES_PER_WINDOW
            || self.global_failures.len() >= MAX_GLOBAL_FAILURES_PER_WINDOW
    }

    fn note_failure(&mut self, peer: &str) {
        let now = (self.now)();
        self.failures.entry(peer.to_owned()).or_default().push(now);
        self.global_failures.push(now);
    }

    fn prune(&mut self) {
        let cutoff = (self.now)() - FAILURE_WINDOW * 1000.;
        self.global_failures.retain(|&date| date >= cutoff);
        self.failures.retain(|_, dates| {
            dates.retain(|&date| date >= cutoff);
            !dates.is_empty()
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    };

    struct Shared(Arc<std::sync::Mutex<Vec<PairedDevice>>>);
    impl DeviceStorage for Shared {
        fn load(&self) -> anyhow::Result<Vec<PairedDevice>> {
            Ok(self.0.lock().unwrap().clone())
        }
        fn save(&self, devices: &[PairedDevice]) -> anyhow::Result<()> {
            *self.0.lock().unwrap() = devices.to_vec();
            Ok(())
        }
    }

    fn pairing() -> (
        Pairing,
        Arc<AtomicU64>,
        Arc<std::sync::Mutex<Vec<PairedDevice>>>,
    ) {
        let clock = Arc::new(AtomicU64::new(1_000_000));
        let saved = Arc::new(std::sync::Mutex::new(Vec::new()));
        let now = clock.clone();
        let pairing = Pairing::with_clock(
            Box::new(Shared(saved.clone())),
            Box::new(move || now.load(Ordering::SeqCst) as f64),
        )
        .unwrap();
        (pairing, clock, saved)
    }

    #[test]
    fn a_secret_pairs_once_and_only_its_token_hash_is_kept() {
        let (mut pairing, _, saved) = pairing();
        let secret = pairing.make_secret();
        assert_eq!(secret.value.len(), 32);
        let (device, token) = pairing
            .pair(&secret.value, "  Apoorv’s iPhone ", "10.0.0.2")
            .unwrap();
        assert_eq!(device.name, "Apoorv’s iPhone");
        assert_eq!(device.id, device.id.to_uppercase());
        let stored = saved.lock().unwrap().clone();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].token_hash, crypto::sha256_hex(token.as_bytes()));
        assert!(!serde_json::to_string(&stored).unwrap().contains(&token));
        // Single use.
        let again = pairing
            .pair(&secret.value, "Other", "10.0.0.3")
            .unwrap_err();
        assert_eq!(again.code, ErrorCode::PairingFailed);
        assert_eq!(
            again.message,
            "This pairing code has expired. Show a new one on the Mac."
        );
        assert_eq!(
            pairing
                .authenticate(&device.id, &token, "10.0.0.2")
                .unwrap()
                .id,
            device.id
        );
        let wrong = pairing
            .authenticate(&device.id, "nope", "10.0.0.2")
            .unwrap_err();
        assert_eq!(wrong.code, ErrorCode::Unauthorized);
        pairing.revoke(&device.id);
        assert!(!pairing.is_paired(&device.id));
        assert!(saved.lock().unwrap().is_empty());
    }

    #[test]
    fn secrets_expire_and_die_after_five_wrong_guesses() {
        let (mut pairing, clock, _) = pairing();
        let secret = pairing.make_secret();
        for attempt in 0..MAX_FAILURES_PER_SECRET {
            let error = pairing
                .pair("wrong", "x", &format!("10.0.0.{attempt}"))
                .unwrap_err();
            assert_eq!(
                error.message,
                "The pairing code didn’t match. Show a new one on the Mac."
            );
        }
        assert!(pairing.pair(&secret.value, "x", "10.0.1.1").is_err());
        let secret = pairing.make_secret();
        clock.fetch_add((SECRET_LIFETIME * 1000.) as u64, Ordering::SeqCst);
        assert!(!pairing.has_live_secret());
        assert!(pairing.pair(&secret.value, "x", "10.0.2.1").is_err());
        assert_eq!(pairing.paired_devices().len(), 0);
        assert_eq!(
            pairing.pair("", "", "default").unwrap_err().code,
            ErrorCode::PairingFailed
        );
    }

    #[test]
    fn failures_are_rate_limited_per_address_and_globally() {
        let (mut pairing, clock, _) = pairing();
        for _ in 0..MAX_FAILURES_PER_WINDOW {
            assert_eq!(
                pairing.authenticate("D", "T", "10.0.0.9").unwrap_err().code,
                ErrorCode::Unauthorized
            );
        }
        let limited = pairing.authenticate("D", "T", "10.0.0.9").unwrap_err();
        assert_eq!(limited.code, ErrorCode::RateLimited);
        assert_eq!(
            limited.message,
            "Too many attempts. Wait a minute and try again."
        );
        // A valid secret is refused without checking while the address is limited.
        let secret = pairing.make_secret();
        assert_eq!(
            pairing
                .pair(&secret.value, "x", "10.0.0.9")
                .unwrap_err()
                .code,
            ErrorCode::RateLimited
        );
        for peer in 0..(MAX_GLOBAL_FAILURES_PER_WINDOW - MAX_FAILURES_PER_WINDOW) {
            let _ = pairing.authenticate("D", "T", &format!("10.1.0.{peer}"));
        }
        assert!(pairing.is_limited("10.2.0.1"));
        clock.fetch_add((FAILURE_WINDOW * 1000.) as u64 + 1, Ordering::SeqCst);
        assert!(!pairing.is_limited("10.0.0.9"));
        assert!(pairing.pair(&secret.value, "x", "10.0.0.9").is_ok());
    }

    #[test]
    fn names_are_defaulted_and_clipped_and_devices_sorted_newest_first() {
        let (mut pairing, clock, _) = pairing();
        let first = pairing.make_secret();
        pairing.pair(&first.value, "   ", "a").unwrap();
        clock.fetch_add(10, Ordering::SeqCst);
        let second = pairing.make_secret();
        pairing.pair(&second.value, &"n".repeat(200), "a").unwrap();
        let devices = pairing.paired_devices();
        assert_eq!(devices[0].name.chars().count(), 80);
        assert_eq!(devices[1].name, "iPhone");
        pairing.revoke_all();
        assert!(pairing.paired_devices().is_empty());
    }
    #[test]
    fn failed_secret_storage_does_not_authorize_an_ephemeral_device() {
        struct Unavailable;
        impl DeviceStorage for Unavailable {
            fn load(&self) -> anyhow::Result<Vec<PairedDevice>> {
                Ok(Vec::new())
            }
            fn save(&self, _: &[PairedDevice]) -> anyhow::Result<()> {
                anyhow::bail!("fixture")
            }
        }
        let mut pairing = Pairing::new(Box::new(Unavailable)).unwrap();
        let secret = pairing.make_secret();
        assert!(pairing.pair(&secret.value, "Fixture", "127.0.0.1").is_err());
        assert!(pairing.paired_devices().is_empty());
        assert!(pairing.storage_error.is_some());
        assert!(!pairing.has_live_secret());
    }
}
