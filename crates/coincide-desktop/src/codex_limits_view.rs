//! Explicit default-Codex-runtime observations, separate from saved turn usage.
use gpui_kit::{base::Disableable, component::button::Button, *};
use serde_json::Value;

const SCOPE: &str = "default_runtime_account_identity_unknown";
#[derive(Clone, Debug, PartialEq)]
pub struct WindowReport {
    pub position: String,
    pub used: Option<f64>,
    pub remaining: Option<f64>,
    pub minutes: Option<u64>,
    pub resets: Option<f64>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Bucket {
    pub id: String,
    pub name: Option<String>,
    pub plan: Option<String>,
    pub windows: Vec<WindowReport>,
    pub credits: Option<Credits>,
    pub notes: Vec<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Credits {
    pub has: Option<bool>,
    pub unlimited: Option<bool>,
    pub balance: Option<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub enum Phase {
    Idle,
    Loading,
    Ready {
        observed_ms: Option<u64>,
        buckets: Vec<Bucket>,
    },
    Failed(&'static str),
    Closing,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Observation {
    pub request_id: String,
    pub generation: u64,
    pub phase: Phase,
}
fn text(value: &Value) -> Result<String, ()> {
    value
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
        .map(str::to_owned)
        .ok_or(())
}
fn optional<T>(value: &Value, read: impl FnOnce(&Value) -> Result<T, ()>) -> Result<Option<T>, ()> {
    if value.is_null() {
        Ok(None)
    } else {
        read(value).map(Some)
    }
}
fn number(value: &Value) -> Result<f64, ()> {
    value.as_f64().filter(|v| v.is_finite()).ok_or(())
}
fn bucket(value: &Value) -> Result<Bucket, ()> {
    value.as_object().ok_or(())?;
    let windows = value["windows"]
        .as_array()
        .filter(|v| v.len() <= 3)
        .ok_or(())?
        .iter()
        .map(|v| {
            Ok(WindowReport {
                position: text(&v["position"])?,
                used: optional(&v["usedPercent"], number)?,
                remaining: optional(&v["remainingPercent"], number)?,
                minutes: optional(&v["durationMinutes"], |v| v.as_u64().ok_or(()))?,
                resets: optional(&v["resetsAtEpochSeconds"], number)?,
            })
        })
        .collect::<Result<Vec<_>, ()>>()?;
    let credits = optional(&value["credits"], |v| {
        v.as_object().ok_or(())?;
        Ok(Credits {
            has: optional(&v["hasCredits"], |v| v.as_bool().ok_or(()))?,
            unlimited: optional(&v["unlimited"], |v| v.as_bool().ok_or(()))?,
            balance: optional(&v["balance"], text)?,
        })
    })?;
    let notes = value["notes"]
        .as_array()
        .filter(|v| v.len() <= 3)
        .ok_or(())?
        .iter()
        .map(|v| match v.as_str() {
            Some("workspace_credits_depleted") => Ok("Workspace credits depleted".into()),
            Some("workspace_usage_limit_reached") => Ok("Workspace usage limit reached".into()),
            Some("workspace_spend_control_reached") => Ok("Workspace spend control reached".into()),
            _ => Err(()),
        })
        .collect::<Result<Vec<_>, ()>>()?;
    Ok(Bucket {
        id: text(&value["id"])?,
        name: optional(&value["displayName"], text)?,
        plan: optional(&value["plan"], text)?,
        windows,
        credits,
        notes,
    })
}
pub fn decode(value: &Value) -> Result<Observation, ()> {
    decode_scoped(value, None)
}
pub(super) fn decode_scoped(value: &Value, target: Option<&Value>) -> Result<Observation, ()> {
    let scope = if let Some(target) = target {
        if value.get("threadId") != target.get("threadId")
            || value.get("accountId") != target.get("accountId")
            || value.get("expectedSelection") != target.get("expectedSelection")
            || value["authenticationChecked"] != (value["state"] == "ready")
        {
            return Err(());
        }
        "named_codex_profile"
    } else {
        SCOPE
    };
    if value["provider"] != "codex"
        || value["accountScope"] != scope
        || value["accountIdentityVerified"] != false
    {
        return Err(());
    }
    let phase = match value["state"].as_str() {
        Some("loading") if value["snapshot"].is_null() && value["error"].is_null() => {
            Phase::Loading
        }
        Some("failed") if value["snapshot"].is_null() => {
            Phase::Failed(match value["error"].as_str() {
                Some("unsupported_platform") => "Codex limits are unavailable on this platform.",
                Some("unavailable_executable") => "The configured Codex executable is unavailable.",
                Some("cancelled") => "The limits read was cancelled. Refresh to try again.",
                Some("no_reported_limits") => {
                    "Codex did not report limits. Missing limits do not mean zero allowance."
                }
                Some("read_failed" | "invalid_response" | "response_too_large") => {
                    "Codex limits could not be read. Refresh to try again."
                }
                _ => return Err(()),
            })
        }
        Some("ready") if value["error"].is_null() => {
            let snapshot = &value["snapshot"];
            if snapshot["provenance"] != "codex_app_server_account_rate_limits"
                || snapshot["accountScope"] != scope
                || snapshot["accountIdentityVerified"] != false
            {
                return Err(());
            }
            let mut buckets = Vec::new();
            if !snapshot["main"].is_null() {
                buckets.push(bucket(&snapshot["main"])?);
            }
            let models = snapshot["modelBuckets"]
                .as_array()
                .filter(|v| v.len() <= 64)
                .ok_or(())?;
            for model in models {
                buckets.push(bucket(model)?);
            }
            if buckets.is_empty() {
                return Err(());
            }
            Phase::Ready {
                observed_ms: optional(&value["observedAtEpochMs"], |v| {
                    v.as_u64().filter(|v| *v > 0).ok_or(())
                })?,
                buckets,
            }
        }
        _ => return Err(()),
    };
    Ok(Observation {
        request_id: text(&value["requestId"])?,
        generation: value["generation"].as_u64().ok_or(())?,
        phase,
    })
}

/// Civil UTC rendering without introducing a new desktop dependency. Inputs are
/// Unix seconds from the limits protocol, never Apple's persisted-date epoch.
fn utc(seconds: f64) -> String {
    if !seconds.is_finite() || !(0.0..=253_402_300_799.0).contains(&seconds) {
        return "Date unavailable".into();
    }
    let seconds = seconds.floor() as i64;
    let day_seconds = seconds % 86_400;
    let z = seconds / 86_400 + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    format!(
        "{year:04}-{month:02}-{day:02} {:02}:{:02}:{:02} UTC",
        day_seconds / 3600,
        day_seconds / 60 % 60,
        day_seconds % 60
    )
}
fn reported<T: std::fmt::Display>(value: Option<T>) -> String {
    value
        .map(|v| v.to_string())
        .unwrap_or_else(|| "Not reported".into())
}
fn window_text(window: &WindowReport) -> String {
    format!(
        "{} · used {} · remaining {} · duration {} · resets {}",
        window.position,
        window
            .used
            .map(|v| format!("{v}%"))
            .unwrap_or_else(|| "Not reported".into()),
        window
            .remaining
            .map(|v| format!("{v}%"))
            .unwrap_or_else(|| "Not reported".into()),
        window
            .minutes
            .map(|v| format!("{v} min"))
            .unwrap_or_else(|| "Not reported".into()),
        window
            .resets
            .map(utc)
            .unwrap_or_else(|| "Not reported".into())
    )
}
pub struct Refresh;
pub struct LimitsView {
    phase: Phase,
    account: Option<String>,
}
impl Default for LimitsView {
    fn default() -> Self {
        Self {
            phase: Phase::Idle,
            account: None,
        }
    }
}
impl EventEmitter<Refresh> for LimitsView {}
impl LimitsView {
    pub(super) fn context(&mut self, account: Option<String>, cx: &mut Context<Self>) {
        self.account = account;
        self.phase = Phase::Idle;
        cx.notify();
    }
    pub fn set(&mut self, phase: Phase, cx: &mut Context<Self>) {
        if self.phase != phase {
            self.phase = phase;
            cx.notify();
        }
    }
}
impl Render for LimitsView {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut body = div().flex().flex_col().gap_2();
        match &self.phase {
            Phase::Idle => {
                body = body.child(if self.account.is_some() {
                    "Refresh to read this selected profile’s reported limits. No turn is sent."
                } else {
                    "Refresh to read the limits reported by your default Codex runtime."
                })
            }
            Phase::Loading => body = body.child("Reading Codex limits…"),
            Phase::Failed(error) => body = body.child(*error),
            Phase::Closing => body = body.child("Limits view is closing."),
            Phase::Ready {
                observed_ms,
                buckets,
            } => {
                body = body.child(format!(
                    "Observed: {}",
                    observed_ms
                        .map(|v| utc(v as f64 / 1000.))
                        .unwrap_or_else(|| "time unavailable".into())
                ));
                for bucket in buckets {
                    let mut row = div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .p_2()
                        .border_1()
                        .border_color(rgb(0x354050))
                        .child(format!(
                            "{} · plan {}",
                            bucket
                                .name
                                .as_ref()
                                .map(|name| format!("{name} ({})", bucket.id))
                                .unwrap_or_else(|| bucket.id.clone()),
                            reported(bucket.plan.as_deref())
                        ));
                    for window in &bucket.windows {
                        row = row.child(window_text(window));
                    }
                    if bucket.windows.is_empty() {
                        row = row.child("No windows reported.");
                    }
                    if let Some(credits) = &bucket.credits {
                        row = row.child(format!(
                            "Credits: available {} · unlimited {} · balance {}",
                            reported(credits.has),
                            reported(credits.unlimited),
                            reported(credits.balance.as_deref())
                        ));
                    }
                    for note in &bucket.notes {
                        row = row.child(note.clone());
                    }
                    body = body.child(row);
                }
            }
        }
        div().id("codex-limits-panel").flex().flex_col().gap_2().p_3()
            .child(div().text_lg().child("Codex reported limits"))
            .child(self.account.as_ref().map(|account| format!("Selected local Codex profile {account}. Subscription authentication is checked for each read; account identity is unverified. These observations are separate from saved turn usage and billing.")).unwrap_or_else(|| "Default Codex runtime. Account identity is unverified; these observations are separate from saved turn usage and billing.".into()))
            .child(Button::new("codex-limits-refresh").label("Refresh Codex limits").disabled(matches!(self.phase, Phase::Loading | Phase::Closing)).on_click(cx.listener(|this, _, _, cx| {
                if !matches!(this.phase, Phase::Loading | Phase::Closing) { this.set(Phase::Loading, cx); cx.emit(Refresh); }
            })))
            .child(body)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    pub(super) fn ready() -> Value {
        json!({"requestId":"request-one","provider":"codex","accountScope":SCOPE,"accountIdentityVerified":false,"state":"ready","generation":1,"observedAtEpochMs":1793934061000_u64,"error":null,
            "snapshot":{"provenance":"codex_app_server_account_rate_limits","accountScope":SCOPE,"accountIdentityVerified":false,"main":{"id":"codex","displayName":null,"plan":null,"windows":[{"position":"primary","usedPercent":42.5,"remainingPercent":null,"durationMinutes":null,"resetsAtEpochSeconds":null}],"credits":null,"notes":[]},"modelBuckets":[]}})
    }
    #[::core::prelude::v1::test]
    fn reported_values_are_literal_and_missing_is_not_zero_or_subtracted() {
        let Phase::Ready { buckets, .. } = decode(&ready()).unwrap().phase else {
            panic!()
        };
        let text = window_text(&buckets[0].windows[0]);
        assert!(text.contains("used 42.5% · remaining Not reported"));
        assert!(!text.contains("57.5"));
        assert!(text.contains("duration Not reported · resets Not reported"));
    }
    #[::core::prelude::v1::test]
    fn rejects_account_scope_spoof_and_failed_payload_with_stale_success() {
        let mut value = ready();
        value["accountIdentityVerified"] = json!(true);
        assert!(decode(&value).is_err());
        value = ready();
        value["state"] = json!("failed");
        value["error"] = json!("read_failed");
        assert!(decode(&value).is_err());
    }
    #[::core::prelude::v1::test]
    fn invalid_or_unbounded_bucket_data_is_not_rendered() {
        let mut value = ready();
        value["snapshot"]["main"]["displayName"] = json!("bad\nname");
        assert!(decode(&value).is_err());
        value = ready();
        value["snapshot"]["modelBuckets"] = json!(vec![value["snapshot"]["main"].clone(); 65]);
        assert!(decode(&value).is_err());
    }
    #[::core::prelude::v1::test]
    fn unix_dates_render_utc_across_leap_century_and_bounds() {
        assert_eq!(utc(0.), "1970-01-01 00:00:00 UTC");
        assert_eq!(utc(951_782_400.), "2000-02-29 00:00:00 UTC");
        assert_eq!(utc(4_107_542_400.), "2100-03-01 00:00:00 UTC");
        assert_eq!(utc(253_402_300_799.), "9999-12-31 23:59:59 UTC");
        assert_eq!(utc(f64::NAN), "Date unavailable");
    }
    #[::core::prelude::v1::test]
    fn named_decode_requires_exact_account_thread_selection_and_authenticated_scope() {
        let target = json!({"threadId":"a","accountId":"profile-a","expectedSelection":{"provider":"codex","accountID":"profile-a","modelID":"default"}});
        let mut value = ready();
        value["accountScope"] = json!("named_codex_profile");
        value["snapshot"]["accountScope"] = json!("named_codex_profile");
        value["threadId"] = target["threadId"].clone();
        value["accountId"] = target["accountId"].clone();
        value["expectedSelection"] = target["expectedSelection"].clone();
        value["authenticationChecked"] = json!(true);
        assert!(decode_scoped(&value, Some(&target)).is_ok());
        assert!(decode(&value).is_err());
        for (key, replacement) in [
            ("accountId", json!("profile-b")),
            ("threadId", json!("b")),
            ("expectedSelection", json!({})),
            ("authenticationChecked", json!(false)),
        ] {
            let mut bad = value.clone();
            bad[key] = replacement;
            assert!(decode_scoped(&bad, Some(&target)).is_err());
        }
        value["snapshot"]["accountScope"] = json!(SCOPE);
        assert!(decode_scoped(&value, Some(&target)).is_err());
    }
}
