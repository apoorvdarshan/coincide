//! Private image ingestion for the API and desktop. Sources remain untouched;
//! originals and static, normalized first frames are stored separately.
use crate::agent::ImageAttachment;
use anyhow::{Context, Result, bail, ensure};
use image::{
    DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits, Rgb, RgbImage,
    codecs::jpeg::JpegEncoder, imageops::FilterType,
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Cursor, Read, Write},
    path::{Path, PathBuf},
};
use uuid::Uuid;

pub const MAX_SOURCE_BYTES: u64 = 20 * 1024 * 1024;
pub const MAX_NORMALIZED_BYTES: u64 = 3_750_000;
pub const MAX_IMAGE_EDGE: u32 = 2_000;
const MAX_SOURCE_EDGE: u32 = 32_768;
const MAX_SOURCE_PIXELS: u64 = 64_000_000;
const MAX_DECODED_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredImage {
    pub id: String,
    pub original_name: String,
    pub original_path: PathBuf,
    pub original_mime_type: String,
    pub path: PathBuf,
    pub mime_type: String,
    pub width: u32,
    pub height: u32,
    pub byte_len: u64,
    pub original_byte_len: u64,
}

impl StoredImage {
    /// Deserialized thread metadata is untrusted. Only files inside this image's
    /// UUID directory in the selected candidate data directory may be opened.
    pub fn prepare_in(&self, data_directory: &Path) -> Result<ImageAttachment> {
        let id = Uuid::parse_str(&self.id).context("Invalid stored image identifier")?;
        ensure!(
            id.to_string() == self.id,
            "Stored image identifier is not canonical"
        );
        ensure!(
            self.width > 0
                && self.height > 0
                && self.width <= MAX_IMAGE_EDGE
                && self.height <= MAX_IMAGE_EDGE,
            "Invalid stored image dimensions"
        );
        ensure!(
            self.byte_len > 0 && self.byte_len <= MAX_NORMALIZED_BYTES,
            "Invalid stored image byte length"
        );
        ensure!(
            self.original_byte_len > 0 && self.original_byte_len <= MAX_SOURCE_BYTES,
            "Invalid stored original byte length"
        );
        let root = canonical_data_directory(data_directory)?;
        let attachments = root.join("attachments");
        require_directory(&attachments)?;
        let directory = attachments.join(&self.id);
        require_directory(&directory)?;
        let normalized_extension = match self.mime_type.as_str() {
            "image/png" => "png",
            "image/jpeg" => "jpg",
            _ => bail!("Stored normalized image has an unsupported MIME type"),
        };
        let original_extension = extension_for_mime(&self.original_mime_type)?;
        ensure!(
            self.path == directory.join(format!("{}.{}", self.id, normalized_extension)),
            "Stored image path is outside its UUID directory"
        );
        ensure!(
            self.original_path
                == directory.join(format!("{}-original.{}", self.id, original_extension)),
            "Stored original path is outside its UUID directory"
        );
        let original = open_regular(&self.original_path)?;
        let original_length = original.metadata()?.len();
        ensure!(
            original_length == self.original_byte_len && original_length <= MAX_SOURCE_BYTES,
            "Stored original length changed"
        );
        let bytes = read_bounded(&self.path, MAX_NORMALIZED_BYTES)?;
        ensure!(
            bytes.len() as u64 == self.byte_len,
            "Stored image length changed"
        );
        // Re-decode the bounded materialized image so forged dimensions or stale
        // metadata cannot bypass the normalized image limits.
        let decoded = decode(&bytes, false)?;
        ensure!(
            decoded.width() == self.width && decoded.height() == self.height,
            "Stored image dimensions changed"
        );
        ImageAttachment::new(self.path.clone(), self.mime_type.clone(), bytes)
    }
}

/// Decode first, then create private UUID files. Failures never modify the source
/// and clean only the new files created by this call.
pub fn ingest_image(data_directory: &Path, source: &Path) -> Result<StoredImage> {
    let source_bytes = read_bounded(source, MAX_SOURCE_BYTES)?;
    let name = source
        .file_name()
        .context("Image source has no filename")?
        .to_string_lossy();
    ingest_bytes(
        data_directory,
        &source_bytes,
        &name,
        false,
        |_| Ok(()),
        |_| Ok(()),
    )
}
/// Trusted historical-media seam. Ownership must be durably recorded before
/// this callback returns. Once owned, partial managed files are never auto-deleted.
pub(crate) fn ingest_image_bytes_owned(
    data_directory: &Path,
    source_bytes: &[u8],
    name: &str,
    before_write: impl FnOnce(&StoredImage) -> Result<()>,
) -> Result<StoredImage> {
    ingest_bytes(
        data_directory,
        source_bytes,
        name,
        true,
        before_write,
        |_| Ok(()),
    )
}
fn ingest_bytes(
    data_directory: &Path,
    source_bytes: &[u8],
    name: &str,
    retain_partial: bool,
    before_write: impl FnOnce(&StoredImage) -> Result<()>,
    after_original: impl FnOnce(&StoredImage) -> Result<()>,
) -> Result<StoredImage> {
    let root = canonical_data_directory(data_directory)?;
    ensure!(
        source_bytes.len() as u64 <= MAX_SOURCE_BYTES,
        "Image exceeds source byte limit"
    );
    let original_format = supported_format(source_bytes)?;
    let original_mime_type = mime_for_format(original_format)?;
    let decoded = decode(source_bytes, true)?;
    let (bytes, mime_type, width, height) = normalize(decoded)?;
    let attachments = root.join("attachments");
    let id = Uuid::new_v4().to_string();
    let directory = attachments.join(&id);
    let image = StoredImage {
        original_path: directory.join(format!(
            "{id}-original.{}",
            extension_for_mime(original_mime_type)?
        )),
        path: directory.join(format!("{id}.{}", extension_for_mime(mime_type)?)),
        id,
        original_name: name.into(),
        original_mime_type: original_mime_type.into(),
        mime_type: mime_type.into(),
        width,
        height,
        byte_len: bytes.len() as u64,
        original_byte_len: source_bytes.len() as u64,
    };
    // No managed directory/file for this identity exists before durable ownership.
    before_write(&image)?;
    match create_private_directory(&attachments) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error).context("Unable to create private image directory"),
    }
    require_directory(&attachments)?;
    create_private_directory(&directory)?;
    let mut created = CreatedFiles {
        directory,
        files: Vec::new(),
        keep: retain_partial,
    };
    created.write(&image.original_path, source_bytes)?;
    after_original(&image)?;
    created.write(&image.path, &bytes)?;
    created.keep = true;
    Ok(image)
}

/// A clipboard-only source owned by one import. Dropping it removes only the
/// file created here, after checking its identity; durable imported images and
/// user-provided source paths are never part of this cleanup.
pub struct StagedClipboardImage {
    path: PathBuf,
    directory: PathBuf,
    root: PathBuf,
    identity: fs::Metadata,
}
impl StagedClipboardImage {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

pub fn stage_clipboard_image(data_directory: &Path, bytes: &[u8]) -> Result<StagedClipboardImage> {
    ensure!(
        !bytes.is_empty() && bytes.len() as u64 <= MAX_SOURCE_BYTES,
        "Clipboard image must contain 1 byte–20 MiB of encoded data"
    );
    let format = supported_format(bytes)?;
    let extension = extension_for_mime(mime_for_format(format)?)?;
    let root = canonical_data_directory(data_directory)?.join("clipboard-staging");
    match create_private_directory(&root) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error).context("Unable to create clipboard staging directory"),
    }
    require_directory(&root)?;
    let directory = root.join(Uuid::new_v4().to_string());
    create_private_directory(&directory)?;
    let mut created = CreatedFiles {
        directory: directory.clone(),
        files: Vec::new(),
        keep: false,
    };
    let path = directory.join(format!("clipboard.{extension}"));
    created.write(&path, bytes)?;
    let identity = fs::symlink_metadata(&path)?;
    created.keep = true;
    Ok(StagedClipboardImage {
        path,
        directory,
        root,
        identity,
    })
}

impl Drop for StagedClipboardImage {
    fn drop(&mut self) {
        if require_directory(&self.root).is_err()
            || require_directory(&self.directory).is_err()
            || self.directory.canonicalize().ok().as_ref() != Some(&self.directory)
        {
            return;
        }
        let Ok(current) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if !current.is_file() || current.file_type().is_symlink() {
            return;
        }
        #[cfg(unix)]
        let same = {
            use std::os::unix::fs::MetadataExt;
            current.dev() == self.identity.dev() && current.ino() == self.identity.ino()
        };
        #[cfg(not(unix))]
        let same = current
            .created()
            .ok()
            .is_some_and(|created| self.identity.created().ok() == Some(created))
            && current.len() == self.identity.len();
        if same {
            let _ = fs::remove_file(&self.path);
            let _ = fs::remove_dir(&self.directory);
        }
    }
}

fn canonical_data_directory(path: &Path) -> Result<PathBuf> {
    require_directory(path)?;
    let path = fs::canonicalize(path).context("Unable to resolve attachment data directory")?;
    ensure!(
        path.to_str().is_some(),
        "Attachment data directory must be UTF-8"
    );
    Ok(path)
}

fn require_directory(path: &Path) -> Result<()> {
    let metadata = fs::symlink_metadata(path).context("Attachment directory is unavailable")?;
    ensure!(
        !metadata.file_type().is_symlink() && metadata.is_dir(),
        "Attachment directory must be a real directory, not a symlink"
    );
    Ok(())
}

fn create_private_directory(path: &Path) -> std::io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)
}

fn open_regular(path: &Path) -> Result<File> {
    let metadata = fs::symlink_metadata(path).context("Image file is unavailable")?;
    ensure!(
        !metadata.file_type().is_symlink() && metadata.is_file(),
        "Image must be a regular file, not a symlink"
    );
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path).context("Unable to open image file")?;
    ensure!(file.metadata()?.is_file(), "Image must be a regular file");
    Ok(file)
}

fn read_bounded(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let file = open_regular(path)?;
    let length = file.metadata()?.len();
    ensure!(
        length > 0 && length <= limit,
        "Image file is empty or exceeds its byte limit"
    );
    let mut bytes = Vec::with_capacity(length as usize);
    file.take(limit + 1)
        .read_to_end(&mut bytes)
        .context("Unable to read image file")?;
    ensure!(
        bytes.len() as u64 == length && bytes.len() as u64 <= limit,
        "Image changed while it was read or exceeds its byte limit"
    );
    Ok(bytes)
}

fn supported_format(bytes: &[u8]) -> Result<ImageFormat> {
    let format = image::guess_format(bytes).context("Unable to identify image format")?;
    ensure!(
        matches!(
            format,
            ImageFormat::Png | ImageFormat::Jpeg | ImageFormat::Gif | ImageFormat::WebP
        ),
        "Only PNG, JPEG, GIF and WebP images are supported"
    );
    Ok(format)
}

fn mime_for_format(format: ImageFormat) -> Result<&'static str> {
    match format {
        ImageFormat::Png => Ok("image/png"),
        ImageFormat::Jpeg => Ok("image/jpeg"),
        ImageFormat::Gif => Ok("image/gif"),
        ImageFormat::WebP => Ok("image/webp"),
        _ => bail!("Unsupported image format"),
    }
}

fn extension_for_mime(mime: &str) -> Result<&'static str> {
    match mime {
        "image/png" => Ok("png"),
        "image/jpeg" => Ok("jpg"),
        "image/gif" => Ok("gif"),
        "image/webp" => Ok("webp"),
        _ => bail!("Unsupported image MIME type"),
    }
}

fn decode(bytes: &[u8], normalize_size: bool) -> Result<DynamicImage> {
    let format = supported_format(bytes)?;
    let mut reader = ImageReader::with_format(Cursor::new(bytes), format);
    let mut limits = Limits::default();
    limits.max_image_width = Some(MAX_SOURCE_EDGE);
    limits.max_image_height = Some(MAX_SOURCE_EDGE);
    limits.max_alloc = Some(MAX_DECODED_BYTES);
    reader.limits(limits);
    let mut decoder = reader
        .into_decoder()
        .context("Invalid or oversized image")?;
    let (width, height) = decoder.dimensions();
    ensure!(
        normalize_size || (width <= MAX_IMAGE_EDGE && height <= MAX_IMAGE_EDGE),
        "Stored normalized image exceeds the pixel dimension limit"
    );
    ensure!(
        width > 0 && height > 0 && u64::from(width) * u64::from(height) <= MAX_SOURCE_PIXELS,
        "Image exceeds the 64 megapixel decode limit"
    );
    ensure!(
        decoder.total_bytes() <= MAX_DECODED_BYTES,
        "Image exceeds the decoded memory limit"
    );
    let orientation = decoder
        .orientation()
        .context("Invalid image orientation metadata")?;
    let mut decoded =
        DynamicImage::from_decoder(decoder).context("Unable to decode image pixels")?;
    // Resize before orientation to avoid rotating another full-size photograph.
    if normalize_size && (decoded.width() > MAX_IMAGE_EDGE || decoded.height() > MAX_IMAGE_EDGE) {
        decoded = decoded.resize(MAX_IMAGE_EDGE, MAX_IMAGE_EDGE, FilterType::Triangle);
    }
    decoded.apply_orientation(orientation);
    Ok(decoded)
}

fn normalize(decoded: DynamicImage) -> Result<(Vec<u8>, &'static str, u32, u32)> {
    let mut rgba = decoded.to_rgba8();
    loop {
        let mut png = Cursor::new(Vec::new());
        DynamicImage::ImageRgba8(rgba.clone()).write_to(&mut png, ImageFormat::Png)?;
        let png = png.into_inner();
        if png.len() as u64 <= MAX_NORMALIZED_BYTES {
            return Ok((png, "image/png", rgba.width(), rgba.height()));
        }
        // Keep alpha intact. Opaque photographs can use JPEG; transparent images
        // instead shrink until a PNG fits, with the original retained unchanged.
        if rgba.pixels().all(|pixel| pixel[3] == 255) {
            let rgb = RgbImage::from_fn(rgba.width(), rgba.height(), |x, y| {
                let pixel = rgba.get_pixel(x, y);
                Rgb([pixel[0], pixel[1], pixel[2]])
            });
            for quality in [90, 80, 70, 60, 45] {
                let mut jpeg = Vec::new();
                JpegEncoder::new_with_quality(&mut jpeg, quality).encode_image(&rgb)?;
                if jpeg.len() as u64 <= MAX_NORMALIZED_BYTES {
                    return Ok((jpeg, "image/jpeg", rgb.width(), rgb.height()));
                }
            }
        }
        ensure!(
            rgba.width() > 1 || rgba.height() > 1,
            "Unable to normalize image within byte limit"
        );
        let width = (rgba.width() * 4 / 5).max(1);
        let height = (rgba.height() * 4 / 5).max(1);
        rgba = image::imageops::resize(&rgba, width, height, FilterType::Triangle);
    }
}

struct CreatedFiles {
    directory: PathBuf,
    files: Vec<PathBuf>,
    keep: bool,
}
impl CreatedFiles {
    fn write(&mut self, path: &Path, bytes: &[u8]) -> Result<()> {
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(path)
            .context("Unable to create private image file")?;
        self.files.push(path.into());
        file.write_all(bytes)?;
        file.sync_all()?;
        Ok(())
    }
}
impl Drop for CreatedFiles {
    fn drop(&mut self) {
        if !self.keep {
            for path in &self.files {
                let _ = fs::remove_file(path);
            }
            let _ = fs::remove_dir(&self.directory);
        }
    }
}

#[cfg(test)]
pub(crate) fn ingest_owned_copy_fault(
    data: &Path,
    bytes: &[u8],
    own: impl FnOnce(&StoredImage) -> Result<()>,
) -> Result<StoredImage> {
    ingest_bytes(data, bytes, "fixture.png", true, own, |_| {
        anyhow::bail!("injected after original copy")
    })
}
