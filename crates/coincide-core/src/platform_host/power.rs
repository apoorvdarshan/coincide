//! Scoped idle-sleep inhibition, intentionally narrower than Swift's privileged
//! lid-close/pmset helper. A native backend owns and releases its OS assertion.
use anyhow::Result;

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct AwakePolicy {
    pub enabled: bool,
    pub sleep_on_battery: bool,
    pub on_battery: bool,
    pub active_turns: usize,
    /// Provider background commands must keep the lease after a turn finishes.
    pub background_jobs: usize,
}
impl AwakePolicy {
    pub fn needs_lease(self) -> bool {
        self.enabled
            && !(self.sleep_on_battery && self.on_battery)
            && (self.active_turns > 0 || self.background_jobs > 0)
    }
}

/// Implementations must make failed acquire/release calls retry-safe and release
/// any outstanding assertion on Drop. Never change persistent system settings.
pub trait SleepInhibitor {
    fn acquire(&mut self) -> Result<()>;
    fn release(&mut self) -> Result<()>;
}
pub struct AwakeController<B> {
    backend: B,
    held: bool,
}
impl<B: SleepInhibitor> AwakeController<B> {
    pub fn new(backend: B) -> Self {
        Self {
            backend,
            held: false,
        }
    }
    pub fn is_held(&self) -> bool {
        self.held
    }
    /// State changes only after OS acknowledgement; errors permit the next tick to retry.
    pub fn reconcile(&mut self, policy: AwakePolicy) -> Result<()> {
        let wanted = policy.needs_lease();
        if wanted != self.held {
            if wanted {
                self.backend.acquire()?;
            } else {
                self.backend.release()?;
            }
            self.held = wanted;
        }
        Ok(())
    }
    pub fn shutdown(&mut self) -> Result<()> {
        self.reconcile(AwakePolicy::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    struct Fake(Arc<Mutex<Vec<bool>>>);
    impl SleepInhibitor for Fake {
        fn acquire(&mut self) -> Result<()> {
            self.0.lock().unwrap().push(true);
            Ok(())
        }
        fn release(&mut self) -> Result<()> {
            self.0.lock().unwrap().push(false);
            Ok(())
        }
    }
    #[test]
    fn background_work_and_battery_transition() {
        let calls = Arc::new(Mutex::new(vec![]));
        let mut c = AwakeController::new(Fake(calls.clone()));
        let mut p = AwakePolicy {
            enabled: true,
            sleep_on_battery: true,
            background_jobs: 1,
            ..Default::default()
        };
        c.reconcile(p).unwrap();
        c.reconcile(p).unwrap();
        p.on_battery = true;
        c.reconcile(p).unwrap();
        p.on_battery = false;
        c.reconcile(p).unwrap();
        c.shutdown().unwrap();
        assert_eq!(*calls.lock().unwrap(), vec![true, false, true, false]);
    }
    #[test]
    fn failed_acquisition_is_not_reported_as_held() {
        struct Fails;
        impl SleepInhibitor for Fails {
            fn acquire(&mut self) -> Result<()> {
                anyhow::bail!("unavailable")
            }
            fn release(&mut self) -> Result<()> {
                unreachable!()
            }
        }
        let mut c = AwakeController::new(Fails);
        assert!(
            c.reconcile(AwakePolicy {
                enabled: true,
                active_turns: 1,
                ..Default::default()
            })
            .is_err()
        );
        assert!(!c.is_held());
    }
}
