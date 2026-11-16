//! Best-effort, bounded Quick Look previews for files the user selected.
use super::PickedPath;
use crate::{agent::OwnedChild, attachments::StoredImage};
use anyhow::{Context, Result, ensure};
use std::{
    path::Path,
    process::{Command, Stdio},
    time::{Duration, Instant},
};

const TIMEOUT: Duration = Duration::from_millis(1500);
const MAX_SOURCE_BYTES: u64 = 100 * 1024 * 1024;

pub(super) fn make(picked: &PickedPath, data_directory: &Path) -> Option<StoredImage> {
    let path = Path::new(&picked.path);
    let extension = path.extension()?.to_str()?.to_ascii_lowercase();
    if picked.size? > MAX_SOURCE_BYTES
        || !matches!(
            extension.as_str(),
            "pdf"
                | "doc"
                | "docx"
                | "ppt"
                | "pptx"
                | "xls"
                | "xlsx"
                | "pages"
                | "key"
                | "numbers"
                | "rtf"
                | "svg"
                | "heic"
                | "heif"
                | "tif"
                | "tiff"
                | "bmp"
                | "avif"
        )
    {
        return None;
    }
    generate(
        path,
        data_directory,
        Path::new("/usr/bin/qlmanage"),
        TIMEOUT,
    )
    .ok()
}

fn generate(
    source: &Path,
    data_directory: &Path,
    executable: &Path,
    timeout: Duration,
) -> Result<StoredImage> {
    // A private temporary directory is removed even on timeout. qlmanage sees
    // exactly the selected path as an argument, never through a shell.
    let directory = tempfile::Builder::new()
        .prefix("coincide-preview-")
        .tempdir()?;
    let mut command = Command::new(executable);
    command
        .arg("-t")
        .arg("-s")
        .arg("192")
        .arg("-o")
        .arg(directory.path())
        .arg(source)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let child = OwnedChild::spawn(&mut command)?;
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(code) = child.exit_code()? {
            ensure!(code == 0, "Thumbnail service failed");
            break;
        }
        ensure!(Instant::now() < deadline, "Thumbnail service timed out");
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut images = std::fs::read_dir(directory.path())?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.extension()
                .is_some_and(|ext| ext.eq_ignore_ascii_case("png"))
        });
    let output = images.next().context("Thumbnail was unavailable")?;
    ensure!(images.next().is_none(), "Thumbnail result was ambiguous");
    // The existing image importer checks size, type, symlinks, dimensions and
    // writes a private managed copy used for both drafts and sent messages.
    crate::attachments::ingest_image(data_directory, &output)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn generated_thumbnail_is_a_managed_image_and_timeout_is_bounded() {
        let root = tempfile::tempdir().unwrap();
        let input = root.path().join("example.pdf");
        std::fs::write(&input, b"fixture").unwrap();
        let fixture = root.path().join("fixture.png");
        image::DynamicImage::new_rgba8(3, 2).save(&fixture).unwrap();
        let script = root.path().join("thumbnailer");
        std::fs::write(
            &script,
            format!(
                "#!/bin/sh\n/bin/cp '{}' \"$5/preview.png\"\n",
                fixture.display()
            ),
        )
        .unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700)).unwrap();
        let image = generate(&input, root.path(), &script, Duration::from_secs(2)).unwrap();
        assert!(image.prepare_in(root.path()).is_ok());
        assert_eq!(std::fs::read(&input).unwrap(), b"fixture");
        std::fs::write(&script, "#!/bin/sh\nwhile :; do :; done\n").unwrap();
        let start = Instant::now();
        assert!(generate(&input, root.path(), &script, Duration::from_millis(70)).is_err());
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    #[ignore = "requires the macOS Quick Look service"]
    fn system_quicklook_renders_a_selected_pdf() {
        let root = tempfile::tempdir().unwrap();
        let pdf = root.path().join("example.pdf");
        std::fs::write(
            &pdf,
            include_bytes!("../../coincide-desktop/assets/providers/logo-codex.pdf"),
        )
        .unwrap();
        let picked = PickedPath::inspect(&pdf)
            .unwrap()
            .with_preview_image(root.path());
        let image = picked
            .preview_image
            .expect("Quick Look did not return a thumbnail");
        assert!(image.prepare_in(root.path()).is_ok());
    }
}
