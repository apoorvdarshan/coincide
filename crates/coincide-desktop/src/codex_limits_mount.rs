//! No desktop worker or provider process: the core owns explicit reads, their
//! cancellation and actual join receipts through its ordinary shutdown owner.
use crate::codex_limits_view::{LimitsView, Observation, Phase, decode};
use coincide_core::api::SharedEngine;
use gpui_kit::*;
use serde_json::{Value, json};

#[derive(Default)]
struct Driver {
    current: Option<Observation>,
    closed: bool,
}
impl Driver {
    fn refresh(&mut self, mut call: impl FnMut(&str, Value) -> Result<Value, ()>) -> Phase {
        if self.closed {
            return Phase::Closing;
        }
        // Supersession clears the previous success even if dispatch is refused.
        self.current = None;
        match call("usage.codexLimits.refresh", json!({})).and_then(|value| decode(&value)) {
            Ok(observation) => {
                let phase = observation.phase.clone();
                self.current = Some(observation);
                phase
            }
            Err(()) => Phase::Failed("Codex limits refresh could not start. Refresh to try again."),
        }
    }
    fn poll(
        &mut self,
        mut call: impl FnMut(&str, Value) -> Result<Option<Value>, ()>,
    ) -> Option<Phase> {
        if self.closed {
            return None;
        }
        let current = self.current.as_ref()?;
        let result = call(
            "usage.codexLimits.status",
            json!({"requestId":current.request_id}),
        );
        let value = match result {
            Ok(None) => return None, // Busy Engine: no dispatch occurred.
            Ok(Some(value)) => value,
            Err(()) => {
                self.current = None;
                return Some(Phase::Failed(
                    "This limits observation is unavailable or its context changed. Refresh to read again.",
                ));
            }
        };
        match decode(&value) {
            Ok(next)
                if next.request_id == current.request_id
                    && next.generation == current.generation =>
            {
                if next == *current {
                    return None;
                }
                let phase = next.phase.clone();
                self.current = Some(next);
                Some(phase)
            }
            _ => {
                self.current = None;
                Some(Phase::Failed(
                    "The limits response did not match this read. Refresh to try again.",
                ))
            }
        }
    }
    fn close(&mut self) {
        self.closed = true;
        self.current = None;
    }
}
pub struct Mount {
    pub panel: Entity<LimitsView>,
    engine: SharedEngine,
    driver: Driver,
}
impl Mount {
    pub fn new(engine: SharedEngine, cx: &mut App) -> Self {
        Self {
            panel: cx.new(|_| LimitsView::default()),
            engine,
            driver: Driver::default(),
        }
    }
    pub fn refresh(&mut self, cx: &mut App) {
        let engine = &self.engine;
        let phase = self
            .driver
            .refresh(|method, params| crate::call(engine, method, params).map_err(|_| ()));
        self.panel.update(cx, |panel, cx| panel.set(phase, cx));
    }
    pub fn poll(&mut self, cx: &mut App) {
        let engine = &self.engine;
        if let Some(phase) =
            self.driver
                .poll(|method, params| match crate::call(engine, method, params) {
                    Ok(value) => Ok(Some(value)),
                    Err(error) if crate::engine_busy(&error) => Ok(None),
                    Err(_) => Err(()),
                })
        {
            self.panel.update(cx, |panel, cx| panel.set(phase, cx));
        }
    }
    pub fn request_shutdown(&mut self) {
        self.driver.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn loading(id: &str, generation: u64) -> Value {
        json!({"requestId":id,"provider":"codex","accountScope":"default_runtime_account_identity_unknown","accountIdentityVerified":false,"state":"loading","generation":generation,"observedAtEpochMs":null,"snapshot":null,"error":null})
    }
    #[::core::prelude::v1::test]
    fn refresh_is_explicit_and_status_never_issues_another_refresh() {
        let mut driver = Driver::default();
        assert!(
            driver
                .poll(|_, _| panic!("idle must not dispatch"))
                .is_none()
        );
        assert_eq!(
            driver.refresh(|method, params| {
                assert_eq!(method, "usage.codexLimits.refresh");
                assert_eq!(params, json!({}));
                Ok(loading("first", 1))
            }),
            Phase::Loading
        );
        assert!(
            driver
                .poll(|method, params| {
                    assert_eq!(method, "usage.codexLimits.status");
                    assert_eq!(params, json!({"requestId":"first"}));
                    Ok(Some(loading("first", 1)))
                })
                .is_none()
        );
    }
    #[::core::prelude::v1::test]
    fn new_failed_refresh_clears_the_previous_success_without_fallback() {
        let mut driver = Driver {
            current: Some(Observation {
                request_id: "old".into(),
                generation: 1,
                phase: Phase::Ready {
                    observed_ms: Some(1),
                    buckets: vec![],
                },
            }),
            closed: false,
        };
        assert!(matches!(driver.refresh(|_, _| Err(())), Phase::Failed(_)));
        assert!(driver.current.is_none());
        assert!(driver.poll(|_, _| panic!("must not poll old id")).is_none());
    }
    #[::core::prelude::v1::test]
    fn mismatched_late_request_or_generation_cannot_replace_the_current_read() {
        for response in [loading("old", 2), loading("new", 1)] {
            let mut driver = Driver::default();
            driver.refresh(|_, _| Ok(loading("new", 2)));
            assert!(matches!(
                driver.poll(|_, _| Ok(Some(response.clone()))),
                Some(Phase::Failed(_))
            ));
            assert!(driver.current.is_none());
        }
    }
    #[::core::prelude::v1::test]
    fn context_loss_removes_snapshot_and_busy_does_not_fabricate_completion() {
        let mut driver = Driver::default();
        driver.refresh(|_, _| Ok(loading("one", 1)));
        assert!(driver.poll(|_, _| Ok(None)).is_none());
        assert!(matches!(
            driver.current.as_ref().unwrap().phase,
            Phase::Loading
        ));
        assert!(matches!(
            driver.poll(|_, _| Err(())),
            Some(Phase::Failed(_))
        ));
        assert!(driver.current.is_none());
    }
    #[::core::prelude::v1::test]
    fn closing_discards_observation_and_forbids_status_or_refresh_dispatch() {
        let mut driver = Driver::default();
        driver.refresh(|_, _| Ok(loading("one", 1)));
        driver.close();
        assert!(driver.current.is_none());
        assert_eq!(
            driver.refresh(|_, _| panic!("closed refresh")),
            Phase::Closing
        );
        assert!(driver.poll(|_, _| panic!("closed poll")).is_none());
    }
}
