//! Native-only controls. Parent owns Runtime/agent reply routing, and persists this
//! entity. No constructor calls TCC/AX. The switch is saved, and while it is on
//! every thread has access through its private connection (Swift's model).
use crate::computer_use::{Handle, Status};
use coincide_core::computer_use::{Failure, Permission, PermissionKind};
use gpui_kit::{
    base::Disableable,
    component::{
        ActiveTheme, Sizable, StyledExt,
        button::{Button, ButtonVariants},
        switch::Switch,
    },
    prelude::FluentBuilder,
    *,
};
use std::{collections::BTreeMap, time::Duration};
use uuid::Uuid;
pub struct ComputerUseSettingsPanel {
    handle: Handle,
    status: Status,
    /// The desktop owner's title while a thread holds the shared desktop.
    owner: Option<String>,
    titles: BTreeMap<Uuid, String>,
    in_use: Vec<Uuid>,
    save_error: Option<String>,
    notice: Option<String>,
    _poll: Task<()>,
}
const COMPUTER: &str = if cfg!(target_os = "macos") {
    "Mac"
} else {
    "computer"
};
/// Swift's ComputerUseController.stateDescription, for this runtime: it is
/// in-process, so it is ready whenever it is on and has not stopped.
fn state_description(status: &Status, in_use: Option<&str>) -> String {
    if !status.enabled {
        return "Off".into();
    }
    if status.permissions.accessibility != Permission::Granted {
        return if cfg!(target_os = "macos") {
            "Waiting for Accessibility access"
        } else {
            "Waiting for app accessibility"
        }
        .into();
    }
    if status.stopped {
        return "Stopped".into();
    }
    match in_use {
        Some(title) => format!("In use by “{title}”"),
        None => "Ready".into(),
    }
}
/// What went wrong, in words, for the "needs attention" text.
fn failure_text(failure: Failure) -> &'static str {
    match failure {
        Failure::InvalidRequest => "An agent sent a request Computer Use couldn’t read.",
        Failure::Off => "Computer Use is off.",
        Failure::NotGranted => "That thread isn’t allowed to use Computer Use.",
        Failure::Unsupported => "Computer Use isn’t available in this build.",
        Failure::PermissionDenied => "Computer Use needs a permission that isn’t granted.",
        Failure::Busy => "Computer Use was busy with another request.",
        Failure::StaleObservation => "The window changed since the agent last looked at it.",
        Failure::TimedOut => "A Computer Use request timed out.",
        Failure::TooLarge => "A Computer Use result was too large to return.",
        Failure::Native => "The native Computer Use adapter reported an error.",
        Failure::Revoked => "Computer Use access was revoked.",
    }
}
/// Swift's activeThreadTitles: titles of the threads using Computer Use,
/// sorted as Finder sorts names; threads without a known title are left out.
fn titles_of(threads: &[Uuid], titles: &BTreeMap<Uuid, String>) -> Vec<String> {
    let mut names: Vec<String> = threads
        .iter()
        .filter_map(|id| titles.get(id).cloned())
        .collect();
    names.sort_by_key(|name| name.to_lowercase());
    names
}

fn activity_titles(
    threads: &[Uuid],
    titles: &BTreeMap<Uuid, String>,
    owner: Option<&str>,
) -> Vec<String> {
    let mut names = titles_of(threads, titles);
    if let Some(owner) = owner {
        let owner = if owner.is_empty() { "a thread" } else { owner };
        if !names.iter().any(|name| name == owner) {
            names.push(owner.to_owned());
            names.sort_by_key(|name| name.to_lowercase());
        }
    }
    names
}
impl ComputerUseSettingsPanel {
    pub fn new(handle: Handle, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this
                    .update(cx, |this, cx| {
                        if let Some(status) = this.handle.try_status() {
                            this.status = status;
                            cx.notify();
                        }
                        let (_, in_use) = this.handle.activity();
                        if this.in_use != in_use {
                            this.in_use = in_use;
                            cx.notify();
                        }
                    })
                    .is_err()
                {
                    break;
                }
            }
        });
        Self {
            handle,
            status: Status::default(),
            owner: None,
            titles: BTreeMap::new(),
            in_use: Vec::new(),
            save_error: None,
            notice: None,
            _poll: poll,
        }
    }
    pub fn set_activity(
        &mut self,
        owner: Option<String>,
        save_error: Option<String>,
        cx: &mut Context<Self>,
    ) {
        if self.owner != owner || self.save_error != save_error {
            self.owner = owner;
            self.save_error = save_error;
            cx.notify();
        }
    }
    pub fn set_titles(&mut self, titles: BTreeMap<Uuid, String>, cx: &mut Context<Self>) {
        if self.titles != titles {
            self.titles = titles;
            cx.notify();
        }
    }
    fn set_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.notice = match self.handle.native_set_saved(enabled) {
            Ok(()) => None,
            Err(Failure::Unsupported) => Some("Computer Use isn’t available in this build.".into()),
            Err(error) => Some(failure_text(error).into()),
        };
        cx.notify();
    }
    fn permission(&mut self, kind: Option<PermissionKind>, cx: &mut Context<Self>) {
        self.notice = match kind {
            Some(k) => self.handle.native_request_permission(k),
            None => self.handle.native_refresh(),
        }
        .err()
        .map(|e| failure_text(e).into());
        cx.notify();
    }
    /// The runtime owner takes precedence over the asynchronously polled titles.
    fn state(&self) -> String {
        let owner = self
            .owner
            .as_deref()
            .map(|title| if title.is_empty() { "a thread" } else { title });
        state_description(&self.status, owner)
    }
}
impl Render for ComputerUseSettingsPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let active = self.status.enabled && self.status.native_compiled && !self.status.stopped;
        let permission = active && !self.status.busy;
        let enabled = self.status.enabled;
        let using = activity_titles(&self.in_use, &self.titles, self.owner.as_deref());
        let attention = if enabled && self.status.stopped {
            Some("Computer Use stopped unexpectedly. Quit and reopen Coincide to use it again.")
        } else {
            self.status.error.map(failure_text)
        };
        let label = |permission| match permission {
            Permission::Granted => "Allowed",
            Permission::Denied => "Not allowed",
            Permission::Unknown => "Not checked",
            Permission::Unsupported => "Unavailable on this platform",
        };
        let mut pane = div().flex().flex_col().gap_3().p_4()
            .child(div().flex().items_center().gap_3()
                .child(div().flex_1().child(format!("Allow agents to use this {COMPUTER}"))
                    .child(div().text_xs().text_color(cx.theme().muted_foreground).child("Agents can see and interact with apps through a private connection for each conversation.")))
                .child(Switch::new("computer-use-enable").color(cx.theme().foreground).accessibility_label(format!("Allow agents to use this {COMPUTER}"))
                    .checked(enabled).disabled(self.status.stopped || (!enabled && !self.status.native_compiled))
                    .on_click(cx.listener(|this, checked, _, cx| this.set_enabled(*checked, cx)))))
            .child(div().flex().items_center().justify_between().child(self.state())
                .child(Button::new("computer-use-refresh").icon(gpui_kit::assets::IconName::RefreshCw).ghost().small().accessibility_label("Refresh permissions").tooltip("Refresh permissions").disabled(!permission)
                    .on_click(cx.listener(|this, _, _, cx| this.permission(None, cx)))));
        for (id, title, state, kind) in [
            (
                "computer-use-ax",
                "Accessibility",
                self.status.permissions.accessibility,
                PermissionKind::Accessibility,
            ),
            (
                "computer-use-screen",
                "Screen Recording",
                self.status.permissions.screen_capture,
                PermissionKind::ScreenCapture,
            ),
        ] {
            pane = pane.child(
                div()
                    .flex()
                    .items_center()
                    .gap_3()
                    .py_2()
                    .border_b_1()
                    .border_color(cx.theme().border)
                    .child(
                        div().flex_1().child(title).child(
                            div()
                                .text_xs()
                                .text_color(cx.theme().muted_foreground)
                                .child(label(state)),
                        ),
                    )
                    .when(state != Permission::Granted, |row| {
                        row.child(
                            Button::new(id)
                                .label("Grant Access")
                                .small()
                                .accessibility_label(format!("Grant {title} access"))
                                .disabled(!permission)
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    this.permission(Some(kind), cx)
                                })),
                        )
                    }),
            );
        }
        pane.child(div().font_semibold().child("Activity"))
            .child(div().text_sm().child(if using.is_empty() { "No conversations are using this computer.".into() } else { using.join("\n") }))
            .children(attention.map(|text| div().text_sm().text_color(cx.theme().danger).child(text)))
            .child(div().text_xs().text_color(cx.theme().muted_foreground).child("Turn Computer Use off to end agents’ access. Access also ends when Coincide quits."))
            .child(div().text_xs().text_color(cx.theme().danger).child(self.notice.clone().or_else(|| self.save_error.clone()).or_else(|| self.status.error.map(|error| failure_text(error).to_owned())).unwrap_or_default()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use coincide_core::computer_use::Permissions;
    fn status(enabled: bool, accessibility: Permission, stopped: bool) -> Status {
        Status {
            enabled,
            permissions: Permissions {
                accessibility,
                screen_capture: Permission::Granted,
            },
            stopped,
            ..Status::default()
        }
    }
    #[::core::prelude::v1::test]
    fn state_reads_like_swift_from_off_to_in_use() {
        assert_eq!(
            state_description(&status(false, Permission::Granted, false), None),
            "Off"
        );
        assert_eq!(
            state_description(&status(true, Permission::Denied, false), Some("Fix CI")),
            if cfg!(target_os = "macos") {
                "Waiting for Accessibility access"
            } else {
                "Waiting for app accessibility"
            }
        );
        assert_eq!(
            state_description(&status(true, Permission::Granted, false), Some("Fix CI")),
            "In use by “Fix CI”"
        );
        assert_eq!(
            state_description(&status(true, Permission::Granted, false), None),
            "Ready"
        );
        assert_eq!(
            state_description(&status(true, Permission::Granted, true), None),
            "Stopped"
        );
    }
    #[::core::prelude::v1::test]
    fn activity_lists_known_titles_sorted_case_insensitively() {
        let (a, b, c) = (Uuid::new_v4(), Uuid::new_v4(), Uuid::new_v4());
        let titles = BTreeMap::from([(a, "beta".to_owned()), (b, "Alpha".to_owned())]);
        assert_eq!(titles_of(&[a, b, c], &titles), ["Alpha", "beta"]);
        assert!(titles_of(&[c], &titles).is_empty());
        assert_eq!(activity_titles(&[], &titles, Some("Alpha")), ["Alpha"]);
        assert_eq!(activity_titles(&[b], &titles, Some("Alpha")), ["Alpha"]);
        assert_eq!(activity_titles(&[], &titles, Some("")), ["a thread"]);
    }
}
