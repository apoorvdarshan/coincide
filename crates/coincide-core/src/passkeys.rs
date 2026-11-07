//! Passkey sign-in for the embedded browser, ported from the Swift app
//! (`CoincideKit/Preview/Passkeys.swift` and `Preview/WebAuthn`).
//!
//! WebViews hand a page's `navigator.credentials` request to the platform, which
//! on macOS serves arbitrary sites only for apps signed with Apple's managed
//! browser passkey entitlement; this developer account can't get it. So, as in
//! the Swift app, Coincide answers sign-in requests itself with passkeys saved in
//! the user's Bitwarden vault, the way Bitwarden's browser extension does in
//! browsers it can't change, and tells the agent and the user when a page asked
//! for a passkey nobody here could provide.
//!
//! Trusted native boundary, like `credentials`: the origin always comes from the
//! WebView's record of the requesting frame, never from the page; the private key
//! is read from `bw` for one signature and never reaches the page or an agent API.
#[path = "passkeys_suffixes.rs"]
mod suffixes;
pub use suffixes::PublicSuffixList;

use crate::credentials::{Failure, VaultCommand, valid_id};
use ring::{
    digest,
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_ASN1_SIGNING, EcdsaKeyPair},
};
use serde_json::{Map, Value, json};
use std::{cmp::Ordering, time::Duration};
use url::Url;
use zeroize::Zeroizing;

/// base64url (RFC 4648 §5), as WebAuthn and Bitwarden write binary values.
/// Encoding never pads. Decoding also takes padding and the standard alphabet, as
/// Bitwarden's own decoder does, so imported vault values read the same.
pub mod base64url {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    pub fn encode(data: &[u8]) -> String {
        let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
        for chunk in data.chunks(3) {
            let n = (u32::from(chunk[0]) << 16)
                | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
                | u32::from(*chunk.get(2).unwrap_or(&0));
            for index in 0..=chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * index) & 63) as usize] as char);
            }
        }
        out
    }

    pub fn decode(text: &str) -> Option<Vec<u8>> {
        let mut body = text.as_bytes();
        let mut padding = 0;
        while padding < 2 && body.last() == Some(&b'=') {
            body = &body[..body.len() - 1];
            padding += 1;
        }
        let remainder = body.len() % 4;
        if remainder == 1 || (padding != 0 && !(remainder + padding).is_multiple_of(4)) {
            return None;
        }
        let mut out = Vec::with_capacity(body.len() * 3 / 4);
        let (mut value, mut bits) = (0_u32, 0);
        for &byte in body {
            let digit = match byte {
                b'A'..=b'Z' => byte - b'A',
                b'a'..=b'z' => byte - b'a' + 26,
                b'0'..=b'9' => byte - b'0' + 52,
                b'-' | b'+' => 62,
                b'_' | b'/' => 63,
                _ => return None,
            };
            value = (value << 6 | u32::from(digit)) & 0xff_ffff;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((value >> bits) as u8);
            }
        }
        Some(out)
    }
}

/// The origin of the frame that asked for a passkey, from the WebView's own record
/// of it (never from the page). Only origins where WebAuthn may run exist: https,
/// and plain http on `localhost` for local development, as browsers allow. IP
/// addresses aren't domains, so they can't be relying parties.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct WebAuthnOrigin {
    scheme: String,
    host: String,
    /// None for the scheme's default port.
    port: Option<u16>,
}

impl WebAuthnOrigin {
    /// From a security origin's parts (`port` 0 meaning the default).
    pub fn new(scheme: &str, host: &str, port: u32) -> Option<Self> {
        let (scheme, host) = (scheme.to_lowercase(), host.to_lowercase());
        if !is_domain(&host) || port > 65_535 {
            return None;
        }
        match scheme.as_str() {
            "https" if host == "localhost" || host.contains('.') => {}
            "http" if host == "localhost" => {}
            _ => return None,
        }
        let default = if scheme == "https" { 443 } else { 80 };
        let port = (port != 0 && port != default).then_some(port as u16);
        Some(Self { scheme, host, port })
    }

    /// From an address, for checking a frame's document address against its
    /// security origin.
    pub fn from_url(url: &str) -> Option<Self> {
        let url = Url::parse(url).ok()?;
        Self::new(
            url.scheme(),
            url.host_str()?,
            url.port().map_or(0, u32::from),
        )
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    /// As `clientDataJSON` names it: `https://example.com`, `http://localhost:3000`.
    pub fn serialized(&self) -> String {
        match self.port {
            Some(port) => format!("{}://{}:{port}", self.scheme, self.host),
            None => format!("{}://{}", self.scheme, self.host),
        }
    }
}

/// The host of an http or https page address, which notices are kept for; None
/// for other pages (`about:blank`, files).
pub fn page_host(address: &str) -> Option<String> {
    let url = Url::parse(address).ok()?;
    matches!(url.scheme(), "http" | "https")
        .then(|| url.host_str().map(str::to_owned))
        .flatten()
}

/// A lowercase ASCII domain name: labels of letters, digits, `-` and `_`, not an IP
/// address (no last label that is a number, as the URL standard reads `1.2.3.4`
/// and `0x7f.1`).
fn is_domain(text: &str) -> bool {
    let Some(labels) = suffixes::labels(text) else {
        return false;
    };
    if text != text.to_lowercase()
        || !labels.iter().all(|label| {
            label
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
        })
    {
        return false;
    }
    let last = labels.last().map(String::as_str).unwrap_or_default();
    let numeric = last.bytes().all(|b| b.is_ascii_digit())
        || last
            .strip_prefix("0x")
            .is_some_and(|hex| hex.bytes().all(|b| b.is_ascii_hexdigit()));
    !numeric
}

/// Which relying party ID a page may use, by WebAuthn's rule (the RP ID must equal
/// the origin's host or be a registrable domain suffix of it), with the Public
/// Suffix List deciding what is registrable. Returns the RP ID for a request from
/// `origin` that named `requested` (None: the origin's host), or None when the
/// request must fail with a SecurityError. A public suffix is never allowed, even
/// as the host itself, and neither is an RP ID above the host's registrable domain.
pub fn validate_relying_party(
    requested: Option<&str>,
    origin: &WebAuthnOrigin,
    suffixes: &PublicSuffixList,
) -> Option<String> {
    let host = origin.host.as_str();
    let rp_id = requested.unwrap_or(host);
    // RP IDs are compared and hashed exactly as written, so only the lowercase form
    // the host has can match.
    if rp_id != rp_id.to_lowercase() || !is_domain(rp_id) {
        return None;
    }
    if host == "localhost" || rp_id == "localhost" {
        return (host == rp_id).then(|| rp_id.to_owned());
    }
    if !rp_id.contains('.') || suffixes.is_public_suffix(rp_id) {
        return None;
    }
    if rp_id == host {
        return Some(rp_id.to_owned());
    }
    let registrable = suffixes.registrable_domain(host)?;
    (host.ends_with(&format!(".{rp_id}"))
        && (rp_id == registrable || rp_id.ends_with(&format!(".{registrable}"))))
    .then(|| rp_id.to_owned())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserVerificationRequirement {
    Required,
    Preferred,
    Discouraged,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mediation {
    Optional,
    Required,
    Silent,
    Conditional,
}

impl Mediation {
    fn name(self) -> &'static str {
        match self {
            Self::Optional => "optional",
            Self::Required => "required",
            Self::Silent => "silent",
            Self::Conditional => "conditional",
        }
    }
}

/// A page's `navigator.credentials.get({publicKey})`, as Coincide's page script
/// forwards it. Everything here comes from the page and is checked and bounded
/// before use; the origin is never part of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GetRequest {
    /// The script's id for the request, so an abort can name it.
    pub id: String,
    pub challenge: Vec<u8>,
    pub rp_id: Option<String>,
    pub allow_credentials: Vec<Vec<u8>>,
    pub user_verification: UserVerificationRequirement,
    /// The page's timeout in milliseconds, if it gave one.
    pub timeout_ms: Option<u64>,
    pub mediation: Mediation,
}

impl GetRequest {
    /// Generous bounds on what a page may send: Google's sign-in challenges and the
    /// credential lists of accounts with many passkeys must fit.
    pub const MAX_CHALLENGE: usize = 65_536;
    pub const MAX_ALLOWED_CREDENTIALS: usize = 256;
    /// WebAuthn's limit for a credential ID.
    pub const MAX_CREDENTIAL_ID: usize = 1_023;
    pub const MAX_RP_ID: usize = 253;

    /// The script's message: `{kind: "get", id, mediation?, publicKey: {challenge,
    /// rpId?, allowCredentials?, userVerification?, timeout?}}` with binary values
    /// in base64url. None when anything is missing, malformed or over its limit;
    /// the page then gets the browser's own behavior.
    pub fn from_message(body: &Value) -> Option<Self> {
        let id = body["id"].as_str()?;
        if body["kind"] != "get"
            || !(1..=64).contains(&id.len())
            || !id.bytes().all(|b| b.is_ascii_alphanumeric())
        {
            return None;
        }
        let options = body.get("publicKey")?.as_object()?;
        let challenge_text = options.get("challenge")?.as_str()?;
        if challenge_text.len() > Self::MAX_CHALLENGE * 2 {
            return None;
        }
        let challenge = base64url::decode(challenge_text)?;
        if !(1..=Self::MAX_CHALLENGE).contains(&challenge.len()) {
            return None;
        }
        let rp_id = match options.get("rpId") {
            None | Some(Value::Null) => None,
            Some(value) => {
                let text = value.as_str()?;
                if text.len() > Self::MAX_RP_ID {
                    return None;
                }
                Some(text.to_owned())
            }
        };
        let mut allow_credentials = Vec::new();
        match options.get("allowCredentials") {
            None | Some(Value::Null) => {}
            Some(value) => {
                let list = value.as_array()?;
                if list.len() > Self::MAX_ALLOWED_CREDENTIALS {
                    return None;
                }
                for entry in list {
                    let id_text = entry.as_object()?.get("id")?.as_str()?;
                    if id_text.len() > Self::MAX_CREDENTIAL_ID * 2 {
                        return None;
                    }
                    let credential = base64url::decode(id_text)?;
                    if !(1..=Self::MAX_CREDENTIAL_ID).contains(&credential.len()) {
                        return None;
                    }
                    // Only public-key descriptors name credentials; browsers skip
                    // other types.
                    if entry["type"].as_str().unwrap_or("public-key") != "public-key" {
                        continue;
                    }
                    if let Some(transports) = entry.get("transports").filter(|v| !v.is_null())
                        && transports.as_array().is_none_or(|list| list.len() > 16)
                    {
                        return None;
                    }
                    allow_credentials.push(credential);
                }
            }
        }
        // Unknown values mean the default, as in the specification.
        let user_verification = match options.get("userVerification").and_then(Value::as_str) {
            Some("required") => UserVerificationRequirement::Required,
            Some("discouraged") => UserVerificationRequirement::Discouraged,
            _ => UserVerificationRequirement::Preferred,
        };
        let timeout_ms = options
            .get("timeout")
            .and_then(Value::as_f64)
            .filter(|value| value.is_finite() && *value >= 0.0)
            .map(|value| value.min(u64::MAX as f64) as u64);
        let mediation = match body.get("mediation") {
            None | Some(Value::Null) => Mediation::Optional,
            Some(value) => match value.as_str()? {
                "optional" => Mediation::Optional,
                "required" => Mediation::Required,
                "silent" => Mediation::Silent,
                "conditional" => Mediation::Conditional,
                _ => return None,
            },
        };
        Some(Self {
            id: id.to_owned(),
            challenge,
            rp_id,
            allow_credentials,
            user_verification,
            timeout_ms,
            mediation,
        })
    }

    /// The shape of a message, for the log when it can't be read: sizes and the
    /// mediation only, never the values.
    pub fn summary(body: &Value) -> String {
        let options = &body["publicKey"];
        let challenge = options["challenge"]
            .as_str()
            .map_or("missing".to_owned(), |text| format!("{} chars", text.len()));
        let allowed = match options.get("allowCredentials") {
            None => "none".to_owned(),
            Some(Value::Array(list)) => list.len().to_string(),
            Some(_) => "not a list".to_owned(),
        };
        let mediation = body["mediation"]
            .as_str()
            .map_or("none".to_owned(), |text| text.chars().take(16).collect());
        format!("challenge {challenge}, allowCredentials {allowed}, mediation {mediation}")
    }

    /// How long Coincide waits for the user, from the page's timeout clamped as
    /// Bitwarden clamps it: 30 seconds to 10 minutes (5 by default) when user
    /// verification is wanted, 30 seconds to 3 minutes (2 by default) when
    /// discouraged.
    pub fn wait_limit(&self) -> Duration {
        let (lower, fallback, upper) =
            if self.user_verification == UserVerificationRequirement::Discouraged {
                (30, 120, 180)
            } else {
                (30, 300, 600)
            };
        self.timeout_ms.map_or(Duration::from_secs(fallback), |ms| {
            Duration::from_millis(ms).clamp(Duration::from_secs(lower), Duration::from_secs(upper))
        })
    }
}

/// The bytes of a WebAuthn assertion (WebAuthn Level 3, §6.1 and §6.3.3).
pub mod assertion {
    use super::*;

    pub const USER_PRESENT: u8 = 0x01;
    pub const USER_VERIFIED: u8 = 0x04;
    pub const BACKUP_ELIGIBLE: u8 = 0x08;
    pub const BACKED_UP: u8 = 0x10;

    /// The client data of a sign-in, in WebAuthn's JSON-compatible serialization
    /// (§5.8.1.1): exactly these fields, in this order. `origin` is the frame's,
    /// from the WebView.
    pub fn client_data_json(challenge: &[u8], origin: &str) -> Vec<u8> {
        format!(
            r#"{{"type":"webauthn.get","challenge":{},"origin":{},"crossOrigin":false}}"#,
            quoted(&base64url::encode(challenge)),
            quoted(origin)
        )
        .into_bytes()
    }

    /// The specification's CCDToString: a JSON string with `"`, `\` and control
    /// characters escaped.
    pub(crate) fn quoted(text: &str) -> String {
        let mut out = String::from("\"");
        for c in text.chars() {
            match c {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out.push('"');
        out
    }

    /// SHA-256 of the RP ID, the flags and the big-endian signature counter; no
    /// attested credential data or extensions.
    pub fn authenticator_data(rp_id: &str, flags: u8, sign_count: u32) -> Vec<u8> {
        let mut data = digest::digest(&digest::SHA256, rp_id.as_bytes())
            .as_ref()
            .to_vec();
        data.push(flags);
        data.extend_from_slice(&sign_count.to_be_bytes());
        data
    }

    /// ES256 over `authenticator_data` followed by SHA-256 of `client_data_json`,
    /// DER-encoded as WebAuthn expects. `pkcs8` is the private key as Bitwarden
    /// stores it (PKCS#8 v1 with its public key, as WebCrypto exports it).
    pub fn signature(
        authenticator_data: &[u8],
        client_data_json: &[u8],
        pkcs8: &[u8],
    ) -> Result<Vec<u8>, Failure> {
        let rng = SystemRandom::new();
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8, &rng)
            .map_err(|_| Failure::InvalidResponse)?;
        let mut signed = authenticator_data.to_vec();
        signed.extend_from_slice(digest::digest(&digest::SHA256, client_data_json).as_ref());
        key.sign(&rng, &signed)
            .map(|signature| signature.as_ref().to_vec())
            .map_err(|_| Failure::FillFailed)
    }
}

/// Synthetic keys and the relying party's check of an assertion, for fixtures
/// that sign and verify end to end. Never used with a vault's keys.
pub mod synthetic {
    use super::*;
    use ring::signature::{ECDSA_P256_SHA256_ASN1, KeyPair, UnparsedPublicKey};

    pub struct Key {
        /// PKCS#8 v1 with its public key, as Bitwarden stores `keyValue`.
        pub pkcs8: Vec<u8>,
        /// Uncompressed SEC1 point.
        pub public: Vec<u8>,
    }

    impl Key {
        pub fn generate() -> Self {
            let rng = SystemRandom::new();
            let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng)
                .expect("system randomness")
                .as_ref()
                .to_vec();
            let public = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &pkcs8, &rng)
                .expect("generated key")
                .public_key()
                .as_ref()
                .to_vec();
            Self { pkcs8, public }
        }

        /// What a relying party checks: the ES256 signature over the
        /// authenticator data and the SHA-256 of the client data.
        pub fn verifies(
            &self,
            authenticator_data: &[u8],
            client_data: &[u8],
            signature: &[u8],
        ) -> bool {
            let mut signed = authenticator_data.to_vec();
            signed.extend_from_slice(digest::digest(&digest::SHA256, client_data).as_ref());
            UnparsedPublicKey::new(&ECDSA_P256_SHA256_ASN1, &self.public)
                .verify(&signed, signature)
                .is_ok()
        }
    }
}

/// A passkey saved in the user's Bitwarden vault, without its private key: what
/// Coincide matches against a page's request and shows the user before they
/// confirm. The key itself is read from `bw` again only after they do.
///
/// Field encodings follow Bitwarden's own clients (bitwarden/clients,
/// `fido2-authenticator.service.ts`, `credential-id-utils.ts`,
/// `fido2-credential.export.ts`): `bw` writes `counter` and `discoverable` as
/// strings, a credential ID is either a GUID or `b64.` and base64url, and only an
/// item's first passkey is used.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct BitwardenPasskey {
    pub item_id: String,
    pub item_name: String,
    /// The account's name on the site (the passkey's user name, else the login's
    /// username).
    pub user_name: String,
    pub user_display_name: String,
    pub rp_id: String,
    /// As Bitwarden stores it, compared when the item is read again.
    pub stored_credential_id: String,
    pub credential_id: Vec<u8>,
    pub user_handle: Option<Vec<u8>>,
    pub counter: u32,
    pub discoverable: bool,
    /// Bitwarden's master password re-prompt is on for the item; Coincide then
    /// signs only after the platform's user verification succeeds.
    pub requires_reprompt: bool,
}

impl BitwardenPasskey {
    /// How the prompt names the account.
    pub fn account_name(&self) -> &str {
        [&self.user_name, &self.user_display_name, &self.item_name]
            .into_iter()
            .find(|name| !name.is_empty())
            .unwrap_or(&self.rp_id)
    }

    /// `bw list items`: every login's passkey Coincide can sign with.
    pub fn parse_list(json: &[u8]) -> Vec<Self> {
        serde_json::from_slice::<Value>(json)
            .ok()
            .and_then(|value| {
                value
                    .as_array()
                    .map(|items| items.iter().filter_map(Self::parse_item).collect())
            })
            .unwrap_or_default()
    }

    /// One item from `bw list items` or `bw get item`: a login (`type` 1), not in
    /// the trash, whose first passkey is an ES256 key (ECDSA on P-256, the only
    /// kind Bitwarden creates) with a readable credential ID and counter.
    pub fn parse_item(item: &Value) -> Option<Self> {
        let item_id = item["id"].as_str()?;
        let login = &item["login"];
        let credential = &login["fido2Credentials"][0];
        if item["type"].as_i64() != Some(1)
            || item["deletedDate"].is_string()
            || !valid_id(item_id)
            || credential["keyType"] != "public-key"
            || credential["keyAlgorithm"] != "ECDSA"
            || credential["keyCurve"] != "P-256"
        {
            return None;
        }
        let rp_id = credential["rpId"].as_str().filter(|id| !id.is_empty())?;
        let stored = credential["credentialId"].as_str()?;
        let credential_id = raw_credential_id(stored)?;
        let counter = counter(credential.get("counter"))?;
        let discoverable =
            credential["discoverable"] == "true" || credential["discoverable"] == true;
        let user_handle = credential["userHandle"]
            .as_str()
            .filter(|text| !text.is_empty())
            .and_then(base64url::decode);
        let user_name = credential["userName"]
            .as_str()
            .filter(|name| !name.is_empty())
            .or_else(|| login["username"].as_str())
            .unwrap_or_default();
        Some(Self {
            item_id: item_id.to_owned(),
            item_name: item["name"].as_str().unwrap_or_default().to_owned(),
            user_name: user_name.to_owned(),
            user_display_name: credential["userDisplayName"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
            rp_id: rp_id.to_owned(),
            stored_credential_id: stored.to_owned(),
            credential_id,
            user_handle,
            counter,
            discoverable,
            requires_reprompt: item["reprompt"].as_i64().unwrap_or(0) != 0,
        })
    }

    /// The passkeys that may answer a request for `rp_id`: with `allow_credentials`,
    /// those whose credential ID it names; without, the discoverable ones. The RP
    /// ID must match exactly, as Bitwarden compares it. Sorted by account.
    pub fn matching(passkeys: &[Self], rp_id: &str, allow_credentials: &[Vec<u8>]) -> Vec<Self> {
        let mut matches: Vec<Self> = passkeys
            .iter()
            .filter(|passkey| {
                passkey.rp_id == rp_id
                    && if allow_credentials.is_empty() {
                        passkey.discoverable
                    } else {
                        allow_credentials.contains(&passkey.credential_id)
                    }
            })
            .cloned()
            .collect();
        matches.sort_by(|lhs, rhs| {
            standard_compare(lhs.account_name(), rhs.account_name())
                .then_with(|| standard_compare(&lhs.item_name, &rhs.item_name))
        });
        matches
    }
}

/// `counter` as `bw` writes it, a decimal string; empty counts as 0 like
/// Bitwarden. A value that isn't a 32-bit count makes the passkey unusable rather
/// than guessed.
fn counter(value: Option<&Value>) -> Option<u32> {
    match value {
        None | Some(Value::Null) => Some(0),
        Some(Value::String(text)) => {
            let text = text.trim();
            if text.is_empty() {
                Some(0)
            } else {
                text.parse().ok()
            }
        }
        Some(Value::Number(number)) => {
            number
                .as_u64()
                .and_then(|n| u32::try_from(n).ok())
                .or_else(|| {
                    number
                        .as_f64()
                        .filter(|n| *n >= 0.0 && *n <= f64::from(u32::MAX) && n.fract() == 0.0)
                        .map(|n| n as u32)
                })
        }
        Some(_) => None,
    }
}

/// Finder-like ordering, as `localizedStandardCompare` sorts accounts: case
/// folded, with runs of digits compared by value.
fn standard_compare(lhs: &str, rhs: &str) -> Ordering {
    let (mut a, mut b) = (lhs.chars().peekable(), rhs.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let take = |chars: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut digits = String::new();
                    while let Some(c) = chars.next_if(char::is_ascii_digit) {
                        digits.push(c);
                    }
                    digits.trim_start_matches('0').to_owned()
                };
                let (x, y) = (take(&mut a), take(&mut b));
                let order = x.len().cmp(&y.len()).then_with(|| x.cmp(&y));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

/// Bitwarden's stored credential IDs: `b64.` followed by base64url of the raw ID
/// (passkeys Bitwarden imported), or a GUID whose 16 bytes are the raw ID
/// (passkeys Bitwarden created).
pub fn raw_credential_id(stored: &str) -> Option<Vec<u8>> {
    if let Some(encoded) = stored.strip_prefix("b64.") {
        return base64url::decode(encoded)
            .filter(|data| !data.is_empty() && data.len() <= GetRequest::MAX_CREDENTIAL_ID);
    }
    if stored.len() != 36 {
        return None;
    }
    uuid::Uuid::try_parse(stored)
        .ok()
        .map(|id| id.as_bytes().to_vec())
}

/// A signed sign-in, ready for the page. Holds no key material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PasskeyAssertion {
    pub credential_id: Vec<u8>,
    pub authenticator_data: Vec<u8>,
    pub signature: Vec<u8>,
    pub user_handle: Option<Vec<u8>>,
}

/// Where passkeys come from: Bitwarden in the app, a fake in tests. Both calls
/// run `bw` and belong on a background worker.
pub trait PasskeyVault {
    /// Whether the vault can answer now, checked without running anything.
    fn ready(&self) -> bool {
        true
    }
    /// Every usable passkey, without private keys.
    fn passkeys(&self) -> Result<Vec<BitwardenPasskey>, Failure>;
    /// Signs in with `passkey` for `rp_id`, reading its private key only now.
    fn assertion(
        &self,
        passkey: &BitwardenPasskey,
        rp_id: &str,
        client_data_json: &[u8],
        user_verified: bool,
    ) -> Result<PasskeyAssertion, Failure>;
}

/// The user's Bitwarden vault through its CLI. Like `credentials::Vault`, this
/// never unlocks, logs in or locks; it only ever edits a used passkey's counter.
pub struct BitwardenPasskeys<R> {
    runner: R,
}

impl<R: VaultCommand> BitwardenPasskeys<R> {
    pub fn new(runner: R) -> Self {
        Self { runner }
    }
}

impl<R: VaultCommand> PasskeyVault for BitwardenPasskeys<R> {
    /// An unlocked session, checked without starting `bw`: the Bitwarden CLI
    /// reads it from `BW_SESSION`, which the app inherits from where it started.
    fn ready(&self) -> bool {
        std::env::var_os("BW_SESSION").is_some_and(|session| !session.is_empty())
    }

    /// `bw` can't list only passkeys or leave out fields, so this reads the vault's
    /// item list and keeps only the passkeys' public details; the output is erased
    /// when it returns.
    fn passkeys(&self) -> Result<Vec<BitwardenPasskey>, Failure> {
        let output = Zeroizing::new(self.runner.run(&["list", "items", "--nointeraction"])?);
        let parsed =
            serde_json::from_slice::<Value>(&output).map_err(|_| Failure::InvalidResponse)?;
        let items = parsed.as_array().ok_or(Failure::InvalidResponse)?;
        Ok(items
            .iter()
            .filter_map(BitwardenPasskey::parse_item)
            .collect())
    }

    /// Reads the passkey's item again, checks it is still the passkey the user
    /// chose for `rp_id`, signs, and counts the use the way Bitwarden does: a
    /// counter above 0 is synced first, incremented, and saved back before the
    /// assertion is returned (none is returned if saving fails); a counter of 0
    /// stays 0. The private key is decoded only here and erased after signing.
    fn assertion(
        &self,
        passkey: &BitwardenPasskey,
        rp_id: &str,
        client_data_json: &[u8],
        user_verified: bool,
    ) -> Result<PasskeyAssertion, Failure> {
        if !valid_id(&passkey.item_id) {
            return Err(Failure::NotFound);
        }
        // Another device may have advanced the counter since this copy of the vault
        // was synced.
        if passkey.counter > 0 {
            self.runner.run(&["sync", "--nointeraction"])?;
        }
        let output = Zeroizing::new(self.runner.run(&[
            "get",
            "item",
            &passkey.item_id,
            "--nointeraction",
        ])?);
        let item: Value = serde_json::from_slice(&output).map_err(|_| Failure::InvalidResponse)?;
        let current = BitwardenPasskey::parse_item(&item).ok_or(Failure::NotFound)?;
        if current.item_id != passkey.item_id
            || current.stored_credential_id != passkey.stored_credential_id
            || current.rp_id != rp_id
            || (!user_verified && current.requires_reprompt)
        {
            return Err(Failure::NotFound);
        }
        let counter = next_counter(current.counter)?;
        let mut flags = assertion::USER_PRESENT | assertion::BACKUP_ELIGIBLE | assertion::BACKED_UP;
        if user_verified {
            flags |= assertion::USER_VERIFIED;
        }
        let authenticator_data = assertion::authenticator_data(rp_id, flags, counter);
        let key = item["login"]["fido2Credentials"][0]["keyValue"]
            .as_str()
            .and_then(base64url::decode)
            .map(Zeroizing::new)
            .ok_or(Failure::NotFound)?;
        let signature = assertion::signature(&authenticator_data, client_data_json, &key)?;
        drop(key);
        if counter != current.counter {
            let edited = Zeroizing::new(
                serde_json::to_vec(&item_setting_counter(&item, counter).ok_or(Failure::NotFound)?)
                    .map_err(|_| Failure::InvalidResponse)?,
            );
            let encoded = Zeroizing::new(standard_base64(&edited));
            let saved = Zeroizing::new(self.runner.run_with_input(
                &["edit", "item", &passkey.item_id, "--nointeraction"],
                encoded.as_bytes(),
            )?);
            let saved: Value =
                serde_json::from_slice(&saved).map_err(|_| Failure::InvalidResponse)?;
            if BitwardenPasskey::parse_item(&saved).map(|saved| saved.counter) != Some(counter) {
                return Err(Failure::FillFailed);
            }
        }
        Ok(PasskeyAssertion {
            credential_id: current.credential_id,
            authenticator_data,
            signature,
            user_handle: current.user_handle,
        })
    }
}

/// Bitwarden's signature counter rule: 0 stays 0 (Bitwarden's synced passkeys
/// don't count), anything else goes up by one. Fails when the count can't go
/// higher.
pub fn next_counter(counter: u32) -> Result<u32, Failure> {
    match counter {
        0 => Ok(0),
        u32::MAX => Err(Failure::FillFailed),
        counter => Ok(counter + 1),
    }
}

/// `item` (from `bw get item`) with its first passkey's counter set, for
/// `bw edit item`.
pub fn item_setting_counter(item: &Value, counter: u32) -> Option<Value> {
    let mut item = item.clone();
    let first = item
        .get_mut("login")?
        .get_mut("fido2Credentials")?
        .as_array_mut()?
        .first_mut()?
        .as_object_mut()?;
    first.insert("counter".into(), Value::String(counter.to_string()));
    Some(item)
}

/// `bw edit` takes the item as standard, padded base64 of its JSON.
fn standard_base64(data: &[u8]) -> String {
    let mut text = base64url::encode(data).replace('-', "+").replace('_', "/");
    while !text.len().is_multiple_of(4) {
        text.push('=');
    }
    text
}

/// A `PublicKeyCredential` for the page to build: the selected credential's ID,
/// the exact client data that was signed, the authenticator data and signature,
/// and the user handle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PasskeyCredential {
    pub assertion: PasskeyAssertion,
    pub client_data_json: Vec<u8>,
}

/// What Coincide's page script does with a passkey request after asking: return a
/// credential, reject with a `DOMException`, or hand the request to the browser's
/// own `navigator.credentials.get` (which, without the platform's passkey
/// entitlement, fails and shows the "Passkeys aren't available" notice).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WebAuthnReply {
    Credential(PasskeyCredential),
    Fallback,
    Failure {
        name: &'static str,
        message: &'static str,
    },
}

impl WebAuthnReply {
    pub const NOT_ALLOWED: Self = Self::Failure {
        name: "NotAllowedError",
        message: "The operation either timed out or was not allowed.",
    };
    pub const PENDING: Self = Self::Failure {
        name: "NotAllowedError",
        message: "A request is already pending.",
    };
    pub const INVALID_RP_ID: Self = Self::Failure {
        name: "SecurityError",
        message: "The relying party ID is not a registrable domain suffix of, nor equal to the current domain.",
    };

    /// The reply for the page script: strings only, binary values in base64url.
    pub fn message(&self) -> Map<String, Value> {
        let mut message = Map::new();
        match self {
            Self::Credential(credential) => {
                let assertion = &credential.assertion;
                message.insert("status".into(), json!("ok"));
                message.insert(
                    "id".into(),
                    json!(base64url::encode(&assertion.credential_id)),
                );
                message.insert(
                    "clientDataJSON".into(),
                    json!(base64url::encode(&credential.client_data_json)),
                );
                message.insert(
                    "authenticatorData".into(),
                    json!(base64url::encode(&assertion.authenticator_data)),
                );
                message.insert(
                    "signature".into(),
                    json!(base64url::encode(&assertion.signature)),
                );
                if let Some(handle) = &assertion.user_handle {
                    message.insert("userHandle".into(), json!(base64url::encode(handle)));
                }
            }
            Self::Fallback => {
                message.insert("status".into(), json!("fallback"));
            }
            Self::Failure {
                name,
                message: text,
            } => {
                message.insert("status".into(), json!("error"));
                message.insert("name".into(), json!(name));
                message.insert("message".into(), json!(text));
            }
        }
        message
    }
}

/// "Sign in to github.com as octocat with your Bitwarden passkey?", and the
/// accounts to pick from when several match.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SignInPrompt {
    /// The relying party ID: the site the passkey belongs to.
    pub site: String,
    /// The host of the page that asked, shown when it isn't the site itself
    /// (`accounts.google.com` for `google.com`).
    pub requester: String,
    pub choices: Vec<BitwardenPasskey>,
    /// The platform's user verification follows the click, whichever account is
    /// chosen.
    pub verifies_user: bool,
    /// How the platform verifies the user, as the prompt names it ("Touch ID or
    /// your Mac password"); None where Coincide can't verify the user.
    pub verifier: Option<&'static str>,
}

impl SignInPrompt {
    pub fn title(&self) -> String {
        match self.choices.as_slice() {
            [only] => format!(
                "Sign in to {} as {} with your Bitwarden passkey?",
                self.site,
                only.account_name()
            ),
            _ => format!("Sign in to {} with your Bitwarden passkey?", self.site),
        }
    }

    /// Who asked when it isn't the site, whether to pick an account, and whether
    /// user verification comes next; empty when there is nothing to add.
    pub fn detail(&self) -> String {
        let mut parts = Vec::new();
        if self.requester != self.site {
            parts.push(format!("The request comes from {}.", self.requester));
        }
        if self.choices.len() > 1 {
            parts.push("Choose an account.".to_owned());
        }
        if self.verifies_user {
            parts.push(match self.verifier {
                Some(verifier) => format!("You’ll confirm with {verifier} next."),
                None => "This site or Bitwarden item asks to verify you, which Coincide can’t do on this computer, so it may refuse this sign-in.".to_owned(),
            });
        }
        parts.join(" ")
    }

    /// For the account picker: the account, with the Bitwarden item it is saved in
    /// when that says more.
    pub fn label(&self, passkey: &BitwardenPasskey) -> String {
        let name = passkey.account_name();
        if passkey.item_name.is_empty() || passkey.item_name == name {
            return name.to_owned();
        }
        format!("{name} · {}", passkey.item_name)
    }

    /// Completes the platform's "Coincide is trying to …" verification dialog.
    pub fn verification_reason(&self) -> String {
        format!("sign in to {} with your Bitwarden passkey", self.site)
    }
}

/// The outcome of asking the platform to verify the user.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UserVerification {
    Verified,
    /// This computer can't verify the user; only the click confirmed the sign-in.
    Unavailable,
    /// The user cancelled or failed.
    Failed,
}

/// Answering a page's passkey request, Bitwarden's browser extension's way, but
/// only after the user clicks Sign In, which is the user presence the assertion
/// reports. User verification follows when the user asked for it on every
/// sign-in, the site requires it, or a matching Bitwarden item has master password
/// re-prompt on; the assertion says the user was verified only when that
/// succeeded. The steps are separate so the app can show its prompt and run `bw`
/// off the UI thread between them; `answer` runs them in order.
pub mod sign_in {
    use super::*;

    /// After the request arrives: answer at once, leave it to the browser (with
    /// the reason, for the log), or list the vault's passkeys for `rp_id`.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum Start {
        Reply(WebAuthnReply),
        Fallback(String),
        List { rp_id: String },
    }

    /// `origin` is the requesting frame's, from the WebView. Requests Coincide
    /// can't serve (conditional or silent mediation, no suffix list) fall back to
    /// the browser; requests it refuses fail like a browser's.
    pub fn start(
        request: &GetRequest,
        origin: &WebAuthnOrigin,
        suffixes: Option<&PublicSuffixList>,
    ) -> Start {
        let Some(suffixes) = suffixes else {
            return Start::Fallback("the public suffix list is missing".into());
        };
        // Never sign without an explicit click: requests the page makes on its own
        // (autofill-style, silent) aren't offered.
        if !matches!(request.mediation, Mediation::Optional | Mediation::Required) {
            return Start::Fallback(format!(
                "{} mediation isn't offered",
                request.mediation.name()
            ));
        }
        match validate_relying_party(request.rp_id.as_deref(), origin, suffixes) {
            Some(rp_id) => Start::List { rp_id },
            None => Start::Reply(WebAuthnReply::INVALID_RP_ID),
        }
    }

    /// After listing: the prompt to show, or the reason the request goes to the
    /// browser. Matched by credential ID alone, whatever transports the site lists:
    /// sites describe passkeys from password managers in their own ways, so
    /// transports don't say whether Bitwarden has one, and an ID it holds does.
    pub fn offer(
        request: &GetRequest,
        origin: &WebAuthnOrigin,
        rp_id: &str,
        listed: Result<Vec<BitwardenPasskey>, Failure>,
        always_verifies_user: bool,
        verifier: Option<&'static str>,
    ) -> Result<SignInPrompt, String> {
        let all = listed.map_err(|_| "Bitwarden didn't list its passkeys".to_owned())?;
        let matches = BitwardenPasskey::matching(&all, rp_id, &request.allow_credentials);
        if matches.is_empty() {
            return Err(format!(
                "none of {} Bitwarden passkeys matches {}",
                all.len(),
                if request.allow_credentials.is_empty() {
                    "the site".to_owned()
                } else {
                    format!("{} allowed credentials", request.allow_credentials.len())
                }
            ));
        }
        // Decided before asking, so the prompt can say whether verification comes
        // next: a re-prompt item among the choices makes every choice verify.
        let verifies_user = always_verifies_user
            || request.user_verification == UserVerificationRequirement::Required
            || matches.iter().any(|passkey| passkey.requires_reprompt);
        Ok(SignInPrompt {
            site: rp_id.to_owned(),
            requester: origin.host.clone(),
            choices: matches,
            verifies_user,
            verifier,
        })
    }

    /// After the user verification step, or right after the click when there is
    /// none: whether the assertion may say the user was verified, or the refusal.
    pub fn verified(
        request: &GetRequest,
        choice: &BitwardenPasskey,
        outcome: Option<UserVerification>,
    ) -> Result<bool, WebAuthnReply> {
        match outcome {
            None | Some(UserVerification::Unavailable)
                if request.user_verification == UserVerificationRequirement::Required
                    || choice.requires_reprompt =>
            {
                Err(WebAuthnReply::NOT_ALLOWED)
            }
            None | Some(UserVerification::Unavailable) => Ok(false),
            Some(UserVerification::Verified) => Ok(true),
            Some(UserVerification::Failed) => Err(WebAuthnReply::NOT_ALLOWED),
        }
    }

    /// The exact client data the assertion signs and the page receives.
    pub fn client_data(request: &GetRequest, origin: &WebAuthnOrigin) -> Vec<u8> {
        assertion::client_data_json(&request.challenge, &origin.serialized())
    }

    /// After signing: the credential for the page, or a browser-like refusal.
    pub fn finish(
        client_data_json: Vec<u8>,
        signed: Result<PasskeyAssertion, Failure>,
    ) -> WebAuthnReply {
        match signed {
            Ok(assertion) => WebAuthnReply::Credential(PasskeyCredential {
                assertion,
                client_data_json,
            }),
            Err(_) => WebAuthnReply::NOT_ALLOWED,
        }
    }

    /// The user's side of a sign-in, for `answer`.
    pub trait Ui {
        /// The index of the passkey to sign in with, None when the user cancels.
        fn confirm(&mut self, prompt: &SignInPrompt) -> Option<usize>;
        fn verify_user(&mut self, reason: &str) -> UserVerification;
    }

    /// Every step in order, with fallbacks and refusals as the app has them. The
    /// second value is why a request went to the browser, for the log.
    pub fn answer(
        request: &GetRequest,
        origin: &WebAuthnOrigin,
        vault: &impl PasskeyVault,
        ui: &mut impl Ui,
        always_verifies_user: bool,
        verifier: Option<&'static str>,
        suffixes: Option<&PublicSuffixList>,
    ) -> (WebAuthnReply, Option<String>) {
        let rp_id = match start(request, origin, suffixes) {
            Start::Reply(reply) => return (reply, None),
            Start::Fallback(reason) => return (WebAuthnReply::Fallback, Some(reason)),
            Start::List { rp_id } => rp_id,
        };
        let prompt = match offer(
            request,
            origin,
            &rp_id,
            vault.passkeys(),
            always_verifies_user,
            verifier,
        ) {
            Ok(prompt) => prompt,
            Err(reason) => return (WebAuthnReply::Fallback, Some(reason)),
        };
        let Some(choice) = ui
            .confirm(&prompt)
            .and_then(|index| prompt.choices.get(index).cloned())
        else {
            return (WebAuthnReply::NOT_ALLOWED, None);
        };
        // The UV flag is set only when verification succeeded for this request.
        let outcome = prompt
            .verifies_user
            .then(|| ui.verify_user(&prompt.verification_reason()));
        let user_verified = match verified(request, &choice, outcome) {
            Ok(verified) => verified,
            Err(reply) => return (reply, None),
        };
        let client_data = client_data(request, origin);
        let signed = vault.assertion(&choice, &rp_id, &client_data, user_verified);
        (finish(client_data, signed), None)
    }
}

/// When a thread's browser shows "Passkeys aren't available", and how far its way
/// around it has got: on a page's first passkey request, until the user dismisses
/// it (then not again for that site in this browser) or the tab moves to another
/// site.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct NoticeState {
    notice: Option<Notice>,
    dismissed_sites: std::collections::BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notice {
    pub tab_id: String,
    pub site: String,
    pub stage: NoticeStage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoticeStage {
    /// Passkeys aren't available here; the page can open in the user's browser.
    Unavailable,
    /// The page is open in the user's browser, where their passkey works.
    OpenedElsewhere,
}

impl NoticeState {
    pub fn notice(&self) -> Option<&Notice> {
        self.notice.as_ref()
    }

    /// A passkey request from `tab_id` on `host`. The page asking again, as it may
    /// after reloading, keeps the notice where it is. True when the notice changed.
    pub fn requested(&mut self, tab_id: &str, host: &str) -> bool {
        let site = site_of(host);
        if self.dismissed_sites.contains(&site)
            || self
                .notice
                .as_ref()
                .is_some_and(|notice| notice.tab_id == tab_id && notice.site == site)
        {
            return false;
        }
        self.notice = Some(Notice {
            tab_id: tab_id.to_owned(),
            site,
            stage: NoticeStage::Unavailable,
        });
        true
    }

    /// "Open in Default Browser" ran. True when the notice changed.
    pub fn opened_elsewhere(&mut self) -> bool {
        match self.notice.as_mut() {
            Some(notice) if notice.stage != NoticeStage::OpenedElsewhere => {
                notice.stage = NoticeStage::OpenedElsewhere;
                true
            }
            _ => false,
        }
    }

    /// The ×: hides the notice and keeps it hidden for that site.
    pub fn dismiss(&mut self) {
        if let Some(notice) = self.notice.take() {
            self.dismissed_sites.insert(notice.site);
        }
    }

    /// The tab committed a page on `host`. Another site's page clears the tab's
    /// notice. True when it changed.
    pub fn navigated(&mut self, tab_id: &str, host: &str) -> bool {
        if self
            .notice
            .as_ref()
            .is_some_and(|notice| notice.tab_id == tab_id && notice.site != site_of(host))
        {
            self.notice = None;
            return true;
        }
        false
    }

    /// The tab closed. True when its notice went with it.
    pub fn closed(&mut self, tab_id: &str) -> bool {
        if self
            .notice
            .as_ref()
            .is_some_and(|notice| notice.tab_id == tab_id)
        {
            self.notice = None;
            return true;
        }
        false
    }

    /// What the notice says at its stage, and its action button.
    pub fn content(notice: &Notice) -> (String, Option<&'static str>) {
        match notice.stage {
            NoticeStage::Unavailable => (
                "Passkeys aren’t available in Coincide’s browser for this sign-in. Sign in with your passkey in your default browser, or choose another way to sign in (like “Try another way” on Google), then fill your password from your password manager.".into(),
                Some("Open in Default Browser"),
            ),
            NoticeStage::OpenedElsewhere => (
                format!("Opened {} in your default browser, where your passkey works. Coincide can’t import that sign-in yet, so to stay signed in here choose another way to sign in.", notice.site),
                None,
            ),
        }
    }
}

fn site_of(host: &str) -> String {
    PublicSuffixList::bundled()
        .map(|list| list.site_or_host(host))
        .unwrap_or_else(|| host.to_lowercase())
}

/// What an agent's `read` says after the page asked for a passkey nobody here
/// could provide. Agent-facing, so not localized.
pub const AGENT_NOTE: &str = "This page asked for a passkey that Coincide's browser couldn't provide, so that request failed: Coincide signs in with passkeys only when they are saved in Bitwarden and Bitwarden is unlocked. Choose another way to sign in (such as \"Try another way\"). Filling a saved password needs the user's approval in Coincide, so ask the user to fill it, or to finish this sign-in with their passkey in their own browser.";

/// Message handler for `DETECTION_SCRIPT`.
pub const DETECTION_HANDLER: &str = "coincidePasskey";
/// The sign-in message handler, which replies to each message.
pub const SIGN_IN_HANDLER: &str = "coincideBitwardenPasskey";

/// Wraps `navigator.credentials.get` and `create` in the page's own script world
/// (the only place a page's calls can be seen). Each wrapper reports a request that
/// carries `publicKey` options, then calls the original with the same `this` and
/// arguments and returns exactly what it returns: the same promise, so the same
/// credential or error, and a synchronous exception propagates unchanged. Requests
/// without `publicKey` (passwords, federated sign-in, OTP) are not reported.
/// Nothing is installed where the WebView has no credentials API or no handler.
/// The Swift app's script, unchanged.
pub const DETECTION_SCRIPT: &str = include_str!("passkeys_detection.js");

/// Coincide's WebAuthn page script, the way Bitwarden's browser extension answers
/// passkey requests in browsers it can't change: it replaces
/// `navigator.credentials.get` in the page's own script world (the only place
/// pages' calls can be answered) and forwards public-key requests to Coincide,
/// which checks the frame's origin itself. The Swift app's script, unchanged.
///
/// Installed at document start in main frames, after `DETECTION_SCRIPT`, so the
/// `get` it falls back to is the detection wrapper and an unanswered request still
/// shows the notice. It captures everything it uses before the page runs; returns
/// credentials built on the real prototypes, so `instanceof` checks pass; rejects
/// with the `DOMException` names browsers use; honors `signal`; and gives up when
/// Coincide never answers. `create` (registration) is left alone. Pages on other
/// origins than https (or http on localhost) and opaque origins get nothing.
pub const SIGN_IN_SCRIPT: &str = include_str!("passkeys_sign_in.js");

#[cfg(test)]
#[path = "passkeys_tests.rs"]
mod tests;
