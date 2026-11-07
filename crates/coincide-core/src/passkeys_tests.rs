//! Ported from the Swift app's WebAuthnTests, BitwardenPasskeyTests and
//! PasskeySupportTests. Synthetic `bw` output with keys generated for each test;
//! no real vault, passkey or keychain item is used.
use super::*;
use std::cell::RefCell;

fn suffixes() -> &'static PublicSuffixList {
    PublicSuffixList::bundled().expect("bundled public suffix list")
}

fn origin(host: &str) -> WebAuthnOrigin {
    WebAuthnOrigin::new("https", host, 0).unwrap()
}

fn validate(rp_id: Option<&str>, host: &str) -> Option<String> {
    validate_relying_party(rp_id, &origin(host), suffixes())
}

#[test]
fn registrable_domains_match_the_lists_own_tests() {
    let list = suffixes();
    assert!(list.is_complete());
    assert!(!PublicSuffixList::parse("com\nco.uk\ngithub.io\n").is_complete());
    let vectors: &[(&str, Option<&str>)] = &[
        ("com", None),
        ("example.com", Some("example.com")),
        ("a.b.example.com", Some("example.com")),
        ("uk.com", None),
        ("b.example.uk.com", Some("example.uk.com")),
        ("mm", None),
        ("c.mm", None),
        ("b.c.mm", Some("b.c.mm")),
        ("a.b.c.mm", Some("b.c.mm")),
        ("ide.kyoto.jp", None),
        ("a.b.ide.kyoto.jp", Some("b.ide.kyoto.jp")),
        ("c.kobe.jp", None),
        ("www.city.kobe.jp", Some("city.kobe.jp")),
        ("test.ck", None),
        ("www.www.ck", Some("www.ck")),
        ("www.test.k12.ak.us", Some("test.k12.ak.us")),
        (
            "www.xn--85x722f.xn--55qx5d.cn",
            Some("xn--85x722f.xn--55qx5d.cn"),
        ),
        ("xn--55qx5d.cn", None),
        ("xn--fiqs8s", None),
        ("example", None),
        ("b.example.example", Some("example.example")),
        ("github.io", None),
        ("www.alice.github.io", Some("alice.github.io")),
        ("s3.amazonaws.com", None),
        ("bucket.s3.amazonaws.com", Some("bucket.s3.amazonaws.com")),
    ];
    for (host, expected) in vectors {
        assert_eq!(
            list.registrable_domain(host).as_deref(),
            *expected,
            "{host}"
        );
    }
    for host in ["", ".", "example.com.", ".example.com", "a..b", "bücher.de"] {
        assert_eq!(list.public_suffix(host), None, "{host}");
    }
}

#[test]
fn punycode_matches_rfc_3492() {
    for (unicode, ascii) in [
        ("bücher", "bcher-kva"),
        ("münchen", "mnchen-3ya"),
        ("公司", "55qx5d"),
        ("网络", "io0a7i"),
        ("ελ", "qxam"),
        ("рф", "p1ai"),
        ("中国", "fiqs8s"),
        ("食狮", "85x722f"),
        ("ليهمابتكلموشعربي؟", "egbpdaj6bu4bxfgehfvwxn"),
    ] {
        assert_eq!(
            suffixes::punycode(unicode).as_deref(),
            Some(ascii),
            "{unicode}"
        );
    }
}

#[test]
fn the_rp_id_defaults_to_the_host_and_may_be_a_parent_domain() {
    assert_eq!(validate(None, "github.com").as_deref(), Some("github.com"));
    assert_eq!(
        validate(Some("google.com"), "accounts.google.com").as_deref(),
        Some("google.com")
    );
    assert_eq!(
        validate(Some("example.co.uk"), "a.b.example.co.uk").as_deref(),
        Some("example.co.uk")
    );
    assert_eq!(
        validate(Some("alice.github.io"), "www.alice.github.io").as_deref(),
        Some("alice.github.io")
    );
    assert_eq!(
        validate(Some("city.kobe.jp"), "www.city.kobe.jp").as_deref(),
        Some("city.kobe.jp")
    );
}

#[test]
fn pages_cant_claim_another_sites_or_a_public_rp_id() {
    for (rp_id, host) in [
        ("github.com", "evil.com"),
        ("github.com", "github.com.evil.com"),
        ("github.com", "evilgithub.com"),
        ("sub.example.com", "example.com"),
        ("alice.github.io", "bob.github.io"),
        ("localhost", "example.com"),
        ("com", "example.com"),
        ("co.uk", "a.b.example.co.uk"),
        ("github.io", "alice.github.io"),
        ("c.kobe.jp", "b.c.kobe.jp"),
        ("amazonaws.com", "bucket.s3.amazonaws.com"),
        ("s3.amazonaws.com", "bucket.s3.amazonaws.com"),
    ] {
        assert_eq!(validate(Some(rp_id), host), None, "{rp_id} from {host}");
    }
    assert_eq!(validate(None, "github.io"), None);
    let local = WebAuthnOrigin::new("http", "localhost", 3000).unwrap();
    assert_eq!(
        validate_relying_party(Some("example.com"), &local, suffixes()),
        None
    );
    assert_eq!(
        validate_relying_party(None, &local, suffixes()).as_deref(),
        Some("localhost")
    );
    let long = format!("{}com", "a.".repeat(130));
    for rp_id in [
        "",
        "Example.com",
        "example.com.",
        ".example.com",
        "exa mple.com",
        "example..com",
        "xn--bcher-kva.example.com\0",
        "bücher.example.com",
        "1.2.3.4",
        long.as_str(),
    ] {
        assert_eq!(validate(Some(rp_id), "example.com"), None, "{rp_id:?}");
    }
}

#[test]
fn only_secure_origins_and_localhost_can_use_webauthn() {
    for (scheme, host, port) in [
        ("http", "example.com", 0),
        ("http", "127.0.0.1", 8080),
        ("https", "192.168.1.1", 0),
        ("https", "0x7f.1", 0),
        ("https", "::1", 0),
        ("https", "[::1]", 0),
        ("https", "intranet", 0),
        ("ftp", "example.com", 0),
        ("file", "", 0),
        ("https", "example.com", 70_000),
    ] {
        assert_eq!(
            WebAuthnOrigin::new(scheme, host, port),
            None,
            "{scheme}://{host}"
        );
    }
    assert_eq!(origin("example.com").serialized(), "https://example.com");
    assert_eq!(
        WebAuthnOrigin::new("https", "Example.COM", 8443)
            .unwrap()
            .serialized(),
        "https://example.com:8443"
    );
    assert_eq!(
        WebAuthnOrigin::new("http", "localhost", 80)
            .unwrap()
            .serialized(),
        "http://localhost"
    );
    assert_eq!(
        WebAuthnOrigin::from_url("https://github.com/login?x=1"),
        Some(origin("github.com"))
    );
    assert_eq!(
        WebAuthnOrigin::from_url("https://github.com:8443/").map(|o| o.serialized()),
        Some("https://github.com:8443".into())
    );
    assert_eq!(WebAuthnOrigin::from_url("about:blank"), None);
}

#[test]
fn client_and_authenticator_data_are_the_specifications_bytes() {
    let data = assertion::client_data_json(&[0xfb, 0xff, 0x01], "https://example.com");
    assert_eq!(
        String::from_utf8(data).unwrap(),
        r#"{"type":"webauthn.get","challenge":"-_8B","origin":"https://example.com","crossOrigin":false}"#
    );
    assert_eq!(assertion::quoted("a\"b\\c\u{1}d"), r#""a\"b\\c\u0001d""#);
    assert_eq!(assertion::quoted("é"), "\"é\"");
    let flags = assertion::USER_PRESENT
        | assertion::USER_VERIFIED
        | assertion::BACKUP_ELIGIBLE
        | assertion::BACKED_UP;
    let data = assertion::authenticator_data("example.com", flags, 0x0102_0304);
    let hex: String = data.iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(
        hex,
        "a379a6f6eeafb9a55e378c118034e2751e682fab9f2d30ab13d2125586ce1947".to_owned()
            + "1d"
            + "01020304"
    );
}

use synthetic::Key;

fn key() -> Key {
    Key::generate()
}

fn verifies(key: &Key, authenticator_data: &[u8], client_data: &[u8], signature: &[u8]) -> bool {
    key.verifies(authenticator_data, client_data, signature)
}

#[test]
fn the_signature_verifies_against_the_public_key_and_these_bytes_only() {
    let key = key();
    let data = assertion::authenticator_data("github.com", assertion::USER_PRESENT, 0);
    let client = assertion::client_data_json(&[7; 32], "https://github.com");
    let signature = assertion::signature(&data, &client, &key.pkcs8).unwrap();
    assert!(verifies(&key, &data, &client, &signature));
    let other = assertion::client_data_json(&[8; 32], "https://github.com");
    assert!(!verifies(&key, &data, &other, &signature));
    assert!(assertion::signature(&data, &client, &[1, 2, 3]).is_err());
}

#[test]
fn base64url_round_trips_and_reads_what_bitwarden_writes() {
    for length in 0..40 {
        let data: Vec<u8> = (0..length).map(|i| ((i * 37 + 11) & 0xff) as u8).collect();
        let text = base64url::encode(&data);
        assert!(!text.contains(['=', '+', '/']));
        assert_eq!(base64url::decode(&text), Some(data));
    }
    assert_eq!(base64url::decode("-_8B"), Some(vec![0xfb, 0xff, 0x01]));
    assert_eq!(base64url::decode("+/8B"), Some(vec![0xfb, 0xff, 0x01]));
    assert_eq!(base64url::decode("AQ=="), Some(vec![1]));
    assert_eq!(base64url::decode("AQI="), Some(vec![1, 2]));
    for invalid in ["A", "AQ=", "AQI==", "A Q", "AQ*", "AQ\n", "====="] {
        assert_eq!(base64url::decode(invalid), None, "{invalid:?}");
    }
    assert_eq!(standard_base64(b"\xfb\xff"), "+/8=");
}

fn challenge() -> String {
    base64url::encode(&[1; 32])
}

fn message(public_key: Value, extra: Value) -> Value {
    let mut body = json!({"kind":"get","id":"abc123","publicKey":public_key});
    for (key, value) in extra.as_object().unwrap() {
        body[key] = value.clone();
    }
    body
}

#[test]
fn reads_the_scripts_message() {
    let request = GetRequest::from_message(&message(
        json!({"challenge":challenge(),"rpId":"github.com","userVerification":"required","timeout":60000,
            "allowCredentials":[{"id":base64url::encode(&[1,2,3]),"type":"public-key","transports":["internal","hybrid"]},
                {"id":base64url::encode(&[4]),"type":"other","transports":"ignored for other types"}]}),
        json!({"mediation":"required"}),
    ))
    .unwrap();
    assert_eq!(request.id, "abc123");
    assert_eq!(request.challenge, vec![1; 32]);
    assert_eq!(request.rp_id.as_deref(), Some("github.com"));
    assert_eq!(
        request.user_verification,
        UserVerificationRequirement::Required
    );
    assert_eq!(request.timeout_ms, Some(60_000));
    assert_eq!(request.mediation, Mediation::Required);
    // Descriptors of other types don't name passkeys.
    assert_eq!(request.allow_credentials, vec![vec![1, 2, 3]]);
    let plain = GetRequest::from_message(&message(
        json!({"challenge":challenge(),"userVerification":"sometimes","timeout":true}),
        json!({}),
    ))
    .unwrap();
    assert!(plain.rp_id.is_none() && plain.allow_credentials.is_empty());
    assert_eq!(
        plain.user_verification,
        UserVerificationRequirement::Preferred
    );
    assert_eq!(
        (plain.timeout_ms, plain.mediation),
        (None, Mediation::Optional)
    );
}

#[test]
fn refuses_malformed_or_oversized_messages() {
    let big = base64url::encode(&vec![2; GetRequest::MAX_CHALLENGE + 1]);
    let long_id = base64url::encode(&vec![3; GetRequest::MAX_CREDENTIAL_ID + 1]);
    let many: Vec<Value> = (0..=GetRequest::MAX_ALLOWED_CREDENTIALS)
        .map(|_| json!({"id":"AQ","type":"public-key"}))
        .collect();
    let invalid = [
        json!("not a dictionary"),
        json!({"kind":"get"}),
        json!({"kind":"create","id":"a","publicKey":{"challenge":challenge()}}),
        json!({"kind":"get","id":"","publicKey":{"challenge":challenge()}}),
        json!({"kind":"get","id":"has space","publicKey":{"challenge":challenge()}}),
        json!({"kind":"get","id":"a".repeat(65),"publicKey":{"challenge":challenge()}}),
        message(json!({}), json!({})),
        message(json!({"challenge":""}), json!({})),
        message(json!({"challenge":"*"}), json!({})),
        message(json!({"challenge":big}), json!({})),
        message(json!({"challenge":1}), json!({})),
        message(json!({"challenge":challenge(),"rpId":1}), json!({})),
        message(
            json!({"challenge":challenge(),"rpId":"a".repeat(254)}),
            json!({}),
        ),
        message(
            json!({"challenge":challenge(),"allowCredentials":"AQ"}),
            json!({}),
        ),
        message(
            json!({"challenge":challenge(),"allowCredentials":many}),
            json!({}),
        ),
        message(
            json!({"challenge":challenge(),"allowCredentials":[{"id":long_id,"type":"public-key"}]}),
            json!({}),
        ),
        message(
            json!({"challenge":challenge(),"allowCredentials":[{"type":"public-key"}]}),
            json!({}),
        ),
        message(
            json!({"challenge":challenge(),"allowCredentials":[{"id":"AQ","transports":"usb"}]}),
            json!({}),
        ),
        message(
            json!({"challenge":challenge()}),
            json!({"mediation":"sometimes"}),
        ),
    ];
    for body in invalid {
        assert_eq!(GetRequest::from_message(&body), None, "{body}");
        // The log summary never carries values.
        assert!(!GetRequest::summary(&body).contains(&challenge()));
    }
}

fn request(user_verification: UserVerificationRequirement, timeout_ms: Option<u64>) -> GetRequest {
    GetRequest {
        id: "r1".into(),
        challenge: vec![9; 32],
        rp_id: None,
        allow_credentials: vec![],
        user_verification,
        timeout_ms,
        mediation: Mediation::Optional,
    }
}

#[test]
fn waits_within_bitwardens_clamps() {
    use UserVerificationRequirement::*;
    let limit = |timeout, uv| request(uv, timeout).wait_limit().as_secs_f64();
    assert_eq!(limit(None, Preferred), 300.0);
    assert_eq!(limit(Some(1_000), Preferred), 30.0);
    assert_eq!(limit(Some(120_500), Required), 120.5);
    assert_eq!(limit(Some(3_600_000), Preferred), 600.0);
    assert_eq!(limit(None, Discouraged), 120.0);
    assert_eq!(limit(Some(3_600_000), Discouraged), 180.0);
    assert_eq!(limit(Some(0), Discouraged), 30.0);
}

/// One synthetic Bitwarden login item with a passkey, as `bw` prints it.
fn item(key: &Key, id: &str, counter: Value, reprompt: i64) -> Value {
    json!({
        "object":"item","id":id,"type":1,"name":"GitHub","reprompt":reprompt,"deletedDate":null,
        "notes":null,"favorite":false,"fields":[],"collectionIds":[],
        "login":{"username":"octocat@example.test","password":"fixture-password","totp":null,
            "uris":[{"match":null,"uri":"https://github.com"}],
            "fido2Credentials":[{"credentialId":"b64.AQIDBA","keyType":"public-key","keyAlgorithm":"ECDSA",
                "keyCurve":"P-256","keyValue":base64url::encode(&key.pkcs8),"rpId":"github.com",
                "userHandle":base64url::encode(&[0xa1,0xb2]),"userName":"octocat","counter":counter,
                "rpName":"GitHub","userDisplayName":"The Octocat","discoverable":"true",
                "creationDate":"2026-01-01T00:00:00.000Z"}]}
    })
}

#[test]
fn credential_ids_convert_like_bitwardens() {
    assert_eq!(raw_credential_id("b64.AQIDBA"), Some(vec![1, 2, 3, 4]));
    assert_eq!(raw_credential_id("b64.-_8B"), Some(vec![0xfb, 0xff, 0x01]));
    let aaguid = vec![
        0xd5, 0x48, 0x82, 0x6e, 0x79, 0xb4, 0xdb, 0x40, 0xa3, 0xd8, 0x11, 0x11, 0x6f, 0x7e, 0x83,
        0x49,
    ];
    assert_eq!(
        raw_credential_id("d548826e-79b4-db40-a3d8-11116f7e8349"),
        Some(aaguid.clone())
    );
    assert_eq!(
        raw_credential_id("D548826E-79B4-DB40-A3D8-11116F7E8349"),
        Some(aaguid)
    );
    let long = format!("b64.{}", base64url::encode(&[1; 1_024]));
    for invalid in [
        "",
        "b64.",
        "b64.***",
        "d548826e79b4db40a3d811116f7e8349",
        "{d548826e-79b4-db40-a3d8-11116f7e8349}",
        "AQIDBA",
        long.as_str(),
    ] {
        assert_eq!(raw_credential_id(invalid), None, "{invalid}");
    }
}

#[test]
fn reads_only_usable_passkeys_without_their_keys() {
    let key = key();
    let good = item(&key, "item-1", json!("0"), 0);
    let mut guid = item(&key, "guid", json!("7"), 1);
    guid["login"]["fido2Credentials"][0]["credentialId"] =
        json!("d548826e-79b4-db40-a3d8-11116f7e8349");
    guid["login"]["fido2Credentials"][0]["discoverable"] = json!("false");
    guid["login"]["fido2Credentials"][0]["userName"] = json!("");
    let mut p384 = item(&key, "p384", json!("0"), 0);
    p384["login"]["fido2Credentials"][0]["keyCurve"] = json!("P-384");
    let mut note = item(&key, "note", json!("0"), 0);
    note["type"] = json!(2);
    let mut trash = item(&key, "trash", json!("0"), 0);
    trash["deletedDate"] = json!("2026-02-01T00:00:00.000Z");
    let mut bad_id = item(&key, "bad-credential", json!("0"), 0);
    bad_id["login"]["fido2Credentials"][0]["credentialId"] = json!("nope");
    let items = json!([
        good,
        guid,
        p384,
        note,
        trash,
        item(&key, "bad-counter", json!("lots"), 0),
        item(&key, "big-counter", json!("4294967296"), 0),
        item(&key, "--help", json!("0"), 0),
        bad_id,
        {"object":"item","id":"plain","type":1,"name":"Plain","login":{"username":"me","password":"pw"}},
    ]);
    let passkeys = BitwardenPasskey::parse_list(items.to_string().as_bytes());
    assert_eq!(
        passkeys
            .iter()
            .map(|p| p.item_id.as_str())
            .collect::<Vec<_>>(),
        ["item-1", "guid"]
    );
    let first = &passkeys[0];
    assert_eq!(first.credential_id, vec![1, 2, 3, 4]);
    assert_eq!(first.user_handle, Some(vec![0xa1, 0xb2]));
    assert!(first.discoverable && !first.requires_reprompt && first.counter == 0);
    assert_eq!(first.account_name(), "octocat");
    // Without the passkey's user name, the login's username names the account.
    let second = &passkeys[1];
    assert_eq!(second.user_name, "octocat@example.test");
    assert!(second.counter == 7 && !second.discoverable && second.requires_reprompt);
    // The private key and the password aren't part of what's kept.
    let dumped = format!("{passkeys:?}");
    assert!(
        !dumped.contains(&base64url::encode(&key.pkcs8)) && !dumped.contains("fixture-password")
    );
    assert_eq!(counter(Some(&json!(""))), Some(0));
    assert_eq!(counter(None), Some(0));
    assert_eq!(counter(Some(&json!(3))), Some(3));
    assert_eq!(counter(Some(&json!(3.0))), Some(3));
    assert_eq!(counter(Some(&json!("-1"))), None);
    assert_eq!(counter(Some(&json!(1.5))), None);
    assert_eq!(counter(Some(&json!(true))), None);
}

fn passkey(
    id: &str,
    rp_id: &str,
    credential: u8,
    discoverable: bool,
    user: &str,
) -> BitwardenPasskey {
    BitwardenPasskey {
        item_id: id.into(),
        item_name: format!("Item {id}"),
        user_name: user.into(),
        user_display_name: String::new(),
        rp_id: rp_id.into(),
        stored_credential_id: format!("b64.{}", base64url::encode(&[credential])),
        credential_id: vec![credential],
        user_handle: None,
        counter: 0,
        discoverable,
        requires_reprompt: false,
    }
}

#[test]
fn matches_the_rp_id_and_allow_credentials_like_bitwarden() {
    let all = [
        passkey("w", "github.com", 1, true, "work"),
        passkey("h", "github.com", 2, true, "home"),
        passkey("n", "github.com", 3, false, "hidden"),
        passkey("o", "gitlab.com", 4, true, "other"),
        passkey("p", "github.com.evil.test", 5, true, "evil"),
        passkey("t", "github.com", 6, true, "user10"),
        passkey("s", "github.com", 7, true, "User9"),
    ];
    let ids =
        |matches: Vec<BitwardenPasskey>| matches.into_iter().map(|p| p.item_id).collect::<Vec<_>>();
    // No allowCredentials: the site's discoverable passkeys, sorted by account,
    // case-insensitively and with numbers by value.
    assert_eq!(
        ids(BitwardenPasskey::matching(&all, "github.com", &[])),
        ["h", "s", "t", "w"]
    );
    assert_eq!(
        ids(BitwardenPasskey::matching(
            &all,
            "github.com",
            &[vec![3], vec![1]]
        )),
        ["n", "w"]
    );
    assert!(BitwardenPasskey::matching(&all, "github.com", &[vec![4], vec![9]]).is_empty());
    assert!(BitwardenPasskey::matching(&all, "GitHub.com", &[]).is_empty());
    assert!(BitwardenPasskey::matching(&all, "evil.test", &[]).is_empty());
}

#[test]
fn counts_like_bitwarden() {
    assert_eq!(next_counter(0), Ok(0));
    assert_eq!(next_counter(41), Ok(42));
    assert!(next_counter(u32::MAX).is_err());
    let original = item(&key(), "item-1", json!("5"), 0);
    let edited = item_setting_counter(&original, 6).unwrap();
    assert_eq!(edited["login"]["fido2Credentials"][0]["counter"], "6");
    // Everything else is sent back as it was.
    let mut restored = edited.clone();
    restored["login"]["fido2Credentials"][0]["counter"] = json!("5");
    assert_eq!(restored, original);
    assert_eq!(item_setting_counter(&json!({"login":{}}), 1), None);
}

type Replies = Vec<(Vec<String>, Result<Vec<u8>, Failure>)>;
type Calls = Vec<(Vec<String>, Option<Vec<u8>>)>;

/// Answers `bw` commands from fixed output and records each call and its input.
#[derive(Default)]
struct FakeRunner {
    replies: RefCell<Replies>,
    calls: RefCell<Calls>,
}

impl FakeRunner {
    fn reply(&self, args: &[&str], output: Result<&str, Failure>) {
        self.replies.borrow_mut().push((
            args.iter().map(|s| s.to_string()).collect(),
            output.map(|text| text.as_bytes().to_vec()),
        ));
    }
    fn answer(&self, args: &[&str], input: Option<&[u8]>) -> Result<Vec<u8>, Failure> {
        self.calls.borrow_mut().push((
            args.iter().map(|s| s.to_string()).collect(),
            input.map(<[u8]>::to_vec),
        ));
        self.replies
            .borrow()
            .iter()
            .rev()
            .find(|(expected, _)| expected == args)
            .map_or(Err(Failure::Unavailable), |(_, output)| output.clone())
    }
    fn commands(&self) -> Vec<String> {
        self.calls
            .borrow()
            .iter()
            .map(|(args, _)| args[0].clone())
            .collect()
    }
}

impl VaultCommand for FakeRunner {
    fn run(&self, args: &[&str]) -> Result<Vec<u8>, Failure> {
        self.answer(args, None)
    }
    fn run_with_input(&self, args: &[&str], input: &[u8]) -> Result<Vec<u8>, Failure> {
        self.answer(args, Some(input))
    }
}

fn client_data() -> Vec<u8> {
    assertion::client_data_json(&[5; 32], "https://github.com")
}

#[test]
fn signs_with_a_fresh_read_and_leaves_a_zero_counter_alone() {
    let key = key();
    let item = item(&key, "item-1", json!("0"), 0);
    let vault = BitwardenPasskeys::new(FakeRunner::default());
    vault.runner.reply(
        &["list", "items", "--nointeraction"],
        Ok(&json!([item]).to_string()),
    );
    vault.runner.reply(
        &["get", "item", "item-1", "--nointeraction"],
        Ok(&item.to_string()),
    );
    let passkey = vault.passkeys().unwrap().remove(0);
    let signed = vault
        .assertion(&passkey, "github.com", &client_data(), true)
        .unwrap();
    assert_eq!(signed.credential_id, vec![1, 2, 3, 4]);
    assert_eq!(signed.user_handle, Some(vec![0xa1, 0xb2]));
    assert_eq!(
        signed.authenticator_data,
        assertion::authenticator_data("github.com", 0x1d, 0)
    );
    assert!(verifies(
        &key,
        &signed.authenticator_data,
        &client_data(),
        &signed.signature
    ));
    assert_eq!(vault.runner.commands(), ["list", "get"]);
    // The key never goes into a command line, the reply or a description.
    let secret = base64url::encode(&key.pkcs8);
    assert!(vault.runner.calls.borrow().iter().all(|(args, input)| {
        args.last().map(String::as_str) == Some("--nointeraction")
            && !args.contains(&secret)
            && input.is_none()
    }));
    let reply = WebAuthnReply::Credential(PasskeyCredential {
        assertion: signed.clone(),
        client_data_json: client_data(),
    });
    assert!(!Value::Object(reply.message()).to_string().contains(&secret));
    assert!(!format!("{signed:?}").contains(&secret));
    // Without verification, the UV flag stays off.
    let unverified = vault
        .assertion(&passkey, "github.com", &client_data(), false)
        .unwrap();
    assert_eq!(unverified.authenticator_data[32], 0x19);
    assert!(verifies(
        &key,
        &unverified.authenticator_data,
        &client_data(),
        &unverified.signature
    ));
}

#[test]
fn a_counter_above_zero_is_synced_incremented_and_saved_through_stdin() {
    let key = key();
    let original = item(&key, "item-1", json!("5"), 0);
    let vault = BitwardenPasskeys::new(FakeRunner::default());
    let passkey = BitwardenPasskey::parse_item(&original).unwrap();
    vault
        .runner
        .reply(&["sync", "--nointeraction"], Ok("Syncing complete."));
    vault.runner.reply(
        &["get", "item", "item-1", "--nointeraction"],
        Ok(&original.to_string()),
    );
    vault.runner.reply(
        &["edit", "item", "item-1", "--nointeraction"],
        Ok(&item(&key, "item-1", json!("6"), 0).to_string()),
    );
    let signed = vault
        .assertion(&passkey, "github.com", &client_data(), true)
        .unwrap();
    assert_eq!(signed.authenticator_data[33..], [0, 0, 0, 6]);
    assert!(verifies(
        &key,
        &signed.authenticator_data,
        &client_data(),
        &signed.signature
    ));
    assert_eq!(vault.runner.commands(), ["sync", "get", "edit"]);
    let calls = vault.runner.calls.borrow();
    let (args, input) = calls.last().unwrap();
    assert_eq!(args, &["edit", "item", "item-1", "--nointeraction"]);
    let sent = String::from_utf8(input.clone().unwrap()).unwrap();
    let sent: Value =
        serde_json::from_slice(&base64url::decode(&sent).expect("standard base64 of the item"))
            .unwrap();
    assert_eq!(sent["login"]["fido2Credentials"][0]["counter"], "6");
    assert_eq!(sent["login"]["password"], "fixture-password");
}

#[test]
fn no_assertion_when_the_count_cant_be_saved_or_the_item_changed() {
    let key = key();
    let original = item(&key, "item-1", json!("5"), 0);
    let passkey = BitwardenPasskey::parse_item(&original).unwrap();
    for edit in [
        Err(Failure::Unavailable),
        Ok(item(&key, "item-1", json!("5"), 0).to_string()),
        Ok("not json".to_owned()),
    ] {
        let vault = BitwardenPasskeys::new(FakeRunner::default());
        vault.runner.reply(&["sync", "--nointeraction"], Ok(""));
        vault.runner.reply(
            &["get", "item", "item-1", "--nointeraction"],
            Ok(&original.to_string()),
        );
        vault.runner.reply(
            &["edit", "item", "item-1", "--nointeraction"],
            edit.as_deref().map_err(|e| *e),
        );
        assert!(
            vault
                .assertion(&passkey, "github.com", &client_data(), true)
                .is_err()
        );
    }
    // A failed sync stops it before anything is read.
    let vault = BitwardenPasskeys::new(FakeRunner::default());
    assert!(
        vault
            .assertion(&passkey, "github.com", &client_data(), true)
            .is_err()
    );
    assert_eq!(vault.runner.commands(), ["sync"]);
    // A changed item, another RP ID, or a re-prompt item without verification.
    let fresh = item(&key, "item-1", json!("0"), 0);
    let chosen = BitwardenPasskey::parse_item(&fresh).unwrap();
    let mut changed = fresh.clone();
    changed["login"]["fido2Credentials"][0]["credentialId"] = json!("b64.CQkJ");
    let guarded = item(&key, "item-1", json!("0"), 1);
    for (current, rp_id, verified) in [
        (&changed, "github.com", true),
        (&fresh, "evil.test", true),
        (&guarded, "github.com", false),
    ] {
        let vault = BitwardenPasskeys::new(FakeRunner::default());
        vault.runner.reply(
            &["get", "item", "item-1", "--nointeraction"],
            Ok(&current.to_string()),
        );
        assert_eq!(
            vault.assertion(&chosen, rp_id, &client_data(), verified),
            Err(Failure::NotFound)
        );
    }
}

/// Item, RP ID, client data and whether the user was verified, per signing.
type Signings = Vec<(String, String, Vec<u8>, bool)>;

struct FakeVault {
    list: Option<Vec<BitwardenPasskey>>,
    signed: RefCell<Signings>,
}

impl FakeVault {
    fn new(list: Option<Vec<BitwardenPasskey>>) -> Self {
        Self {
            list,
            signed: RefCell::default(),
        }
    }
}

impl PasskeyVault for FakeVault {
    fn passkeys(&self) -> Result<Vec<BitwardenPasskey>, Failure> {
        self.list.clone().ok_or(Failure::Locked)
    }
    fn assertion(
        &self,
        passkey: &BitwardenPasskey,
        rp_id: &str,
        client_data_json: &[u8],
        user_verified: bool,
    ) -> Result<PasskeyAssertion, Failure> {
        self.signed.borrow_mut().push((
            passkey.item_id.clone(),
            rp_id.into(),
            client_data_json.to_vec(),
            user_verified,
        ));
        Ok(PasskeyAssertion {
            credential_id: passkey.credential_id.clone(),
            authenticator_data: vec![1],
            signature: vec![2],
            user_handle: passkey.user_handle.clone(),
        })
    }
}

struct FakeUi {
    prompts: Vec<SignInPrompt>,
    reasons: Vec<String>,
    choose: Option<usize>,
    verification: UserVerification,
}

impl FakeUi {
    fn new() -> Self {
        Self {
            prompts: vec![],
            reasons: vec![],
            choose: Some(0),
            verification: UserVerification::Verified,
        }
    }
}

impl sign_in::Ui for FakeUi {
    fn confirm(&mut self, prompt: &SignInPrompt) -> Option<usize> {
        self.prompts.push(prompt.clone());
        self.choose
    }
    fn verify_user(&mut self, reason: &str) -> UserVerification {
        self.reasons.push(reason.into());
        self.verification
    }
}

const MAC: Option<&str> = Some("Touch ID or your Mac password");

fn answer(
    request: &GetRequest,
    vault: &FakeVault,
    ui: &mut FakeUi,
    always: bool,
    from: &str,
) -> (WebAuthnReply, Option<String>) {
    sign_in::answer(
        request,
        &origin(from),
        vault,
        ui,
        always,
        MAC,
        Some(suffixes()),
    )
}

fn github() -> BitwardenPasskey {
    let mut passkey = passkey("a", "github.com", 1, true, "octocat");
    passkey.item_name = "GitHub".into();
    passkey.user_handle = Some(vec![7]);
    passkey
}

#[test]
fn signs_in_after_the_click_alone_by_default() {
    for uv in [
        UserVerificationRequirement::Preferred,
        UserVerificationRequirement::Discouraged,
    ] {
        let vault = FakeVault::new(Some(vec![github()]));
        let mut ui = FakeUi::new();
        let mut request = request(uv, None);
        request.rp_id = Some("github.com".into());
        let (reply, reason) = answer(&request, &vault, &mut ui, false, "github.com");
        let client = assertion::client_data_json(&[9; 32], "https://github.com");
        assert_eq!(reason, None);
        assert_eq!(
            reply,
            WebAuthnReply::Credential(PasskeyCredential {
                assertion: PasskeyAssertion {
                    credential_id: vec![1],
                    authenticator_data: vec![1],
                    signature: vec![2],
                    user_handle: Some(vec![7]),
                },
                client_data_json: client.clone(),
            })
        );
        assert!(ui.reasons.is_empty());
        assert_eq!(
            vault.signed.borrow().as_slice(),
            [("a".to_owned(), "github.com".to_owned(), client, false)]
        );
        assert_eq!(
            ui.prompts[0].title(),
            "Sign in to github.com as octocat with your Bitwarden passkey?"
        );
        assert_eq!(ui.prompts[0].detail(), "");
    }
}

#[test]
fn verification_follows_the_setting_the_site_or_a_reprompt_item() {
    let mut guarded = passkey("r", "github.com", 5, true, "r");
    guarded.requires_reprompt = true;
    for (always, uv, list, verification, expected_verified) in [
        (
            true,
            UserVerificationRequirement::Preferred,
            vec![github()],
            UserVerification::Verified,
            Some(true),
        ),
        (
            true,
            UserVerificationRequirement::Preferred,
            vec![github()],
            UserVerification::Unavailable,
            Some(false),
        ),
        (
            true,
            UserVerificationRequirement::Preferred,
            vec![github()],
            UserVerification::Failed,
            None,
        ),
        (
            false,
            UserVerificationRequirement::Required,
            vec![github()],
            UserVerification::Verified,
            Some(true),
        ),
        (
            false,
            UserVerificationRequirement::Required,
            vec![github()],
            UserVerification::Unavailable,
            None,
        ),
        (
            false,
            UserVerificationRequirement::Preferred,
            vec![guarded.clone()],
            UserVerification::Unavailable,
            None,
        ),
        (
            false,
            UserVerificationRequirement::Preferred,
            vec![guarded.clone()],
            UserVerification::Verified,
            Some(true),
        ),
    ] {
        let vault = FakeVault::new(Some(list));
        let mut ui = FakeUi::new();
        ui.verification = verification;
        let (reply, _) = answer(&request(uv, None), &vault, &mut ui, always, "github.com");
        assert_eq!(
            ui.reasons,
            ["sign in to github.com with your Bitwarden passkey"]
        );
        assert_eq!(
            ui.prompts[0].detail(),
            "You’ll confirm with Touch ID or your Mac password next."
        );
        match expected_verified {
            Some(verified) => {
                assert!(matches!(reply, WebAuthnReply::Credential(_)));
                assert_eq!(vault.signed.borrow()[0].3, verified);
            }
            None => {
                assert_eq!(reply, WebAuthnReply::NOT_ALLOWED);
                assert!(vault.signed.borrow().is_empty());
            }
        }
    }
}

#[test]
fn a_subdomain_signs_in_to_its_parent_and_several_matches_let_the_user_pick() {
    let mut hubot = passkey("b", "github.com", 2, true, "hubot");
    hubot.item_name = "GitHub (work)".into();
    let vault = FakeVault::new(Some(vec![github(), hubot]));
    let mut ui = FakeUi::new();
    ui.choose = Some(0);
    let mut request = request(UserVerificationRequirement::Preferred, None);
    request.rp_id = Some("github.com".into());
    let (reply, _) = answer(&request, &vault, &mut ui, false, "gist.github.com");
    assert!(matches!(reply, WebAuthnReply::Credential(_)));
    let prompt = &ui.prompts[0];
    assert_eq!(
        prompt.title(),
        "Sign in to github.com with your Bitwarden passkey?"
    );
    assert_eq!(
        prompt.detail(),
        "The request comes from gist.github.com. Choose an account."
    );
    assert_eq!(prompt.label(&prompt.choices[0]), "hubot · GitHub (work)");
    assert_eq!(prompt.label(&prompt.choices[1]), "octocat · GitHub");
    // Sorted, so index 0 is hubot; the origin is the requesting page's.
    let signed = vault.signed.borrow();
    assert_eq!(signed[0].0, "b");
    assert!(
        String::from_utf8_lossy(&signed[0].2).contains(r#""origin":"https://gist.github.com""#)
    );
    // Linux has no user verification to promise.
    let none = SignInPrompt {
        verifier: None,
        verifies_user: true,
        ..prompt.clone()
    };
    assert!(none.detail().contains("can’t do on this computer"));
}

#[test]
fn cancelling_refused_rp_ids_and_what_coincide_cant_answer() {
    let vault = FakeVault::new(Some(vec![github()]));
    let mut ui = FakeUi::new();
    ui.choose = None;
    let base = request(UserVerificationRequirement::Preferred, None);
    assert_eq!(
        answer(&base, &vault, &mut ui, false, "github.com").0,
        WebAuthnReply::NOT_ALLOWED
    );
    let mut claim = base.clone();
    claim.rp_id = Some("github.com".into());
    let mut ui = FakeUi::new();
    assert_eq!(
        answer(&claim, &vault, &mut ui, false, "evil.test").0,
        WebAuthnReply::INVALID_RP_ID
    );
    assert!(ui.prompts.is_empty());
    for (request, vault, reason) in [
        (
            GetRequest {
                mediation: Mediation::Conditional,
                ..base.clone()
            },
            FakeVault::new(Some(vec![github()])),
            "conditional mediation isn't offered",
        ),
        (
            GetRequest {
                mediation: Mediation::Silent,
                ..base.clone()
            },
            FakeVault::new(Some(vec![github()])),
            "silent mediation isn't offered",
        ),
        (
            base.clone(),
            FakeVault::new(None),
            "Bitwarden didn't list its passkeys",
        ),
        (
            GetRequest {
                allow_credentials: vec![vec![9]],
                ..base.clone()
            },
            FakeVault::new(Some(vec![github()])),
            "none of 1 Bitwarden passkeys matches 1 allowed credentials",
        ),
    ] {
        let mut ui = FakeUi::new();
        assert_eq!(
            answer(&request, &vault, &mut ui, false, "github.com"),
            (WebAuthnReply::Fallback, Some(reason.to_owned()))
        );
        assert!(ui.prompts.is_empty() && vault.signed.borrow().is_empty());
    }
    let mut ui = FakeUi::new();
    assert_eq!(
        sign_in::answer(
            &base,
            &origin("github.com"),
            &vault,
            &mut ui,
            false,
            MAC,
            None
        ),
        (
            WebAuthnReply::Fallback,
            Some("the public suffix list is missing".into())
        )
    );
}

#[test]
fn replies_are_strings_for_the_page_script() {
    assert_eq!(
        Value::Object(WebAuthnReply::Fallback.message()),
        json!({"status":"fallback"})
    );
    assert_eq!(
        Value::Object(WebAuthnReply::NOT_ALLOWED.message()),
        json!({"status":"error","name":"NotAllowedError","message":"The operation either timed out or was not allowed."})
    );
    let reply = WebAuthnReply::Credential(PasskeyCredential {
        assertion: PasskeyAssertion {
            credential_id: vec![1, 2],
            authenticator_data: vec![3],
            signature: vec![4],
            user_handle: None,
        },
        client_data_json: b"{}".to_vec(),
    });
    assert_eq!(
        Value::Object(reply.message()),
        json!({"status":"ok","id":"AQI","clientDataJSON":"e30","authenticatorData":"Aw","signature":"BA"})
    );
}

#[test]
fn the_notice_shows_once_per_site_until_dismissed_or_the_tab_moves_on() {
    let mut state = NoticeState::default();
    assert!(state.requested("tab-1", "accounts.google.com"));
    assert_eq!(state.notice().unwrap().site, "google.com");
    // The page asking again, or another page of the site, keeps it.
    assert!(!state.requested("tab-1", "myaccount.google.com"));
    assert!(state.opened_elsewhere());
    assert!(!state.opened_elsewhere());
    assert_eq!(state.notice().unwrap().stage, NoticeStage::OpenedElsewhere);
    assert_eq!(
        NoticeState::content(state.notice().unwrap()).1,
        None,
        "nothing to import yet"
    );
    assert!(!state.navigated("tab-1", "www.google.com"));
    assert!(state.navigated("tab-1", "github.com"));
    assert!(state.notice().is_none());
    assert!(state.requested("tab-2", "github.com"));
    assert!(!state.closed("tab-1"));
    state.dismiss();
    assert!(!state.requested("tab-3", "github.com"));
    assert!(state.requested("tab-3", "gitlab.com"));
    assert!(state.closed("tab-3"));
    assert_eq!(
        NoticeState::content(&Notice {
            tab_id: "t".into(),
            site: "s".into(),
            stage: NoticeStage::Unavailable
        })
        .1,
        Some("Open in Default Browser")
    );
}

#[test]
fn the_page_scripts_are_the_swift_apps_and_use_these_handlers() {
    assert!(DETECTION_SCRIPT.contains(&format!("handlers.{DETECTION_HANDLER};")));
    assert!(SIGN_IN_SCRIPT.contains(&format!("handlers.{SIGN_IN_HANDLER};")));
    // Registration is left to the browser; only `get` is replaced.
    assert!(SIGN_IN_SCRIPT.contains("describe(Container.prototype, 'get')"));
    assert!(!SIGN_IN_SCRIPT.contains("'create')"));
    // The sign-in script refuses insecure and opaque origins before anything else.
    assert!(SIGN_IN_SCRIPT.contains("window.origin === 'null'"));
    // The Rust preview has no agent password fill: the note sends agents to the user.
    assert!(AGENT_NOTE.contains("Try another way") && AGENT_NOTE.contains("ask the user"));
}
