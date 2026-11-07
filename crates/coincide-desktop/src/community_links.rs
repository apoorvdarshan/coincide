//! Help & Community, Follow, and Contact & Legal, from Swift's CommunityLink.
//! Settings › About lists them and Settings search finds them. Report an Issue
//! and Request a Feature first ask whether to use GitHub or Discord, and a bug
//! report's form starts with only this computer's versions filled in.
use gpui_kit::assets::IconName;

const REPOSITORY: &str = "https://github.com/apoorvdarshan/coincide";
/// Longest value a link puts in a form field; the version fields are one line.
const MAX_FIELD: usize = 120;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Group {
    Community,
    Follow,
    Contact,
}
impl Group {
    pub(super) const ALL: [Self; 3] = [Self::Community, Self::Follow, Self::Contact];
    pub(super) fn title(self) -> &'static str {
        match self {
            Self::Community => "Help & Community",
            Self::Follow => "Follow",
            Self::Contact => "Contact & Legal",
        }
    }
}

/// The two links that open a GitHub form or a Discord channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Report {
    template: &'static str,
    pub(super) discord: &'static str,
    pub(super) message: &'static str,
    /// Only the bug form takes this computer's versions.
    versions: bool,
}

pub(super) struct Link {
    pub(super) id: &'static str,
    pub(super) title: &'static str,
    pub(super) detail: &'static str,
    pub(super) icon: IconName,
    pub(super) tint: u32,
    pub(super) group: Group,
    url: &'static str,
    pub(super) keywords: &'static [&'static str],
    pub(super) report: Option<Report>,
}
impl Link {
    /// Where the link goes; for a report, its GitHub form.
    pub(super) fn url(&self) -> String {
        match self.report {
            Some(report) if report.versions => report_url(
                report.template,
                Some(&app_version()),
                system_version().as_deref(),
            ),
            Some(report) => report_url(report.template, None, None),
            None => self.url.to_owned(),
        }
    }
}

const fn link(
    id: &'static str,
    title: &'static str,
    detail: &'static str,
    icon: IconName,
    tint: u32,
    group: Group,
    url: &'static str,
    keywords: &'static [&'static str],
) -> Link {
    Link {
        id,
        title,
        detail,
        icon,
        tint,
        group,
        url,
        keywords,
        report: None,
    }
}

pub(super) const LINKS: &[Link] = &[
    link(
        "help",
        "Get Help",
        "Ask in the help channel on Discord",
        IconName::CircleQuestionMark,
        0x30b0c7,
        Group::Community,
        "https://discord.com/channels/1566352780862427258/1566353949336797275",
        &["help", "support", "question", "discord", "community", "ask"],
    ),
    Link {
        report: Some(Report {
            template: "bug_report.yml",
            discord: "https://discord.com/channels/1566352780862427258/1566353951299862598",
            message: "Fill in the bug report form on GitHub, or use /bug in the bug reports channel on Discord. Channel links work once you’ve joined the server. Reports sent on Discord become public GitHub issues and need no GitHub account.",
            versions: true,
        }),
        ..link(
            "bug",
            "Report an Issue",
            "On GitHub or Discord",
            IconName::Bug,
            0xff3b30,
            Group::Community,
            "",
            &[
                "Bug", "Feedback", "issue", "report", "problem", "crash", "broken", "github",
                "discord", "support",
            ],
        )
    },
    Link {
        report: Some(Report {
            template: "feature_request.yml",
            discord: "https://discord.com/channels/1566352780862427258/1566353955494039602",
            message: "Fill in the feature request form on GitHub, or use /feature in the feature requests channel on Discord. Channel links work once you’ve joined the server. Requests sent on Discord become public GitHub issues and need no GitHub account.",
            versions: false,
        }),
        ..link(
            "feature",
            "Request a Feature",
            "On GitHub or Discord",
            IconName::Lightbulb,
            0xff9500,
            Group::Community,
            "",
            &[
                "Idea",
                "Feedback",
                "feature",
                "request",
                "suggestion",
                "enhancement",
                "github",
                "discord",
            ],
        )
    },
    link(
        "discord",
        "Join the Discord",
        "discord.gg/DETrbhDVqw",
        IconName::MessagesSquare,
        0x5856d6,
        Group::Community,
        "https://discord.gg/DETrbhDVqw",
        &["discord", "community", "chat", "server", "join", "invite"],
    ),
    link(
        "github",
        "Star on GitHub",
        "Coincide is open source under the MIT License",
        IconName::Star,
        0x8e8e93,
        Group::Community,
        REPOSITORY,
        &[
            "github",
            "star",
            "source",
            "code",
            "open source",
            "license",
            "mit",
            "repository",
        ],
    ),
    link(
        "product-hunt",
        "Upvote on Product Hunt",
        "producthunt.com/products/coincide",
        IconName::ArrowBigUp,
        0xff9500,
        Group::Community,
        "https://www.producthunt.com/products/coincide",
        &[
            "product hunt",
            "producthunt",
            "upvote",
            "vote",
            "launch",
            "review",
        ],
    ),
    link(
        "support",
        "Support on Ko-fi",
        "Buy Apoorv a coffee",
        IconName::Heart,
        0xff2d55,
        Group::Community,
        "https://ko-fi.com/apoorvdarshan",
        &[
            "support", "donate", "donation", "tip", "coffee", "ko-fi", "kofi", "sponsor",
        ],
    ),
    link(
        "x",
        "X",
        "@apoorvdarshan",
        IconName::AtSign,
        0x1c1c1e,
        Group::Follow,
        "https://x.com/apoorvdarshan",
        &["x", "twitter", "follow", "social", "@apoorvdarshan"],
    ),
    link(
        "instagram",
        "Instagram",
        "@apoorvcodes",
        IconName::Camera,
        0xff2d55,
        Group::Follow,
        "https://instagram.com/apoorvcodes",
        &["instagram", "follow", "social", "@apoorvcodes"],
    ),
    link(
        "linkedin",
        "LinkedIn",
        "linkedin.com/showcase/coincide-dev",
        IconName::Users,
        0x007aff,
        Group::Follow,
        "https://www.linkedin.com/showcase/coincide-dev",
        &["linkedin", "follow", "social", "company"],
    ),
    link(
        "contact",
        "Contact",
        "apoorv@fud-ai.app",
        IconName::Mail,
        0x32ade6,
        Group::Contact,
        "mailto:apoorv@fud-ai.app",
        &["contact", "email", "mail", "support", "apoorv@fud-ai.app"],
    ),
    link(
        "privacy",
        "Privacy Policy",
        "coincide.dev/privacy",
        IconName::Hand,
        0x007aff,
        Group::Contact,
        "https://coincide.dev/privacy",
        &["privacy", "policy", "data", "legal"],
    ),
    link(
        "terms",
        "Terms of Service",
        "coincide.dev/terms",
        IconName::FileText,
        0x8e8e93,
        Group::Contact,
        "https://coincide.dev/terms",
        &["terms", "service", "legal", "conditions"],
    ),
];

/// A field's value on one line, trimmed and cut to the field's length.
fn field_value(value: Option<&str>) -> Option<String> {
    let line = value?.split(['\r', '\n']).collect::<Vec<_>>().join(" ");
    let line = line.trim();
    (!line.is_empty()).then(|| line.chars().take(MAX_FIELD).collect())
}

fn query_escape(value: &str) -> String {
    let mut escaped = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                escaped.push(byte as char)
            }
            // GitHub reads "+" in a query as a space.
            _ => escaped.push_str(&format!("%{byte:02X}")),
        }
    }
    escaped
}

/// The issue form; a bug report fills in "Coincide version" and "macOS
/// version" with what is given, leaving out empty values.
fn report_url(template: &str, coincide: Option<&str>, system: Option<&str>) -> String {
    let mut url = format!(
        "{REPOSITORY}/issues/new?template={}",
        query_escape(template)
    );
    for (field, value) in [("coincide-version", coincide), ("macos-version", system)] {
        if let Some(value) = field_value(value) {
            url.push_str(&format!("&{field}={}", query_escape(&value)));
        }
    }
    url
}

/// This app's version as the bug form reads it, naming the Rust desktop app.
pub(super) fn app_version() -> String {
    format!(
        "{} (Rust desktop, {} {})",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH
    )
}

/// The bug form's "macOS version", "macOS 26.1 (25B78)". Other systems leave
/// the field for the reporter; the app version already names the platform.
pub(super) fn system_version() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let plist =
            std::fs::read_to_string("/System/Library/CoreServices/SystemVersion.plist").ok()?;
        let value = |key: &str| {
            let rest = &plist[plist.find(&format!("<key>{key}</key>"))?..];
            let start = rest.find("<string>")? + "<string>".len();
            let end = rest[start..].find("</string>")?;
            Some(rest[start..start + end].trim().to_owned())
        };
        let version = value("ProductVersion")?;
        Some(match value("ProductBuildVersion") {
            Some(build) => format!("macOS {version} ({build})"),
            None => format!("macOS {version}"),
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn bug_form_fills_only_one_line_versions() {
        assert_eq!(
            report_url(
                "bug_report.yml",
                Some(" 0.1.0 (Rust desktop, macos aarch64)\n"),
                Some("macOS 26.1 (25B78)")
            ),
            "https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml&coincide-version=0.1.0%20%28Rust%20desktop%2C%20macos%20aarch64%29&macos-version=macOS%2026.1%20%2825B78%29"
        );
        assert_eq!(
            report_url("bug_report.yml", Some("  "), None),
            "https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml"
        );
        assert_eq!(query_escape("a+b c"), "a%2Bb%20c");
        let long = "x".repeat(300);
        assert_eq!(field_value(Some(&long)).unwrap().chars().count(), MAX_FIELD);
        assert_eq!(field_value(Some("a\nb")).as_deref(), Some("a b"));
    }

    #[::core::prelude::v1::test]
    fn only_reports_ask_github_or_discord_and_groups_follow_swift() {
        let reports = LINKS
            .iter()
            .filter(|link| link.report.is_some())
            .map(|link| link.title)
            .collect::<Vec<_>>();
        assert_eq!(reports, ["Report an Issue", "Request a Feature"]);
        let feature = LINKS.iter().find(|link| link.id == "feature").unwrap();
        assert_eq!(
            feature.url(),
            "https://github.com/apoorvdarshan/coincide/issues/new?template=feature_request.yml"
        );
        assert!(feature.report.unwrap().message.contains("/feature"));
        assert_eq!(
            Group::ALL.map(|group| LINKS.iter().filter(|link| link.group == group).count()),
            [7, 3, 3]
        );
        assert!(
            LINKS
                .iter()
                .filter(|link| link.report.is_none())
                .all(|link| link.url().starts_with("https://") || link.url().starts_with("mailto:"))
        );
    }
}
