//! ACP text-file access is anchored to an opened workspace directory. Writes
//! execute only after the adapter receives an explicit one-use approval.
use super::*;
#[cfg(unix)]
use std::fs::File;
#[cfg(unix)]
use std::os::fd::{AsRawFd, FromRawFd};
use std::path::{Component, Path};
pub(super) struct Files {
    root: PathBuf,
    #[cfg(unix)]
    directory: File,
}
impl Files {
    pub fn new(root: &Path) -> Result<Self> {
        let root = root.canonicalize()?;
        ensure!(root.is_dir(), "Antigravity workspace is not a directory");
        #[cfg(unix)]
        let directory = File::open(&root)?;
        Ok(Self {
            root,
            #[cfg(unix)]
            directory,
        })
    }
    #[cfg(unix)]
    fn parent(&self, params: &Value, create: bool) -> Result<(File, std::ffi::CString)> {
        let path = Path::new(
            params["path"]
                .as_str()
                .context("Antigravity file path is missing")?,
        );
        ensure!(path.is_absolute(), "Antigravity file path must be absolute");
        let relative = path
            .strip_prefix(&self.root)
            .context("Antigravity file path is outside the workspace")?;
        let mut parts = relative
            .components()
            .map(|part| match part {
                Component::Normal(name) => Ok(name),
                _ => bail!("Antigravity file path contains traversal"),
            })
            .collect::<Result<Vec<_>>>()?;
        let last = parts
            .pop()
            .context("Antigravity file path is the workspace itself")?;
        use std::os::unix::ffi::OsStrExt;
        let filename = std::ffi::CString::new(last.as_bytes())?;
        let mut directory = self.directory.try_clone()?;
        for part in parts {
            let name = std::ffi::CString::new(part.as_bytes())?;
            let mut fd = unsafe {
                libc::openat(
                    directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0
                && create
                && std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound
            {
                ensure!(
                    unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o755) } == 0,
                    "Unable to create Antigravity workspace directory"
                );
                fd = unsafe {
                    libc::openat(
                        directory.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    )
                };
            }
            ensure!(
                fd >= 0,
                "Antigravity workspace path is missing or traverses a symbolic link"
            );
            directory = unsafe { File::from_raw_fd(fd) };
        }
        Ok((directory, filename))
    }
    pub fn read(&self, params: &Value) -> Result<Value> {
        #[cfg(not(unix))]
        {
            let _ = params;
            bail!("Antigravity filesystem callbacks are unavailable on this platform");
        }
        #[cfg(unix)]
        {
            let (directory, name) = self.parent(params, false)?;
            let fd = unsafe {
                libc::openat(
                    directory.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
                )
            };
            ensure!(fd >= 0, "Antigravity workspace file could not be opened");
            let file = unsafe { File::from_raw_fd(fd) };
            ensure!(
                file.metadata()?.is_file() && file.metadata()?.len() <= 8 * 1024 * 1024,
                "Antigravity workspace file is not bounded text"
            );
            let mut text = String::new();
            file.take(8 * 1024 * 1024 + 1).read_to_string(&mut text)?;
            ensure!(
                text.len() <= 8 * 1024 * 1024,
                "Antigravity workspace file grew beyond 8 MiB"
            );
            if params.get("line").is_none() && params.get("limit").is_none() {
                return Ok(json!({"content":text}));
            }
            let lines = text.split('\n').collect::<Vec<_>>();
            let start = params["line"]
                .as_i64()
                .unwrap_or(1)
                .saturating_sub(1)
                .max(0) as usize;
            let start = start.min(lines.len());
            let limit = params["limit"].as_i64().unwrap_or(i64::MAX).max(0) as usize;
            Ok(
                json!({"content":lines[start..start.saturating_add(limit).min(lines.len())].join("\n")}),
            )
        }
    }
    pub fn validate_write(&self, params: &Value) -> Result<()> {
        let text = params["content"]
            .as_str()
            .context("Antigravity file content missing")?;
        ensure!(
            text.len() <= 8 * 1024 * 1024,
            "Antigravity file write exceeds 8 MiB"
        );
        let path = Path::new(
            params["path"]
                .as_str()
                .context("Antigravity file path missing")?,
        );
        ensure!(
            path.starts_with(&self.root)
                && path
                    .components()
                    .all(|c| !matches!(c, Component::ParentDir)),
            "Antigravity file write is outside the workspace"
        );
        Ok(())
    }
    pub fn write(&self, params: &Value) -> Result<Value> {
        self.validate_write(params)?;
        #[cfg(not(unix))]
        {
            bail!("Antigravity filesystem callbacks are unavailable on this platform");
        }
        #[cfg(unix)]
        {
            let (directory, name) = self.parent(params, true)?;
            let mut metadata = std::mem::MaybeUninit::<libc::stat>::uninit();
            let status = unsafe {
                libc::fstatat(
                    directory.as_raw_fd(),
                    name.as_ptr(),
                    metadata.as_mut_ptr(),
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            };
            let mode = if status == 0 {
                let metadata = unsafe { metadata.assume_init() };
                ensure!(
                    metadata.st_mode & libc::S_IFMT == libc::S_IFREG,
                    "Antigravity destination is not a regular file"
                );
                metadata.st_mode & 0o777
            } else {
                ensure!(
                    std::io::Error::last_os_error().kind() == std::io::ErrorKind::NotFound,
                    "Unable to inspect Antigravity destination permissions"
                );
                // New files start private; never override a restrictive user umask.
                0o600
            };
            let temporary =
                std::ffi::CString::new(format!(".coincide-write-{}", uuid::Uuid::new_v4()))?;
            let fd = unsafe {
                libc::openat(
                    directory.as_raw_fd(),
                    temporary.as_ptr(),
                    libc::O_WRONLY
                        | libc::O_CREAT
                        | libc::O_EXCL
                        | libc::O_CLOEXEC
                        | libc::O_NOFOLLOW,
                    0o600,
                )
            };
            ensure!(fd >= 0, "Unable to stage Antigravity file write");
            let mut file = unsafe { File::from_raw_fd(fd) };
            let result = (|| -> Result<()> {
                file.write_all(params["content"].as_str().unwrap().as_bytes())?;
                ensure!(
                    unsafe { libc::fchmod(file.as_raw_fd(), mode) } == 0,
                    "Unable to preserve Antigravity destination permissions"
                );
                file.sync_all()?;
                ensure!(
                    unsafe {
                        libc::renameat(
                            directory.as_raw_fd(),
                            temporary.as_ptr(),
                            directory.as_raw_fd(),
                            name.as_ptr(),
                        )
                    } == 0,
                    "Unable to save Antigravity workspace file"
                );
                Ok(())
            })();
            if result.is_err() {
                unsafe { libc::unlinkat(directory.as_raw_fd(), temporary.as_ptr(), 0) };
            }
            result?;
            Ok(json!({}))
        }
    }
}
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    #[test]
    fn atomic_writes_preserve_private_and_executable_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let files = Files::new(&root).unwrap();
        for mode in [0o600, 0o640, 0o755] {
            let path = root.join(format!("mode-{mode:o}"));
            std::fs::write(&path, "before").unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(mode)).unwrap();
            files
                .write(&json!({"path":path,"content":"after"}))
                .unwrap();
            assert_eq!(std::fs::read_to_string(&path).unwrap(), "after");
            assert_eq!(
                std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                mode
            );
        }
        let new_file = root.join("new-private");
        files
            .write(&json!({"path":new_file,"content":"new"}))
            .unwrap();
        assert_eq!(
            std::fs::metadata(new_file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let target = root.join("original");
        std::fs::write(&target, "preserve").unwrap();
        let link = root.join("link");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(
            files
                .write(&json!({"path":link,"content":"replace"}))
                .is_err()
        );
        assert_eq!(std::fs::read_to_string(target).unwrap(), "preserve");
    }
    #[test]
    fn workspace_reads_and_atomic_writes_cannot_follow_links() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("workspace");
        std::fs::create_dir(&root).unwrap();
        let files = Files::new(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let outside = dir.path().join("outside");
        std::fs::write(&outside, "preserve").unwrap();
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        assert!(files.read(&json!({"path":root.join("link")})).is_err());
        std::os::unix::fs::symlink(dir.path(), root.join("escape")).unwrap();
        assert!(
            files
                .write(&json!({"path":root.join("escape/outside"),"content":"overwrite"}))
                .is_err()
        );
        files
            .write(&json!({"path":root.join("new/file"),"content":"first\nsecond\nthird"}))
            .unwrap();
        assert_eq!(
            files
                .read(&json!({"path":root.join("new/file"),"line":2,"limit":1}))
                .unwrap()["content"],
            "second"
        );
        assert_eq!(std::fs::read_to_string(outside).unwrap(), "preserve");
    }
}
