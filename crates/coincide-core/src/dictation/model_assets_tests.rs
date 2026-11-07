use super::{Downloader, Error, ModelId, Repository, Result, Spec, hex};
use sha2::{Digest, Sha256};
use std::{
    io::Write,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
const BODY: &[u8] = b"synthetic-model-fixture";
fn spec() -> Spec {
    Spec {
        id: ModelId::Base,
        name: "Synthetic model",
        bytes: BODY.len() as u64,
        filename: "fixture.bin",
        sha256: Box::leak(hex(&Sha256::digest(BODY)).into_boxed_str()),
    }
}
struct Fake {
    body: Vec<u8>,
    calls: Arc<AtomicUsize>,
    cancel: Option<Arc<AtomicBool>>,
}
impl Downloader for Fake {
    fn fetch(&self, _: &Spec, output: &mut dyn Write, _: &(dyn Fn() -> bool + Sync)) -> Result<()> {
        self.calls.fetch_add(1, Ordering::AcqRel);
        output.write_all(&self.body).map_err(|_| Error::Storage)?;
        if let Some(cancel) = &self.cancel {
            cancel.store(true, Ordering::Release)
        }
        Ok(())
    }
}
fn source(body: &[u8]) -> Fake {
    Fake {
        body: body.into(),
        calls: Arc::new(AtomicUsize::new(0)),
        cancel: None,
    }
}
#[test]
fn verified_download_streams_private_fixture_and_never_overwrites_existing_content() {
    let root = tempfile::tempdir().unwrap();
    let repository = Repository::open(root.path()).unwrap();
    let source = source(BODY);
    let mut progress = Vec::new();
    let model = repository
        .download_spec(spec(), &source, &|| false, &mut |written| {
            progress.push(written)
        })
        .unwrap();
    assert_eq!(progress.last().copied(), Some(BODY.len() as u64));
    assert_eq!(std::fs::read(model.path()).unwrap(), BODY);
    assert_eq!(source.calls.load(Ordering::Acquire), 1);
    assert!(matches!(
        repository.download_spec(spec(), &source, &|| false, &mut |_| {}),
        Err(Error::ExistingPreserved)
    ));
    assert_eq!(source.calls.load(Ordering::Acquire), 1);
    std::fs::write(
        repository.directory.path.join("unknown-user-file"),
        b"keep exact unknown data",
    )
    .unwrap();
    repository.remove(&model, &|| false).unwrap();
    assert!(!model.path().exists());
    assert_eq!(
        std::fs::read(repository.directory.path.join("unknown-user-file")).unwrap(),
        b"keep exact unknown data"
    );
    assert_eq!(repository.pending_recovery(), 0);
}
#[test]
fn size_hash_and_cancel_failures_never_install_or_leave_owned_staging() {
    for (body, expected) in [
        (b"short".as_slice(), Error::SizeMismatch),
        (
            b"synthetic-model-fixturX".as_slice(),
            Error::ChecksumMismatch,
        ),
        (
            b"synthetic-model-fixture-overrun".as_slice(),
            Error::SizeMismatch,
        ),
    ] {
        let root = tempfile::tempdir().unwrap();
        let repository = Repository::open(root.path()).unwrap();
        assert_eq!(
            repository
                .download_spec(spec(), &source(body), &|| false, &mut |_| {})
                .map(|_| ()),
            Err(expected)
        );
        assert!(
            std::fs::read_dir(&repository.directory.path)
                .unwrap()
                .next()
                .is_none()
        );
        assert_eq!(repository.pending_recovery(), 0);
    }
    let root = tempfile::tempdir().unwrap();
    let repository = Repository::open(root.path()).unwrap();
    let cancel = Arc::new(AtomicBool::new(false));
    let source = Fake {
        body: BODY.into(),
        calls: Arc::new(AtomicUsize::new(0)),
        cancel: Some(cancel.clone()),
    };
    assert!(matches!(
        repository.download_spec(
            spec(),
            &source,
            &|| cancel.load(Ordering::Acquire),
            &mut |_| {}
        ),
        Err(Error::Cancelled)
    ));
    assert!(
        std::fs::read_dir(&repository.directory.path)
            .unwrap()
            .next()
            .is_none()
    );
}
#[test]
fn modified_model_and_replaced_directory_are_preserved_instead_of_being_adopted() {
    let root = tempfile::tempdir().unwrap();
    let repository = Repository::open(root.path()).unwrap();
    let model = repository
        .download_spec(spec(), &source(BODY), &|| false, &mut |_| {})
        .unwrap();
    let private_replacement = vec![b'x'; BODY.len()];
    std::fs::write(model.path(), &private_replacement).unwrap();
    assert!(matches!(
        repository.remove(&model, &|| false),
        Err(Error::ChecksumMismatch)
    ));
    assert_eq!(std::fs::read(model.path()).unwrap(), private_replacement);
    assert!(model.acquire(&|| false).is_err());
    #[cfg(unix)]
    {
        let retained = root.path().join("retained-model-directory");
        std::fs::rename(&repository.directory.path, &retained).unwrap();
        crate::native_file::private_directory(&repository.directory.path).unwrap();
        let replacement = repository.directory.path.join(spec().filename);
        std::fs::write(&replacement, b"different owner directory").unwrap();
        assert!(matches!(
            repository.remove(&model, &|| false),
            Err(Error::Changed)
        ));
        assert_eq!(
            std::fs::read(replacement).unwrap(),
            b"different owner directory"
        );
        assert_eq!(
            std::fs::read(retained.join(spec().filename)).unwrap(),
            private_replacement
        );
    }
}
struct CancelOnDrop(Arc<AtomicBool>);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}
#[test]
fn removal_waits_actual_read_lease_and_cancellation_does_not_delete_the_model() {
    let root = tempfile::tempdir().unwrap();
    let repository = Repository::open(root.path()).unwrap();
    let model = repository
        .download_spec(spec(), &source(BODY), &|| false, &mut |_| {})
        .unwrap();
    // The ordinary native picker may select this same physical model. Its
    // independent lease must block catalog removal just like a catalog lease.
    let lease = super::acquire_model_path(&model.path(), &|| false).unwrap();
    assert!(lease.matches_path(&model.path()));
    let cancel = Arc::new(AtomicBool::new(false));
    std::thread::scope(|scope| {
        let _cancel = CancelOnDrop(cancel.clone());
        let worker = scope.spawn(|| repository.remove(&model, &|| cancel.load(Ordering::Acquire)));
        let deadline = Instant::now() + Duration::from_secs(5);
        while model.available_for_new_use() {
            assert!(
                !worker.is_finished(),
                "remove cannot complete while a native read lease is held"
            );
            assert!(
                Instant::now() < deadline,
                "remove did not enter its actual reader gate"
            );
            std::thread::yield_now();
        }
        assert!(!worker.is_finished());
        cancel.store(true, Ordering::Release);
        assert_eq!(worker.join().unwrap(), Err(Error::Cancelled));
    });
    assert!(model.path().exists());
    drop(lease);
    repository.remove(&model, &|| false).unwrap();
    assert!(!model.path().exists());
}

#[test]
fn unwinding_downloader_discards_only_its_private_staging_file() {
    struct PanicSource;
    impl Downloader for PanicSource {
        fn fetch(
            &self,
            _: &Spec,
            output: &mut dyn Write,
            _: &(dyn Fn() -> bool + Sync),
        ) -> Result<()> {
            output.write_all(b"partial").unwrap();
            panic!("synthetic downloader unwind");
        }
    }
    let root = tempfile::tempdir().unwrap();
    let repository = Repository::open(root.path()).unwrap();
    let unknown = repository.directory.path.join("untouched-user-file");
    std::fs::write(&unknown, b"preserve").unwrap();
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        repository.download_spec(spec(), &PanicSource, &|| false, &mut |_| {})
    }));
    assert!(result.is_err());
    assert_eq!(std::fs::read(unknown).unwrap(), b"preserve");
    assert_eq!(
        std::fs::read_dir(&repository.directory.path)
            .unwrap()
            .count(),
        1
    );
    assert_eq!(repository.pending_recovery(), 0);
}
