//! Settings › General › Remote: lets Coincide Remote on iPhone and iPad connect,
//! pairs devices and lists them, as `RemoteSettingsView.swift` does. The server
//! stays off, and the system secret store unread, until the user turns it on.
use super::*;
use coincide_core::remote::{
    crypto::display_fingerprint,
    protocol::{Device, PairingPayload},
    qr,
    server::{RemoteServer, Snapshot, Status},
    text::{self, Dot},
};
use gpui_kit::component::switch::Switch;

pub(super) struct RemoteSettingsPanel {
    server: Option<RemoteServer>,
    snapshot: Option<Snapshot>,
    sheet_open: bool,
    revoking: Option<Device>,
    confirming_reset: bool,
    notice: Option<String>,
    /// The countdown last drawn, so the sheet redraws once a second.
    countdown: String,
    /// The pairing code's modules, made once per code.
    code: Option<(String, qr::Matrix)>,
}

fn now_ms() -> f64 {
    coincide_core::remote::pairing::now_ms()
}

impl RemoteSettingsPanel {
    pub(super) fn new(engine: SharedEngine) -> Self {
        let directory = engine
            .lock()
            .ok()
            .and_then(|engine| engine.store.data_directory().ok());
        let mut server = directory.map(|directory| {
            RemoteServer::new(directory, engine.clone(), env!("CARGO_PKG_VERSION"))
        });
        if let Some(server) = &mut server {
            server.start_if_enabled();
        }
        let snapshot = server.as_ref().map(RemoteServer::snapshot);
        Self {
            server,
            snapshot,
            sheet_open: false,
            revoking: None,
            confirming_reset: false,
            notice: None,
            countdown: String::new(),
            code: None,
        }
    }

    /// Called from the window's tick: picks up connections, pairings and the
    /// pairing code's countdown.
    pub(super) fn poll(&mut self, cx: &mut Context<Self>) {
        let Some(server) = &self.server else { return };
        let snapshot = server.snapshot();
        let countdown = snapshot
            .pairing
            .as_ref()
            .filter(|_| self.sheet_open)
            .map(|payload| text::countdown(payload.expires_at, now_ms()).0)
            .unwrap_or_default();
        if Some(&snapshot) != self.snapshot.as_ref() || countdown != self.countdown {
            self.snapshot = Some(snapshot);
            self.countdown = countdown;
            cx.notify();
        }
    }

    /// Stops listening as the app quits.
    pub(super) fn shut_down(&mut self) {
        if let Some(server) = &mut self.server {
            server.stop();
        }
    }

    fn update(&mut self, cx: &mut Context<Self>, change: impl FnOnce(&mut RemoteServer)) {
        if let Some(server) = &mut self.server {
            change(server);
            self.snapshot = Some(server.snapshot());
        }
        cx.notify();
    }

    fn set_enabled(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.notice = None;
        self.update(cx, |server| server.set_enabled(enabled));
        if !enabled {
            self.sheet_open = false;
            self.revoking = None;
            self.confirming_reset = false;
        }
    }

    fn begin_pairing(&mut self, cx: &mut Context<Self>) {
        self.update(cx, |server| {
            server.begin_pairing();
        });
        self.sheet_open = true;
    }

    fn close_sheet(&mut self, cx: &mut Context<Self>) {
        self.sheet_open = false;
        self.code = None;
        self.update(cx, RemoteServer::cancel_pairing);
    }

    fn row(label: AnyElement, trailing: Option<AnyElement>, cx: &App) -> Div {
        div()
            .flex()
            .items_center()
            .gap_3()
            .py_2()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(label),
            )
            .when_some(trailing, |row, trailing| row.child(trailing))
    }

    fn secondary(text: impl Into<SharedString>, cx: &App) -> Div {
        div()
            .text_sm()
            .text_color(cx.theme().muted_foreground)
            .child(text.into())
    }

    fn dot(dot: Dot, cx: &App) -> Div {
        let theme = cx.theme();
        let color = match dot {
            Dot::Green => theme.success,
            Dot::Yellow => theme.warning,
            Dot::Orange => rgb(0xFF8A3D).into(),
            Dot::Off => theme.border,
        };
        div().size(px(8.)).flex_none().rounded_full().bg(color)
    }

    fn status_rows(&self, snapshot: &Snapshot, cx: &mut Context<Self>) -> Vec<AnyElement> {
        let running = matches!(snapshot.status, Status::Running { .. });
        let mut rows = vec![
            Self::row(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(6.))
                            .child(Self::dot(text::status_dot(&snapshot.status), cx))
                            .child(text::status_title(&snapshot.status)),
                    )
                    .child(Self::secondary(
                        text::status_detail(&snapshot.status, snapshot.connected.len()),
                        cx,
                    ))
                    .into_any_element(),
                Some(
                    Button::new("remote-pair")
                        .label("Pair iPhone or iPad…")
                        .disabled(!running)
                        .on_click(cx.listener(|this, _, _, cx| this.begin_pairing(cx)))
                        .into_any_element(),
                ),
                cx,
            )
            .into_any_element(),
        ];
        if !snapshot.candidates.is_empty() {
            let mut hosts = div().flex().flex_col().items_end().gap(px(2.));
            for candidate in &snapshot.candidates {
                hosts = hosts.child(
                    div()
                        .flex()
                        .gap(px(6.))
                        .child(div().font_family("monospace").child(candidate.host.clone()))
                        .child(Self::secondary(text::kind_label(candidate.kind), cx)),
                );
            }
            rows.push(
                Self::row(
                    div().child("Reachable at").into_any_element(),
                    Some(hosts.into_any_element()),
                    cx,
                )
                .into_any_element(),
            );
        }
        if snapshot.devices.is_empty() {
            rows.push(
                Self::row(
                    div().child("Paired devices").into_any_element(),
                    Some(Self::secondary("None yet", cx).into_any_element()),
                    cx,
                )
                .into_any_element(),
            );
        }
        for (index, device) in snapshot.devices.iter().enumerate() {
            let connected = snapshot.connected.contains(&device.id);
            let revoking = device.clone();
            rows.push(
                Self::row(
                    div()
                        .flex()
                        .flex_col()
                        .gap_1()
                        .child(
                            div()
                                .flex()
                                .items_center()
                                .gap(px(6.))
                                .child(Self::dot(if connected { Dot::Green } else { Dot::Off }, cx))
                                .child(device.name.clone()),
                        )
                        .child(Self::secondary(
                            text::device_detail(device, connected, now_ms()),
                            cx,
                        ))
                        .into_any_element(),
                    Some(
                        Button::new(SharedString::from(format!("remote-revoke-{index}")))
                            .label("Revoke…")
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.revoking = Some(revoking.clone());
                                cx.notify();
                            }))
                            .into_any_element(),
                    ),
                    cx,
                )
                .into_any_element(),
            );
        }
        rows.push(
            Self::row(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child("Certificate")
                    .child(
                        Self::secondary(
                            snapshot
                                .fingerprint
                                .as_ref()
                                .map(|f| format!("SHA-256 {}", display_fingerprint(f, 8)))
                                .unwrap_or_else(|| "–".into()),
                            cx,
                        )
                        .font_family("monospace"),
                    )
                    .into_any_element(),
                Some(
                    Button::new("remote-reset")
                        .label("Reset…")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.confirming_reset = true;
                            cx.notify();
                        }))
                        .into_any_element(),
                ),
                cx,
            )
            .into_any_element(),
        );
        rows
    }

    fn confirmation(
        title: String,
        message: &'static str,
        confirm: &'static str,
        id: &'static str,
        cx: &mut Context<Self>,
        on_confirm: impl Fn(&mut Self, &mut Context<Self>) + 'static,
    ) -> AnyElement {
        div()
            .flex()
            .flex_col()
            .gap_2()
            .p_3()
            .rounded_md()
            .border_1()
            .border_color(cx.theme().border)
            .child(div().font_weight(FontWeight::SEMIBOLD).child(title))
            .child(Self::secondary(message, cx))
            .child(
                div()
                    .flex()
                    .justify_end()
                    .gap_2()
                    .child(
                        Button::new(SharedString::from(format!("{id}-cancel")))
                            .label("Cancel")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.revoking = None;
                                this.confirming_reset = false;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new(SharedString::from(format!("{id}-confirm")))
                            .label(confirm)
                            .danger()
                            .on_click(cx.listener(move |this, _, _, cx| on_confirm(this, cx))),
                    ),
            )
            .into_any_element()
    }

    fn code_matrix(&mut self, payload: &PairingPayload) -> Option<qr::Matrix> {
        let encoded = payload.encoded();
        if self
            .code
            .as_ref()
            .is_none_or(|(known, _)| *known != encoded)
        {
            self.code = qr::encode(&encoded).map(|matrix| (encoded, matrix));
        }
        self.code.as_ref().map(|(_, matrix)| matrix.clone())
    }

    /// The code drawn as rectangles 240 points square, each module's edges on
    /// whole pixels so the camera sees crisp squares.
    fn code_view(matrix: &qr::Matrix) -> AnyElement {
        const SIDE: f32 = 240.;
        let scale = SIDE / matrix.size as f32;
        let edge = |modules: usize| (modules as f32 * scale).round();
        let mut canvas = div().relative().size(px(SIDE));
        for (row, column, length) in matrix.runs() {
            let (left, top) = (edge(column), edge(row));
            canvas = canvas.child(
                div()
                    .absolute()
                    .left(px(left))
                    .top(px(top))
                    .w(px(edge(column + length) - left))
                    .h(px(edge(row + 1) - top))
                    .bg(rgb(0x000000)),
            );
        }
        div()
            .p(px(12.))
            .bg(rgb(0xFFFFFF))
            .rounded(px(12.))
            .child(canvas)
            .into_any_element()
    }

    fn sheet(&mut self, snapshot: &Snapshot, cx: &mut Context<Self>) -> AnyElement {
        let mut sheet = div()
            .id("remote-pairing-sheet")
            .flex()
            .flex_col()
            .items_center()
            .gap_4()
            .p_6()
            .w(px(380.))
            .rounded_lg()
            .border_1()
            .border_color(cx.theme().border)
            .bg(cx.theme().background)
            .child(
                div()
                    .text_xl()
                    .font_weight(FontWeight::SEMIBOLD)
                    .child("Pair Coincide Remote"),
            );
        if let Some(device) = &snapshot.last_paired {
            sheet = sheet
                .child(
                    div()
                        .size(px(64.))
                        .rounded_full()
                        .bg(cx.theme().success)
                        .flex()
                        .items_center()
                        .justify_center()
                        .text_color(rgb(0xFFFFFF))
                        .text_3xl()
                        .child("✓"),
                )
                .child(
                    div()
                        .font_weight(FontWeight::SEMIBOLD)
                        .child(format!("“{}” is paired.", device.name)),
                )
                .child(
                    Button::new("remote-pairing-done")
                        .label("Done")
                        .primary()
                        .on_click(cx.listener(|this, _, _, cx| this.close_sheet(cx))),
                );
        } else if let Some(payload) = snapshot.pairing.clone() {
            let (countdown, live) = text::countdown(payload.expires_at, now_ms());
            sheet = sheet.child(
                Self::secondary(
                    "Open Coincide Remote on your iPhone or iPad, tap Scan Pairing Code, and point the camera here.",
                    cx,
                )
                .text_center(),
            );
            if let Some(matrix) = self.code_matrix(&payload) {
                sheet = sheet.child(Self::code_view(&matrix));
            }
            let copied = payload.encoded();
            sheet = sheet
                .child(
                    div()
                        .text_sm()
                        .text_color(if live {
                            cx.theme().muted_foreground
                        } else {
                            rgb(0xFF8A3D).into()
                        })
                        .child(countdown),
                )
                .child(
                    Self::secondary(
                        format!(
                            "Certificate {}",
                            display_fingerprint(&payload.fingerprint, 8)
                        ),
                        cx,
                    )
                    .text_xs()
                    .font_family("monospace"),
                )
                .child(
                    div()
                        .w_full()
                        .flex()
                        .gap_2()
                        .child(
                            Button::new("remote-pairing-new")
                                .label("New Code")
                                .on_click(cx.listener(|this, _, _, cx| this.begin_pairing(cx))),
                        )
                        // The clipboard carries it to a device whose camera can't scan.
                        .child(
                            Button::new("remote-pairing-copy")
                                .label("Copy Code")
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    cx.write_to_clipboard(ClipboardItem::new_string(
                                        copied.clone(),
                                    ));
                                    this.notice = Some("Copied".into());
                                    cx.notify();
                                })),
                        )
                        .child(div().flex_1())
                        .child(
                            Button::new("remote-pairing-cancel")
                                .label("Cancel")
                                .on_click(cx.listener(|this, _, _, cx| this.close_sheet(cx))),
                        ),
                );
        } else {
            sheet = sheet
                .child(Self::secondary("Coincide Remote isn’t running.", cx))
                .child(
                    Button::new("remote-pairing-close")
                        .label("Close")
                        .on_click(cx.listener(|this, _, _, cx| this.close_sheet(cx))),
                );
        }
        sheet
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                if event.keystroke.key == "escape" {
                    this.close_sheet(cx);
                }
            }))
            .into_any_element()
    }
}

impl Render for RemoteSettingsPanel {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let Some(snapshot) = self.snapshot.clone() else {
            return div()
                .p_3()
                .child("Coincide Remote is unavailable: the app’s data folder couldn’t be found.")
                .into_any_element();
        };
        let mut panel = div()
            .flex()
            .flex_col()
            .p_3()
            .gap_1()
            .border_b_1()
            .border_color(cx.theme().border)
            .child(div().text_lg().child("Remote"))
            .child(Self::row(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child("Allow Coincide Remote")
                    .child(Self::secondary(
                        "Drive Coincide from your iPhone or iPad on this network or your Tailscale network. Paired devices connect over an encrypted connection; nothing goes through the internet.",
                        cx,
                    ))
                    .into_any_element(),
                Some(
                    Switch::new("remote-enabled")
                        .accessibility_label("Allow Coincide Remote")
                        .checked(snapshot.enabled)
                        .on_click(cx.listener(|this, checked: &bool, _, cx| {
                            this.set_enabled(*checked, cx)
                        }))
                        .into_any_element(),
                ),
                cx,
            ));
        if snapshot.enabled {
            panel = panel.children(self.status_rows(&snapshot, cx));
        }
        if let Some(device) = self.revoking.clone() {
            panel = panel.child(Self::confirmation(
                format!("Revoke “{}”?", device.name),
                "It disconnects now and has to pair again to connect.",
                "Revoke",
                "remote-revoke",
                cx,
                move |this, cx| {
                    let id = device.id.clone();
                    this.revoking = None;
                    this.update(cx, |server| server.revoke(&id));
                },
            ));
        }
        if self.confirming_reset {
            panel = panel.child(Self::confirmation(
                "Reset the remote certificate?".into(),
                "Coincide makes a new certificate and forgets every paired device. Each one has to pair again.",
                "Reset Certificate",
                "remote-reset",
                cx,
                |this, cx| {
                    this.confirming_reset = false;
                    let mut failure = None;
                    this.update(cx, |server| failure = server.reset_identity().err());
                    this.notice = failure.map(|error| error.to_string());
                },
            ));
        }
        if self.sheet_open && snapshot.enabled {
            panel = panel.child(
                div()
                    .flex()
                    .justify_center()
                    .py_3()
                    .child(self.sheet(&snapshot, cx)),
            );
        }
        if let Some(notice) = self.notice.clone().or(snapshot.storage_error.clone()) {
            panel = panel.child(Self::secondary(notice, cx));
        }
        panel.into_any_element()
    }
}
