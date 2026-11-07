//! Native-only controls. Parent owns Runtime/agent reply routing, and persists this
//! entity. No constructor calls TCC/AX; selected-thread changes never auto-grant.
use crate::computer_use::{Handle, Status};
use coincide_core::computer_use::{Failure, Permission, PermissionKind};
use gpui_kit::{base::Disableable, component::button::Button, *};
use std::{collections::BTreeMap, time::Duration};
use uuid::Uuid;
pub struct ComputerUseSettingsPanel {
    handle: Handle,
    status: Status,
    selected: Option<Uuid>,
    /// Conversation titles from the parent, for the in-use and activity text.
    titles: BTreeMap<Uuid, String>,
    /// Allowed threads and those with a request running, from the last poll.
    granted: Vec<Uuid>,
    in_use: Vec<Uuid>,
    notice: Option<String>,
    _poll: Task<()>,
}
/// Swift's ComputerUseController.stateDescription, for this runtime: it is
/// in-process, so it is ready whenever it is on and has not stopped.
fn state_description(status: &Status, in_use: Option<&str>) -> String {
    if !status.enabled {
        return "Off".into();
    }
    if status.permissions.accessibility != Permission::Granted {
        return "Waiting for Accessibility access".into();
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
                        let (granted, in_use) = this.handle.activity();
                        if (&granted, &in_use) != (&this.granted, &this.in_use) {
                            (this.granted, this.in_use) = (granted, in_use);
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
            selected: None,
            titles: BTreeMap::new(),
            granted: Vec::new(),
            in_use: Vec::new(),
            notice: None,
            _poll: poll,
        }
    }
    pub fn set_thread(&mut self, thread: Option<Uuid>, cx: &mut Context<Self>) {
        self.selected = thread;
        cx.notify();
    }
    pub fn set_titles(&mut self, titles: BTreeMap<Uuid, String>, cx: &mut Context<Self>) {
        if self.titles != titles {
            self.titles = titles;
            cx.notify();
        }
    }
    fn enable(&mut self, cx: &mut Context<Self>) {
        self.notice = self
            .handle
            .native_enable(!self.status.enabled)
            .err()
            .map(|e| failure_text(e).into());
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
    fn grant(&mut self, cx: &mut Context<Self>) {
        if let Some(thread) = self.selected {
            self.notice = Some(match self.handle.native_grant(thread) {
                Ok(()) => "Selected thread access enabled for this session".into(),
                Err(e) => failure_text(e).into(),
            });
        }
        cx.notify();
    }
    fn revoke(&mut self, cx: &mut Context<Self>) {
        if let Some(thread) = self.selected {
            self.handle.native_revoke(thread);
            self.notice=Some("Selected thread access revoked; fresh observations are required after granting again".into());
        }
        cx.notify();
    }
}
impl Render for ComputerUseSettingsPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let active = self.status.enabled && self.status.native_compiled && !self.status.stopped;
        let permission = active && !self.status.busy;
        let in_use = titles_of(&self.in_use, &self.titles);
        let using = titles_of(&self.granted, &self.titles);
        let selected = self.selected.map(|id| {
            self.titles
                .get(&id)
                .map(|title| format!("Selected thread: “{title}”"))
                .unwrap_or_else(|| format!("Selected thread: {id}"))
        });
        // Swift's "needs attention": a stopped runtime first, then the last failure.
        let attention = if self.status.enabled && self.status.stopped {
            Some("Computer Use stopped unexpectedly. Quit and reopen Coincide to use it again.")
        } else {
            self.status.error.map(failure_text)
        };
        div().flex().flex_col().gap_3().p_4()
            .child(div().text_lg().child("Computer Use"))
            .child("Allow selected threads to observe and interact with native app windows. Each input requires a fresh observation. Access starts off for every session.")
            .child(format!("Status: {}", state_description(&self.status, in_use.first().map(String::as_str))))
            .child(format!("Enabled: {} · Native adapter compiled: {} · Busy: {}",self.status.enabled,self.status.native_compiled,self.status.busy))
            .child(format!("App accessibility: {:?} · Window capture: {:?}",self.status.permissions.accessibility,self.status.permissions.screen_capture))
            .child(div().flex().gap_2()
                .child(Button::new("computer-use-enable").label(if self.status.enabled{"Disable Computer Use"}else{"Enable Computer Use"}).disabled(self.status.stopped||(!self.status.enabled&&!self.status.native_compiled)).on_click(cx.listener(|this,_,_,cx|this.enable(cx))))
                .child(Button::new("computer-use-refresh").label("Refresh permissions").disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(None,cx)))))
            .child(div().flex().gap_2()
                .child(Button::new("computer-use-ax").label(if cfg!(target_os="macos") {"Grant Accessibility access"} else {"Check app accessibility"}).disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(Some(PermissionKind::Accessibility),cx))))
                .child(Button::new("computer-use-screen").label(if cfg!(target_os="macos") {"Grant Screen Recording access"} else {"Check window capture"}).disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(Some(PermissionKind::ScreenCapture),cx)))))
            .child(selected.unwrap_or_else(||"Select a thread to grant access".into()))
            .child(div().flex().gap_2()
                .child(Button::new("computer-use-thread-grant").label("Allow selected thread").disabled(!active||self.selected.is_none()||self.status.permissions.accessibility!=Permission::Granted).on_click(cx.listener(|this,_,_,cx|this.grant(cx))))
                .child(Button::new("computer-use-thread-revoke").label("Revoke selected thread").disabled(self.selected.is_none()).on_click(cx.listener(|this,_,_,cx|this.revoke(cx)))))
            .child(div().text_sm().child("Activity"))
            .child(if using.is_empty() { "No threads are using this computer.".into() } else { using.join("\n") })
            .child("No browser control, arbitrary scripts or commands. macOS requires Accessibility and Screen Recording access. Windows follows its app and window capture permissions. Linux requires X11, XRes, XComposite and app accessibility; Wayland and XWayland are unsupported. Dispatch success requires a new observation to verify the result.")
            .children(attention.map(|text| div().flex().flex_col().gap_1().child(div().text_sm().child("Computer Use needs attention")).child(text)))
            .child(self.notice.clone().unwrap_or_default())
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
            "Waiting for Accessibility access"
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
