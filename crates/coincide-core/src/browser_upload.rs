//! Bounded explicit local-file attachment. Paths are never included in page data.
use anyhow::{Result, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Serialize;
use std::{fs, io::Read, path::Path};

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
pub(super) struct UploadFile {
    name: String,
    mime: &'static str,
    data: String,
}

pub(super) fn prepare(paths: &[String]) -> Result<Vec<UploadFile>> {
    validate_paths(paths)?;
    let mut remaining = MAX_BYTES;
    let mut result = Vec::with_capacity(paths.len());
    for path in paths {
        let path = Path::new(path);
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
        let file = options.open(path)?;
        let metadata = file.metadata()?;
        ensure!(metadata.is_file(), "Upload requires regular files");
        ensure!(
            metadata.len() <= remaining,
            "Upload exceeds the 4 MiB combined limit"
        );
        let mut bytes = Vec::new();
        file.take(remaining + 1).read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() as u64 <= remaining,
            "Upload exceeds the 4 MiB combined limit"
        );
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
