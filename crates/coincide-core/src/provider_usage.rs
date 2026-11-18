//! Background usage reads for the default provider account. Credentials never
//! leave their provider's fixed first-party host or the native process.
use crate::{
    api::Engine,
    provider_configuration::{self, LaunchConfiguration},
    usage_limits::{Figure, Limits, Unit, Window, WindowKind},
};
use chrono::{DateTime, Utc};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    io::Read,
    path::{Path, PathBuf},
    sync::mpsc::Receiver,
    time::Duration,
};
use zeroize::Zeroizing;

const MAX_FILE: u64 = 1024 * 1024;
const MAX_RESPONSE: u64 = 2 * 1024 * 1024;
const GROK_SCOPES: [&str; 2] = [
    "https://auth.x.ai::b1a00492-073a-47ea-816f-4c329264a828",
    "https://accounts.x.ai/sign-in",
];
const GROK_CUSTOM: [&str; 12] = [
    "GROK_OIDC_ISSUER",
    "GROK_OIDC_CLIENT_ID",
    "GROK_OAUTH2_ISSUER",
    "GROK_OAUTH2_CLIENT_ID",
    "GROK_OAUTH2_PRINCIPAL_TYPE",
    "GROK_OAUTH2_PRINCIPAL_ID",
    "GROK_AUTH_PROVIDER_COMMAND",
    "GROK_LOCAL_AUTH",
    "GROK_CLI_CHAT_PROXY_BASE_URL",
    "GROK_MODELS_BASE_URL",
    "GROK_CONFIG",
    "GROK_CONFIG_PATH",
];
/// Browser sessions are only read after the user enabled this feature. Honor
/// the Swift app's existing OpenCode browser-usage choice during migration.
pub fn browser_fallback_enabled(settings: &Value) -> bool {
    settings["usageBrowserFallbackEnabled"]
        .as_bool()
        .unwrap_or_else(|| {
            settings["usageBrowserSignIn"]
                .as_array()
                .is_some_and(|sources| sources.iter().any(|source| source == "opencode-console"))
        })
}

/// An opaque snapshot of the provider's approved default-account configuration.
pub struct Prepared {
    provider: &'static str,
    config: Option<LaunchConfiguration>,
    cursor_keychain: bool,
    browser_fallback: bool,
}
pub struct Completed {
    prepared: Prepared,
    pub result: Result<Limits, &'static str>,
}
struct Credential {
    token: Zeroizing<String>,
    org: Option<String>,
}
impl Credential {
    fn signature(&self) -> [u8; 32] {
        let mut digest = Sha256::new();
        digest.update(self.token.as_bytes());
        digest.update([0]);
        digest.update(self.org.as_deref().unwrap_or("").as_bytes());
        digest.finalize().into()
    }
}
impl Engine {
    /// Captures provider configuration under the engine lock, then the caller
    /// can run network I/O on a worker without blocking the app.
    pub fn prepare_default_usage(&self, provider: &'static str) -> anyhow::Result<Prepared> {
        anyhow::ensure!(
            matches!(
                provider,
                "grok" | "opencode" | "cursor" | "antigravity" | "lithos" | "acp-devin"
            ),
            "Unsupported usage reader"
        );
        anyhow::ensure!(!self.admissions_frozen(), "Usage is closing");
        self.require_provider_enabled(provider)?;
        Ok(Prepared {
            provider,
            // Lithos console usage is independent of the local coding
            // executable and its inference key.
            config: if provider == "lithos" {
                None
            } else {
                self.provider_launch_configuration(provider)?
            },
            cursor_keychain: provider == "cursor"
                && self
                    .store
                    .document("settings.json")?
                    .is_some_and(|settings| settings["cursorKeychainUsageEnabled"] == true),
            browser_fallback: if matches!(provider, "opencode" | "lithos") {
                self.store
                    .document("settings.json")?
                    .is_some_and(|settings| {
                        (provider == "opencode" && browser_fallback_enabled(&settings))
                            || (provider == "lithos"
                                && settings["usageLithosBrowserFallbackEnabled"] == true)
                    })
            } else {
                false
            },
        })
    }
}
impl Completed {
    /// Discard the result if the user disabled the provider or changed the
    /// approved account environment while the network request was in flight.
    pub fn still_current(&self, engine: &Engine) -> bool {
        if engine.admissions_frozen()
            || engine
                .require_provider_enabled(self.prepared.provider)
                .is_err()
        {
            return false;
        }
        if matches!(self.prepared.provider, "cursor" | "opencode" | "lithos") {
            let Ok(settings) = engine.store.document("settings.json") else {
                return false;
            };
            if self.prepared.provider == "cursor"
                && settings
                    .as_ref()
                    .is_some_and(|s| s["cursorKeychainUsageEnabled"] == true)
                    != self.prepared.cursor_keychain
            {
                return false;
            }
            if self.prepared.provider == "opencode"
                && settings.as_ref().is_some_and(browser_fallback_enabled)
                    != self.prepared.browser_fallback
            {
                return false;
            }
            if self.prepared.provider == "lithos"
                && settings
                    .as_ref()
                    .is_some_and(|s| s["usageLithosBrowserFallbackEnabled"] == true)
                    != self.prepared.browser_fallback
            {
                return false;
            }
        }
        if self.prepared.provider == "lithos" {
            return true;
        }
        match engine.provider_launch_configuration(self.prepared.provider) {
            Ok(current) => {
                current.as_ref().map(|c| c.stamp())
                    == self.prepared.config.as_ref().map(|c| c.stamp())
            }
            Err(_) => false,
        }
    }
}
impl Prepared {
    pub fn run(
        self,
        browser_cookie: Option<Receiver<Option<Zeroizing<String>>>>,
        chrome_default: bool,
    ) -> Completed {
        let _scope = provider_configuration::enter(self.config.clone());
        if self.provider == "acp-devin" {
            let result = self
                .config
                .as_ref()
                .and_then(|config| config.approved_executable())
                .ok_or("Add Devin in Providers to check account usage.")
                .and_then(|executable| crate::devin_usage::read(&executable));
            return Completed {
                prepared: self,
                result,
            };
        }
        if self.provider == "lithos" {
            let result = if self.browser_fallback {
                crate::lithos_usage::read(browser_cookie)
            } else {
                Err("Enable Lithos console usage and sign in to see its balance and spend.")
            };
            return Completed {
                prepared: self,
                result,
            };
        }
        let result = (|| {
            let first = match credential(self.provider, self.cursor_keychain) {
                Ok(credential) => credential,
                Err(original) if self.provider == "opencode" && self.browser_fallback => {
                    if browser_cookie.is_none() && !chrome_default {
                        return Err(original);
                    }
                    let result = read_browser_fallback(None, browser_cookie, chrome_default, true);
                    if credential(self.provider, self.cursor_keychain).is_ok() {
                        return Err("The provider sign-in changed. Refresh to try again.");
                    }
                    return result;
                }
                Err(error) => return Err(error),
            };
            let signature = first.signature();
            let mut result = match self.provider {
                "grok" => read_grok(&first),
                "opencode" => read_opencode(&first),
                "cursor" => read_cursor(&first),
                _ => Err("This provider does not report limits yet."),
            };
            if self.provider == "opencode"
                && self.browser_fallback
                && (browser_cookie.is_some() || chrome_default)
            {
                let separate = first.org.is_none() && result.is_err();
                match read_browser_fallback(Some(&first), browser_cookie, chrome_default, separate)
                {
                    Ok(mut extra) => match &mut result {
                        Ok(limits) => {
                            limits.figures.append(&mut extra.figures);
                        }
                        Err(_) => result = Ok(extra),
                    },
                    Err(reason) if result.is_err() => result = Err(reason),
                    Err(_) => {}
                }
            }
            // Re-resolve the selected account after I/O; never display a report
            // for a sign-in that changed while the request was in flight.
            if credential(self.provider, self.cursor_keychain)
                .map(|c| c.signature())
                .ok()
                != Some(signature)
            {
                return Err("The provider sign-in changed. Refresh to try again.");
            }
            result
        })();
        Completed {
            prepared: self,
            result,
        }
    }
}
fn env(name: &str) -> Option<String> {
    provider_configuration::effective_var(name)?
        .into_string()
        .ok()
        .and_then(|s| {
            let s = s.trim().to_owned();
            (!s.is_empty()).then_some(s)
        })
}
fn home() -> Result<PathBuf, &'static str> {
    env("HOME")
        .map(PathBuf::from)
        .ok_or("The provider's home folder is unavailable.")
}
fn read_file(path: &Path) -> Result<Option<Zeroizing<String>>, &'static str> {
    let file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(_) => return Err("The provider's sign-in could not be read."),
    };
    if !file
        .metadata()
        .is_ok_and(|m| m.is_file() && m.len() <= MAX_FILE)
    {
        return Err("The provider's sign-in is invalid.");
    }
    let mut text = Zeroizing::new(String::new());
    file.take(MAX_FILE + 1)
        .read_to_string(&mut text)
        .map_err(|_| "The provider's sign-in could not be read.")?;
    if text.len() as u64 > MAX_FILE {
        return Err("The provider's sign-in is invalid.");
    }
    Ok(Some(text))
}
fn token(value: Option<&str>) -> Result<Zeroizing<String>, &'static str> {
    let token = value
        .map(str::trim)
        .filter(|v| !v.is_empty() && v.len() <= 16384 && !v.chars().any(char::is_control))
        .ok_or("This provider has no supported signed-in account to read.")?;
    Ok(Zeroizing::new(token.to_owned()))
}
fn credential(provider: &str, cursor_keychain: bool) -> Result<Credential, &'static str> {
    match provider {
        "grok" => grok_credential(),
        "opencode" => opencode_credential(),
        "cursor" => cursor_credential(cursor_keychain),
        "antigravity" => {
            Err("Gemini API-key accounts do not expose Antigravity subscription limits.")
        }
        _ => Err("This provider does not report limits yet."),
    }
}
fn custom_grok_config(text: &str) -> bool {
    text.lines().any(|line| {
        let line = line
            .trim_start()
            .trim_start_matches('[')
            .trim_start()
            .trim_start_matches(['\'', '"']);
        ["auth", "grok_com_config", "endpoints"].iter().any(|key| {
            line.strip_prefix(key).is_some_and(|s| {
                let s = s.trim_start().trim_start_matches(['\'', '"']).trim_start();
                s.starts_with('.') || s.starts_with(']') || s.starts_with('=')
            })
        })
    })
}
fn grok_credential() -> Result<Credential, &'static str> {
    if env("XAI_API_KEY").is_some() || GROK_CUSTOM.iter().any(|v| env(v).is_some()) {
        return Err(
            "Grok's current API key or custom account does not expose subscription limits.",
        );
    }
    let dir = env("GROK_HOME")
        .map(PathBuf::from)
        .unwrap_or(home()?.join(".grok"));
    for path in [
        dir.join("config.toml"),
        dir.join("managed_config.toml"),
        dir.join("requirements.toml"),
        PathBuf::from("/etc/grok/managed_config.toml"),
        PathBuf::from("/etc/grok/requirements.toml"),
    ] {
        if read_file(&path)?.is_some_and(|s| custom_grok_config(&s)) {
            return Err(
                "Grok uses a custom account or endpoint; its limits cannot be identified safely.",
            );
        }
    }
    let data = match env("GROK_AUTH") {
        Some(s) => Zeroizing::new(s),
        None => read_file(&dir.join("auth.json"))?
            .ok_or("Sign in to Grok to see subscription limits.")?,
    };
    let auth: Value =
        serde_json::from_str(&data).map_err(|_| "Grok's sign-in could not be read.")?;
    let entries = auth
        .as_object()
        .ok_or("Grok's sign-in could not be read.")?;
    if !entries.values().all(|v| {
        v.is_object()
            && ["key", "auth_mode", "email"]
                .iter()
                .all(|k| v.get(k).is_none_or(Value::is_string))
    }) {
        return Err("Grok's sign-in could not be read.");
    }
    let entry = GROK_SCOPES
        .iter()
        .find_map(|key| entries.get(*key))
        .ok_or("Sign in to Grok to see subscription limits.")?;
    if entry["auth_mode"] == "api_key" {
        return Err("Grok's API key does not expose subscription limits.");
    }
    Ok(Credential {
        token: token(entry["key"].as_str())?,
        org: None,
    })
}
fn opencode_credential() -> Result<Credential, &'static str> {
    let root = env("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or(home()?.join(".local/share"))
        .join("opencode");
    let inline = env("OPENCODE_AUTH_CONTENT");
    if inline.is_none() {
        let name = env("OPENCODE_DB").unwrap_or_else(|| "opencode.db".into());
        if name != ":memory:" {
            let path = PathBuf::from(&name);
            let path = if path.is_absolute() {
                path
            } else {
                root.join(path)
            };
            if path.exists() {
                let db = rusqlite::Connection::open_with_flags(
                    path,
                    rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
                        | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
                )
                .map_err(|_| "OpenCode's active sign-in could not be read.")?;
                db.busy_timeout(Duration::from_millis(100))
                    .map_err(|_| "OpenCode's active sign-in could not be read.")?;
                use rusqlite::OptionalExtension;
                let raw: Option<Zeroizing<String>> = db.query_row("SELECT value FROM credential WHERE integration_id='opencode' AND active IS NOT 0 ORDER BY active DESC, time_created DESC, id DESC LIMIT 1", [], |r| r.get::<_, String>(0)).optional().map_err(|_| "OpenCode's active sign-in could not be read.")?.map(Zeroizing::new);
                if let Some(raw) = raw {
                    if raw.len() as u64 > MAX_FILE {
                        return Err("OpenCode's active sign-in is invalid.");
                    }
                    let entry: Value = serde_json::from_str(&raw)
                        .map_err(|_| "OpenCode's active sign-in is invalid.")?;
                    let server = entry["metadata"]["server"]
                        .as_str()
                        .unwrap_or("https://opencode.ai/console")
                        .trim_end_matches('/');
                    if server != "https://opencode.ai/console" {
                        return Err(
                            "OpenCode uses a custom server; its account limits cannot be identified safely.",
                        );
                    }
                    let org = entry["metadata"]["orgID"]
                        .as_str()
                        .filter(|s| {
                            !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control)
                        })
                        .map(str::to_owned);
                    let value = match entry["type"].as_str() {
                        Some("key") => entry["key"].as_str(),
                        Some("oauth") => {
                            if entry["expires"]
                                .as_i64()
                                .is_some_and(|n| n <= Utc::now().timestamp_millis())
                            {
                                return Err(
                                    "OpenCode's sign-in has expired; sign in again to see limits.",
                                );
                            }
                            entry["access"].as_str()
                        }
                        _ => return Err("OpenCode's active sign-in does not expose limits."),
                    };
                    return Ok(Credential {
                        token: token(value)?,
                        org,
                    });
                }
            }
        }
    }
    let data = match inline {
        Some(v) => Some(Zeroizing::new(v)),
        None => read_file(&root.join("auth.json"))?,
    };
    let auth: Value = match data {
        Some(d) => serde_json::from_str(&d).map_err(|_| "OpenCode's sign-in could not be read.")?,
        None => Value::Null,
    };
    let stored = if auth["opencode-go"]["type"] == "api" {
        auth["opencode-go"]["key"].as_str()
    } else {
        None
    };
    let supplied = env("OPENCODE_API_KEY");
    Ok(Credential {
        token: token(stored.or(supplied.as_deref()))?,
        org: None,
    })
}
fn cursor_credential(allow_keychain: bool) -> Result<Credential, &'static str> {
    if ["CURSOR_API_ENDPOINT", "CURSOR_API_BASE_URL"]
        .iter()
        .any(|name| env(name).is_some_and(|s| s.trim_end_matches('/') != "https://api2.cursor.sh"))
    {
        return Err(
            "Cursor uses a custom endpoint; its account limits cannot be identified safely.",
        );
    }
    let explicit = env("CURSOR_AUTH_TOKEN");
    if explicit.is_none() && env("CURSOR_API_KEY").is_some() {
        return Err("Cursor's API key does not expose subscription limits.");
    }
    let store = env("AGENT_CLI_CREDENTIAL_STORE");
    let value = if let Some(v) = explicit {
        Zeroizing::new(v)
    } else if store.as_deref() == Some("file") {
        let data = read_file(&home()?.join(".cursor/auth.json"))?
            .ok_or("Sign in to Cursor to see subscription limits.")?;
        let auth: Value =
            serde_json::from_str(&data).map_err(|_| "Cursor's sign-in could not be read.")?;
        token(auth["accessToken"].as_str())?
    } else if store.as_deref() == Some("memory") {
        return Err("Cursor's in-memory sign-in cannot be read for usage.");
    } else if allow_keychain && cfg!(target_os = "macos") {
        let bytes = crate::agent::usage_keychain_access_token()
            .map_err(|_| "Cursor's Keychain sign-in could not be read.")?
            .ok_or("Sign in to Cursor to see subscription limits.")?;
        let bytes = Zeroizing::new(bytes);
        let text =
            std::str::from_utf8(&bytes).map_err(|_| "Cursor's Keychain sign-in is invalid.")?;
        token(Some(text))?
    } else {
        return Err("Enable Cursor account usage in Cursor settings to see its limits.");
    };
    Ok(Credential {
        token: token(Some(&value))?,
        org: None,
    })
}
fn date(value: Option<&str>) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value?)
        .ok()
        .map(|v| v.with_timezone(&Utc))
}
fn read_http(
    url: &'static str,
    method: &str,
    cred: &Credential,
    org_header: Option<&str>,
) -> Result<(u16, Value), &'static str> {
    let agent = ureq::Agent::config_builder()
        .proxy(None)
        .max_redirects(0)
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(10)))
        .build()
        .new_agent();
    let bearer = Zeroizing::new(format!("Bearer {}", cred.token.as_str()));
    let mut request = ureq::http::Request::builder()
        .method(method)
        .uri(url)
        .header("Authorization", bearer.as_str())
        .header("Accept", "application/json");
    if let (Some(header), Some(org)) = (org_header, &cred.org) {
        request = request.header(header, org);
    }
    if method == "POST" {
        request = request
            .header("Content-Type", "application/json")
            .header("connect-protocol-version", "1")
            .header("x-cursor-client-type", "cli");
    }
    let req = request
        .body(if method == "POST" { "{}" } else { "" })
        .map_err(|_| "The usage check could not start.")?;
    let mut response = agent
        .run(req)
        .map_err(|_| "The usage check failed or timed out.")?;
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Ok((status, Value::Null));
    }
    let mut bytes = Zeroizing::new(Vec::new());
    response
        .body_mut()
        .as_reader()
        .take(MAX_RESPONSE + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "The usage response could not be read.")?;
    if bytes.len() as u64 > MAX_RESPONSE {
        return Err("The usage response was too large.");
    }
    let value = serde_json::from_slice(&bytes)
        .map_err(|_| "The provider returned an invalid usage response.")?;
    Ok((status, value))
}
fn read_grok(cred: &Credential) -> Result<Limits, &'static str> {
    let (status, value) = read_http(
        "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
        "GET",
        cred,
        None,
    )?;
    if !(200..300).contains(&status) {
        return Err("Grok did not accept the subscription usage request.");
    }
    parse_grok(&value)
}
fn parse_grok(value: &Value) -> Result<Limits, &'static str> {
    let config = &value["config"];
    let period = &config["currentPeriod"];
    let kind = match period["type"]
        .as_str()
        .unwrap_or("")
        .trim_start_matches("USAGE_PERIOD_TYPE_")
    {
        "WEEKLY" => WindowKind::Weekly,
        "MONTHLY" => WindowKind::Monthly,
        _ => WindowKind::Other,
    };
    let reset = date(period["end"].as_str());
    let reported = match config.get("creditUsagePercent") {
        None => None,
        Some(value) => Some(
            value
                .as_f64()
                .filter(|n| n.is_finite())
                .ok_or("Grok returned an invalid subscription allowance.")?,
        ),
    };
    let used = reported
        .or_else(|| {
            let start = date(period["start"].as_str())?;
            (kind != WindowKind::Other && start < reset?).then_some(0.)
        })
        .ok_or("Grok did not report a subscription allowance.")?;
    let label = match kind {
        WindowKind::Weekly => "Weekly",
        WindowKind::Monthly => "Monthly",
        _ => "Subscription",
    };
    Ok(Limits::new(
        vec![Window::new("subscription", kind, label, used).resetting(reset, None)],
        Utc::now(),
    ))
}
fn read_opencode(cred: &Credential) -> Result<Limits, &'static str> {
    let go = read_http(
        "https://opencode.ai/zen/go/v1/usage",
        "GET",
        cred,
        Some("x-opencode-org-id"),
    );
    let budgets = if cred.org.is_some() {
        read_http(
            "https://opencode.ai/console/api/policies/current-budgets",
            "GET",
            cred,
            Some("x-org-id"),
        )
    } else {
        Ok((403, Value::Null))
    };
    parse_opencode(go, budgets)
}
fn parse_opencode(
    go: Result<(u16, Value), &'static str>,
    budgets: Result<(u16, Value), &'static str>,
) -> Result<Limits, &'static str> {
    let mut limits = Limits::new(Vec::new(), Utc::now());
    if let Ok((go_status, go)) = &go
        && (200..300).contains(go_status)
    {
        for (key, kind, label, mins) in [
            ("rolling", WindowKind::Session, "Go · Session", Some(300)),
            ("weekly", WindowKind::Weekly, "Go · Weekly", Some(10080)),
            ("monthly", WindowKind::Monthly, "Go · Monthly", None),
        ] {
            let meter = &go["usage"][key];
            if let (Some(percent), Some(reset)) = (
                meter["percent"].as_f64().filter(|n| n.is_finite()),
                date(meter["resetsAt"].as_str()),
            ) {
                limits
                    .windows
                    .push(Window::new(key, kind, label, percent).resetting(Some(reset), mins));
            }
        }
    }
    if let Ok((status, budgets)) = &budgets
        && (200..300).contains(status)
        && let Some(rows) = budgets.as_array()
    {
        for (i, row) in rows.iter().take(32).enumerate() {
            let (Some(limit), Some(used)) = (
                row["limitDollars"]
                    .as_f64()
                    .filter(|n| n.is_finite() && *n >= 0.),
                row["spentDollars"]
                    .as_f64()
                    .filter(|n| n.is_finite() && *n >= 0.),
            ) else {
                continue;
            };
            let mut figure = Figure::new(
                &format!("budget-{i}"),
                "Budget",
                Unit::Currency("USD".into()),
            );
            figure.limit = Some(limit);
            figure.used = Some(used);
            figure.resets_at = date(row["resetsAt"].as_str());
            limits.figures.push(figure);
        }
    }
    if limits.has_rows() {
        limits.sort();
        return Ok(limits);
    }
    if go.as_ref().is_ok_and(|(status, _)| *status == 403)
        && budgets.as_ref().is_ok_and(|(status, _)| *status == 403)
    {
        Err("OpenCode did not provide plan limits for this sign-in.")
    } else if let Some(error) = go.err().or_else(|| budgets.err()) {
        Err(error)
    } else {
        Err("OpenCode did not report any plan limits.")
    }
}
fn read_browser_fallback(
    credential: Option<&Credential>,
    receiver: Option<Receiver<Option<Zeroizing<String>>>>,
    chrome_default: bool,
    separate: bool,
) -> Result<Limits, &'static str> {
    let read = |cookie: &str| {
        if separate {
            read_opencode_browser_independent(cookie)
        } else {
            read_opencode_browser(
                credential.ok_or("OpenCode's browser and CLI accounts could not be matched.")?,
                cookie,
            )
        }
    };
    let mut reason = "Sign in to OpenCode in your browser to see its Zen balance.";
    if let Some(receiver) = receiver
        && let Ok(Some(cookie)) = receiver.recv_timeout(Duration::from_secs(4))
    {
        match read(&cookie) {
            Ok(result) => return Ok(result),
            Err(error) => reason = error,
        }
    }
    #[cfg(target_os = "macos")]
    if chrome_default {
        let cookie = crate::browser_usage_chrome::opencode_header()?;
        return read(&cookie);
    }
    #[cfg(not(target_os = "macos"))]
    let _ = chrome_default;
    Err(reason)
}
fn read_browser_http(
    url: &'static str,
    cookie: &str,
    org: Option<&str>,
) -> Result<Value, &'static str> {
    let agent = ureq::Agent::config_builder()
        .proxy(None)
        .max_redirects(0)
        .http_status_as_error(false)
        .timeout_global(Some(Duration::from_secs(10)))
        .build()
        .new_agent();
    let mut request = ureq::http::Request::builder()
        .method("GET")
        .uri(url)
        .header("Cookie", cookie)
        .header("Accept", "application/json");
    if let Some(org) = org {
        request = request.header("x-org-id", org);
    }
    let mut response = agent
        .run(
            request
                .body("")
                .map_err(|_| "The browser usage check could not start.")?,
        )
        .map_err(|_| "OpenCode's browser usage check failed or timed out.")?;
    if !response.status().is_success() {
        return Err("OpenCode's browser sign-in could not read its billing.");
    }
    let mut bytes = Zeroizing::new(Vec::new());
    response
        .body_mut()
        .as_reader()
        .take(MAX_RESPONSE + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "OpenCode's browser usage could not be read.")?;
    if bytes.len() as u64 > MAX_RESPONSE {
        return Err("OpenCode's browser usage response was too large.");
    }
    serde_json::from_slice(&bytes)
        .map_err(|_| "OpenCode's billing page returned an unrecognized response.")
}
fn read_opencode_browser(cred: &Credential, cookie: &str) -> Result<Limits, &'static str> {
    let org = cred
        .org
        .as_deref()
        .filter(|org| valid_browser_workspace(org))
        .ok_or("OpenCode's browser and CLI accounts could not be matched.")?;
    let workspaces = read_browser_http("https://opencode.ai/console/api/orgs", cookie, None)?;
    if !browser_workspace_matches(&workspaces, org) {
        return Err("The OpenCode browser sign-in does not match the CLI workspace.");
    }
    let billing = read_browser_http(
        "https://opencode.ai/console/api/billing/drawer/status",
        cookie,
        Some(org),
    )?;
    parse_opencode_browser(&billing)
}
fn read_opencode_browser_independent(cookie: &str) -> Result<Limits, &'static str> {
    let workspaces = read_browser_http("https://opencode.ai/console/api/orgs", cookie, None)?;
    browser_balances_independent(&workspaces, |org| {
        read_browser_http(
            "https://opencode.ai/console/api/billing/drawer/status",
            cookie,
            Some(org),
        )
    })
}
fn browser_balances_independent(
    workspaces: &Value,
    mut read: impl FnMut(&str) -> Result<Value, &'static str>,
) -> Result<Limits, &'static str> {
    let rows = workspaces
        .as_array()
        .filter(|rows| rows.len() <= 100)
        .ok_or("OpenCode's browser account returned an unrecognized workspace list.")?;
    let mut limits = Limits::new(Vec::new(), Utc::now());
    for row in rows.iter().filter(|row| row["blocked"] != true).take(10) {
        let Some(org) = row["id"]
            .as_str()
            .filter(|org| valid_browser_workspace(org))
        else {
            continue;
        };
        if let Ok(billing) = read(org)
            && let Ok(mut workspace) = parse_opencode_browser(&billing)
            && let Some(mut figure) = workspace.figures.pop()
        {
            figure.id = format!("zen_balance_{}", limits.figures.len());
            figure.detail = row["name"]
                .as_str()
                .filter(|name| {
                    !name.is_empty() && name.len() <= 120 && !name.chars().any(char::is_control)
                })
                .map(str::to_owned);
            limits.figures.push(figure);
        }
    }
    if limits.figures.is_empty() {
        return Err("OpenCode's browser account did not report a Zen balance.");
    }
    limits
        .notes
        .push("Browser account; no CLI account was matched.".into());
    Ok(limits)
}
fn browser_workspace_matches(workspaces: &Value, org: &str) -> bool {
    valid_browser_workspace(org)
        && workspaces.as_array().is_some_and(|items| {
            items.len() <= 100 && items.iter().any(|item| item["id"].as_str() == Some(org))
        })
}
fn valid_browser_workspace(org: &str) -> bool {
    org.len() <= 64
        && (org.starts_with("org_") || org.starts_with("wrk_"))
        && org.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
}
fn parse_opencode_browser(body: &Value) -> Result<Limits, &'static str> {
    let billing = &body["billing"];
    let amount = |value: &Value| {
        value
            .as_f64()
            .or_else(|| value.as_str().and_then(|s| s.parse::<f64>().ok()))
            .filter(|n| n.is_finite() && n.fract() == 0. && n.abs() <= 9_007_199_254_740_992.)
    };
    let available = amount(&billing["availableMicroCents"])
        .ok_or("OpenCode did not report a Zen balance for this workspace.")?;
    let mut figure = Figure::new(
        "zen_balance",
        "Zen balance · browser",
        Unit::Currency("USD".into()),
    );
    figure.remaining = Some(available.max(0.) / 100_000_000.);
    if billing["mode"] == "invoiceable" {
        figure.limit = amount(&billing["creditLimitMicroCents"])
            .filter(|n| *n > 0.)
            .map(|n| n / 100_000_000.);
    }
    let mut limits = Limits::new(Vec::new(), Utc::now());
    limits.figures.push(figure);
    Ok(limits)
}
fn read_cursor(cred: &Credential) -> Result<Limits, &'static str> {
    let (status, body) = read_http(
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
        "POST",
        cred,
        None,
    )?;
    if !(200..300).contains(&status) {
        return Err("Cursor did not accept the subscription usage request.");
    }
    parse_cursor(&body)
}
fn parse_cursor(body: &Value) -> Result<Limits, &'static str> {
    let ms = body["billingCycleEnd"].as_i64().or_else(|| {
        body["billingCycleEnd"]
            .as_str()
            .and_then(|s| s.parse().ok())
    });
    let reset = ms.and_then(DateTime::from_timestamp_millis);
    let mut limits = Limits::new(Vec::new(), Utc::now());
    for (key, label) in [
        ("totalPercentUsed", "Overall"),
        ("autoPercentUsed", "Cursor Models"),
        ("apiPercentUsed", "Other Models"),
    ] {
        if let Some(used) = body["planUsage"][key].as_f64().filter(|n| n.is_finite()) {
            limits
                .windows
                .push(Window::new(key, WindowKind::Monthly, label, used).resetting(reset, None));
        }
    }
    let dollars = |v: &Value| {
        v.as_f64()
            .filter(|n| n.is_finite() && *n >= 0.)
            .map(|n| n / 100.)
    };
    let plan = &body["planUsage"];
    if let Some(limit) = dollars(&plan["limit"]).filter(|n| *n > 0.) {
        let mut f = Figure::new("included", "Included usage", Unit::Currency("USD".into()));
        f.limit = Some(limit);
        f.used = dollars(&plan["includedSpend"]);
        f.remaining = dollars(&plan["remaining"]);
        f.resets_at = reset;
        limits.figures.push(f);
    }
    let spend = &body["spendLimitUsage"];
    if let Some(used) = dollars(&spend["individualUsed"]) {
        let mut f = Figure::new("on_demand", "On-demand usage", Unit::Currency("USD".into()));
        f.used = Some(used);
        f.limit = dollars(&spend["individualLimit"]).filter(|n| *n > 0.);
        f.remaining = f.limit.and_then(|_| dollars(&spend["individualRemaining"]));
        f.resets_at = reset;
        limits.figures.push(f);
    }
    if limits.has_rows() {
        limits.sort();
        Ok(limits)
    } else {
        Err("Cursor did not report any plan limits.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn antigravity_usage_never_reads_a_subscription_credential() {
        assert_eq!(
            credential("antigravity", false).err(),
            Some("Gemini API-key accounts do not expose Antigravity subscription limits.")
        );
    }
    #[test]
    fn grok_shows_zero_only_for_a_real_weekly_period() {
        let report = json!({"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-11-01T00:00:00Z","end":"2026-11-08T00:00:00Z"}}});
        let limits = parse_grok(&report).unwrap();
        assert_eq!(limits.windows[0].used_percent, 0.);
        assert_eq!(limits.windows[0].kind, WindowKind::Weekly);
        assert!(limits.windows[0].resets_at.is_some());
        assert!(parse_grok(&json!({"config":{"currentPeriod":{"type":"WEEKLY"}}})).is_err());
        let mut malformed = report;
        malformed["config"]["creditUsagePercent"] = json!("not a number");
        assert!(parse_grok(&malformed).is_err());
    }
    #[test]
    fn grok_custom_config_is_detected() {
        for value in [
            "[auth]",
            "[[endpoints]]",
            "auth.foo=1",
            "\"grok_com_config\" = {}",
        ] {
            assert!(custom_grok_config(value));
        }
        assert!(!custom_grok_config(
            "# [auth]\n[other]\nauthentication = true"
        ));
    }
    #[test]
    fn browser_fallback_requires_opt_in_and_honors_the_swift_setting() {
        assert!(!browser_fallback_enabled(&json!({})));
        assert!(browser_fallback_enabled(
            &json!({"usageBrowserSignIn":["opencode-console"]})
        ));
        assert!(!browser_fallback_enabled(
            &json!({"usageBrowserSignIn":["opencode-console"],"usageBrowserFallbackEnabled":false})
        ));
        assert!(browser_fallback_enabled(
            &json!({"usageBrowserFallbackEnabled":true})
        ));
    }
    #[test]
    fn opencode_reports_only_actual_windows_and_budgets() {
        let meter = |percent| json!({"percent":percent,"resetsAt":"2030-01-01T00:00:00Z"});
        let go = json!({"usage":{"rolling":meter(21),"weekly":meter(35),"monthly":meter(42)}});
        let budgets =
            json!([{"spentDollars":3.25,"limitDollars":10,"resetsAt":"2030-01-01T00:00:00Z"}]);
        let result = parse_opencode(Ok((200, go)), Ok((200, budgets))).unwrap();
        assert_eq!(result.windows.len(), 3);
        assert_eq!(result.windows[0].used_percent, 21.);
        assert_eq!(result.figures[0].left(), Some(6.75));
        assert!(result.figures[0].resets_at.is_some());
        assert_eq!(
            parse_opencode(Ok((403, Value::Null)), Ok((403, Value::Null))),
            Err("OpenCode did not provide plan limits for this sign-in.")
        );
        let partial = json!({"usage":{"weekly":meter(35)}});
        assert_eq!(
            parse_opencode(Ok((200, partial)), Err("budget unavailable"))
                .unwrap()
                .windows
                .len(),
            1
        );
    }
    #[test]
    fn cursor_uses_reported_percentages_and_real_currency_amounts() {
        let response = json!({"billingCycleEnd":"1893456000000","planUsage":{"totalPercentUsed":55,"autoPercentUsed":30,"limit":2000,"includedSpend":500,"remaining":1500},"spendLimitUsage":{"individualUsed":250,"individualLimit":1000,"individualRemaining":750}});
        let result = parse_cursor(&response).unwrap();
        assert_eq!(result.windows.len(), 2);
        assert!(result.windows.iter().all(|w| w.resets_at.is_some()));
        assert_eq!(result.figures[0].used, Some(5.));
        assert_eq!(result.figures[1].left(), Some(7.5));
        assert!(parse_cursor(&json!({})).is_err());
    }
    #[test]
    fn browser_balance_requires_the_same_workspace_and_preserves_currency() {
        let list = json!([{"id":"org_one"},{"id":"org_two"}]);
        assert!(browser_workspace_matches(&list, "org_two"));
        assert!(!browser_workspace_matches(&list, "org_other"));
        assert!(!browser_workspace_matches(
            &json!([{"id":"org_unsafe/header"}]),
            "org_unsafe/header"
        ));
        let value = json!({"billing":{"availableMicroCents":"1250000000","mode":"invoiceable","creditLimitMicroCents":"2000000000"}});
        let result = parse_opencode_browser(&value).unwrap();
        assert_eq!(result.figures[0].remaining, Some(12.5));
        assert_eq!(result.figures[0].limit, Some(20.));
        assert!(parse_opencode_browser(&json!({"billing":null})).is_err());
        let separate = browser_balances_independent(
            &json!([{"id":"org_one","name":"Personal"},{"id":"org_unsafe/header"}]),
            |org| {
                assert_eq!(org, "org_one");
                Ok(value.clone())
            },
        )
        .unwrap();
        assert_eq!(separate.figures[0].detail.as_deref(), Some("Personal"));
        assert_eq!(separate.figures[0].remaining, Some(12.5));
        assert_eq!(
            separate.notes,
            ["Browser account; no CLI account was matched."]
        );
    }
    #[test]
    #[ignore = "explicit read-only check of the local provider accounts"]
    fn live_default_provider_limits() {
        for provider in ["grok", "opencode", "cursor"] {
            let result = credential(provider, false).and_then(|cred| match provider {
                "grok" => read_grok(&cred),
                "opencode" => read_opencode(&cred),
                _ => read_cursor(&cred),
            });
            match result {
                Ok(limits) => println!(
                    "{provider}: {} windows, {} figures, reset reported: {}",
                    limits.windows.len(),
                    limits.figures.len(),
                    limits.windows.iter().any(|w| w.resets_at.is_some())
                ),
                Err(message) => println!("{provider}: {message}"),
            }
        }
    }
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "explicit read-only check of the user's Chrome sign-in"]
    fn live_chrome_opencode_balance() {
        let result = crate::browser_usage_chrome::opencode_header().and_then(|cookie| {
            match opencode_credential() {
                Ok(account) if account.org.is_some() => read_opencode_browser(&account, &cookie),
                _ => read_opencode_browser_independent(&cookie),
            }
        });
        match result {
            Ok(limits) => println!(
                "Chrome OpenCode: {} reported balance figures",
                limits.figures.len()
            ),
            Err(reason) => println!("Chrome OpenCode: {reason}"),
        }
    }
}
