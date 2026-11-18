//! Read-only account figures from Devin CLI's built-in /usage command.
use crate::{
    terminal::Terminal,
    usage_limits::{Figure, Limits, Unit, Window, WindowKind},
};
use anyhow::{Context, Result, ensure};
use chrono::{DateTime, TimeDelta, Utc};
use portable_pty::CommandBuilder;
use std::{
    path::Path,
    process::Command,
    thread,
    time::{Duration, Instant},
};

pub(crate) fn read(executable: &Path) -> Result<Limits, &'static str> {
    check_usage(executable).map_err(
        |_| "Devin couldn’t report usage. Check your Devin sign-in or open its usage dashboard.",
    )
}

fn check_usage(executable: &Path) -> Result<Limits> {
    // Use an empty, disposable workspace and config. The installed CLI owns
    // its login and queries its account; Coincide handles no credentials.
    let scratch = tempfile::tempdir()?;
    let config = scratch.path().join("config.json");
    std::fs::write(&config, "{}")?;
    let mut approved = Command::new(executable);
    crate::provider_configuration::apply_to_child(&mut approved, false)?;
    let mut command = CommandBuilder::new(executable);
    command.env_clear();
    for name in [
        "HOME",
        "USERPROFILE",
        "XDG_DATA_HOME",
        "PATH",
        "TMPDIR",
        "TEMP",
        "SYSTEMROOT",
        "APPDATA",
        "LOCALAPPDATA",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
    ] {
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    for (key, value) in approved.get_envs() {
        if let Some(value) = value {
            command.env(key, value);
        }
    }
    command.env("TERM", "xterm-256color");
    command.env("LANG", "en_US.UTF-8");
    command.env("XDG_CONFIG_HOME", scratch.path());
    command.args([
        "--process-model",
        "in-process",
        "--respect-workspace-trust",
        "false",
        "--config",
    ]);
    command.arg(config);
    let mut terminal = Terminal::spawn_command(scratch.path(), command, 50, 120, None)?;
    // Wait for the actual input prompt, then confirm the built-in command is
    // offered before submitting it. Older CLIs must never receive chat text.
    wait_for_screen(&mut terminal, |lines| {
        lines
            .iter()
            .any(|line| line.contains("❭ Ask Devin"))
            .then_some(())
    })?;
    terminal.write("/usage")?;
    wait_for_screen(&mut terminal, |lines| {
        lines
            .iter()
            .any(|line| line.contains("/usage") && line.contains("Show session usage"))
            .then_some(())
    })?;
    terminal.write("\r")?;
    wait_for_screen(&mut terminal, |lines| account_limits(lines, Utc::now()))
}

fn wait_for_screen<T>(
    terminal: &mut Terminal,
    mut observe: impl FnMut(&[&str]) -> Option<T>,
) -> Result<T> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let snapshot = terminal.snapshot()?;
        ensure!(!terminal.exited(), "Devin usage command exited");
        let lines = snapshot["lines"]
            .as_array()
            .context("Missing terminal rows")?;
        let lines = lines
            .iter()
            .filter_map(|line| line.as_str())
            .collect::<Vec<_>>();
        if let Some(output) = observe(&lines) {
            return Ok(output);
        }
        ensure!(Instant::now() < deadline, "Devin usage read timed out");
        thread::sleep(Duration::from_millis(40));
    }
}

fn account_limits(lines: &[&str], now: DateTime<Utc>) -> Option<Limits> {
    let start = lines.iter().rposition(|line| line.trim() == "Usage")?;
    let report = &lines[start + 1..];
    let end = report
        .iter()
        .position(|line| line.trim_start().starts_with('❭'))?;
    let mut limits = Limits::new(Vec::new(), now);
    for line in &report[..end] {
        let line = line.trim();
        let mut parts = line.split_whitespace();
        let Some(label) = parts.next() else { continue };
        let (id, kind, name, duration) = match label {
            "Daily" => ("daily", WindowKind::Session, "Daily", Some(24 * 60)),
            "Weekly" => ("weekly", WindowKind::Weekly, "Weekly", Some(7 * 24 * 60)),
            "Monthly" => ("monthly", WindowKind::Monthly, "Monthly", None),
            _ => {
                if let Some(balance) = line
                    .strip_prefix("Extra usage balance")
                    .and_then(|balance| balance.trim().strip_prefix('$'))
                    .and_then(|balance| balance.replace(',', "").parse::<f64>().ok())
                    .filter(|balance| balance.is_finite() && *balance >= 0.)
                {
                    let mut figure = Figure::new(
                        "extra-balance",
                        "Extra usage balance",
                        Unit::Currency("USD".into()),
                    );
                    figure.remaining = Some(balance);
                    limits.figures.push(figure);
                }
                continue;
            }
        };
        let Some((used, suffix)) = line.split_once("% used") else {
            continue;
        };
        let Some(percent) = used
            .split_whitespace()
            .last()
            .and_then(|value| value.parse::<f64>().ok())
            .filter(|percent| (0.0..=100.0).contains(percent))
        else {
            continue;
        };
        let reset = suffix
            .split_once("resets in ")
            .and_then(|(_, countdown)| reset_minutes(countdown))
            .and_then(|minutes| now.checked_add_signed(TimeDelta::minutes(minutes)));
        if !limits.windows.iter().any(|window| window.id == id) {
            limits
                .windows
                .push(Window::new(id, kind, name, percent).resetting(reset, duration));
        }
    }
    limits.sort();
    limits.has_rows().then_some(limits)
}

fn reset_minutes(countdown: &str) -> Option<i64> {
    let mut result = 0;
    for part in countdown.split_whitespace() {
        let unit = part.chars().last()?;
        let value = part.strip_suffix(unit)?;
        let value: i64 = value.parse().ok()?;
        if !(0..=1440).contains(&value) {
            return None;
        }
        result += value
            * match unit {
                'd' => 1440,
                'h' => 60,
                'm' => 1,
                _ => return None,
            };
    }
    (result > 0).then_some(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_only_reported_quota_windows_and_extra_balance() {
        let now = Utc::now();
        let input = [
            " Usage",
            " Daily                ■■■■■■■■■■■■■■■■■■■■  38% used · resets in 17h 42m",
            " Weekly               ■■■■■■■■■■■■■■■■■■■■  54% used · resets in 3d 17h",
            " Extra usage balance  $12.30",
            " No usage yet in this session.",
            "❭ Ask Devin to build features",
        ];
        let limits = account_limits(&input, now).unwrap();
        let daily = limits
            .windows
            .iter()
            .find(|window| window.id == "daily")
            .unwrap();
        assert_eq!(daily.used_percent, 38.);
        assert_eq!(daily.resets_at, Some(now + TimeDelta::minutes(1062)));
        assert_eq!(limits.windows.len(), 2);
        assert_eq!(limits.figures[0].remaining, Some(12.30));
    }

    #[test]
    fn unfinished_and_invalid_output_never_display_fake_zeroes() {
        let now = Utc::now();
        assert!(account_limits(&["Usage", "Daily 0% used"], now).is_none());
        assert!(account_limits(&["Usage", "Weekly 101% used", "❭ Ask Devin"], now).is_none());
        assert!(reset_minutes("15λ").is_none());
        assert_eq!(reset_minutes("3d 17h"), Some(5340));
    }
}
