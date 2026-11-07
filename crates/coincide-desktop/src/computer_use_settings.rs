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
use std::time::Duration;
pub struct ComputerUseSettingsPanel {
    handle: Handle,
    status: Status,
    /// The desktop owner's title while a thread holds the shared desktop.
    owner: Option<String>,
    save_error: Option<String>,
    notice: Option<String>,
    _poll: Task<()>,
}
const COMPUTER: &str = if cfg!(target_os = "macos") {
    "Mac"
} else {
    "computer"
};
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
    fn set_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.notice = match self.handle.native_set_saved(enabled) {
            Ok(()) => None,
            Err(Failure::Unsupported) => Some("Computer Use isn’t available in this build.".into()),
            Err(error) => Some(format!("{error:?}")),
        };
        cx.notify();
    }
    fn permission(&mut self, kind: Option<PermissionKind>, cx: &mut Context<Self>) {
        self.notice = match kind {
            Some(k) => self.handle.native_request_permission(k),
            None => self.handle.native_refresh(),
        }
        .err()
        .map(|e| format!("{e:?}"));
        cx.notify();
    }
    /// Swift `ComputerUseController.stateDescription`.
    fn state(&self) -> String {
        if !self.status.enabled {
            return "Off".into();
        }
        if self.status.permissions.accessibility != Permission::Granted {
            return if cfg!(target_os = "macos") {
                "Waiting for Accessibility access".into()
            } else {
                "Waiting for app accessibility".into()
            };
        }
        match self.owner.as_deref() {
            Some(title) if !title.is_empty() => format!("In use by “{title}”"),
            Some(_) => "In use by a thread".into(),
            None => "Ready".into(),
        }
    }
}
impl Render for ComputerUseSettingsPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let active = self.status.enabled && self.status.native_compiled && !self.status.stopped;
        let permission = active && !self.status.busy;
        let enabled = self.status.enabled;
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
            .child(div().text_sm().child("Turning Computer Use off ends agents’ access. Computer Use also stops when Coincide quits."))
            .child("No browser control, arbitrary scripts or commands. macOS requires Accessibility and Screen Recording access. Windows follows its app and window capture permissions. Linux requires X11, XRes, XComposite and app accessibility; Wayland and XWayland are unsupported. Dispatch success requires a new observation to verify the result.")
            .child(self.notice.clone().or_else(||self.save_error.clone()).or_else(||self.status.error.map(|e|format!("{e:?}"))).unwrap_or_default())
    }
}
