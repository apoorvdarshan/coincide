//! Native-only controls. Parent owns Runtime/agent reply routing, and persists this
//! entity. No constructor calls TCC/AX; selected-thread changes never auto-grant.
use crate::computer_use::{Handle, Status};
use coincide_core::computer_use::{Permission, PermissionKind};
use gpui_kit::{base::Disableable, component::button::Button, *};
use std::time::Duration;
use uuid::Uuid;
pub struct ComputerUseSettingsPanel {
    handle: Handle,
    status: Status,
    selected: Option<Uuid>,
    notice: Option<String>,
    _poll: Task<()>,
}
impl ComputerUseSettingsPanel {
    pub fn new(handle: Handle, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let poll = cx.spawn_in(window, async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(100))
                    .await;
                if this
                    .update_in(cx, |this, _, cx| {
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
            selected: None,
            notice: None,
            _poll: poll,
        }
    }
    pub fn set_thread(&mut self, thread: Option<Uuid>, cx: &mut Context<Self>) {
        self.selected = thread;
        cx.notify();
    }
    fn enable(&mut self, cx: &mut Context<Self>) {
        self.notice = self
            .handle
            .native_enable(!self.status.enabled)
            .err()
            .map(|e| format!("{e:?}"));
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
    fn grant(&mut self, cx: &mut Context<Self>) {
        if let Some(thread) = self.selected {
            self.notice = Some(match self.handle.native_grant(thread) {
                Ok(()) => "Selected thread access enabled for this session".into(),
                Err(e) => format!("{e:?}"),
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
        div().flex().flex_col().gap_3().p_4()
            .child(div().text_lg().child("Computer Use"))
            .child("Allow selected threads to observe and interact with native Mac windows. Each input requires a fresh observation. Access starts off for every session.")
            .child(format!("Enabled: {} · Native adapter compiled: {} · Busy: {}",self.status.enabled,self.status.native_compiled,self.status.busy))
            .child(format!("Accessibility: {:?} · Screen Recording: {:?}",self.status.permissions.accessibility,self.status.permissions.screen_capture))
            .child(div().flex().gap_2()
                .child(Button::new("computer-use-enable").label(if self.status.enabled{"Disable Computer Use"}else{"Enable Computer Use"}).disabled(self.status.stopped||(!self.status.enabled&&!self.status.native_compiled)).on_click(cx.listener(|this,_,_,cx|this.enable(cx))))
                .child(Button::new("computer-use-refresh").label("Refresh permissions").disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(None,cx)))))
            .child(div().flex().gap_2()
                .child(Button::new("computer-use-ax").label("Grant Accessibility access").disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(Some(PermissionKind::Accessibility),cx))))
                .child(Button::new("computer-use-screen").label("Grant Screen Recording access").disabled(!permission).on_click(cx.listener(|this,_,_,cx|this.permission(Some(PermissionKind::ScreenCapture),cx)))))
            .child(self.selected.map(|id|format!("Selected thread: {id}")).unwrap_or_else(||"Select a thread to grant access".into()))
            .child(div().flex().gap_2()
                .child(Button::new("computer-use-thread-grant").label("Allow selected thread").disabled(!active||self.selected.is_none()||self.status.permissions.accessibility!=Permission::Granted).on_click(cx.listener(|this,_,_,cx|this.grant(cx))))
                .child(Button::new("computer-use-thread-revoke").label("Revoke selected thread").disabled(self.selected.is_none()).on_click(cx.listener(|this,_,_,cx|this.revoke(cx)))))
            .child("No browser control, arbitrary scripts or commands. Screenshots require Screen Recording and macOS 14 or later; other platforms are unsupported. Dispatch success requires a new observation to verify the result.")
            .child(self.notice.clone().or_else(||self.status.error.map(|e|format!("{e:?}"))).unwrap_or_default())
    }
}
