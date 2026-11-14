//! Read-only OpenCode sign-in from the user's default Chrome profile on macOS.
//! Cookie bytes and the Chrome Safe Storage key stay in memory; no values or
//! provider responses are written to logs, settings, or the app database.
use aes::Aes128;
use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
use ring::pbkdf2;
use rusqlite::{Connection, OpenFlags};
use sha2::{Digest, Sha256};
use std::{
    fs::OpenOptions,
    io::Read,
    num::NonZeroU32,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
use zeroize::Zeroizing;

const MAX_FILE: u64 = 16 * 1024 * 1024;
const CHROME_EPOCH_MICROS: i64 = 11_644_473_600_000_000;
const NOT_SIGNED_IN: &str =
    "Sign in to OpenCode in Chrome or Coincide's browser to see its Zen balance.";
const PERMISSION: &str = "Allow Full Disk Access for Coincide to read Chrome's OpenCode sign-in.";

struct Row {
    host: String,
    name: String,
    path: String,
    encrypted: Zeroizing<Vec<u8>>,
    plain: Zeroizing<String>,
}
fn read_error(error: &std::io::Error) -> &'static str {
    if error.kind() == std::io::ErrorKind::PermissionDenied {
        PERMISSION
    } else {
        "Chrome's browser profile could not be read."
    }
}
fn open_file(path: &Path) -> Result<std::fs::File, &'static str> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|e| read_error(&e))?;
    if !file.metadata().is_ok_and(|m| m.is_file()) {
        return Err("Chrome's browser profile is invalid.");
    }
    Ok(file)
}
fn profile(root: &Path) -> Result<PathBuf, &'static str> {
    let mut file = open_file(&root.join("Local State"))?;
    if file.metadata().map_err(|e| read_error(&e))?.len() > MAX_FILE {
        return Err("Chrome's browser profile is too large.");
    }
    let mut bytes = Zeroizing::new(Vec::new());
    file.by_ref()
        .take(MAX_FILE + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| read_error(&e))?;
    if bytes.len() as u64 > MAX_FILE {
        return Err("Chrome's browser profile is too large.");
    }
    let value: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| "Chrome's browser profile is invalid.")?;
    let name = value["profile"]["last_used"].as_str().unwrap_or("Default");
    if name.len() > 80
        || name.is_empty()
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b' ' || b == b'_' || b == b'-')
    {
        return Err("Chrome's active profile cannot be identified safely.");
    }
    let path = root.join(name);
    if std::fs::symlink_metadata(&path)
        .map_err(|e| read_error(&e))?
        .file_type()
        .is_symlink()
    {
        return Err("Chrome's active profile cannot be identified safely.");
    }
    Ok(path)
}
fn cookie_path(profile: &Path) -> Result<PathBuf, &'static str> {
    for path in [profile.join("Cookies"), profile.join("Network/Cookies")] {
        match open_file(&path) {
            Ok(_) => return Ok(path),
            Err(PERMISSION) => return Err(PERMISSION),
            Err(_) if !path.exists() => continue,
            Err(_) => return Err("Chrome's cookie store could not be read."),
        }
    }
    Err(NOT_SIGNED_IN)
}
fn applies(host: &str, path: &str, name: &str) -> bool {
    let matches = |target: &str| {
        target == path
            || target
                .strip_prefix(path)
                .is_some_and(|rest| path.ends_with('/') || rest.starts_with('/'))
    };
    host.trim_start_matches('.')
        .eq_ignore_ascii_case("opencode.ai")
        && !name.is_empty()
        && name.len() <= 256
        && !name
            .chars()
            .any(|c| c.is_control() || c.is_whitespace() || c == ';' || c == '=')
        && matches("/console/api/orgs")
        && matches("/console/api/billing/drawer/status")
}
fn is_session(name: &str) -> bool {
    name == "__Host-console_session"
        || name == "console_session"
        || name.starts_with("__Host-console_session.")
        || name.starts_with("console_session.")
}
fn rows(path: &Path) -> Result<(i64, Vec<Row>), &'static str> {
    let db = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )
    .map_err(|_| "Chrome's cookie store could not be read.")?;
    db.busy_timeout(Duration::from_millis(100))
        .map_err(|_| "Chrome's cookie store is busy.")?;
    let version: String = db
        .query_row("SELECT value FROM meta WHERE key='version'", [], |r| {
            r.get(0)
        })
        .map_err(|_| "Chrome's cookie store version is unavailable.")?;
    let version: i64 = version
        .parse()
        .map_err(|_| "Chrome's cookie store version is invalid.")?;
    let mut stmt = db.prepare("SELECT host_key,name,path,encrypted_value,value,expires_utc,has_expires,top_frame_site_key FROM cookies WHERE host_key IN ('opencode.ai','.opencode.ai') LIMIT 1025")
        .map_err(|_| "Chrome's cookie store format is unsupported.")?;
    let mut cursor = stmt
        .query([])
        .map_err(|_| "Chrome's cookie store could not be read.")?;
    let now = chrono::Utc::now()
        .timestamp_micros()
        .saturating_add(CHROME_EPOCH_MICROS);
    let mut result = Vec::new();
    while let Some(row) = cursor
        .next()
        .map_err(|_| "Chrome's cookie store could not be read.")?
    {
        if result.len() >= 128 {
            return Err("Chrome has too many OpenCode cookies to read safely.");
        }
        let host: String = row
            .get(0)
            .map_err(|_| "Chrome's cookie store is invalid.")?;
        let name: String = row
            .get(1)
            .map_err(|_| "Chrome's cookie store is invalid.")?;
        let path: String = row
            .get(2)
            .map_err(|_| "Chrome's cookie store is invalid.")?;
        let expires: i64 = row
            .get(5)
            .map_err(|_| "Chrome's cookie store is invalid.")?;
        let has_expires: bool = row
            .get(6)
            .map_err(|_| "Chrome's cookie store is invalid.")?;
        let partition: String = row
            .get(7)
            .map_err(|_| "Chrome's cookie store is invalid.")?;
        if !applies(&host, &path, &name) || (has_expires && expires <= now) || !partition.is_empty()
        {
            continue;
        }
        let encrypted = Zeroizing::new(
            row.get::<_, Vec<u8>>(3)
                .map_err(|_| "Chrome's cookie store is invalid.")?,
        );
        let plain = Zeroizing::new(
            row.get::<_, String>(4)
                .map_err(|_| "Chrome's cookie store is invalid.")?,
        );
        if encrypted.len() > 16 * 1024
            || plain.len() > 4096
            || (!encrypted.is_empty() && !plain.is_empty())
        {
            continue;
        }
        result.push(Row {
            host,
            name,
            path,
            encrypted,
            plain,
        });
    }
    if !result.iter().any(|row| is_session(&row.name)) {
        return Err(NOT_SIGNED_IN);
    }
    Ok((version, result))
}
fn password() -> Result<Zeroizing<Vec<u8>>, &'static str> {
    let mut command = Command::new("/usr/bin/security");
    command
        .args([
            "find-generic-password",
            "-s",
            "Chrome Safe Storage",
            "-a",
            "Chrome",
            "-w",
        ])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut value = Zeroizing::new(
        crate::agent::usage_keychain_capture(command, Duration::from_secs(30)).map_err(
            |_| "Allow Coincide to use Chrome Safe Storage in Keychain to read the sign-in.",
        )?,
    );
    if value.last() == Some(&b'\n') {
        value.pop();
    }
    if value.is_empty() || value.len() > 64 * 1024 {
        return Err("Chrome's Keychain entry is invalid.");
    }
    Ok(value)
}
fn derive(password: &[u8]) -> Zeroizing<[u8; 16]> {
    let mut key = Zeroizing::new([0u8; 16]);
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA1,
        NonZeroU32::new(1003).unwrap(),
        b"saltysalt",
        password,
        &mut *key,
    );
    key
}
fn decrypt(
    data: &[u8],
    key: &[u8; 16],
    version: i64,
    host: &str,
) -> Result<Zeroizing<String>, &'static str> {
    let payload = data
        .strip_prefix(b"v10")
        .ok_or("Chrome's cookie encryption is unsupported.")?;
    if payload.is_empty() || payload.len() % 16 != 0 {
        return Err("Chrome's OpenCode sign-in is invalid.");
    }
    let mut buf = Zeroizing::new(payload.to_vec());
    let decrypted = cbc::Decryptor::<Aes128>::new(key.into(), (&[b' '; 16]).into())
        .decrypt_padded_mut::<Pkcs7>(&mut buf)
        .map_err(|_| "Chrome's OpenCode sign-in could not be unlocked.")?;
    let value = if version >= 24 {
        let (digest, value) = decrypted
            .split_at_checked(32)
            .ok_or("Chrome's OpenCode sign-in is invalid.")?;
        if digest != &Sha256::digest(host.as_bytes())[..] {
            return Err("Chrome's OpenCode sign-in did not match its host.");
        }
        value
    } else {
        decrypted
    };
    let value = std::str::from_utf8(value).map_err(|_| "Chrome's OpenCode sign-in is invalid.")?;
    if value.len() > 4096 || value.chars().any(|c| c.is_control() || c == ';') {
        return Err("Chrome's OpenCode sign-in is invalid.");
    }
    Ok(Zeroizing::new(value.to_owned()))
}
fn header(
    version: i64,
    mut rows: Vec<Row>,
    password: Option<&[u8]>,
) -> Result<Zeroizing<String>, &'static str> {
    rows.sort_by_key(|row| std::cmp::Reverse(row.path.len()));
    let key = password.map(derive);
    let mut header = Zeroizing::new(String::new());
    let mut has_session = false;
    for row in rows {
        let value = if !row.encrypted.is_empty() {
            let key = key
                .as_deref()
                .ok_or("Chrome's Keychain sign-in is unavailable.")?;
            decrypt(&row.encrypted, key, version, &row.host)?
        } else {
            row.plain
        };
        if value.len() > 4096 || value.chars().any(|c| c.is_control() || c == ';') {
            continue;
        }
        if !header.is_empty() {
            header.push_str("; ");
        }
        header.push_str(&row.name);
        header.push('=');
        header.push_str(&value);
        has_session |= is_session(&row.name);
        if header.len() > 32768 {
            return Err("Chrome has too many OpenCode cookies to read safely.");
        }
    }
    if !has_session {
        return Err(NOT_SIGNED_IN);
    }
    Ok(header)
}
/// Call only after native UI has verified that Chrome is the system default and
/// the user enabled browser fallback. This never writes to Chrome's profile.
pub(crate) fn opencode_header() -> Result<Zeroizing<String>, &'static str> {
    let home = std::env::var_os("HOME").ok_or("Chrome's home folder is unavailable.")?;
    let root = PathBuf::from(home).join("Library/Application Support/Google/Chrome");
    let path = cookie_path(&profile(&root)?)?;
    let (version, rows) = rows(&path)?;
    let encrypted = rows.iter().any(|row| !row.encrypted.is_empty());
    let password = if encrypted { Some(password()?) } else { None };
    header(version, rows, password.as_deref().map(|p| p.as_slice()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use cbc::cipher::BlockEncryptMut;
    fn encrypt(value: &[u8], key: &[u8; 16], host: &str, version: i64) -> Vec<u8> {
        let mut plain = if version >= 24 {
            Sha256::digest(host.as_bytes()).to_vec()
        } else {
            Vec::new()
        };
        plain.extend_from_slice(value);
        let length = plain.len();
        plain.resize(length + 16, 0);
        let encrypted = cbc::Encryptor::<Aes128>::new(key.into(), (&[b' '; 16]).into())
            .encrypt_padded_mut::<Pkcs7>(&mut plain, length)
            .unwrap();
        [b"v10".as_slice(), encrypted].concat()
    }
    #[test]
    fn chrome_cookie_decryption_validates_the_host_and_version() {
        let key = derive(b"synthetic password");
        let encrypted = encrypt(b"synthetic-session", &key, ".opencode.ai", 24);
        assert_eq!(
            decrypt(&encrypted, &key, 24, ".opencode.ai")
                .unwrap()
                .as_str(),
            "synthetic-session"
        );
        assert!(decrypt(&encrypted, &key, 24, "opencode.ai").is_err());
        let old = encrypt(b"synthetic-session", &key, "opencode.ai", 23);
        assert_eq!(
            decrypt(&old, &key, 23, "opencode.ai").unwrap().as_str(),
            "synthetic-session"
        );
        assert!(decrypt(b"v20untrusted", &key, 24, "opencode.ai").is_err());
    }
    #[test]
    fn chrome_cookie_selection_uses_only_first_party_billing_paths() {
        assert!(applies(".opencode.ai", "/", "console_session"));
        assert!(applies("opencode.ai", "/console/api", "console_session"));
        assert!(!applies("other.example", "/", "console_session"));
        assert!(!applies("opencode.ai", "/con", "console_session"));
        assert!(!applies(
            "opencode.ai",
            "/console/api/billing",
            "console_session"
        ));
        assert!(!applies("opencode.ai", "/", "bad=name"));
    }
    #[test]
    fn chrome_fallback_reads_only_selected_unpartitioned_unexpired_workspace_cookies() {
        let temp = tempfile::tempdir().unwrap();
        let profile_dir = temp.path().join("Profile 1");
        std::fs::create_dir(&profile_dir).unwrap();
        std::fs::write(
            temp.path().join("Local State"),
            r#"{"profile":{"last_used":"Profile 1"}}"#,
        )
        .unwrap();
        assert_eq!(profile(temp.path()).unwrap(), profile_dir);
        let path = profile_dir.join("Cookies");
        let db = Connection::open(&path).unwrap();
        db.execute_batch("CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version','24'); CREATE TABLE cookies(host_key TEXT, name TEXT, path TEXT, encrypted_value BLOB, value TEXT, expires_utc INTEGER, has_expires INTEGER, top_frame_site_key TEXT);").unwrap();
        let key = derive(b"synthetic password");
        let encrypted = encrypt(b"fixture-session", &key, ".opencode.ai", 24);
        for (host, name, cookie_path, expired, partition) in [
            (".opencode.ai", "__Host-console_session", "/", false, ""),
            ("other.example", "console_session", "/", false, ""),
            (".opencode.ai", "old", "/", true, ""),
            (
                ".opencode.ai",
                "partitioned",
                "/",
                false,
                "https://other.example",
            ),
            (
                ".opencode.ai",
                "wrong_path",
                "/console/api/billing",
                false,
                "",
            ),
        ] {
            db.execute(
                "INSERT INTO cookies VALUES(?1,?2,?3,?4,'',?5,1,?6)",
                rusqlite::params![
                    host,
                    name,
                    cookie_path,
                    &encrypted,
                    if expired { 1 } else { i64::MAX },
                    partition
                ],
            )
            .unwrap();
        }
        drop(db);
        let (version, selected) = rows(&path.canonicalize().unwrap()).unwrap();
        assert_eq!(selected.len(), 1);
        assert_eq!(
            header(version, selected, Some(b"synthetic password"))
                .unwrap()
                .as_str(),
            "__Host-console_session=fixture-session"
        );
        assert_eq!(
            read_error(&std::io::ErrorKind::PermissionDenied.into()),
            PERMISSION
        );
    }
}
