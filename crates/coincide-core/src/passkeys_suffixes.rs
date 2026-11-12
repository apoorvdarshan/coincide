//! Mozilla's Public Suffix List (publicsuffix.org), shipped unmodified as
//! `resources/public_suffix_list.dat` under the Mozilla Public License 2.0 (see
//! THIRD_PARTY_NOTICES.md; `scripts/update-public-suffix-list.sh` refreshes it and
//! the Swift app's copy together). Rules from its ICANN and private sections both
//! count, as they do for browsers' cookies, so `github.io` is a suffix that every
//! customer's site sits under and none of them can claim.
//!
//! Hosts are ASCII (internationalized labels in their `xn--` form, as WebViews
//! report them); the list's own internationalized rules are converted with
//! Punycode when it loads.
use std::{collections::HashSet, sync::OnceLock};

const BUNDLED: &str = include_str!("../resources/public_suffix_list.dat");

pub struct PublicSuffixList {
    rules: HashSet<String>,
    /// `*.ck` is kept as `ck`: every label directly under it is a suffix.
    wildcards: HashSet<String>,
    /// `!www.ck` is kept as `www.ck`: registrable, although a wildcard covers it.
    exceptions: HashSet<String>,
}

impl PublicSuffixList {
    /// Parses the list's text: one rule per line up to the first whitespace, `//`
    /// comments, blank lines ignored.
    pub fn parse(text: &str) -> Self {
        let (mut rules, mut wildcards, mut exceptions) =
            (HashSet::new(), HashSet::new(), HashSet::new());
        for line in text.lines() {
            let Some(token) = line.split_whitespace().next() else {
                continue;
            };
            if token.starts_with("//") {
                continue;
            }
            let rule = token.to_lowercase();
            if let Some(rule) = rule.strip_prefix('!') {
                if let Some(ascii) = ascii(rule) {
                    exceptions.insert(ascii);
                }
            } else if let Some(rule) = rule.strip_prefix("*.") {
                if let Some(ascii) = ascii(rule) {
                    wildcards.insert(ascii);
                }
            } else if let Some(ascii) = ascii(&rule) {
                rules.insert(ascii);
            }
        }
        Self {
            rules,
            wildcards,
            exceptions,
        }
    }

    /// The copy bundled with Coincide, or None when it doesn't look like the full
    /// list. Callers fail closed without it.
    pub fn bundled() -> Option<&'static Self> {
        static LIST: OnceLock<Option<PublicSuffixList>> = OnceLock::new();
        LIST.get_or_init(|| {
            let list = Self::parse(BUNDLED);
            list.is_complete().then_some(list)
        })
        .as_ref()
    }

    /// Whether the list has the size and landmarks of the real one, so a truncated
    /// file isn't trusted.
    pub fn is_complete(&self) -> bool {
        self.rules.len() > 5_000
            && self.wildcards.len() > 50
            && !self.exceptions.is_empty()
            && ["com", "co.uk", "github.io"]
                .iter()
                .all(|rule| self.rules.contains(*rule))
    }

    /// The public suffix of `host`: the longest rule it matches, an exception rule
    /// taking precedence, or its last label when no rule matches (the list's
    /// implicit `*`). None when `host` isn't a valid ASCII domain.
    pub fn public_suffix(&self, host: &str) -> Option<String> {
        let labels = labels(host)?;
        let count = labels.len();
        for start in 0..count {
            if self.exceptions.contains(&labels[start..].join(".")) {
                return Some(labels[start + 1..].join("."));
            }
        }
        for start in 0..count {
            let suffix = labels[start..].join(".");
            if self.rules.contains(&suffix) {
                return Some(suffix);
            }
            if start + 1 < count && self.wildcards.contains(&labels[start + 1..].join(".")) {
                return Some(suffix);
            }
        }
        Some(labels[count - 1].clone())
    }

    /// The public suffix plus one label (`www.example.co.uk` → `example.co.uk`), or
    /// None when `host` is itself a public suffix or isn't a valid domain.
    pub fn registrable_domain(&self, host: &str) -> Option<String> {
        let labels = labels(host)?;
        let suffix = self.public_suffix(host)?;
        let suffix_count = suffix.split('.').count();
        if labels.len() <= suffix_count {
            return None;
        }
        Some(labels[labels.len() - suffix_count - 1..].join("."))
    }

    /// Whether `host` is a public suffix, which no site may claim as its own (`com`,
    /// `co.uk`, `github.io`).
    pub fn is_public_suffix(&self, host: &str) -> bool {
        self.public_suffix(host)
            .is_some_and(|suffix| suffix == host.to_lowercase())
    }

    /// The registrable domain, else the host itself: the "site" a notice is
    /// remembered for.
    pub fn site_or_host(&self, host: &str) -> String {
        self.registrable_domain(host)
            .unwrap_or_else(|| host.to_lowercase())
    }
}

/// The labels of a lowercase ASCII domain: no empty labels (so no leading or
/// trailing dot), at most 253 characters.
pub(crate) fn labels(host: &str) -> Option<Vec<String>> {
    let host = host.to_lowercase();
    if host.is_empty() || host.len() > 253 || !host.is_ascii() {
        return None;
    }
    let labels: Vec<String> = host.split('.').map(str::to_owned).collect();
    labels
        .iter()
        .all(|label| !label.is_empty() && label.len() <= 63)
        .then_some(labels)
}

/// A rule with its internationalized labels in `xn--` form.
fn ascii(rule: &str) -> Option<String> {
    let mut labels = Vec::new();
    for label in rule.split('.') {
        if label.is_ascii() {
            labels.push(label.to_owned());
        } else {
            labels.push(format!("xn--{}", punycode(label)?));
        }
    }
    (!labels.iter().any(String::is_empty)).then(|| labels.join("."))
}

/// RFC 3492 Punycode encoding of one label, as IDNA uses after its `xn--` prefix.
/// Only for the suffix list's own rules, which are already normalized (lowercase,
/// NFC).
pub(crate) fn punycode(input: &str) -> Option<String> {
    const BASE: i64 = 36;
    const T_MIN: i64 = 1;
    const T_MAX: i64 = 26;
    const SKEW: i64 = 38;
    const DAMP: i64 = 700;
    fn digit(value: i64) -> char {
        (if value < 26 {
            b'a' + value as u8
        } else {
            b'0' + (value - 26) as u8
        }) as char
    }
    fn adapt(delta: i64, points: i64, first: bool) -> i64 {
        let mut delta = if first { delta / DAMP } else { delta / 2 };
        delta += delta / points;
        let mut k = 0;
        while delta > ((BASE - T_MIN) * T_MAX) / 2 {
            delta /= BASE - T_MIN;
            k += BASE;
        }
        k + ((BASE - T_MIN + 1) * delta) / (delta + SKEW)
    }
    let points: Vec<i64> = input.chars().map(|c| c as i64).collect();
    let mut output: String = input.chars().filter(char::is_ascii).collect();
    let basic = output.chars().count();
    let mut handled = basic;
    if basic > 0 {
        output.push('-');
    }
    let (mut n, mut delta, mut bias) = (0x80_i64, 0_i64, 72_i64);
    while handled < points.len() {
        let next = points.iter().copied().filter(|&p| p >= n).min()?;
        let product = (next - n).checked_mul(handled as i64 + 1)?;
        if delta > i64::from(i32::MAX) - product {
            return None;
        }
        delta += product;
        n = next;
        for &point in &points {
            if point < n {
                delta += 1;
            }
            if point != n {
                continue;
            }
            let mut q = delta;
            let mut k = BASE;
            loop {
                let t = if k <= bias {
                    T_MIN
                } else if k >= bias + T_MAX {
                    T_MAX
                } else {
                    k - bias
                };
                if q < t {
                    break;
                }
                output.push(digit(t + (q - t) % (BASE - t)));
                q = (q - t) / (BASE - t);
                k += BASE;
            }
            output.push(digit(q));
            bias = adapt(delta, handled as i64 + 1, handled == basic);
            delta = 0;
            handled += 1;
        }
        delta += 1;
        n += 1;
    }
    Some(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_list_is_complete_and_matches_browser_rules() {
        let list = PublicSuffixList::bundled().expect("bundled list");
        assert_eq!(
            list.public_suffix("www.example.co.uk").as_deref(),
            Some("co.uk")
        );
        assert_eq!(
            list.registrable_domain("www.example.co.uk").as_deref(),
            Some("example.co.uk")
        );
        assert_eq!(list.registrable_domain("co.uk"), None);
        assert!(list.is_public_suffix("github.io"));
        assert!(list.is_public_suffix("COM"));
        assert_eq!(
            list.registrable_domain("octocat.github.io").as_deref(),
            Some("octocat.github.io")
        );
        // The implicit `*` rule for unlisted TLDs.
        assert_eq!(
            list.registrable_domain("a.passkey-fixture.invalid")
                .as_deref(),
            Some("passkey-fixture.invalid")
        );
        assert_eq!(list.public_suffix("bad..host"), None);
        assert_eq!(list.site_or_host("accounts.google.com"), "google.com");
        assert_eq!(list.site_or_host("localhost"), "localhost");
    }

    #[test]
    fn bundled_list_contains_both_sections() {
        assert!(BUNDLED.contains("===BEGIN ICANN DOMAINS==="));
        assert!(BUNDLED.contains("===END PRIVATE DOMAINS==="));
        assert!(PublicSuffixList::parse(BUNDLED).is_complete());
    }

    #[test]
    fn wildcard_exception_and_internationalized_rules() {
        let list = PublicSuffixList::parse(
            "// comment\n*.ck\n!www.ck\nგე\n公司.cn extra words\n\n  \ncom\n",
        );
        assert_eq!(list.public_suffix("a.b.ck").as_deref(), Some("b.ck"));
        assert_eq!(list.registrable_domain("a.b.ck").as_deref(), Some("a.b.ck"));
        assert_eq!(list.public_suffix("www.ck").as_deref(), Some("ck"));
        assert_eq!(list.registrable_domain("www.ck").as_deref(), Some("www.ck"));
        // RFC 3492 sample and the list's own IDN rules, as WebViews report hosts.
        assert_eq!(punycode("公司").as_deref(), Some("55qx5d"));
        assert_eq!(punycode("bücher").as_deref(), Some("bcher-kva"));
        assert!(list.is_public_suffix("xn--55qx5d.cn"));
        assert!(list.is_public_suffix("xn--node"));
        assert!(!list.is_complete());
    }
}
