//! Only a confirmed name-only mutation can carry a same-row native intent
//! forward. No opaque removal plan or arbitrary credential revision is rebased.
use super::*;
struct Rename {
    provider: String,
    source: Row,
    name: String,
    baseline: String,
    epoch: u64,
}
struct Queued {
    provider: String,
    request: Request,
    generation: u64,
    _custody: NativeUiEditLease,
    ready: bool,
    expected: Option<Row>,
    baseline: String,
}
#[derive(Default)]
pub(super) struct Order {
    context: Option<String>,
    epoch: u64,
    rename: Option<Rename>,
    queued: Option<Queued>,
}
pub(super) struct Receipt<'a> {
    pub provider: &'a str,
    pub id: &'a str,
    pub source_revision: &'a str,
    pub revision: &'a str,
    pub name: &'a str,
    pub baseline: &'a str,
    pub rows: &'a [Row],
    pub generation: u64,
}
pub(super) struct Ready {
    pub provider: String,
    pub request: Request,
    pub custody: NativeUiEditLease,
}
pub(super) enum Dispatch {
    Empty,
    Stale,
    Ready(Box<Ready>),
}
impl Request {
    pub(super) fn after_name_target(&self) -> Option<(&str, &str)> {
        match self {
            Self::SaveKey { id, revision, .. }
            | Self::SaveAdmin { id, revision, .. }
            | Self::Auth { id, revision, .. }
            | Self::CodexAuth { id, revision, .. }
            | Self::Setup { id, revision }
            | Self::Check { id, revision }
            | Self::Enroll { id, revision }
            | Self::ReadAdmin { id, revision } => Some((id, revision)),
            _ => None,
        }
    }
    fn use_rename_revision(&mut self, revision: &str) -> bool {
        match self {
            Self::SaveKey {
                revision: target, ..
            }
            | Self::SaveAdmin {
                revision: target, ..
            }
            | Self::Auth {
                revision: target, ..
            }
            | Self::CodexAuth {
                revision: target, ..
            }
            | Self::Setup {
                revision: target, ..
            }
            | Self::Check {
                revision: target, ..
            }
            | Self::Enroll {
                revision: target, ..
            }
            | Self::ReadAdmin {
                revision: target, ..
            } => {
                *target = revision.into();
                true
            }
            _ => false,
        }
    }
}
impl Order {
    pub(super) fn context(&mut self, provider: Option<&str>) {
        if self.context.as_deref() != provider {
            self.context = provider.map(str::to_owned);
            self.cancel();
        }
    }
    pub(super) fn cancel(&mut self) {
        self.epoch = self.epoch.wrapping_add(1);
        self.rename = None;
        self.queued = None;
    }
    pub(super) fn cancel_provider(&mut self, provider: &str) {
        if self
            .rename
            .as_ref()
            .is_some_and(|item| item.provider == provider)
            || self
                .queued
                .as_ref()
                .is_some_and(|item| item.provider == provider)
        {
            self.cancel();
        }
    }
    pub(super) fn edited(&mut self, provider: &str) {
        if self
            .queued
            .as_ref()
            .is_some_and(|item| item.provider == provider)
        {
            self.queued = None;
        }
    }
    pub(super) fn begin(&mut self, provider: &str, source: Row, name: &str, baseline: &str) {
        self.rename = if self.context.as_deref() == Some(provider) {
            Some(Rename {
                provider: provider.into(),
                source,
                name: name.trim().into(),
                baseline: baseline.into(),
                epoch: self.epoch,
            })
        } else {
            None
        };
    }
    pub(super) fn enqueue(
        &mut self,
        provider: &str,
        request: Request,
        source: &Row,
        baseline: &str,
        generation: u64,
        custody: NativeUiEditLease,
    ) -> bool {
        let Some(rename) = &self.rename else {
            return false;
        };
        if self.queued.is_some()
            || self.context.as_deref() != Some(provider)
            || rename.provider != provider
            || rename.epoch != self.epoch
            || rename.source != *source
            || rename.baseline != baseline
            || request.after_name_target() != Some((source.id.as_str(), source.revision.as_str()))
        {
            return false;
        }
        self.queued = Some(Queued {
            provider: provider.into(),
            request,
            generation,
            _custody: custody,
            ready: false,
            expected: None,
            baseline: baseline.into(),
        });
        true
    }
    pub(super) fn finish(&mut self, receipt: Receipt<'_>) -> bool {
        let Receipt {
            provider,
            id,
            source_revision,
            revision,
            name,
            baseline,
            rows,
            generation,
        } = receipt;
        let Some(rename) = self.rename.take() else {
            return false;
        };
        let Some(mut queued) = self.queued.take() else {
            return false;
        };
        let mut expected = rename.source.clone();
        expected.native.revision = revision.into();
        expected.native.name = name.into();
        let accepted = self.context.as_deref() == Some(provider)
            && rename.epoch == self.epoch
            && rename.provider == provider
            && rename.source.id == id
            && rename.source.revision == source_revision
            && rename.name == name
            && rename.baseline == baseline
            && queued.provider == provider
            && queued.generation == generation
            && rows.iter().any(|row| *row == expected)
            && queued.request.use_rename_revision(revision);
        if accepted {
            queued.ready = true;
            queued.expected = Some(expected);
            self.queued = Some(queued);
        }
        accepted
    }
    pub(super) fn has_queued(&self) -> bool {
        self.queued.is_some()
    }
    pub(super) fn take(
        &mut self,
        provider: &str,
        rows: &[Row],
        baseline: &str,
        generation: u64,
    ) -> Dispatch {
        if !self.queued.as_ref().is_some_and(|queued| queued.ready) {
            return Dispatch::Empty;
        }
        let Some(queued) = self.queued.take() else {
            return Dispatch::Empty;
        };
        if self.context.as_deref() != Some(provider)
            || queued.provider != provider
            || queued.baseline != baseline
            || queued.generation != generation
            || !queued
                .expected
                .as_ref()
                .is_some_and(|expected| rows.contains(expected))
        {
            return Dispatch::Stale;
        }
        Dispatch::Ready(Box::new(Ready {
            provider: queued.provider,
            request: queued.request,
            custody: queued._custody,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc,
    };
    fn create(engine: &SharedEngine) -> Row {
        super::super::tests::rows(
            execute(
                engine,
                "grok",
                Request::Create {
                    login: false,
                    name: "Original".into(),
                    variable: "XAI_API_KEY".into(),
                },
                &|| true,
            )
            .unwrap(),
        )
        .remove(0)
    }
    fn baseline(engine: &SharedEngine) -> String {
        try_state(engine)
            .unwrap()
            .native_provider_configuration("grok")
            .unwrap()
            .baseline
    }
    fn custody(engine: &SharedEngine) -> NativeUiEditLease {
        try_state(engine)
            .unwrap()
            .native_ui_editors()
            .editor()
            .pending_native_action()
    }
    fn finish(order: &mut Order, outcome: &Outcome, generation: u64) -> bool {
        let Outcome::Renamed {
            snapshot,
            id,
            source_revision,
            revision,
            name,
            provider_baseline,
        } = outcome
        else {
            panic!("Expected real rename receipt")
        };
        order.finish(Receipt {
            provider: "grok",
            id,
            source_revision,
            revision,
            name,
            baseline: provider_baseline,
            rows: &snapshot.rows,
            generation,
        })
    }
    #[::core::prelude::v1::test]
    fn changed_backend_snapshot_after_receipt_denies_before_sdk_dispatch() {
        let (_root, engine) = super::super::tests::fixture();
        let row = create(&engine);
        let baseline = baseline(&engine);
        let mut order = Order::default();
        order.context(Some("grok"));
        order.begin("grok", row.clone(), "Renamed", &baseline);
        assert!(order.enqueue(
            "grok",
            Request::SaveKey {
                id: row.id.clone(),
                revision: row.revision.clone(),
                value: "synthetic-stale-key".into()
            },
            &row,
            &baseline,
            1,
            custody(&engine)
        ));
        let outcome = execute(
            &engine,
            "grok",
            Request::Rename {
                id: row.id.clone(),
                revision: row.revision.clone(),
                name: "Renamed".into(),
                login: false,
                legacy: false,
            },
            &|| true,
        )
        .unwrap();
        assert!(finish(&mut order, &outcome, 1));
        let Outcome::Renamed { revision, .. } = &outcome else {
            unreachable!()
        };
        try_state(&engine)
            .unwrap()
            .set_native_provider_account_auth("grok", &row.id, revision, "login", None)
            .unwrap();
        let current = snapshot(&engine, "grok").unwrap();
        assert!(matches!(
            order.take("grok", &current.rows, &baseline, 1),
            Dispatch::Stale
        ));
        assert!(!order.has_queued());
    }
    #[::core::prelude::v1::test]
    fn delayed_real_rename_carries_same_click_key_intent_once_after_actual_worker_return() {
        let (_root, engine) = super::super::tests::fixture();
        let row = create(&engine);
        let baseline = baseline(&engine);
        let mut order = Order::default();
        order.context(Some("grok"));
        order.begin("grok", row.clone(), "Renamed", &baseline);
        let (entered_tx, entered) = mpsc::sync_channel(1);
        let (rename_tx, rename) = mpsc::sync_channel(1);
        let (reply_tx, reply) = mpsc::sync_channel(1);
        let (exit_tx, exit) = mpsc::sync_channel(1);
        let mut workers = worker_owner::WorkerOwner::default();
        let worker_engine = engine.clone();
        let id = row.id.clone();
        let revision = row.revision.clone();
        assert!(workers.spawn(move |admission| {
            entered_tx.send(()).unwrap();
            rename.recv_timeout(Duration::from_secs(3)).unwrap();
            let result = execute(
                &worker_engine,
                "grok",
                Request::Rename {
                    id,
                    revision,
                    name: "Renamed".into(),
                    login: false,
                    legacy: false,
                },
                &|| admission.allowed(),
            );
            reply_tx.send(result).unwrap();
            exit.recv_timeout(Duration::from_secs(3)).unwrap();
        }));
        entered.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(order.enqueue(
            "grok",
            Request::SaveKey {
                id: row.id.clone(),
                revision: row.revision.clone(),
                value: "synthetic-queued-key".into()
            },
            &row,
            &baseline,
            7,
            custody(&engine)
        ));
        assert!(!workers.can_start());
        assert!(matches!(
            order.take("grok", std::slice::from_ref(&row), &baseline, 7),
            Dispatch::Empty
        ));
        rename_tx.send(()).unwrap();
        let outcome = reply.recv_timeout(Duration::from_secs(3)).unwrap().unwrap();
        assert!(finish(&mut order, &outcome, 7));
        // The reply can arrive before thread/TLS cleanup. Production flush uses
        // this actual WorkerOwner admission, not semantic rename completion.
        assert!(!workers.can_start());
        let sdk_writes = AtomicUsize::new(0);
        assert_eq!(sdk_writes.load(Ordering::SeqCst), 0);
        assert_ne!(
            try_state(&engine)
                .unwrap()
                .dispatch(json!({"method":"app.quit","params":{}}))["ok"],
            true
        );
        exit_tx.send(()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while !workers.can_start() {
            assert!(Instant::now() < deadline);
            std::thread::yield_now();
        }
        let Outcome::Renamed {
            snapshot, revision, ..
        } = &outcome
        else {
            unreachable!()
        };
        let Dispatch::Ready(ready) = order.take("grok", &snapshot.rows, &baseline, 7) else {
            panic!("Same-click request was dropped")
        };
        let Ready {
            provider,
            request,
            custody,
        } = *ready;
        assert_eq!(provider, "grok");
        // Strict injected SDK boundary: the personal OS vault is never called.
        let Request::SaveKey {
            id,
            revision: expected,
            value,
        } = request
        else {
            panic!("Another user action was substituted")
        };
        assert_eq!(id, row.id);
        assert_eq!(&expected, revision);
        assert_eq!(value, "synthetic-queued-key");
        assert_eq!(
            try_state(&engine)
                .unwrap()
                .native_provider_accounts("grok")
                .unwrap()[0]
                .revision,
            expected
        );
        sdk_writes.fetch_add(1, Ordering::SeqCst);
        drop(custody);
        assert!(matches!(
            order.take("grok", &snapshot.rows, &baseline, 7),
            Dispatch::Empty
        ));
        assert!(!finish(&mut order, &outcome, 7));
        assert_eq!(sdk_writes.load(Ordering::SeqCst), 1);
    }
    #[::core::prelude::v1::test]
    fn exact_receipt_runs_real_same_click_method_change_without_duplicate_write() {
        let (_root, engine) = super::super::tests::fixture();
        let row = create(&engine);
        let baseline = baseline(&engine);
        let before = try_state(&engine).unwrap().revision;
        let mut order = Order::default();
        order.context(Some("grok"));
        order.begin("grok", row.clone(), "Renamed", &baseline);
        assert!(order.enqueue(
            "grok",
            Request::Auth {
                id: row.id.clone(),
                revision: row.revision.clone(),
                login: true,
                variable: None
            },
            &row,
            &baseline,
            2,
            custody(&engine)
        ));
        let outcome = execute(
            &engine,
            "grok",
            Request::Rename {
                id: row.id.clone(),
                revision: row.revision.clone(),
                name: "Renamed".into(),
                login: false,
                legacy: false,
            },
            &|| true,
        )
        .unwrap();
        assert!(finish(&mut order, &outcome, 2));
        let Outcome::Renamed { snapshot, .. } = &outcome else {
            unreachable!()
        };
        let Dispatch::Ready(ready) = order.take("grok", &snapshot.rows, &baseline, 2) else {
            panic!("Method choice was lost")
        };
        let Ready {
            provider,
            request,
            custody,
        } = *ready;
        let rows =
            super::super::tests::rows(execute(&engine, &provider, request, &|| true).unwrap());
        drop(custody);
        assert!(rows[0].authentication == Auth::Login);
        assert_eq!(rows[0].name, "Renamed");
        assert_eq!(try_state(&engine).unwrap().revision, before + 2);
        assert!(matches!(
            order.take("grok", &snapshot.rows, &baseline, 2),
            Dispatch::Empty
        ));
    }
    #[::core::prelude::v1::test]
    fn changed_method_missing_row_discard_tab_and_newer_edits_deny_queued_credentials() {
        let (_root, engine) = super::super::tests::fixture();
        let row = create(&engine);
        let baseline = baseline(&engine);
        let outcome = execute(
            &engine,
            "grok",
            Request::Rename {
                id: row.id.clone(),
                revision: row.revision.clone(),
                name: "Renamed".into(),
                login: false,
                legacy: false,
            },
            &|| true,
        )
        .unwrap();
        for reason in 0..5 {
            let mut order = Order::default();
            order.context(Some("grok"));
            order.begin("grok", row.clone(), "Renamed", &baseline);
            assert!(order.enqueue(
                "grok",
                Request::SaveKey {
                    id: row.id.clone(),
                    revision: row.revision.clone(),
                    value: "synthetic-never-written".into()
                },
                &row,
                &baseline,
                3,
                custody(&engine)
            ));
            match reason {
                0 => {
                    order.cancel_provider("grok");
                }
                1 => {
                    order.context(Some("claude"));
                }
                2 => {
                    order.edited("grok");
                }
                3 => {}
                _ => {}
            }
            let Outcome::Renamed {
                snapshot,
                id,
                source_revision,
                revision,
                name,
                provider_baseline,
            } = &outcome
            else {
                unreachable!()
            };
            let mut rows = snapshot.rows.clone();
            if reason == 3 {
                rows.clear();
            }
            if reason == 4 {
                rows[0].native.authentication = Auth::Login;
            }
            assert!(!order.finish(Receipt {
                provider: "grok",
                id,
                source_revision,
                revision,
                name,
                baseline: provider_baseline,
                rows: &rows,
                generation: 3
            }));
            assert!(!order.has_queued());
            assert!(!matches!(
                order.take("grok", &rows, &baseline, 3),
                Dispatch::Ready(_)
            ));
        }
    }
}
