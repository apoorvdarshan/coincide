//! Native-only controls. Parent owns Runtime/agent reply routing, and persists this
//! entity. No constructor calls TCC/AX. The switch is saved, and while it is on
//! every thread has access through its private connection (Swift's model).
use crate::computer_use::{Handle, Status};
use coincide_core::computer_use::{Failure, Permission, PermissionKind};
use gpui_kit::{
    base::Disableable,
    component::{button::Button, checkbox::Checkbox},
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
        let using = titles_of(&self.in_use, &self.titles);
        let attention = if enabled && self.status.stopped {
            Some("Computer Use stopped unexpectedly. Quit and reopen Coincide to use it again.")
        } else {
            self.status.error.map(failure_text)
        };
        div().flex().flex_col().gap_3().p_4()
            .child(div().text_lg().child("Computer Use"))
            .child(format!("Let agents see and interact with {} through Coincide.", if cfg!(target_os="macos") {"Mac apps"} else {"apps on this computer"}))
            .child(div().flex().flex_col().gap_1()
                .child(Checkbox::new("computer-use-enable").label(format!("Allow agents to use this {COMPUTER}")).checked(enabled).disabled(self.status.stopped||(!enabled&&!self.status.native_compiled)).on_click(cx.listener(|this,checked,_,cx|this.set_enabled(*checked,cx))))
                .child(div().text_sm().child("Agents can view the screen and interact with apps while Computer Use is on. All providers use a private connection for each thread.")))
            .child(format!("Status: {}", self.state()))
            .child(format!("App accessibility: {:?} · Window capture: {:?}",self.status.permissions.accessibility,self.status.permissions.screen_capture))
            .child(div().flex().gap_2()
                .child(Button::new("computer-use-refresh").label("Refresh").disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(None,cx)))))
            .child(div().flex().gap_2()
                .child(Button::new("computer-use-ax").label(if cfg!(target_os="macos") {"Grant Accessibility access"} else {"Check app accessibility"}).disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(Some(PermissionKind::Accessibility),cx))))
                .child(Button::new("computer-use-screen").label(if cfg!(target_os="macos") {"Grant Screen Recording access"} else {"Check window capture"}).disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(Some(PermissionKind::ScreenCapture),cx)))))
            .child(div().text_sm().child("Activity"))
            .child(if using.is_empty() { "No threads are using this computer.".into() } else { using.join("\n") })
            .children(attention.map(|text| div().flex().flex_col().gap_1().child(div().text_sm().child("Computer Use needs attention")).child(text)))
            .child(div().text_sm().child("Turning Computer Use off ends agents’ access. Computer Use also stops when Coincide quits."))
            .child("No browser control, arbitrary scripts or commands. macOS requires Accessibility and Screen Recording access. Windows follows its app and window capture permissions. Linux requires X11, XRes, XComposite and app accessibility; Wayland and XWayland are unsupported. Dispatch success requires a new observation to verify the result.")
            .child(self.notice.clone().or_else(||self.save_error.clone()).or_else(||self.status.error.map(|e|format!("{e:?}"))).unwrap_or_default())
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
    }
}
