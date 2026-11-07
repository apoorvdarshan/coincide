//! `RemoteCrypto` from CoincideRemoteKit: random tokens, SHA-256 hex,
//! constant-time comparison and base64url, so tokens, hashes and fingerprints
//! read the same on both sides.
use base64::Engine as _;
use ring::rand::{SecureRandom, SystemRandom};
use sha2::{Digest, Sha256};

/// `count` random bytes, base64url without padding.
pub fn random_token(count: usize) -> String {
    let mut bytes = vec![0u8; count];
    SystemRandom::new()
        .fill(&mut bytes)
        .expect("the system random number generator is unavailable");
    base64_url(&bytes)
}

pub fn sha256_hex(data: &[u8]) -> String {
    crate::digest_hex::lower_hex(Sha256::digest(data))
}

/// Compares without returning early, so timing doesn't tell how much of a
/// secret matched.
pub fn constant_time_equals(lhs: &str, rhs: &str) -> bool {
    let (a, b) = (lhs.as_bytes(), rhs.as_bytes());
    let mut difference = u8::from(a.len() != b.len());
    for index in 0..a.len().max(b.len()) {
        difference |= a.get(index).copied().unwrap_or(0) ^ b.get(index).copied().unwrap_or(0);
    }
    difference == 0
}

pub fn base64_url(data: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

/// Accepts padded or unpadded base64url, as `RemoteCrypto.data(base64URL:)` does.
pub fn from_base64_url(string: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(string.trim_end_matches('='))
        .ok()
}

/// A fingerprint grouped for reading aloud, such as `AB12 CD34 …`.
pub fn display_fingerprint(hex: &str, groups: usize) -> String {
    let upper = hex.to_uppercase();
    let chars = upper.chars().collect::<Vec<_>>();
    chars
        .chunks(4)
        .take(groups)
        .map(|chunk| chunk.iter().collect::<String>())
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn helpers_match_remote_crypto() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert!(constant_time_equals("token", "token"));
        assert!(!constant_time_equals("token", "tokem"));
        assert!(!constant_time_equals("token", "token2"));
        assert!(!constant_time_equals("", "a"));
        let token = random_token(32);
        assert_eq!(token.len(), 43);
        assert!(!token.contains(['=', '+', '/']));
        assert_eq!(from_base64_url(&token).unwrap().len(), 32);
        assert_eq!(from_base64_url("aGk="), Some(b"hi".to_vec()));
        assert_eq!(base64_url(&[0xfb, 0xff]), "-_8");
        assert_eq!(display_fingerprint("ab12cd34ef56", 2), "AB12 CD34");
        assert_eq!(
            display_fingerprint(&"a".repeat(64), 8).split(' ').count(),
            8
        );
    }
}
