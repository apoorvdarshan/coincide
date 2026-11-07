//! Explicit Check Again data. A version or model listing is never a runtime,
//! account, or model-option grant. Raw CLI output never leaves this parser.
use super::*;
#[derive(Clone, Default)]
pub struct ProbeReport {
    pub executable: PathBuf,
    pub version: Option<String>,
    pub authenticated: Option<bool>,
    pub account: Option<String>,
    pub integrations: Option<String>,
    pub models: Vec<Value>,
}
pub struct Probe {
    provider: String,
    binary: Binary,
    configuration: Option<LaunchConfiguration>,
}
impl Engine {
    pub fn prepare_native_login_account_check(
        &self,
        provider: &str,
        id: &str,
        expected: &str,
    ) -> Result<Probe> {
        self.require_admissions()?;
        self.require_provider_enabled(provider)?;
        let account = self
            .native_login_accounts(provider)?
            .into_iter()
            .find(|account| account.id == id)
            .context("Native account is not configured")?;
        ensure!(
            account.revision == expected,
            "Account changed; reload before checking"
        );
        let configuration = self.native_login_launch_configuration(provider, id)?;
        let executable = configuration
            .approved_executable()
            .context("Install this provider or approve its executable first")?;
        Ok(Probe {
            provider: provider.into(),
            binary: Binary::capture(&executable)?,
            configuration: Some(configuration),
        })
    }
    pub fn prepare_native_provider_check(&self, provider: &str) -> Result<Probe> {
        self.require_admissions()?;
        provider_id(provider)?;
        self.require_provider_enabled(provider)?;
        ensure!(
            provider != "antigravity",
            "Check Antigravity through its managed account and runtime setup"
        );
        let configuration = self.provider_launch_configuration(provider)?;
        let executable = configuration
            .as_ref()
            .and_then(LaunchConfiguration::approved_executable)
            .or_else(|| default_executable(provider))
            .context("Provider executable not found; install it or choose a custom path")?;
        Ok(Probe {
            provider: provider.into(),
            binary: Binary::capture(&executable)?,
            configuration,
        })
    }
}
impl Probe {
    pub fn run(&self, allowed: &impl Fn() -> bool) -> Result<ProbeReport> {
        self.binary.validate()?;
        let _scope = enter(self.configuration.clone());
        let capture = |args: &[&str]| {
            self.binary.validate()?;
            crate::agent::metadata_capture::capture(&self.binary.requested, args, allowed)
        };
        let (success, out, err) = capture(&["--version"])?;
        ensure!(
            success,
            "Provider version check failed; use its setup instructions"
        );
        let mut report = ProbeReport {
            executable: self.binary.requested.clone(),
            version: version(&out).or_else(|| version(&err)),
            ..Default::default()
        };
        match self.provider.as_str() {
            "claude" => {
                if let Ok((true, out, _)) = capture(&["auth", "status", "--json"])
                    && let Ok(value) = serde_json::from_slice::<Value>(&out)
                {
                    report.authenticated = value["loggedIn"].as_bool();
                    if report.authenticated == Some(true) {
                        report.account = bounded_text(&value["email"])
                            .or_else(|| bounded_text(&value["authMethod"]));
                    }
                }
            }
            "cursor" => {
                if let Ok((true, out, _)) = capture(&["status", "--format", "json"])
                    && let Ok(value) = serde_json::from_slice::<Value>(&out)
                {
                    report.authenticated =
                        value["isAuthenticated"].as_bool().or_else(|| {
                            match value["status"].as_str() {
                                Some("authenticated") => Some(true),
                                Some("unauthenticated" | "not_authenticated" | "not_logged_in") => {
                                    Some(false)
                                }
                                _ => None,
                            }
                        });
                    if report.authenticated == Some(true) {
                        report.account = bounded_text(&value["userInfo"]["email"]);
                    }
                }
                if report.authenticated == Some(true)
                    && let Ok((true, out, _)) = capture(&["models"])
                {
                    report.models = cursor_models(&out);
                }
            }
            "grok" => {
                if let Ok((true, out, err)) = capture(&["models"]) {
                    let text = format!(
                        "{}\n{}",
                        String::from_utf8_lossy(&out),
                        String::from_utf8_lossy(&err)
                    );
                    let lower = text.to_lowercase();
                    report.authenticated = if lower.contains("you are logged in") {
                        Some(true)
                    } else if lower.contains("not authenticated") || lower.contains("not logged in")
                    {
                        Some(false)
                    } else {
                        None
                    };
                    for line in text.lines() {
                        let line = line.trim();
                        if let Some(rest) =
                            line.strip_prefix("* ").or_else(|| line.strip_prefix("- "))
                            && let Some(id) = rest
                                .split_whitespace()
                                .next()
                                .filter(|id| crate::composer_selection::validate_model(id).is_ok())
                            && report.models.len() < 1000
                            && !report.models.iter().any(|model| model["id"] == id)
                        {
                            report.models.push(json!({"id":id,"name":id}));
                        }
                    }
                }
            }
            "opencode" => {
                self.binary.validate()?;
                if report
                    .version
                    .as_deref()
                    .and_then(|version| version.split('.').next())
                    .and_then(|major| major.parse::<u64>().ok())
                    .is_none_or(|major| major >= 2)
                    && let Ok((models, integrations)) = crate::agent::opencode_installation_metadata(
                        &self.binary.requested,
                        allowed,
                    )
                {
                    report.models = models;
                    report.integrations = integrations;
                }
            }
            "codex" => {}
            _ => bail!("Unsupported provider check"),
        }
        ensure!(allowed(), "Provider check cancelled");
        Ok(report)
    }
}
// Swift CursorModels.parseModelsCommand uses the CLI's "id - name" rows.
// These remain display metadata, never an ACP model/options capability grant.
fn cursor_models(bytes: &[u8]) -> Vec<Value> {
    let mut clean = String::new();
    let mut escape = false;
    for character in String::from_utf8_lossy(bytes).chars() {
        if character == '\u{1b}' {
            escape = true;
            continue;
        }
        if escape {
            if character.is_ascii_alphabetic() || character == '~' {
                escape = false;
            }
            continue;
        }
        clean.push(character);
    }
    let mut rows = Vec::new();
    for line in clean.lines().take(4000) {
        let Some((id, name)) = line.trim().split_once(" - ") else {
            continue;
        };
        if crate::composer_selection::validate_model(id).is_err()
            || rows.iter().any(|row: &Value| row["id"] == id)
        {
            continue;
        }
        let name = name
            .trim()
            .trim_end_matches(" (default)")
            .trim_end_matches(" (current)");
        let Some(name) = bounded_text(&json!(name)) else {
            continue;
        };
        rows.push(json!({"id":id,"displayName":name}));
        if rows.len() == 1000 {
            break;
        }
    }
    rows
}
fn bounded_text(value: &Value) -> Option<String> {
    value
        .as_str()
        .filter(|value| {
            !value.is_empty() && value.len() <= 512 && !value.chars().any(char::is_control)
        })
        .map(str::to_owned)
}
fn version(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    text.split(|character: char| {
        !character.is_ascii_alphanumeric() && !matches!(character, '.' | '-' | '+')
    })
    .find(|word| {
        word.len() <= 64
            && word
                .split('.')
                .take(3)
                .filter(|part| !part.is_empty() && part.bytes().all(|byte| byte.is_ascii_digit()))
                .count()
                == 3
    })
    .map(str::to_owned)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn named_check_captures_only_native_profile_and_rejects_stale_review() {
        let (_root, mut engine, binary) = super::super::tests::fixture();
        super::super::tests::save(&mut engine, "claude", &binary, "synthetic");
        let account = engine
            .create_native_login_account("claude", "Work")
            .unwrap();
        let probe = engine
            .prepare_native_login_account_check("claude", &account.id, &account.revision)
            .unwrap();
        let _scope = enter(probe.configuration.clone());
        assert_eq!(
            effective_var("CLAUDE_CONFIG_DIR"),
            Some(account.home.as_os_str().to_owned())
        );
        assert!(effective_var("ANTHROPIC_API_KEY").is_none());
        engine
            .rename_native_login_account("claude", &account.id, &account.revision, "Changed")
            .unwrap();
        assert!(
            engine
                .prepare_native_login_account_check("claude", &account.id, &account.revision)
                .is_err()
        );
        assert!(
            engine
                .prepare_native_login_account_check(
                    "claude",
                    &Uuid::new_v4().to_string(),
                    &account.revision
                )
                .is_err()
        );
    }
    #[test]
    fn cursor_cli_models_keep_reported_order_and_names_without_granting_options() {
        let rows = cursor_models(b"Available models:\n\x1b[32mreported-a - First model (default)\x1b[0m\nreported-b - Second model (current)\nreported-a - Duplicate\n--bad - Not a model\n");
        assert_eq!(rows,json!([{"id":"reported-a","displayName":"First model"},{"id":"reported-b","displayName":"Second model"}]).as_array().unwrap().clone());
        assert!(rows.iter().all(|row| row.get("reportedEfforts").is_none()
            && row.get("authenticationChecked").is_none()));
    }
    #[test]
    fn version_parser_never_treats_arbitrary_auth_output_as_account_or_ready_state() {
        assert_eq!(version(b"Claude Code 2.1.42\n"), Some("2.1.42".into()));
        assert_eq!(version(b"Logged in with fixture-not-a-real-key"), None);
        assert_eq!(bounded_text(&json!("bad\nfixture")), None);
    }
}
