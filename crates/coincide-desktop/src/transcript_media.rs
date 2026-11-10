//! Images a reply points at, drawn under the message like Swift's
//! `TranscriptMedia`.
//!
//! Agents describe what they made the same way they would in chat: a Markdown
//! image, a link to a saved screenshot, or an `attachments` entry for a
//! generated file. Swift scans the reply text plus `attachments` and shows a
//! card per item. Rust drew the text only, so a reply whose whole answer was a
//! screenshot showed a bare path.
//!
//! Only local images are collected. Nothing here fetches a URL: a reply can
//! point anywhere, and loading remote images from agent-written text would turn
//! the transcript into a beacon. Video, audio and interactive HTML wait for a
//! player; they stay as ordinary links until then.
use std::path::{Component, Path, PathBuf};

/// Swift's `TranscriptMedia.maxItems`.
pub(super) const MAX_ITEMS: usize = 8;
/// Swift's `MediaImageLoader` bound for a local file.
pub(super) const MAX_BYTES: u64 = 64 * 1024 * 1024;

/// One local image a reply shows.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Media {
    /// The path as the reply wrote it, for the caption and element identity.
    pub source: String,
    /// The file to draw.
    pub path: PathBuf,
}

/// Every image a reply points at, in the order it mentions them: its Markdown
/// images and image links, then its `attachments`.
pub(super) fn images(text: &str, attachments: &[String], root: Option<&Path>) -> Vec<Media> {
    let mut found: Vec<Media> = Vec::new();
    let mut add = |source: &str| {
        if found.len() >= MAX_ITEMS {
            return;
        }
        let Some(path) = resolve(source, root) else {
            return;
        };
        if found.iter().any(|media| media.path == path) {
            return;
        }
        found.push(Media {
            source: source.to_owned(),
            path,
        });
    };
    for target in targets(text) {
        add(&target);
    }
    for attachment in attachments {
        add(attachment);
    }
    found
}

/// Markdown link and image destinations, in order, as written.
fn targets(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let bytes = text.as_bytes();
    let mut index = 0;
    while index + 1 < bytes.len() {
        // Both `[alt](src)` images and `[text](src)` links can name a file.
        if bytes[index] == b']' && bytes[index + 1] == b'(' {
            let mut start = index + 2;
            while bytes.get(start) == Some(&b' ') {
                start += 1;
            }
            let wrapped = bytes.get(start) == Some(&b'<');
            if wrapped {
                start += 1;
            }
            let mut end = start;
            while end < bytes.len() {
                match bytes[end] {
                    b')' | b'\n' => break,
                    b'>' if wrapped => break,
                    _ => end += 1,
                }
            }
            if end > start
                && let Some(target) = text.get(start..end)
            {
                // A title after the destination (` "Shot"`) is not the file; a
                // path's own spaces are, so only a quoted tail is dropped.
                let trimmed = target.trim_end();
                let cut = [" \"", " '"]
                    .iter()
                    .filter_map(|quote| trimmed.find(quote))
                    .min();
                let target = cut.map_or(trimmed, |cut| &trimmed[..cut]);
                out.push(target.to_owned());
                index = end;
                continue;
            }
        }
        index += 1;
    }
    out
}

/// The local file a target names, when it names an image that exists.
fn resolve(source: &str, root: Option<&Path>) -> Option<PathBuf> {
    let source = source.trim();
    if source.is_empty() {
        return None;
    }
    let path = source.strip_prefix("file://").unwrap_or(source);
    // Remote images are never fetched.
    if path.contains("://") || path.starts_with("data:") {
        return None;
    }
    let decoded = percent_decoded(path);
    let path = Path::new(&decoded);
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else if let Some(rest) = decoded.strip_prefix("~/") {
        home()?.join(rest)
    } else {
        let root = root?;
        let joined = root.join(path);
        if !inside(&joined, root) {
            return None;
        }
        joined
    };
    if !is_image(&path) {
        return None;
    }
    let meta = std::fs::metadata(&path).ok()?;
    (meta.is_file() && meta.len() > 0 && meta.len() <= MAX_BYTES).then_some(path)
}

fn home() -> Option<PathBuf> {
    std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from)
}

/// Only formats GPUI can decode; anything else keeps its ordinary link.
fn is_image(path: &Path) -> bool {
    const EXTENSIONS: [&str; 10] = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "avif", "bmp", "tif", "tiff",
    ];
    path.extension()
        .and_then(|ext| ext.to_str())
        .is_some_and(|ext| {
            let ext = ext.to_ascii_lowercase();
            EXTENSIONS.contains(&ext.as_str())
        })
}

/// Spaces and other reserved bytes in a Markdown destination are escaped.
fn percent_decoded(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%'
            && index + 2 < bytes.len()
            && let (Some(high), Some(low)) = (hex(bytes[index + 1]), hex(bytes[index + 2]))
        {
            out.push(high * 16 + low);
            index += 3;
            continue;
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| source.to_owned())
}

fn hex(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

/// A path is inside the folder it resolves against, so a reply cannot make the
/// transcript draw files it has no business reading through `..`.
pub(super) fn inside(path: &Path, root: &Path) -> bool {
    let normalized = |path: &Path| {
        let mut out = PathBuf::new();
        for component in path.components() {
            match component {
                Component::ParentDir => {
                    out.pop();
                }
                Component::CurDir => {}
                other => out.push(other),
            }
        }
        out
    };
    normalized(path).starts_with(normalized(root))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn folder() -> tempfile::TempDir {
        tempfile::tempdir().expect("temp dir")
    }

    fn image_in(dir: &Path, name: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, b"png").expect("write");
        path
    }

    #[test]
    fn markdown_images_and_links_are_collected_in_order() {
        let dir = folder();
        let one = image_in(dir.path(), "one.png");
        let two = image_in(dir.path(), "two.jpg");
        let text = format!(
            "See ![first]({}) and [second]({}).",
            one.display(),
            two.display()
        );
        let found = images(&text, &[], Some(dir.path()));
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].path, one);
        assert_eq!(found[1].path, two);
    }

    #[test]
    fn relative_targets_resolve_against_the_thread_folder() {
        let dir = folder();
        image_in(dir.path(), "shot.png");
        let found = images("![shot](shot.png)", &[], Some(dir.path()));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].path, dir.path().join("shot.png"));
    }

    #[test]
    fn attachments_are_images_too_and_duplicates_appear_once() {
        let dir = folder();
        let one = image_in(dir.path(), "one.png");
        let source = one.display().to_string();
        let found = images(&format!("![shot]({source})"), &[source.clone()], None);
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn a_missing_file_or_other_extension_is_not_media() {
        let dir = folder();
        image_in(dir.path(), "notes.txt");
        assert!(
            images(
                "![gone](gone.png) ![text](notes.txt)",
                &[],
                Some(dir.path())
            )
            .is_empty()
        );
    }

    #[test]
    fn remote_and_data_targets_are_never_collected() {
        let found = images(
            "![web](https://example.com/a.png) ![inline](data:image/png;base64,AAA)",
            &[],
            None,
        );
        assert!(found.is_empty());
    }

    #[test]
    fn escaped_spaces_and_file_urls_resolve() {
        let dir = folder();
        image_in(dir.path(), "my shot.png");
        let found = images("![shot](my%20shot.png)", &[], Some(dir.path()));
        assert_eq!(found.len(), 1);
        let url = format!("file://{}", dir.path().join("my shot.png").display());
        assert_eq!(images(&format!("[x]({url})"), &[], None).len(), 1);
    }

    #[test]
    fn a_title_after_the_destination_is_not_the_file() {
        let dir = folder();
        image_in(dir.path(), "shot.png");
        let found = images("![shot](shot.png \"A shot\")", &[], Some(dir.path()));
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].source, "shot.png");
    }

    #[test]
    fn at_most_eight_images_are_shown() {
        let dir = folder();
        let mut text = String::new();
        for index in 0..12 {
            image_in(dir.path(), &format!("{index}.png"));
            text.push_str(&format!("![{index}]({index}.png) "));
        }
        assert_eq!(images(&text, &[], Some(dir.path())).len(), MAX_ITEMS);
    }

    #[test]
    fn a_relative_parent_escape_is_outside_the_folder() {
        let path = Path::new("/work/thread/../secret.png");
        assert!(!inside(path, Path::new("/work/thread")));
        assert!(inside(
            Path::new("/work/thread/shots/a.png"),
            Path::new("/work/thread")
        ));
    }
}
