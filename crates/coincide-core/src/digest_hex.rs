//! Stable lowercase byte encoding for persisted SHA-256 identities/checksums.
//! Keep independent of digest output-container formatting traits.
pub(crate) fn lower_hex(bytes: impl AsRef<[u8]>) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let bytes = bytes.as_ref();
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        encoded.push(DIGITS[(byte >> 4) as usize] as char);
        encoded.push(DIGITS[(byte & 15) as usize] as char);
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    #[test]
    fn sha256_fips_vectors_keep_exact_persisted_lowercase_hex() {
        for (input, expected) in [
            (
                "",
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            ),
            (
                "abc",
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
            ),
        ] {
            assert_eq!(lower_hex(Sha256::digest(input.as_bytes())), expected);
            let mut streamed = Sha256::new();
            for chunk in input.as_bytes().chunks(7) {
                streamed.update(chunk);
            }
            assert_eq!(lower_hex(streamed.finalize()), expected);
        }
    }
}
