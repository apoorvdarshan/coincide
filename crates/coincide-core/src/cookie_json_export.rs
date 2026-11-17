//! Cookie-Editor JSON exports use the WebExtension Cookie record shape.
use super::{Cookie, Failure, MAX_ROWS, Preview, Result, Review, SameSite};
use serde::Deserialize;
use serde::de::IgnoredAny;
use serde_json::value::RawValue;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExportedCookie {
    domain: String,
    name: String,
    value: String,
    path: String,
    secure: bool,
    http_only: bool,
    host_only: bool,
    session: bool,
    expiration_date: Option<f64>,
    same_site: Option<String>,
    partition_key: Option<IgnoredAny>,
    first_party_domain: Option<String>,
    #[serde(rename = "storeId")]
    _store_id: Option<String>,
}

impl ExportedCookie {
    fn into_cookie(self) -> Option<Cookie> {
        if self.partition_key.is_some()
            || self
                .first_party_domain
                .is_some_and(|domain| !domain.is_empty())
        {
            return None;
        }
        let expires = match (self.session, self.expiration_date) {
            (true, None) => None,
            (false, Some(seconds)) if (0.0..253402300800.0).contains(&seconds) => {
                // Round down so conversion never extends a cookie's lifetime.
                Some(seconds.floor() as i64)
            }
            _ => return None,
        };
        let same_site = match self.same_site.as_deref() {
            None | Some("unspecified") => SameSite::Unspecified,
            Some("no_restriction" | "none") => SameSite::None,
            Some("lax") => SameSite::Lax,
            Some("strict") => SameSite::Strict,
            _ => return None,
        };
        let domain = if self.host_only {
            if self.domain.starts_with('.') {
                return None;
            }
            self.domain
        } else {
            let host = self.domain.strip_prefix('.').unwrap_or(&self.domain);
            if !matches!(url::Host::parse(host), Ok(url::Host::Domain(_)))
                || psl::domain(host.as_bytes()).is_none()
            {
                return None;
            }
            format!(".{host}")
        };
        Some(Cookie {
            domain,
            name: self.name,
            value: self.value,
            path: self.path,
            secure: self.secure,
            http_only: self.http_only,
            expires,
            same_site,
        })
    }
}

pub(super) fn decode(bytes: &[u8], now: i64) -> Result<(Vec<Cookie>, Preview)> {
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    let rows: Vec<&RawValue> =
        serde_json::from_slice(bytes).map_err(|_| Failure::InvalidSnapshot)?;
    if rows.len() > MAX_ROWS {
        return Err(Failure::LimitExceeded);
    }
    let mut review = Review::default();
    for row in rows {
        let cookie = serde_json::from_str::<ExportedCookie>(row.get())
            .ok()
            .and_then(ExportedCookie::into_cookie);
        if let Some(cookie) = cookie {
            review.add(cookie, true, now)?;
        } else {
            review.unsupported += 1;
        }
    }
    Ok(review.finish())
}
