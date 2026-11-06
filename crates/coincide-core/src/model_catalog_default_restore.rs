//! Authenticated read-only readiness for the actual default Codex CLI account.
//! Environment values are fingerprinted privately and never serialized or logged.
use super::*;
use std::{
    fs,
    hash::{Hash, Hasher},
    path::Path,
    time::SystemTime,
};

#[derive(Clone, Debug, PartialEq, Eq)]
struct Stamp {
    length: u64,
    modified: SystemTime,
    canonical: PathBuf,
    #[cfg(unix)]
    identity: (u64, u64),
}
impl Stamp {
    fn read(path: &Path) -> Result<Option<Self>> {
        let metadata = match fs::metadata(path) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
        };
        Ok(Some(Self {
            length: if metadata.is_dir() { 0 } else { metadata.len() },
            modified: if metadata.is_dir() {
                std::time::UNIX_EPOCH
            } else {
                metadata.modified()?
            },
            canonical: path.canonicalize()?,
            #[cfg(unix)]
            identity: {
                use std::os::unix::fs::MetadataExt;
                (metadata.dev(), metadata.ino())
            },
        }))
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct DefaultBinding {
    thread: String,
    pub(super) cwd: PathBuf,
    executable: PathBuf,
    binary: EffortExecutable,
    home: PathBuf,
    home_stamp: Option<Stamp>,
    auth: Option<Stamp>,
    config: Option<Stamp>,
    cwd_stamp: Stamp,
    environment: u64,
}
impl DefaultBinding {
    pub(crate) fn capture(thread: &str, cwd: &Path, executable: &Path) -> Result<Self> {
        ensure!(
            uuid::Uuid::parse_str(thread).is_ok(),
            "Invalid default account restore thread"
        );
        let home = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".codex")))
            .context("Default Codex home is unavailable")?;
        ensure!(
            home.is_absolute() && cwd.is_absolute() && cwd.is_dir(),
            "Default account readiness requires absolute home and project directory"
        );
        let mut fingerprint = std::collections::hash_map::DefaultHasher::new();
        for key in [
            "HOME",
            "CODEX_HOME",
            "OPENAI_API_KEY",
            "CODEX_API_KEY",
            "CODEX_ACCESS_TOKEN",
            "OPENAI_BASE_URL",
            "CHATGPT_BASE_URL",
        ] {
            key.hash(&mut fingerprint);
            std::env::var_os(key).hash(&mut fingerprint);
        }
        Ok(Self {
            thread: thread.into(),
            cwd: cwd.into(),
            executable: executable.into(),
            binary: EffortExecutable::read(executable)?,
            home_stamp: Stamp::read(&home)?,
            auth: Stamp::read(&home.join("auth.json"))?,
            config: Stamp::read(&home.join("config.toml"))?,
            cwd_stamp: Stamp::read(cwd)?.context("Project directory disappeared")?,
            home,
            environment: fingerprint.finish(),
        })
    }
    pub(crate) fn validate(&self) -> Result<()> {
        ensure!(
            Self::capture(&self.thread, &self.cwd, &self.executable)? == *self,
            "Default account authentication, executable, home or project changed"
        );
        Ok(())
    }
    pub(crate) fn thread(&self) -> &str {
        &self.thread
    }
    pub(crate) fn executable(&self) -> &Path {
        &self.executable
    }
}
impl ModelCatalog {
    pub(crate) fn ready_default_restore(&self, binding: &DefaultBinding) -> Option<Value> {
        binding.validate().ok()?;
        let job = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.jobs.get(id))
            .find(|job| job.named.is_none() && job.response["provider"] == "codex")?;
        let id = job.response["requestId"].as_str()?;
        (self.default_restore.get(id) == Some(binding)
            && job.response["state"] == "ready"
            && job.response["authenticationChecked"] == true
            && !job.cancelled.load(Ordering::Acquire))
        .then(|| job.response.clone())
    }
    pub(crate) fn refresh_default_restore(&mut self, binding: DefaultBinding) -> Result<Value> {
        binding.validate()?;
        // Never relabel a normal model-list job as an authenticated observation.
        if let Some(job) = self.jobs.values().find(|job| {
            job.named.is_none()
                && job.response["provider"] == "codex"
                && job.response["state"] == "loading"
        }) {
            ensure!(
                self.default_restore
                    .get(job.response["requestId"].as_str().unwrap_or(""))
                    == Some(&binding),
                "A different default catalog observation is still running"
            );
            return Ok(job.response.clone());
        }
        let work = binding.clone();
        let response =
            self.refresh_bound("codex", Some(binding.binary.clone()), move |cancelled| {
                discover(&work, cancelled).map_err(|error| error.to_string())
            })?;
        let id = response["requestId"]
            .as_str()
            .context("Missing default catalog request")?
            .to_owned();
        self.default_restore
            .retain(|id, _| self.jobs.contains_key(id));
        self.default_restore.insert(id, binding);
        Ok(response)
    }
    pub(crate) fn default_restore_status(
        &self,
        request: &str,
        binding: &DefaultBinding,
    ) -> Result<Value> {
        binding.validate()?;
        let job = self
            .jobs
            .get(request)
            .context("Unknown default account observation")?;
        ensure!(
            self.default_restore.get(request) == Some(binding)
                && !job.cancelled.load(Ordering::Acquire),
            "Default account observation was cancelled or changed"
        );
        let latest = self
            .order
            .iter()
            .rev()
            .filter_map(|id| self.jobs.get(id))
            .find(|job| job.named.is_none() && job.response["provider"] == "codex");
        ensure!(
            latest.is_some_and(|latest| latest.response["requestId"] == request),
            "Default account observation was superseded"
        );
        Ok(job.response.clone())
    }
}
#[cfg(unix)]
fn discover(binding: &DefaultBinding, cancelled: &AtomicBool) -> Result<Vec<Value>> {
    binding.validate()?;
    let mut rpc = ProcessRpc::spawn_in_directory(
        "codex",
        binding.executable.clone(),
        DEADLINE,
        cancelled,
        None,
        Some(&binding.cwd),
    )?;
    codex_initialize(&mut rpc)?;
    const ACCOUNT: u64 = 4_000_000_001;
    rpc.write(&json!({"id":ACCOUNT,"method":"account/read","params":{"refreshToken":false}}))?;
    let account = rpc.response(ACCOUNT)?;
    ensure!(
        matches!(
            account["account"]["type"].as_str(),
            Some("chatgpt" | "apiKey")
        ),
        "Default Codex account is not authenticated"
    );
    rpc.named_account_admitted = true;
    let models = codex_model_pages(&mut rpc)?;
    binding.validate()?;
    Ok(models)
}
#[cfg(not(unix))]
fn discover(_: &DefaultBinding, _: &AtomicBool) -> Result<Vec<Value>> {
    bail!("Default Codex readiness observations are unavailable on this platform")
}
