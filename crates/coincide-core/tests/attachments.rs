use coincide_core::attachments::{
    MAX_IMAGE_EDGE, MAX_NORMALIZED_BYTES, MAX_SOURCE_BYTES, StoredImage, ingest_image,
};
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use std::{fs, io::Cursor, path::Path};

fn encode(path: &Path, image: &DynamicImage, format: ImageFormat) -> Vec<u8> {
    let mut output = Cursor::new(Vec::new());
    if format == ImageFormat::Jpeg {
        DynamicImage::ImageRgb8(image.to_rgb8())
            .write_to(&mut output, format)
            .unwrap();
    } else {
        image.write_to(&mut output, format).unwrap();
    }
    let bytes = output.into_inner();
    fs::write(path, &bytes).unwrap();
    bytes
}

fn solid(width: u32, height: u32) -> DynamicImage {
    DynamicImage::ImageRgba8(RgbaImage::from_pixel(
        width,
        height,
        Rgba([20, 90, 180, 255]),
    ))
}

#[test]
fn all_supported_formats_decode_preserve_originals_and_prepare_from_private_storage() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source-with-untrusted-extension.txt");
    for (format, mime) in [
        (ImageFormat::Png, "image/png"),
        (ImageFormat::Jpeg, "image/jpeg"),
        (ImageFormat::Gif, "image/gif"),
        (ImageFormat::WebP, "image/webp"),
    ] {
        let original = encode(&source, &solid(32, 16), format);
        let stored = ingest_image(directory.path(), &source).unwrap();
        assert_eq!(stored.original_mime_type, mime);
        assert_eq!(stored.original_name, "source-with-untrusted-extension.txt");
        assert_eq!(fs::read(&source).unwrap(), original);
        assert_eq!(fs::read(&stored.original_path).unwrap(), original);
        assert_ne!(stored.path, stored.original_path);
        assert_eq!((stored.width, stored.height), (32, 16));
        assert!(stored.byte_len <= MAX_NORMALIZED_BYTES);
        let decoded = image::load_from_memory(&fs::read(&stored.path).unwrap()).unwrap();
        assert_eq!((decoded.width(), decoded.height()), (32, 16));
        let roundtrip: StoredImage =
            serde_json::from_value(serde_json::to_value(&stored).unwrap()).unwrap();
        let attachment = roundtrip.prepare_in(directory.path()).unwrap();
        assert_eq!(attachment.path(), stored.path);
        assert_eq!(attachment.byte_len() as u64, stored.byte_len);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&stored.path).unwrap().permissions().mode() & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(&stored.original_path)
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
            assert_eq!(
                fs::metadata(stored.path.parent().unwrap())
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o700
            );
        }
    }
}

#[test]
fn large_images_resize_without_changing_source_and_use_unique_uuid_files() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("large.png");
    let original = encode(&source, &solid(3000, 1500), ImageFormat::Png);
    let first = ingest_image(directory.path(), &source).unwrap();
    let second = ingest_image(directory.path(), &source).unwrap();
    assert_eq!(
        (first.width, first.height),
        (MAX_IMAGE_EDGE, MAX_IMAGE_EDGE / 2)
    );
    assert_ne!(first.id, second.id);
    assert_ne!(first.path, second.path);
    assert!(
        first
            .path
            .file_name()
            .unwrap()
            .to_string_lossy()
            .starts_with(&first.id)
    );
    assert_eq!(fs::read(source).unwrap(), original);
    first.prepare_in(directory.path()).unwrap();
}

#[test]
fn jpeg_exif_orientation_is_applied_to_the_normalized_image() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("rotated.jpg");
    let jpeg = encode(&source, &solid(20, 10), ImageFormat::Jpeg);
    // Minimal little-endian TIFF IFD: orientation tag 0x0112, SHORT value 6.
    let exif: &[u8] = b"Exif\0\0II\x2a\0\x08\0\0\0\x01\0\x12\x01\x03\0\x01\0\0\0\x06\0\0\0\0\0\0\0";
    let mut oriented = jpeg[..2].to_vec();
    oriented.extend([0xff, 0xe1]);
    oriented.extend(((exif.len() + 2) as u16).to_be_bytes());
    oriented.extend(exif);
    oriented.extend(&jpeg[2..]);
    fs::write(&source, &oriented).unwrap();
    let stored = ingest_image(directory.path(), &source).unwrap();
    assert_eq!((stored.width, stored.height), (10, 20));
    assert_eq!(fs::read(stored.original_path).unwrap(), oriented);
}

#[test]
fn concurrent_imports_do_not_overwrite_each_other_or_fail_directory_creation() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("shared.png");
    let original = encode(&source, &solid(8, 4), ImageFormat::Png);
    let (first, second) = std::thread::scope(|scope| {
        let first = scope.spawn(|| ingest_image(directory.path(), &source).unwrap());
        let second = scope.spawn(|| ingest_image(directory.path(), &source).unwrap());
        (first.join().unwrap(), second.join().unwrap())
    });
    assert_ne!(first.path, second.path);
    first.prepare_in(directory.path()).unwrap();
    second.prepare_in(directory.path()).unwrap();
    assert_eq!(fs::read(source).unwrap(), original);
}

fn noisy(alpha: bool) -> DynamicImage {
    let mut random = 7_u32;
    DynamicImage::ImageRgba8(RgbaImage::from_fn(1200, 1200, |_, _| {
        let mut values = [0; 4];
        for value in &mut values {
            random ^= random << 13;
            random ^= random >> 17;
            random ^= random << 5;
            *value = random as u8;
        }
        if !alpha {
            values[3] = 255;
        }
        Rgba(values)
    }))
}

#[test]
fn opaque_noise_recompresses_as_jpeg_and_transparency_survives_png_downsizing() {
    let directory = tempfile::tempdir().unwrap();
    for alpha in [false, true] {
        let source = directory
            .path()
            .join(if alpha { "alpha.png" } else { "opaque.png" });
        let original = encode(&source, &noisy(alpha), ImageFormat::Png);
        assert!(original.len() as u64 > MAX_NORMALIZED_BYTES);
        let stored = ingest_image(directory.path(), &source).unwrap();
        assert!(stored.byte_len <= MAX_NORMALIZED_BYTES);
        assert_eq!(
            stored.mime_type,
            if alpha { "image/png" } else { "image/jpeg" }
        );
        let decoded = image::open(&stored.path).unwrap().to_rgba8();
        assert_eq!(decoded.pixels().any(|pixel| pixel[3] < 255), alpha);
        if alpha {
            assert!(stored.width < 1200);
        }
        assert_eq!(fs::read(&source).unwrap(), original);
        stored.prepare_in(directory.path()).unwrap();
    }
}

#[test]
fn invalid_unsupported_empty_and_oversize_sources_create_no_attachment_files() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("bad.png");
    for bytes in [
        Vec::new(),
        b"not an image".to_vec(),
        b"\x89PNG\r\n\x1a\ntruncated".to_vec(),
        b"BMnot-supported".to_vec(),
    ] {
        fs::write(&source, &bytes).unwrap();
        assert!(ingest_image(directory.path(), &source).is_err());
        assert_eq!(fs::read(&source).unwrap(), bytes);
        assert!(!directory.path().join("attachments").exists());
    }
    fs::File::create(&source)
        .unwrap()
        .set_len(MAX_SOURCE_BYTES + 1)
        .unwrap();
    assert!(ingest_image(directory.path(), &source).is_err());
    assert_eq!(fs::metadata(source).unwrap().len(), MAX_SOURCE_BYTES + 1);
    assert!(!directory.path().join("attachments").exists());
}

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = !0_u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xedb88320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

#[test]
fn forged_huge_dimensions_fail_before_decoding_pixels() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("huge.png");
    let mut bytes = encode(&source, &solid(1, 1), ImageFormat::Png);
    bytes[16..20].copy_from_slice(&10_000_u32.to_be_bytes());
    bytes[20..24].copy_from_slice(&10_000_u32.to_be_bytes());
    let crc = crc32(&bytes[12..29]);
    bytes[29..33].copy_from_slice(&crc.to_be_bytes());
    fs::write(&source, &bytes).unwrap();
    assert!(ingest_image(directory.path(), &source).is_err());
    assert!(!directory.path().join("attachments").exists());
}

#[test]
fn forged_persisted_metadata_cannot_escape_data_directory_or_bypass_bounds() {
    let directory = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.png");
    encode(&source, &solid(8, 4), ImageFormat::Png);
    let stored = ingest_image(directory.path(), &source).unwrap();
    assert!(stored.prepare_in(other.path()).is_err());
    let mut forged = stored.clone();
    forged.path = source.clone();
    assert!(forged.prepare_in(directory.path()).is_err());
    let mut forged = stored.clone();
    forged.original_path = source;
    assert!(forged.prepare_in(directory.path()).is_err());
    let mut forged = stored.clone();
    forged.id = "../../outside".into();
    assert!(forged.prepare_in(directory.path()).is_err());
    let mut forged = stored.clone();
    forged.byte_len = MAX_NORMALIZED_BYTES + 1;
    assert!(forged.prepare_in(directory.path()).is_err());
    let mut forged = stored.clone();
    forged.width = 9;
    assert!(forged.prepare_in(directory.path()).is_err());
    // Same metadata cannot mask a replaced oversized normalized file.
    fs::OpenOptions::new()
        .write(true)
        .open(&stored.path)
        .unwrap()
        .set_len(MAX_NORMALIZED_BYTES + 1)
        .unwrap();
    assert!(stored.prepare_in(directory.path()).is_err());
}

#[cfg(unix)]
#[test]
fn symlink_sources_storage_directories_and_materialized_files_are_rejected() {
    use std::os::unix::fs::symlink;
    let directory = tempfile::tempdir().unwrap();
    let other = tempfile::tempdir().unwrap();
    let source = other.path().join("source.png");
    encode(&source, &solid(8, 4), ImageFormat::Png);
    let link = directory.path().join("source-link.png");
    symlink(&source, &link).unwrap();
    assert!(ingest_image(directory.path(), &link).is_err());
    symlink(other.path(), directory.path().join("attachments")).unwrap();
    assert!(ingest_image(directory.path(), &source).is_err());
    fs::remove_file(directory.path().join("attachments")).unwrap();
    let stored = ingest_image(directory.path(), &source).unwrap();
    fs::remove_file(&stored.path).unwrap();
    symlink(&source, &stored.path).unwrap();
    assert!(stored.prepare_in(directory.path()).is_err());
    fs::remove_file(&stored.path).unwrap();
    let uuid_directory = stored.path.parent().unwrap();
    let moved = other.path().join("moved");
    fs::rename(uuid_directory, &moved).unwrap();
    symlink(&moved, uuid_directory).unwrap();
    assert!(stored.prepare_in(directory.path()).is_err());
    assert!(source.exists());
}
