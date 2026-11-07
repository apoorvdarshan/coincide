//! Opaque runtime-only Codex API profile identity. Serialized metadata binds
//! private model/resume proofs; deserialization never constructs this grant.
use super::*;
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct NativeCodexApiContext {
    account: String,
    root: PathBuf,
    home: PathBuf,
    home_identity: crate::private_fs::Identity,
    guard_identity: crate::private_fs::Identity,
    configuration: Stamp,
}
impl NativeCodexApiContext {
    pub(crate) fn capture(root: &Path, account: &str, executable: &Path) -> Result<Self> {
        let configuration = current().context("Native Codex key scope missing")?;
        let profile = configuration
            .profile
            .as_ref()
            .context("Native Codex key profile missing")?;
        ensure!(
            profile.is_key_for("codex") && profile.account.id == account && profile.root == root,
            "Native Codex key scope belongs to another account"
        );
        profile.validate()?;
        let binary = configuration
            .record
            .executable
            .as_ref()
            .context("Native Codex executable missing")?;
        ensure!(
            executable == binary.requested || executable == binary.canonical,
            "Native Codex executable changed"
        );
        let value = Self {
            account: account.into(),
            root: root.into(),
            home: profile.account.home.clone(),
            home_identity: profile.account.home_identity,
            guard_identity: profile.account.guard_identity,
            configuration: configuration.stamp.clone(),
        };
        value.validate()?;
        Ok(value)
    }
    pub(crate) fn home(&self) -> &Path {
        &self.home
    }
    pub(crate) fn validate(&self) -> Result<()> {
        let configuration = current().context("Captured Codex API profile scope is unavailable")?;
        ensure!(
            configuration.stamp == self.configuration,
            "Codex API configuration changed; refresh this account's private proofs"
        );
        let profile = configuration
            .profile
            .as_ref()
            .context("Codex API profile is unavailable")?;
        ensure!(
            profile.is_key_for("codex")
                && profile.account.id == self.account
                && profile.root == self.root
                && profile.account.home == self.home
                && profile.account.home_identity == self.home_identity
                && profile.account.guard_identity == self.guard_identity,
            "Codex API profile belongs to another account or home"
        );
        profile.validate()
    }
}
