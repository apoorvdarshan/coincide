//! Portable schedule semantics matching the existing macOS recurrence model.
//! Execution and user approval remain the engine's responsibility.
use anyhow::{Context, Result, bail, ensure};
use chrono::{DateTime, Datelike, Duration, LocalResult, NaiveDate, TimeZone, Utc};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Recurrence {
    pub kind: String,
    #[serde(rename = "timeZoneID")]
    pub time_zone_id: String,
    pub date: Value,
    pub hour: u32,
    pub minute: u32,
    pub weekday: u32,
    #[serde(default)]
    pub weekdays: Option<Vec<u32>>,
    #[serde(default)]
    pub interval_minutes: Option<u32>,
    #[serde(default)]
    pub cron: Option<String>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Recurrence {
    pub fn validate(&self) -> Result<()> {
        self.time_zone_id
            .parse::<Tz>()
            .context("Choose a valid time zone")?;
        parse_date(&self.date)?;
        ensure!(
            self.hour < 24 && self.minute < 60 && (1..=7).contains(&self.weekday),
            "Choose a valid time"
        );
        match self.kind.as_str() {
            "once" | "daily" | "weekly" | "weekdays" => {}
            "days" => ensure!(
                self.weekdays.as_ref().is_some_and(
                    |days| !days.is_empty() && days.iter().all(|d| (1..=7).contains(d))
                ),
                "Choose at least one valid day"
            ),
            "interval" => ensure!(
                self.interval_minutes
                    .is_some_and(|n| (5..=31 * 24 * 60).contains(&n)),
                "Repeat every 5 minutes to 31 days"
            ),
            "cron" => {
                Cron::parse(self.cron.as_deref().unwrap_or(""))?;
            }
            _ => bail!("Unknown schedule kind: {}", self.kind),
        }
        Ok(())
    }

    pub fn next_after(&self, now: DateTime<Utc>) -> Result<Option<DateTime<Utc>>> {
        self.validate()?;
        let start = parse_date(&self.date)?;
        if self.kind == "once" {
            return Ok((start > now).then_some(start));
        }
        if self.kind == "interval" {
            if start > now {
                return Ok(Some(start));
            }
            let step = i64::from(self.interval_minutes.context("Missing interval")?) * 60;
            let elapsed = now.signed_duration_since(start).num_seconds();
            let seconds = (elapsed / step + 1)
                .checked_mul(step)
                .context("Schedule date overflow")?;
            return Ok(Some(
                start
                    .checked_add_signed(Duration::seconds(seconds))
                    .context("Schedule date overflow")?,
            ));
        }
        let zone: Tz = self.time_zone_id.parse()?;
        let cron = if self.kind == "cron" {
            Some(Cron::parse(self.cron.as_deref().unwrap_or(""))?)
        } else {
            None
        };
        let first_day = now.with_timezone(&zone).date_naive();
        let horizon = if cron.is_some() { 366 * 5 } else { 8 };
        for offset in 0..horizon {
            let day = first_day
                .checked_add_signed(Duration::days(offset))
                .context("Schedule date overflow")?;
            let weekday = day.weekday().number_from_sunday();
            let matches = match self.kind.as_str() {
                "weekly" => weekday == self.weekday,
                "weekdays" => (2..=6).contains(&weekday),
                "days" => self
                    .weekdays
                    .as_ref()
                    .is_some_and(|days| days.contains(&weekday)),
                "cron" => cron.as_ref().is_some_and(|c| c.matches_day(day)),
                _ => true,
            };
            if !matches {
                continue;
            }
            if let Some(cron) = &cron {
                for &hour in &cron.hours {
                    for &minute in &cron.minutes {
                        if let Some(candidate) = resolve_time(zone, day, hour, minute)
                            && candidate > now
                        {
                            return Ok(Some(candidate));
                        }
                    }
                }
            } else if let Some(candidate) = resolve_time(zone, day, self.hour, self.minute)
                && candidate > now
            {
                return Ok(Some(candidate));
            }
        }
        Ok(None)
    }
}

/// ISO-8601 is the Swift persisted representation; numeric dates are accepted
/// for earlier Rust preview records and use Apple's January 2001 epoch.
pub fn parse_date(value: &Value) -> Result<DateTime<Utc>> {
    if let Some(text) = value.as_str() {
        return Ok(DateTime::parse_from_rfc3339(text)
            .context("Invalid schedule date")?
            .with_timezone(&Utc));
    }
    let seconds = value.as_f64().context("Invalid schedule date")? + 978_307_200.0;
    ensure!(
        seconds.is_finite() && seconds >= i64::MIN as f64 && seconds < i64::MAX as f64,
        "Invalid schedule date"
    );
    let whole = seconds.floor();
    DateTime::from_timestamp(whole as i64, ((seconds - whole) * 1_000_000_000.0) as u32)
        .context("Invalid schedule date")
}

/// Parse minute-precision editor input using the same DST policy as recurrence.
/// A spring gap advances to the first valid minute; a fold chooses its first occurrence.
pub fn parse_local_datetime(date: &str, time: &str, zone: &str) -> Result<DateTime<Utc>> {
    ensure!(date.len() == 10, "Use a date in YYYY-MM-DD format");
    let day = NaiveDate::parse_from_str(date, "%Y-%m-%d")
        .context("Use a valid date in YYYY-MM-DD format")?;
    ensure!(
        time.len() == 5
            && time.as_bytes()[2] == b':'
            && time
                .bytes()
                .enumerate()
                .all(|(i, b)| i == 2 || b.is_ascii_digit()),
        "Use a time in HH:MM format"
    );
    let hour: u32 = time[..2].parse()?;
    let minute: u32 = time[3..].parse()?;
    ensure!(
        hour < 24 && minute < 60,
        "Time must be between 00:00 and 23:59"
    );
    let zone: Tz = zone.parse().context("Unknown IANA time zone")?;
    resolve_time(zone, day, hour, minute).context("This local date has no valid scheduled time")
}

/// Format a persisted schedule instant for its own time zone, never the host zone.
pub fn format_local_datetime(date: &Value, zone: &str) -> Result<(String, String)> {
    let zone: Tz = zone.parse().context("Unknown IANA time zone")?;
    let local = parse_date(date)?.with_timezone(&zone);
    Ok((
        local.format("%Y-%m-%d").to_string(),
        local.format("%H:%M").to_string(),
    ))
}

// Foundation's .nextTime moves a nonexistent local time to the first valid
// instant; .first selects the earlier occurrence in a fall-back fold. Never
// return the second occurrence after the first has already been consumed.
fn resolve_time(zone: Tz, day: NaiveDate, hour: u32, minute: u32) -> Option<DateTime<Utc>> {
    let mut local = day.and_hms_opt(hour, minute, 0)?;
    while local.date() == day {
        match zone.from_local_datetime(&local) {
            LocalResult::Single(date) => return Some(date.with_timezone(&Utc)),
            LocalResult::Ambiguous(a, b) => return Some(a.min(b).with_timezone(&Utc)),
            LocalResult::None => local = local.checked_add_signed(Duration::minutes(1))?,
        }
    }
    None
}

#[derive(Debug, Clone)]
pub struct Cron {
    minutes: BTreeSet<u32>,
    hours: BTreeSet<u32>,
    month_days: BTreeSet<u32>,
    months: BTreeSet<u32>,
    week_days: BTreeSet<u32>,
    restrict_month_day: bool,
    restrict_week_day: bool,
}
impl Cron {
    pub fn parse(input: &str) -> Result<Self> {
        ensure!(
            input.len() <= 256,
            "A cron expression must fit within 256 bytes"
        );
        let lower = input.trim().to_ascii_lowercase();
        let expanded = match lower.as_str() {
            "@hourly" => "0 * * * *",
            "@daily" | "@midnight" => "0 0 * * *",
            "@weekly" => "0 0 * * 0",
            "@monthly" => "0 0 1 * *",
            "@yearly" | "@annually" => "0 0 1 1 *",
            other => other,
        };
        let parts: Vec<_> = expanded.split_whitespace().collect();
        ensure!(parts.len() == 5, "A cron expression has five fields");
        let cron = Self {
            minutes: parse_field(parts[0], 0, 59, &[])?,
            hours: parse_field(parts[1], 0, 23, &[])?,
            month_days: parse_field(parts[2], 1, 31, &[])?,
            months: parse_field(
                parts[3],
                1,
                12,
                &[
                    "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov",
                    "dec",
                ],
            )?,
            week_days: parse_field(
                parts[4],
                0,
                7,
                &["sun", "mon", "tue", "wed", "thu", "fri", "sat"],
            )?
            .into_iter()
            .map(|d| d % 7)
            .collect(),
            restrict_month_day: !parts[2].starts_with('*'),
            restrict_week_day: !parts[4].starts_with('*'),
        };
        let times: Vec<_> = cron
            .hours
            .iter()
            .flat_map(|h| cron.minutes.iter().map(move |m| h * 60 + m))
            .collect();
        let first = *times.first().context("Cron has no run times")?;
        let last = *times.last().context("Cron has no run times")?;
        ensure!(
            first + 1440 - last >= 5 && times.windows(2).all(|pair| pair[1] - pair[0] >= 5),
            "Runs must be at least 5 minutes apart"
        );
        let lengths = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        ensure!(
            cron.restrict_week_day
                || cron.months.iter().any(|m| cron
                    .month_days
                    .iter()
                    .any(|d| *d <= lengths[*m as usize - 1])),
            "This expression never matches a date"
        );
        Ok(cron)
    }
    fn matches_day(&self, day: NaiveDate) -> bool {
        if !self.months.contains(&day.month()) {
            return false;
        }
        let month = self.month_days.contains(&day.day());
        let week = self
            .week_days
            .contains(&day.weekday().num_days_from_sunday());
        match (self.restrict_month_day, self.restrict_week_day) {
            (true, true) => month || week,
            (true, false) => month,
            (false, true) => week,
            (false, false) => true,
        }
    }
}
fn parse_field(field: &str, low: u32, high: u32, names: &[&str]) -> Result<BTreeSet<u32>> {
    let value = |part: &str| -> Result<u32> {
        if let Ok(n) = part.parse::<u32>() {
            ensure!((low..=high).contains(&n), "Invalid cron field: {field}");
            return Ok(n);
        }
        names
            .iter()
            .position(|name| *name == part)
            .map(|i| i as u32 + low)
            .with_context(|| format!("Invalid cron field: {field}"))
    };
    let mut result = BTreeSet::new();
    for part in field.split(',') {
        ensure!(!part.is_empty(), "Invalid cron field: {field}");
        let pieces: Vec<_> = part.split('/').collect();
        ensure!(pieces.len() <= 2, "Invalid cron field: {field}");
        let step = if pieces.len() == 2 {
            pieces[1].parse::<u32>().context("Invalid cron step")?
        } else {
            1
        };
        ensure!(step > 0 && step <= high + 1, "Invalid cron step");
        let (from, to) = if pieces[0] == "*" {
            (low, high)
        } else if let Some((a, b)) = pieces[0].split_once('-') {
            (value(a)?, value(b)?)
        } else {
            let n = value(pieces[0])?;
            (n, if pieces.len() == 2 { high } else { n })
        };
        ensure!(from <= to, "Invalid cron range");
        result.extend((from..=to).step_by(step as usize));
    }
    Ok(result)
}

/// Known controls are typed; every other persisted field remains lossless,
/// including proposal cards, provider delivery state and future fields.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduledTask {
    pub id: String,
    pub name: String,
    #[serde(rename = "projectID")]
    pub project_id: String,
    pub prompt: String,
    pub recurrence: Recurrence,
    pub is_paused: bool,
    #[serde(default)]
    pub awaiting_approval: Option<bool>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
impl ScheduledTask {
    pub fn validate(&self) -> Result<()> {
        Uuid::parse_str(&self.id).context("Invalid schedule ID")?;
        Uuid::parse_str(&self.project_id).context("Invalid schedule project ID")?;
        ensure!(
            !self.name.trim().is_empty() && self.name.len() <= 1024,
            "Enter a valid task name"
        );
        ensure!(
            !self.prompt.trim().is_empty() && self.prompt.len() <= 1_048_576,
            "Enter a valid task prompt"
        );
        for key in ["nextRunAt", "lastFiredOccurrence"] {
            if let Some(value) = self.extra.get(key).filter(|value| !value.is_null()) {
                parse_date(value).with_context(|| format!("Invalid schedule {key}"))?;
            }
        }
        self.recurrence.validate()
    }
    pub fn is_active(&self) -> bool {
        !self.is_paused && self.awaiting_approval != Some(true)
    }
}

/// The on-disk envelope is versioned independently of the SQLite schema. A
/// malformed or newer schedule file cannot be replaced by an empty default.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduleDocument {
    pub version: u32,
    pub tasks: Vec<ScheduledTask>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}
impl ScheduleDocument {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 1,
            "Unsupported scheduled-tasks document version"
        );
        let mut seen = BTreeSet::new();
        for task in &self.tasks {
            task.validate()?;
            ensure!(
                seen.insert(Uuid::parse_str(&task.id)?),
                "Duplicate schedule ID"
            );
        }
        Ok(())
    }
}

/// The native sidebar's calendar snooze choices. This computes dates only;
/// snoozing never schedules execution or grants provider approval.
pub fn native_snooze_presets() -> Vec<(&'static str, f64)> {
    sidebar_snooze_presets(chrono::Local::now())
}
fn sidebar_snooze_presets<T: TimeZone>(now: DateTime<T>) -> Vec<(&'static str, f64)> {
    let stamp = |date: DateTime<T>| date.timestamp_millis() as f64 / 1000. - 978307200.;
    let mut result = vec![
        ("In 1 Hour", stamp(now.clone() + Duration::hours(1))),
        ("In 3 Hours", stamp(now.clone() + Duration::hours(3))),
    ];
    let at = |days: i64, hour| {
        now.date_naive()
            .checked_add_signed(Duration::days(days))
            .and_then(|day| day.and_hms_opt(hour, 0, 0))
            .and_then(|local| now.timezone().from_local_datetime(&local).earliest())
    };
    if let Some(evening) = at(0, 18)
        && evening.clone().signed_duration_since(now.clone()) > Duration::hours(1)
    {
        result.push(("This Evening", stamp(evening)));
    }
    let tomorrow = at(1, 9);
    if let Some(date) = tomorrow.clone() {
        result.push(("Tomorrow", stamp(date)));
    }
    let days = 7 - i64::from(now.weekday().num_days_from_monday());
    if let Some(monday) = at(days, 9)
        && tomorrow.as_ref() != Some(&monday)
    {
        result.push(("Next Week", stamp(monday)));
    }
    result
}
/// The presets as the sidebar's Snooze menu lists them, each with Swift's
/// subtitle: the local time it wakes at, with the weekday for Next Week.
pub fn native_snooze_menu() -> Vec<(&'static str, String, f64)> {
    sidebar_snooze_menu(chrono::Local::now())
}
fn sidebar_snooze_menu<T: TimeZone>(now: DateTime<T>) -> Vec<(&'static str, String, f64)>
where
    T::Offset: std::fmt::Display,
{
    let zone = now.timezone();
    sidebar_snooze_presets(now)
        .into_iter()
        .map(|(title, stamp)| {
            let millis = ((stamp + 978307200.) * 1000.).round() as i64;
            let detail = zone
                .timestamp_millis_opt(millis)
                .single()
                .map(|date| {
                    date.format(if title == "Next Week" {
                        "%a %H:%M"
                    } else {
                        "%H:%M"
                    })
                    .to_string()
                })
                .unwrap_or_default();
            (title, detail, stamp)
        })
        .collect()
}
#[cfg(test)]
mod sidebar_snooze_tests {
    use super::*;
    #[test]
    fn tomorrow_and_next_week_use_calendar_mornings_across_daylight_saving() {
        let zone: Tz = "America/New_York".parse().unwrap();
        let now = zone
            .with_ymd_and_hms(2026, 3, 7, 16, 30, 0)
            .single()
            .unwrap();
        let choices = sidebar_snooze_presets(now);
        let tomorrow = choices
            .iter()
            .find(|(label, _)| *label == "Tomorrow")
            .unwrap()
            .1;
        let expected = zone
            .with_ymd_and_hms(2026, 3, 8, 9, 0, 0)
            .single()
            .unwrap()
            .timestamp() as f64
            - 978307200.;
        assert_eq!(tomorrow, expected);
        assert!(choices.iter().any(|(label, _)| *label == "This Evening"));
        let sunday = zone
            .with_ymd_and_hms(2026, 3, 8, 20, 0, 0)
            .single()
            .unwrap();
        let choices = sidebar_snooze_presets(sunday);
        assert!(!choices.iter().any(|(label, _)| *label == "Next Week"));
        assert!(!choices.iter().any(|(label, _)| *label == "This Evening"));
    }
    #[test]
    fn snooze_menu_subtitles_show_the_local_wake_time_and_next_weeks_weekday() {
        let zone: Tz = "America/New_York".parse().unwrap();
        let now = zone
            .with_ymd_and_hms(2026, 3, 5, 10, 15, 0)
            .single()
            .unwrap();
        let menu = sidebar_snooze_menu(now);
        let detail = |title: &str| {
            menu.iter()
                .find(|(label, _, _)| *label == title)
                .map(|(_, detail, _)| detail.as_str())
                .unwrap()
        };
        assert_eq!(detail("In 1 Hour"), "11:15");
        assert_eq!(detail("In 3 Hours"), "13:15");
        assert_eq!(detail("This Evening"), "18:00");
        assert_eq!(detail("Tomorrow"), "09:00");
        // Monday 9 March falls after the daylight saving change of 8 March.
        assert_eq!(detail("Next Week"), "Mon 09:00");
        let dates: Vec<_> = sidebar_snooze_presets(now)
            .into_iter()
            .map(|row| row.1)
            .collect();
        assert_eq!(
            menu.iter().map(|row| row.2).collect::<Vec<_>>(),
            dates,
            "the menu snoozes until exactly the presets' dates"
        );
    }
}
