//! The remote server's TLS identity: a P-256 key and a self-signed certificate
//! made once and kept in the system secret store, as `RemoteIdentity.swift`
//! keeps them in the login Keychain. Phones pin the certificate's SHA-256 when
//! they pair, so it stays the same across launches and updates; resetting it
//! makes every paired phone pair again.
use super::secrets::SecretBackend;
use anyhow::{Context, Result};
use base64::Engine as _;
use ring::{
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_ASN1_SIGNING, EcdsaKeyPair, KeyPair},
};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

/// The certificate's common name, as the Mac's is "Coincide Remote".
pub const LABEL: &str = "Coincide Remote";
const ENTRY: &str = "tls-identity";

pub struct Identity {
    /// PKCS#8 private key.
    pub key: Zeroizing<Vec<u8>>,
    pub certificate: Vec<u8>,
}
impl std::fmt::Debug for Identity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Identity")
            .field("fingerprint", &self.fingerprint())
            .finish_non_exhaustive()
    }
}

#[derive(Serialize, Deserialize)]
struct Saved {
    key: String,
    certificate: String,
}

impl Identity {
    /// Lowercase hex SHA-256 of the certificate, which the pairing code carries.
    pub fn fingerprint(&self) -> String {
        super::crypto::sha256_hex(&self.certificate)
    }

    /// The saved identity, or a new one made and saved now.
    pub fn load_or_create(secrets: &dyn SecretBackend) -> Result<Self> {
        if let Some(saved) = secrets.read(ENTRY)?
            && let Ok(saved) = serde_json::from_slice::<Saved>(&saved)
        {
            let engine = base64::engine::general_purpose::STANDARD;
            let identity = Self {
                key: Zeroizing::new(engine.decode(saved.key)?),
                certificate: engine.decode(saved.certificate)?,
            };
            if identity.validate().is_ok() {
                return Ok(identity);
            }
        }
        let identity = Self::create()?;
        let engine = base64::engine::general_purpose::STANDARD;
        let saved = Zeroizing::new(serde_json::to_vec(&Saved {
            key: engine.encode(&*identity.key),
            certificate: engine.encode(&identity.certificate),
        })?);
        secrets
            .write(ENTRY, &saved)
            .context("Coincide couldn’t save the remote server’s certificate")?;
        Ok(identity)
    }

    /// Forgets the key and certificate, so the next start makes new ones.
    pub fn reset(secrets: &dyn SecretBackend) -> Result<()> {
        secrets.delete(ENTRY)
    }

    pub fn create() -> Result<Self> {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, &rng)
            .ok()
            .context("Coincide couldn’t make a key for the remote server.")?;
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_ASN1_SIGNING, pkcs8.as_ref(), &rng)
            .ok()
            .context("Coincide couldn’t make a key for the remote server.")?;
        let mut serial = [0u8; 12];
        ring::rand::SecureRandom::fill(&rng, &mut serial)
            .ok()
            .context("Coincide couldn’t make a certificate for the remote server.")?;
        // Positive and without leading zero bytes, as the Mac's serials are.
        for byte in &mut serial {
            *byte = (*byte % 0x7F) + 1;
        }
        let now = chrono::Utc::now();
        let certificate = self_signed_certificate(
            LABEL,
            pair.public_key().as_ref(),
            &serial,
            now - chrono::Duration::days(1),
            now + chrono::Duration::days(20 * 365),
            |tbs| {
                pair.sign(&rng, tbs)
                    .map(|s| s.as_ref().to_vec())
                    .ok()
                    .context("Coincide couldn’t make a certificate for the remote server.")
            },
        )?;
        Ok(Self {
            key: Zeroizing::new(pkcs8.as_ref().to_vec()),
            certificate,
        })
    }

    /// Rejects a damaged saved identity, which is then made again.
    fn validate(&self) -> Result<()> {
        EcdsaKeyPair::from_pkcs8(
            &ECDSA_P256_SHA256_ASN1_SIGNING,
            &self.key,
            &SystemRandom::new(),
        )
        .ok()
        .context("invalid key")?;
        anyhow::ensure!(
            self.certificate.first() == Some(&0x30),
            "invalid certificate"
        );
        Ok(())
    }
}

/// A minimal X.509 v3 certificate for a P-256 key, signed with ECDSA-SHA256,
/// in DER, byte for byte as `SelfSignedCertificate.make` builds it. Phones trust
/// it by its fingerprint, not by its contents.
pub fn self_signed_certificate(
    common_name: &str,
    public_key: &[u8],
    serial: &[u8],
    not_before: chrono::DateTime<chrono::Utc>,
    not_after: chrono::DateTime<chrono::Utc>,
    sign: impl FnOnce(&[u8]) -> Result<Vec<u8>>,
) -> Result<Vec<u8>> {
    let algorithm = der::sequence(&[der::oid(&[1, 2, 840, 10045, 4, 3, 2])]); // ecdsa-with-SHA256
    let name = der::sequence(&[der::set(&[der::sequence(&[
        der::oid(&[2, 5, 4, 3]),
        der::utf8(common_name),
    ])])]);
    let key_info = der::sequence(&[
        // id-ecPublicKey, P-256
        der::sequence(&[
            der::oid(&[1, 2, 840, 10045, 2, 1]),
            der::oid(&[1, 2, 840, 10045, 3, 1, 7]),
        ]),
        der::bit_string(public_key, 0),
    ]);
    let extensions = der::explicit(
        3,
        &der::sequence(&[
            // Basic constraints: not a certificate authority. Critical.
            der::sequence(&[
                der::oid(&[2, 5, 29, 19]),
                der::boolean(true),
                der::octet_string(&der::sequence(&[])),
            ]),
            // Key usage: digital signature. Critical.
            der::sequence(&[
                der::oid(&[2, 5, 29, 15]),
                der::boolean(true),
                der::octet_string(&der::bit_string(&[0x80], 7)),
            ]),
            // Extended key usage: TLS server.
            der::sequence(&[
                der::oid(&[2, 5, 29, 37]),
                der::octet_string(&der::sequence(&[der::oid(&[1, 3, 6, 1, 5, 5, 7, 3, 1])])),
            ]),
        ]),
    );
    let tbs = der::sequence(&[
        der::explicit(0, &der::integer(&[2])), // v3
        der::integer(serial),
        algorithm.clone(),
        name.clone(),
        der::sequence(&[der::time(not_before), der::time(not_after)]),
        name,
        key_info,
        extensions,
    ]);
    let signature = sign(&tbs)?;
    Ok(der::sequence(&[
        tbs,
        algorithm,
        der::bit_string(&signature, 0),
    ]))
}

/// The few DER encodings the certificate needs.
pub mod der {
    use chrono::Datelike;

    pub fn element(tag: u8, content: &[u8]) -> Vec<u8> {
        let mut data = vec![tag];
        let count = content.len();
        if count < 0x80 {
            data.push(count as u8);
        } else {
            let bytes = count
                .to_be_bytes()
                .into_iter()
                .skip_while(|&b| b == 0)
                .collect::<Vec<_>>();
            data.push(0x80 | bytes.len() as u8);
            data.extend(bytes);
        }
        data.extend_from_slice(content);
        data
    }
    pub fn sequence(elements: &[Vec<u8>]) -> Vec<u8> {
        element(0x30, &elements.concat())
    }
    pub fn set(elements: &[Vec<u8>]) -> Vec<u8> {
        element(0x31, &elements.concat())
    }
    pub fn explicit(number: u8, content: &[u8]) -> Vec<u8> {
        element(0xA0 | number, content)
    }
    pub fn boolean(value: bool) -> Vec<u8> {
        element(0x01, &[if value { 0xFF } else { 0x00 }])
    }
    pub fn octet_string(content: &[u8]) -> Vec<u8> {
        element(0x04, content)
    }
    pub fn utf8(string: &str) -> Vec<u8> {
        element(0x0C, string.as_bytes())
    }
    pub fn bit_string(content: &[u8], unused_bits: u8) -> Vec<u8> {
        element(0x03, &[&[unused_bits], content].concat())
    }
    /// A positive INTEGER from big-endian bytes.
    pub fn integer(bytes: &[u8]) -> Vec<u8> {
        let mut trimmed = bytes
            .iter()
            .copied()
            .skip_while(|&b| b == 0)
            .collect::<Vec<_>>();
        if trimmed.is_empty() {
            trimmed.push(0);
        }
        if trimmed[0] & 0x80 != 0 {
            trimmed.insert(0, 0);
        }
        element(0x02, &trimmed)
    }
    pub fn oid(arcs: &[u64]) -> Vec<u8> {
        let mut content = vec![(arcs[0] * 40 + arcs[1]) as u8];
        for &arc in &arcs[2..] {
            let mut chunk = vec![(arc & 0x7F) as u8];
            let mut value = arc >> 7;
            while value > 0 {
                chunk.insert(0, (value & 0x7F) as u8 | 0x80);
                value >>= 7;
            }
            content.extend(chunk);
        }
        element(0x06, &content)
    }
    /// UTCTime before 2050, GeneralizedTime from then on, as RFC 5280 asks.
    pub fn time(date: chrono::DateTime<chrono::Utc>) -> Vec<u8> {
        if date.year() < 2050 {
            element(0x17, date.format("%y%m%d%H%M%SZ").to_string().as_bytes())
        } else {
            element(0x18, date.format("%Y%m%d%H%M%SZ").to_string().as_bytes())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::secrets::MemorySecrets;
    use chrono::TimeZone;

    #[test]
    fn der_matches_the_swift_encoder() {
        assert_eq!(der::integer(&[0, 0, 0x80]), vec![0x02, 0x02, 0x00, 0x80]);
        assert_eq!(der::integer(&[]), vec![0x02, 0x01, 0x00]);
        assert_eq!(
            der::oid(&[1, 2, 840, 10045, 2, 1]),
            vec![0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        );
        assert_eq!(der::element(0x04, &[7; 200])[..3], [0x04, 0x81, 200]);
        assert_eq!(der::element(0x04, &[7; 300])[..4], [0x04, 0x82, 0x01, 0x2C]);
        let early = chrono::Utc.with_ymd_and_hms(2026, 1, 2, 3, 4, 5).unwrap();
        assert_eq!(
            der::time(early),
            [&[0x17, 13][..], b"260102030405Z"].concat()
        );
        let late = chrono::Utc.with_ymd_and_hms(2050, 1, 2, 3, 4, 5).unwrap();
        assert_eq!(
            der::time(late),
            [&[0x18, 15][..], b"20500102030405Z"].concat()
        );
        assert_eq!(der::bit_string(&[0x80], 7), vec![0x03, 0x02, 0x07, 0x80]);
    }

    #[test]
    fn identity_is_a_tls_server_certificate_kept_across_loads() {
        let secrets = MemorySecrets::default();
        let first = Identity::load_or_create(&secrets).unwrap();
        assert_eq!(first.fingerprint().len(), 64);
        let again = Identity::load_or_create(&secrets).unwrap();
        assert_eq!(first.fingerprint(), again.fingerprint());
        // rustls accepts the pair for a TLS 1.3 server, which also checks that
        // the certificate's key matches the private key.
        super::super::server::tls_config(&again).unwrap();
        Identity::reset(&secrets).unwrap();
        let fresh = Identity::load_or_create(&secrets).unwrap();
        assert_ne!(fresh.fingerprint(), first.fingerprint());
        assert!(!format!("{fresh:?}").contains("key:"));
    }

    #[test]
    fn a_damaged_saved_identity_is_made_again() {
        let secrets = MemorySecrets::default();
        secrets
            .write(ENTRY, b"{\"key\":\"AA==\",\"certificate\":\"AA==\"}")
            .unwrap();
        let identity = Identity::load_or_create(&secrets).unwrap();
        assert_eq!(identity.certificate[0], 0x30);
    }
}
