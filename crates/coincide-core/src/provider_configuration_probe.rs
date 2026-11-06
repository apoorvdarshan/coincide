//! Explicit Check Again data. A version or model listing is never a runtime,
//! account, or model-option grant. Raw CLI output never leaves this parser.
use super::*;
#[derive(Clone, Default)]
pub struct ProbeReport {
    pub executable: PathBuf,
    pub version: Option<String>,
    pub authenticated: Option<bool>,
    pub account: Option<String>,
    pub models: Vec<Value>,
}
pub struct Probe {
    provider: String,
    binary: Binary,
    configuration: Option<LaunchConfiguration>,
}
impl Engine {
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
            "opencode" | "codex" => {}
            _ => bail!("Unsupported provider check"),
        }
        ensure!(allowed(), "Provider check cancelled");
        Ok(report)
    }
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
    fn version_parser_never_treats_arbitrary_auth_output_as_account_or_ready_state() {
        assert_eq!(version(b"Claude Code 2.1.42\n"), Some("2.1.42".into()));
        assert_eq!(version(b"Logged in with fixture-not-a-real-key"), None);
        assert_eq!(bounded_text(&json!("bad\nfixture")), None);
    }
}
