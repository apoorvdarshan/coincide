//! Swift's ComputerUseController.publicResult: a window screenshot reaches the
//! agent as a private file in its thread's folder, not as base64 inside the
//! tool result. Folders live in one per-session temporary directory (0700),
//! files are 0600, each thread keeps its newest SCREENSHOT_LIMIT, and a
//! thread's folder goes when its access does, as Swift's bridge removes it.
use anyhow::{Context, Result, ensure};
use base64::Engine as _;
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use uuid::Uuid;

pub const SCREENSHOT_LIMIT: usize = 32;
const UNSAVED: &str = "A screenshot could not be saved.";

#[derive(Default)]
pub struct Screenshots {
    root: Option<PathBuf>,
}
impl Screenshots {
    /// Replaces an inline `png_base64` screenshot in `result` with the path of
    /// the file it was saved to. A result without one is left as it is.
    pub fn deliver(&mut self, thread: Uuid, result: &mut Value) {
        if result["screenshot"]["encoding"] != "png_base64" {
            return;
        }
        let shot = result["screenshot"].take();
        let saved = self
            .folder(thread)
            .and_then(|folder| save(&folder, &shot["data"], now_ms()));
        result["screenshot"] = match saved {
            Ok(path) => json!({
                "encoding": "file",
                "path": path,
                "mimeType": "image/png",
                "width": shot["width"],
                "height": shot["height"],
            }),
            Err(_) => json!({"encoding": "unavailable", "message": UNSAVED}),
        };
    }
    /// A revoked thread's screenshots go with its access.
    pub fn remove(&mut self, thread: Uuid) {
        if let Some(root) = &self.root {
            let _ = fs::remove_dir_all(root.join(thread.to_string()));
        }
    }
    pub fn remove_all(&mut self) {
        if let Some(root) = self.root.take() {
            let _ = fs::remove_dir_all(root);
        }
    }
    fn folder(&mut self, thread: Uuid) -> Result<PathBuf> {
        let root = match &self.root {
            Some(root) => root.clone(),
            None => {
                let root =
                    std::env::temp_dir().join(format!("CoincideComputerUse-{}", Uuid::new_v4()));
                private_dir(&root)?;
                self.root = Some(root.clone());
                root
            }
        };
        let folder = root.join(thread.to_string());
        private_dir(&folder)?;
        Ok(folder)
    }
}
impl Drop for Screenshots {
    fn drop(&mut self) {
        self.remove_all();
    }
}
fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
fn private_dir(path: &Path) -> Result<()> {
    match fs::create_dir(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    let metadata = fs::symlink_metadata(path)?;
    ensure!(
        metadata.is_dir() && !metadata.file_type().is_symlink(),
        "Screenshot folder is not a private directory"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}
/// Saves the decoded PNG as `screenshot-<ms>-<n>.png`, never replacing a file,
/// then prunes the folder to its newest SCREENSHOT_LIMIT screenshots.
fn save(folder: &Path, data: &Value, stamp: u128) -> Result<String> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data.as_str().context("Missing screenshot data")?)
        .context("Invalid screenshot data")?;
    ensure!(
        bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "Screenshot is not a PNG"
    );
    for n in 1..=16 {
        let path = folder.join(format!("screenshot-{stamp}-{n}.png"));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&path) {
            Ok(mut file) => {
                if let Err(error) = file.write_all(&bytes) {
                    let _ = fs::remove_file(&path);
                    return Err(error.into());
                }
                prune(folder);
                return path
                    .into_os_string()
                    .into_string()
                    .map_err(|_| anyhow::anyhow!("Screenshot path is not UTF-8"));
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
    anyhow::bail!("Too many screenshots in one millisecond")
}
/// Names sort by their millisecond stamp, then counter: oldest first.
fn prune(folder: &Path) {
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    let mut shots: Vec<(u128, u32, PathBuf)> = entries
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            let name = path.file_name()?.to_str()?;
            let (stamp, n) = name
                .strip_prefix("screenshot-")?
                .strip_suffix(".png")?
                .split_once('-')?;
            Some((stamp.parse().ok()?, n.parse().ok()?, path))
        })
        .collect();
    shots.sort();
    let excess = shots.len().saturating_sub(SCREENSHOT_LIMIT);
    for (_, _, path) in shots.into_iter().take(excess) {
        let _ = fs::remove_file(path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn png() -> String {
        let bytes = crate::appshots::encode_rgba(1, 1, vec![0; 4]).unwrap();
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }
    #[test]
    fn inline_screenshot_becomes_a_private_file_and_the_rest_is_kept() {
        let mut screenshots = Screenshots::default();
        let thread = Uuid::new_v4();
        let mut result = json!({"observation":"o","screenshot":{"encoding":"png_base64","data":png(),"width":1,"height":1}});
        screenshots.deliver(thread, &mut result);
        assert_eq!(result["observation"], "o");
        let shot = &result["screenshot"];
        assert_eq!(shot["encoding"], "file");
        assert_eq!(
            (shot["width"].as_u64(), shot["mimeType"].as_str()),
            (Some(1), Some("image/png"))
        );
        let path = PathBuf::from(shot["path"].as_str().unwrap());
        assert!(path.starts_with(screenshots.root.as_ref().unwrap().join(thread.to_string())));
        assert!(fs::read(&path).unwrap().starts_with(b"\x89PNG"));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            let folder = path.parent().unwrap();
            assert_eq!(
                fs::metadata(folder).unwrap().permissions().mode() & 0o777,
                0o700
            );
        }
        let mut plain = json!({"screenshot":null,"elements":[]});
        screenshots.deliver(thread, &mut plain);
        assert_eq!(plain, json!({"screenshot":null,"elements":[]}));
        screenshots.remove(thread);
        assert!(!path.exists());
        let root = screenshots.root.clone().unwrap();
        drop(screenshots);
        assert!(
            !root.exists(),
            "the session folder goes when Computer Use does"
        );
    }
    #[test]
    fn undecodable_data_is_reported_instead_of_returned() {
        let mut screenshots = Screenshots::default();
        let mut result = json!({"screenshot":{"encoding":"png_base64","data":"not base64!","width":1,"height":1}});
        screenshots.deliver(Uuid::new_v4(), &mut result);
        assert_eq!(
            result["screenshot"],
            json!({"encoding":"unavailable","message":UNSAVED})
        );
    }
    #[test]
    fn each_folder_keeps_only_the_newest_screenshots() {
        let folder = tempfile::tempdir().unwrap();
        let data = json!(png());
        for stamp in 0..(SCREENSHOT_LIMIT as u128 + 3) {
            save(folder.path(), &data, 1_000 + stamp).unwrap();
        }
        let same = save(folder.path(), &data, 1_000 + SCREENSHOT_LIMIT as u128 + 2).unwrap();
        assert!(
            same.ends_with("-2.png"),
            "a second shot in one millisecond is not replaced"
        );
        let mut names: Vec<String> = fs::read_dir(folder.path())
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        names.sort();
        assert_eq!(names.len(), SCREENSHOT_LIMIT);
        assert!(!names.contains(&"screenshot-1000-1.png".to_owned()));
        assert!(names.contains(&format!(
            "screenshot-{}-2.png",
            1_000 + SCREENSHOT_LIMIT + 2
        )));
    }
}
