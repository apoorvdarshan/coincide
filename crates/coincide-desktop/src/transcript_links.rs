//! Links clicked in the transcript and the plan card (Swift openLink,
//! LinkRouting and SafeLinks). Agents write these links, so nothing they point
//! at is run: web links open in the thread's browser or the default browser,
//! mail links open, other schemes ask first, and paths resolve against the
//! thread's folder and open in an editor (or are revealed), never in their
//! default app. Files outside the thread's folder ask first.
use super::*;
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use std::path::{Path, PathBuf};

/// What a link names, decided before anything opens.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Link {
    /// An in-document anchor or an empty link: nothing to open.
    Ignore,
    Web(String),
    Mail(String),
    /// A path from a reply, as written (`src/main.rs:12`, `file:///…`).
    File(String),
    /// Any other scheme, whose handler acts on what the link says.
    Other(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Destination {
    /// The thread's browser, beside the conversation.
    Browser,
    /// A new tab of the thread's browser.
    BrowserNewTab,
    /// The user's default browser.
    Default,
}

impl Destination {
    pub(super) fn menu_title(self) -> &'static str {
        match self {
            Self::Browser => "Open in Coincide Browser",
            Self::BrowserNewTab => "Open in New Tab",
            Self::Default => "Open in Default Browser",
        }
    }
}

/// Confirmations show at most this much of a link, which could otherwise grow
/// past the screen.
const SHOWN_LENGTH: usize = 1000;

fn scheme(text: &str) -> Option<&str> {
    let (scheme, _) = text.split_once(':')?;
    // A single letter is a Windows drive, not a scheme.
    (scheme.len() > 1
        && scheme.starts_with(|c: char| c.is_ascii_alphabetic())
        && scheme
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.')))
    .then_some(scheme)
}

/// The http(s) address a link names, `www.` included. None for files, mail,
/// other schemes and web addresses without a host.
pub(super) fn web_url(link: &str) -> Option<String> {
    let text = link.trim();
    let url = if text
        .get(..4)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("www."))
    {
        format!("https://{text}")
    } else {
        text.to_owned()
    };
    let scheme = scheme(&url)?.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let rest = url[scheme.len() + 1..].strip_prefix("//")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host = authority.rsplit('@').next().unwrap_or_default();
    (!host.is_empty() && !host.starts_with(':')).then_some(url)
}

pub(super) fn classify(link: &str) -> Link {
    let text = link.trim();
    if text.is_empty() || text.starts_with('#') {
        return Link::Ignore;
    }
    if let Some(url) = web_url(text) {
        return Link::Web(url);
    }
    match scheme(text).map(str::to_ascii_lowercase).as_deref() {
        Some("mailto") => Link::Mail(text.to_owned()),
        Some("file") => Link::File(text.to_owned()),
        // http(s) without a host is not a web address and opens nothing.
        Some("http" | "https") => Link::Ignore,
        Some(_) => Link::Other(text.to_owned()),
        None => Link::File(text.to_owned()),
    }
}

fn percent_decoded(text: &str) -> Option<String> {
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = text.get(index + 1..index + 3)?;
            decoded.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

/// The path a file link names: percent-decoded, with `#L12` and `:12:3`
/// suffixes and a `file://` prefix removed.
pub(super) fn file_path(reference: &str) -> String {
    let mut path = reference.trim().to_owned();
    if scheme(&path).is_some_and(|scheme| scheme.eq_ignore_ascii_case("file")) {
        path = path[5..].to_owned();
        if let Some(rest) = path.strip_prefix("//") {
            // file://host/path keeps the path; file:///C:/x drops its slash.
            let start = rest.find('/').unwrap_or(rest.len());
            path = rest[start..].to_owned();
            if path.len() > 2 && path.as_bytes()[2] == b':' && cfg!(windows) {
                path.remove(0);
            }
        }
    }
    let mut path = percent_decoded(&path).unwrap_or(path);
    if let Some(hash) = path.find('#') {
        path.truncate(hash);
    }
    while let Some(colon) = path.rfind(':') {
        let suffix = &path[colon + 1..];
        if suffix.is_empty() || !suffix.bytes().all(|b| b.is_ascii_digit()) {
            break;
        }
        path.truncate(colon);
    }
    path
}

/// Where a path from a reply points: absolute, under the home folder for `~/`,
/// or relative to the thread's folder. None when relative without a folder.
pub(super) fn resolve(path: &str, folder: Option<&Path>, home: Option<&Path>) -> Option<PathBuf> {
    if path.is_empty() {
        return None;
    }
    if path == "~" {
        return home.map(Path::to_path_buf);
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return home.map(|home| home.join(rest));
    }
    let candidate = Path::new(path);
    if candidate.is_absolute() {
        Some(candidate.to_path_buf())
    } else {
        folder.map(|folder| folder.join(candidate))
    }
}

/// Where a click goes: the thread's browser, unless the setting or the
/// command key (but not both) asks for the default browser.
pub(super) fn destination(command: bool, option: bool, opens_in_default: bool) -> Destination {
    if command && option {
        Destination::BrowserNewTab
    } else if command != opens_in_default {
        Destination::Default
    } else {
        Destination::Browser
    }
}

pub(super) fn shortened(text: &str) -> String {
    if text.chars().count() > SHOWN_LENGTH {
        text.chars().take(SHOWN_LENGTH).chain(['…']).collect()
    } else {
        text.to_owned()
    }
}

/// The open link menu, drawn by the window above everything else.
pub(super) struct LinkMenu {
    pub menu: Entity<PopupMenu>,
    pub position: Point<Pixels>,
    _dismissed: Subscription,
}

impl Coincide {
    fn opens_links_in_default_browser(&self) -> bool {
        self.settings["opensLinksInDefaultBrowser"]
            .as_bool()
            .unwrap_or(false)
    }

    /// The single entry point for transcript and plan-card link clicks.
    pub(super) fn open_transcript_link(
        &mut self,
        url: &str,
        event: &ClickEvent,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if event.is_secondary() {
            if let Some(url) = web_url(url) {
                self.show_link_menu(url, event.position(), window, cx);
            }
            return;
        }
        if !event.standard_click() {
            return;
        }
        let modifiers = event.modifiers();
        let command = if cfg!(target_os = "macos") {
            modifiers.platform
        } else {
            modifiers.control
        };
        match classify(url) {
            Link::Ignore => {}
            Link::Web(url) => {
                let destination = destination(
                    command,
                    modifiers.alt,
                    self.opens_links_in_default_browser(),
                );
                self.open_web_link(url, destination, cx);
            }
            Link::Mail(url) => cx.open_url(&url),
            Link::File(reference) => self.open_file_link(&reference, window, cx),
            Link::Other(url) => {
                let answer = window.prompt(
                    PromptLevel::Warning,
                    "Open this link in another app?",
                    Some(&shortened(&url)),
                    &["Cancel", "Open Link"],
                    cx,
                );
                cx.spawn(async move |_, cx| {
                    if answer.await == Ok(1) {
                        cx.update(|cx| cx.open_url(&url));
                    }
                })
                .detach();
            }
        }
    }

    /// A web link loads as an ordinary navigation of the user's in the
    /// thread's browser. Without a conversation or a browser it opens in the
    /// default browser instead.
    pub(super) fn open_web_link(
        &mut self,
        url: String,
        destination: Destination,
        cx: &mut Context<Self>,
    ) {
        if destination == Destination::Default || self.selected.is_none() || self.browser.is_none()
        {
            cx.open_url(&url);
            return;
        }
        let thread = self
            .selected
            .as_ref()
            .map(|v| text(v, "id"))
            .unwrap_or_default();
        if !self.browser_panels.contains(&thread) {
            self.browser_action(BrowserAction::Show, None, cx);
        }
        let action = if destination == Destination::BrowserNewTab {
            BrowserAction::NewTab { url: Some(url) }
        } else {
            BrowserAction::Navigate { url }
        };
        self.browser_action(action, None, cx);
    }

    fn open_file_link(&mut self, reference: &str, window: &mut Window, cx: &mut Context<Self>) {
        let folder = self.open_folder();
        let home =
            std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).map(PathBuf::from);
        let path = file_path(reference);
        let Some(target) = resolve(&path, folder.as_deref(), home.as_deref())
            .filter(|target| target.exists())
            .map(|target| target.canonicalize().unwrap_or(target))
        else {
            self.status = format!("Nothing exists at {}.", shortened(&path));
            cx.notify();
            return;
        };
        if folder
            .as_deref()
            .is_some_and(|folder| coincide_core::turn_checkpoints::contains(folder, &target))
        {
            self.show_linked_file(target, cx);
            return;
        }
        let answer = window.prompt(
            PromptLevel::Warning,
            "Open a file outside this thread’s folder?",
            Some(&shortened(&target.to_string_lossy())),
            &["Cancel", "Open File"],
            cx,
        );
        cx.spawn(async move |this, cx| {
            if answer.await == Ok(1) {
                this.update(cx, |this, cx| this.show_linked_file(target, cx))
                    .ok();
            }
        })
        .detach();
    }

    /// Opens a file in an editor, or shows it in the file manager; never with
    /// its default app, which can launch apps and run scripts.
    fn show_linked_file(&mut self, target: PathBuf, cx: &mut Context<Self>) {
        let editor = (!target.is_dir())
            .then(|| open_targets::file_editor(&self.open_targets, &self.settings))
            .flatten();
        match editor {
            Some(editor) => self.open_file_in_editor(editor, target, cx),
            None => cx.reveal_path(&target),
        }
    }

    fn show_link_menu(
        &mut self,
        url: String,
        position: Point<Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let parent = cx.entity().downgrade();
        let menu = PopupMenu::build(window, cx, move |mut menu, _, _| {
            for destination in [
                Destination::Browser,
                Destination::BrowserNewTab,
                Destination::Default,
            ] {
                let parent = parent.clone();
                let url = url.clone();
                menu = menu.item(PopupMenuItem::new(destination.menu_title()).on_click(
                    move |_, _, cx| {
                        let _ = parent.update(cx, |this, cx| {
                            this.link_menu = None;
                            this.open_web_link(url.clone(), destination, cx);
                        });
                    },
                ));
            }
            let parent = parent.clone();
            menu.separator()
                .item(PopupMenuItem::new("Copy Link").on_click(move |_, _, cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(url.clone()));
                    let _ = parent.update(cx, |this, cx| {
                        this.link_menu = None;
                        cx.notify();
                    });
                }))
        });
        let dismissed = cx.subscribe(&menu, |this, _, _: &DismissEvent, cx| {
            this.link_menu = None;
            cx.notify();
        });
        menu.focus_handle(cx).focus(window, cx);
        self.link_menu = Some(LinkMenu {
            menu,
            position,
            _dismissed: dismissed,
        });
        cx.notify();
    }

    pub(super) fn link_menu_overlay(&self) -> Option<AnyElement> {
        let menu = self.link_menu.as_ref()?;
        Some(
            deferred(
                anchored()
                    .position(menu.position)
                    .snap_to_window_with_margin(px(8.))
                    .child(menu.menu.clone()),
            )
            .with_priority(1)
            .into_any_element(),
        )
    }

    /// Routes every rendered transcript link through this window's owner.
    pub(super) fn install_link_router(cx: &mut Context<Self>) {
        let owner = cx.entity().downgrade();
        cx.set_global(transcript::LinkRouter(Arc::new(
            move |url, event, window, cx| {
                let _ = owner.update(cx, |this, cx| {
                    this.open_transcript_link(url, event, window, cx)
                });
            },
        )));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn unicode_file_links_are_classified_without_byte_boundary_slicing() {
        for reference in ["你好.rs", "🦀/main.rs", "é中.md", "src/日本語.rs:12"] {
            assert_eq!(web_url(reference), None);
            assert_eq!(classify(reference), Link::File(reference.into()));
        }
        assert_eq!(
            web_url("WWW.example.com"),
            Some("https://WWW.example.com".into())
        );
    }

    #[::core::prelude::v1::test]
    fn web_links_need_a_host_and_www_gets_https() {
        assert_eq!(
            classify("https://example.com/a?b#c"),
            Link::Web("https://example.com/a?b#c".into())
        );
        assert_eq!(
            classify("HTTP://Example.com"),
            Link::Web("HTTP://Example.com".into())
        );
        assert_eq!(
            classify("www.example.com/x"),
            Link::Web("https://www.example.com/x".into())
        );
        assert_eq!(classify("https://"), Link::Ignore);
        assert_eq!(classify("http:relative"), Link::Ignore);
        assert_eq!(web_url("mailto:a@b.c"), None);
    }

    #[::core::prelude::v1::test]
    fn other_links_are_sorted_before_anything_opens() {
        assert_eq!(classify("#section"), Link::Ignore);
        assert_eq!(classify("  "), Link::Ignore);
        assert_eq!(
            classify("mailto:a@example.com"),
            Link::Mail("mailto:a@example.com".into())
        );
        assert_eq!(classify("ssh://host"), Link::Other("ssh://host".into()));
        assert_eq!(
            classify("vscode://file/x"),
            Link::Other("vscode://file/x".into())
        );
        assert_eq!(
            classify("src/main.rs:12"),
            Link::File("src/main.rs:12".into())
        );
        assert_eq!(
            classify("C:\\code\\a.rs"),
            Link::File("C:\\code\\a.rs".into())
        );
        assert_eq!(
            classify("file:///tmp/a.txt"),
            Link::File("file:///tmp/a.txt".into())
        );
    }

    #[::core::prelude::v1::test]
    fn file_links_drop_line_suffixes_and_decode() {
        assert_eq!(file_path("src/main.rs:12"), "src/main.rs");
        assert_eq!(file_path("src/main.rs:12:4"), "src/main.rs");
        assert_eq!(file_path("src/main.rs#L12"), "src/main.rs");
        assert_eq!(file_path("My%20File.md"), "My File.md");
        assert_eq!(file_path("bad%zzname"), "bad%zzname");
        assert_eq!(file_path("file:///tmp/a%20b.txt"), "/tmp/a b.txt");
        assert_eq!(file_path("file://localhost/tmp/x"), "/tmp/x");
        assert_eq!(file_path("C:\\code\\a.rs:3"), "C:\\code\\a.rs");
    }

    #[::core::prelude::v1::test]
    fn paths_resolve_against_the_thread_folder_or_home() {
        let folder = Path::new("/work/project");
        let home = Path::new("/home/me");
        assert_eq!(
            resolve("src/lib.rs", Some(folder), Some(home)),
            Some(folder.join("src/lib.rs"))
        );
        assert_eq!(
            resolve("~/notes.md", Some(folder), Some(home)),
            Some(home.join("notes.md"))
        );
        assert_eq!(resolve("relative.md", None, Some(home)), None);
        assert_eq!(resolve("", Some(folder), None), None);
        let absolute = if cfg!(windows) {
            "C:\\x\\y.rs"
        } else {
            "/x/y.rs"
        };
        assert_eq!(
            resolve(absolute, Some(folder), None),
            Some(PathBuf::from(absolute))
        );
    }

    #[::core::prelude::v1::test]
    fn command_swaps_the_setting_and_command_option_opens_a_new_tab() {
        assert_eq!(destination(false, false, false), Destination::Browser);
        assert_eq!(destination(true, false, false), Destination::Default);
        assert_eq!(destination(false, false, true), Destination::Default);
        assert_eq!(destination(true, false, true), Destination::Browser);
        assert_eq!(destination(true, true, true), Destination::BrowserNewTab);
        assert_eq!(destination(false, true, false), Destination::Browser);
    }

    #[::core::prelude::v1::test]
    fn confirmations_cut_long_links() {
        let long = "x".repeat(1200);
        let shown = shortened(&long);
        assert_eq!(shown.chars().count(), 1001);
        assert!(shown.ends_with('…'));
        assert_eq!(shortened("short"), "short");
    }
}
