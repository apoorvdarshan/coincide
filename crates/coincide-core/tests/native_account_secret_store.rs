//! Explicit hosted-only OS adapter acceptance. Ordinary cargo test never opens
//! a vault; unit tests continue to use injected backends. One new UUID slot is
//! written/read/deleted, with no enumeration or existing-entry access.
use coincide_core::{
    api::Engine,
    native_file,
    provider_configuration::account_secret_store::{NativeSecretStore, SecretPurpose, SecretSlot},
    store::Store,
};
use std::{fs, io::Write, path::PathBuf};

struct Cleanup<'a> {
    store: &'a NativeSecretStore,
    slot: SecretSlot,
    complete: bool,
}
impl Drop for Cleanup<'_> {
    fn drop(&mut self) {
        if !self.complete {
            let _ = self.store.delete(&self.slot);
        }
    }
}
#[test]
#[ignore = "explicit isolated GitHub runner only; never a developer vault test"]
fn exact_owned_synthetic_entry_round_trip_and_confirmed_removal() {
    assert_eq!(std::env::var("GITHUB_ACTIONS").as_deref(), Ok("true"));
    assert_eq!(
        std::env::var("COINCIDE_NATIVE_SECRET_STORE_CI").as_deref(),
        Ok("owned-synthetic-entry-v1")
    );
    let root = PathBuf::from(
        std::env::var_os("COINCIDE_NATIVE_SECRET_STORE_FIXTURE").expect("private runner fixture"),
    );
    assert!(root.is_absolute());
    assert!(
        root.file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with("coincide-native-secret-store-")
    );
    let data = root.join("native-store");
    native_file::private_directory(&data).expect("private source directory");
    let engine = Engine::new(Store::open(&data.join("state.sqlite")).expect("synthetic Store"));
    let store = engine
        .native_account_secret_store()
        .expect("source-bound native store");
    let account = uuid::Uuid::new_v4().to_string();
    const VALUE: &str = "coincide-owned-synthetic-sdk-value";
    let plan = store
        .prepare("claude", &account, SecretPurpose::ApiKey, VALUE)
        .expect("synthetic plan");
    let receipt = plan.cleanup_receipt();
    let receipt_path = data.join("owned-synthetic-cleanup-receipt.json");
    let mut file =
        native_file::create_private_file(&receipt_path).expect("private cleanup receipt");
    serde_json::to_writer(&mut file, &receipt).expect("metadata-only receipt");
    file.flush().expect("receipt flush");
    file.sync_all()
        .expect("durable cleanup receipt before SDK write");
    drop(file);
    let mut cleanup = Cleanup {
        store: &store,
        slot: receipt.clone(),
        complete: false,
    };
    assert!(
        store
            .read_optional(&receipt)
            .expect("native absence query")
            .is_none()
    );
    let slot = store.write(&plan).expect("native SDK write");
    let value = store.read(&slot).expect("native SDK read");
    assert!(
        value.as_slice() == VALUE.as_bytes(),
        "synthetic SDK value mismatch"
    );
    drop(value);
    store.delete(&slot).expect("native SDK deletion");
    assert!(
        store
            .read_optional(&slot)
            .expect("typed post-deletion absence")
            .is_none()
    );
    cleanup.complete = true;
    fs::remove_file(&receipt_path).expect("confirmed synthetic receipt removal");
    println!("Exact synthetic OS entry written, read and removed; absence confirmed");
}
