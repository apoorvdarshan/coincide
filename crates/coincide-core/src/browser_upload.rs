//! Bounded explicit local-file attachment. Paths are never included in page data.
#[cfg(windows)]
#[path = "browser_upload_windows.rs"]
mod windows;
#[cfg(any(windows, test))]
#[path = "browser_upload_windows_path.rs"]
mod windows_path;
use anyhow::{Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Serialize;
#[cfg(not(windows))]
use std::fs;
use std::{
    io::Read,
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

// Enabled after the six owned Windows SDK filesystem tests (junction and file
// symlink refusal, rename denial, held documents, cancellation, limits) passed on
// a fresh GitHub-hosted runner; Core (windows-latest) reruns them on every change.
// Set false to fail closed again before any path is opened.
const WINDOWS_UPLOAD_SDK_VALIDATED: bool = true;
pub fn available() -> bool {
    !cfg!(windows) || WINDOWS_UPLOAD_SDK_VALIDATED
}
const MAX_FILES: usize = 8;
const MAX_BYTES: u64 = 4 * 1024 * 1024;

pub(super) fn validate_paths(paths: &[String]) -> Result<()> {
    ensure!(
        (1..=MAX_FILES).contains(&paths.len()),
        "Upload requires 1–8 files"
    );
    for path in paths {
        ensure!(
            path.len() <= 4096 && !path.contains('\0') && Path::new(path).is_absolute(),
            "Upload paths must be absolute and at most 4096 bytes"
        );
        ensure!(
            !Path::new(path)
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir)),
            "Upload paths cannot contain parent traversal"
        );
    }
    Ok(())
}

#[derive(Serialize)]
pub struct UploadFile {
    name: String,
    mime: &'static str,
    data: String,
}

pub(super) fn prepare(paths: &[String]) -> Result<Vec<UploadFile>> {
    prepare_controlled(paths, &UploadWork::new(Duration::from_secs(10)))
}

pub fn prepare_controlled(paths: &[String], work: &UploadWork) -> Result<Vec<UploadFile>> {
    ensure!(
        available(),
        "Windows uploads await native filesystem SDK acceptance; local-drive-only attachment is not enabled"
    );
    prepare_admitted(paths, work)
}

fn prepare_admitted(paths: &[String], work: &UploadWork) -> Result<Vec<UploadFile>> {
    validate_paths(paths)?;
    work.check()?;
    let mut remaining = MAX_BYTES;
    let mut result = Vec::with_capacity(paths.len());
    for path in paths {
        work.check()?;
        let path = Path::new(path);
        #[cfg(windows)]
        let mut retained = windows::RetainedFile::open(path, work)?;
        #[cfg(windows)]
        let file = &mut retained.file;
        #[cfg(not(windows))]
        let mut file = {
            // Reject the final symlink and special files before opening. On Unix,
            // NOFOLLOW closes the final-component race and NONBLOCK avoids a FIFO
            // swapped in after this check. The opened descriptor is checked again.
            let metadata = fs::symlink_metadata(path)?;
            ensure!(
                metadata.is_file(),
                "Upload requires regular files, not symlinks or directories"
            );
            let mut options = fs::OpenOptions::new();
            options.read(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
            }
            options.open(path)?
        };
        work.check()?;
        let metadata = file.metadata()?;
        ensure!(metadata.is_file(), "Upload requires regular files");
        ensure!(
            metadata.len() <= remaining,
            "Upload exceeds the 4 MiB combined limit"
        );
        #[cfg(windows)]
        let bytes = read_bounded(file, remaining, work)?;
        #[cfg(not(windows))]
        let bytes = read_bounded(&mut file, remaining, work)?;
        remaining -= bytes.len() as u64;
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| anyhow::anyhow!("Upload filename must be UTF-8"))?;
        ensure!(
            !name.is_empty() && name.len() <= 255 && !name.chars().any(char::is_control),
            "Invalid upload filename"
        );
        let mime = match path
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("")
            .to_ascii_lowercase()
            .as_str()
        {
            "txt" => "text/plain",
            "csv" => "text/csv",
            "json" => "application/json",
            "pdf" => "application/pdf",
            "png" => "image/png",
            "jpg" | "jpeg" => "image/jpeg",
            "gif" => "image/gif",
            "webp" => "image/webp",
            _ => "application/octet-stream",
        };
        result.push(UploadFile {
            name: name.to_owned(),
            mime,
            data: STANDARD.encode(bytes),
        });
    }
    Ok(result)
}

fn read_bounded(reader: &mut impl Read, remaining: u64, work: &UploadWork) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 65536];
    loop {
        work.check()?;
        let limit = chunk
            .len()
            .min((remaining + 1 - bytes.len() as u64) as usize);
        if limit == 0 {
            break;
        }
        let count = reader.read(&mut chunk[..limit])?;
        if count == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..count]);
    }
    work.check()?;
    ensure!(
        bytes.len() as u64 <= remaining,
        "Upload exceeds the 4 MiB combined limit"
    );
    Ok(bytes)
}

/// Cancellation is cooperative between filesystem operations. Blocked kernel I/O
/// cannot be killed safely; its permit remains held, bounding stalled workers.
#[derive(Clone)]
pub struct UploadWork {
    cancelled: Arc<AtomicBool>,
    deadline: Instant,
}
impl UploadWork {
    pub fn new(timeout: Duration) -> Self {
        Self {
            cancelled: Arc::new(AtomicBool::new(false)),
            deadline: Instant::now() + timeout,
        }
    }
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
    pub fn check(&self) -> Result<()> {
        ensure!(!self.cancelled.load(Ordering::Acquire), "Upload cancelled");
        ensure!(
            Instant::now() < self.deadline,
            "Upload preparation timed out"
        );
        Ok(())
    }
}
#[derive(Default)]
pub struct UploadSlots(Arc<AtomicUsize>);
pub struct UploadPermit(Arc<AtomicUsize>);
impl UploadSlots {
    pub fn reserve(&self) -> Result<UploadPermit> {
        let mut active = self.0.load(Ordering::Acquire);
        loop {
            ensure!(active < 2, "At most two upload workers may be active");
            match self.0.compare_exchange_weak(
                active,
                active + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(observed) => active = observed,
            }
        }
        Ok(UploadPermit(self.0.clone()))
    }
}
impl Drop for UploadPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancellation_during_read_discards_bytes_and_stops_next_read() {
        struct CancellingReader {
            work: UploadWork,
            reads: usize,
        }
        impl Read for CancellingReader {
            fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
                self.reads += 1;
                bytes[0] = 42;
                self.work.cancel();
                Ok(1)
            }
        }
        let work = UploadWork::new(Duration::from_secs(10));
        let mut reader = CancellingReader {
            work: work.clone(),
            reads: 0,
        };
        assert!(
            read_bounded(&mut reader, 1024, &work)
                .unwrap_err()
                .to_string()
                .contains("cancelled")
        );
        assert_eq!(reader.reads, 1);
    }
    #[test]
    fn growing_reader_is_bounded_by_remaining_plus_one() {
        let work = UploadWork::new(Duration::from_secs(10));
        let mut reader = std::io::Cursor::new(vec![42u8; 100]);
        assert!(read_bounded(&mut reader, 3, &work).is_err());
        assert_eq!(reader.position(), 4);
    }
}
