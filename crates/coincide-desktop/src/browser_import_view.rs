//! The import dialog owns presentation; existing workers verify and commit exports.
use super::*;
use gpui_kit::{
    App, ClickEvent, FocusHandle, FontWeight, KeyDownEvent, MouseButton, Role,
    component::ActiveTheme, px, rgba,
};

#[derive(Clone, Copy, Default, PartialEq, Eq)]
enum ImportKind {
    #[default]
    Bookmarks,
    History,
    Cookies,
}

pub(super) struct ImportDialog {
    open: bool,
    kind: ImportKind,
    focus: FocusHandle,
    restore: Option<FocusHandle>,
    #[cfg(target_os = "macos")]
    installed: Option<Vec<installed_import::Profile>>,
    #[cfg(target_os = "macos")]
    scanning: bool,
}
impl ImportDialog {
    pub fn new(cx: &mut Context<BrowserSettings>) -> Self {
        Self {
            open: false,
            kind: ImportKind::default(),
            focus: cx.focus_handle(),
            restore: None,
            #[cfg(target_os = "macos")]
            installed: None,
            #[cfg(target_os = "macos")]
            scanning: false,
        }
    }
    pub fn deactivate(&mut self) {
        self.open = false;
        self.restore = None;
    }
}

pub(super) fn page_controls(
    id: &'static str,
    page: usize,
    pages: usize,
    busy: bool,
    previous: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
    next: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> impl IntoElement {
    div()
        .id(id)
        .flex()
        .items_center()
        .gap_2()
        .child(
            Button::new("previous")
                .label("Previous")
                .small()
                .ghost()
                .disabled(busy || page == 0)
                .on_click(previous),
        )
        .child(div().text_xs().child(format!("{} of {pages}", page + 1)))
        .child(
            Button::new("next")
                .label("Next")
                .small()
                .ghost()
                .disabled(busy || page + 1 >= pages)
                .on_click(next),
        )
}

impl BrowserSettings {
    pub(in super::super) fn import_dialog_open(&self) -> bool {
        self.import_dialog.open
    }

    pub(in super::super) fn open_import_dialog(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.import_dialog.open = true;
        self.import_dialog.restore = window.focused(cx);
        self.import_dialog.focus.focus(window, cx);
        #[cfg(target_os = "macos")]
        self.scan_installed_browsers(cx);
        cx.notify();
    }

    pub(in super::super) fn close_import_dialog(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let restore = self.import_dialog.restore.take();
        self.import_dialog.deactivate();
        if let Some(restore) = restore {
            restore.focus(window, cx);
        }
        cx.notify();
    }

    pub(in super::super) fn render_import_dialog(&self, cx: &mut Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let foreground = theme.foreground;
        let muted = theme.muted_foreground;
        let border = theme.border;
        let background = theme.background;
        let selected = self.import_dialog.kind;
        let tabs = div().flex().items_center().gap_1().flex_wrap().children(
            [
                (ImportKind::Bookmarks, "Bookmarks"),
                (ImportKind::History, "History"),
                (ImportKind::Cookies, "Cookies"),
            ]
            .into_iter()
            .map(|(kind, label)| {
                div().debug_selector(move || label.to_owned()).child(
                    Button::new(label)
                        .label(label)
                        .small()
                        .when(kind != selected, |button| button.ghost())
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.import_dialog.kind = kind;
                            cx.notify();
                        })),
                )
            }),
        );
        let content = match selected {
            ImportKind::Bookmarks => self.bookmark_import_form(cx),
            ImportKind::History => self.render_history(cx),
            ImportKind::Cookies => self.cookie_import_panel(cx),
        };
        crate::chat_layout::modal_backdrop()
            .id("browser-import-overlay")
            .flex()
            .items_center()
            .justify_center()
            .p_4()
            .bg(rgba(0x00000066))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, window, cx| {
                    this.close_import_dialog(window, cx);
                    cx.stop_propagation();
                }),
            )
            .child(
                div()
                    .id("browser-import-dialog")
                    .debug_selector(|| "browser-import-dialog".into())
                    .role(Role::Dialog)
                    .aria_label("Import browser data")
                    .track_focus(&self.import_dialog.focus)
                    .tab_group()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                        if event.keystroke.key == "escape" {
                            this.close_import_dialog(window, cx);
                            cx.stop_propagation();
                        }
                    }))
                    .w_full()
                    .max_w(px(510.))
                    .max_h_full()
                    .min_h_0()
                    .overflow_hidden()
                    .rounded_lg()
                    .border_1()
                    .border_color(border)
                    .bg(background)
                    .text_color(foreground)
                    .flex()
                    .flex_col()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_3()
                            .p_4()
                            .flex_shrink_0()
                            .border_b_1()
                            .border_color(border)
                            .child(
                                div()
                                    .flex()
                                    .items_center()
                                    .gap_2()
                                    .child(
                                        div()
                                            .flex_1()
                                            .text_lg()
                                            .font_weight(FontWeight::SEMIBOLD)
                                            .child("Import browser data"),
                                    )
                                    .child(
                                        Button::new("close-browser-import")
                                            .icon(gpui_kit::assets::IconName::Close)
                                            .accessibility_label("Close import")
                                            .tooltip("Close import")
                                            .ghost()
                                            .small()
                                            .on_click(cx.listener(|this, _, window, cx| {
                                                this.close_import_dialog(window, cx);
                                            })),
                                    ),
                            )
                            .child(tabs),
                    )
                    .child(
                        div()
                            .id(("browser-import-body", selected as usize))
                            .min_h_0()
                            .max_h(px(390.))
                            .overflow_y_scroll()
                            .p_4()
                            .text_color(muted)
                            .child(content),
                    ),
            )
            .into_any_element()
    }

    #[cfg(target_os = "macos")]
    fn scan_installed_browsers(&mut self, cx: &mut Context<Self>) {
        if self.import_dialog.scanning {
            return;
        }
        self.import_dialog.scanning = true;
        cx.spawn(async move |this, cx| {
            let profiles = cx
                .background_executor()
                .spawn(async { installed_import::discover() })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.import_dialog.installed = Some(profiles);
                this.import_dialog.scanning = false;
                cx.notify();
            });
        })
        .detach();
    }

    #[cfg(target_os = "macos")]
    pub(super) fn installed_browser_profiles(
        &self,
        kind: installed_import::Kind,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let theme = cx.theme();
        let mut list = div().flex().flex_col().gap_1p5().child(
            div()
                .text_xs()
                .font_weight(FontWeight::SEMIBOLD)
                .child("Installed browsers"),
        );
        let Some(profiles) = self.import_dialog.installed.as_ref() else {
            return list
                .child(div().text_xs().child("Looking for browser profiles…"))
                .into_any_element();
        };
        let choices: Vec<_> = profiles
            .iter()
            .filter(|profile| profile.source_exists(kind))
            .collect();
        if choices.is_empty() {
            return list
                .child(div().text_xs().child("No readable browser profiles found."))
                .into_any_element();
        }
        for (index, profile) in choices.into_iter().enumerate() {
            let icon = browser_logos()
                .iter()
                .find(|(name, _)| *name == profile.browser)
                .map(|(_, logo)| logo.clone());
            let choice = profile.clone();
            let caption = format!("{} · {}", profile.browser, profile.label);
            list = list.child(
                Button::new(("installed-browser", index))
                    .small()
                    .ghost()
                    .w_full()
                    .accessibility_label(caption.clone())
                    .debug_selector(move || caption.clone())
                    .disabled(disabled)
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap_2()
                            .min_w_0()
                            .w_full()
                            .when_some(icon, |row, icon| {
                                row.child(gpui_kit::img(icon).size(px(17.)))
                            })
                            .child(
                                div()
                                    .text_color(theme.foreground)
                                    .flex_shrink_0()
                                    .child(profile.browser),
                            )
                            .child(div().text_xs().truncate().child(profile.label.clone()))
                            .child(div().flex_1())
                            .child(
                                gpui_kit::component::Icon::new(
                                    gpui_kit::assets::IconName::ChevronRight,
                                )
                                .size(px(14.)),
                            ),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| match kind {
                        installed_import::Kind::Bookmarks => {
                            this.preview_installed_bookmarks(choice.clone(), cx)
                        }
                        installed_import::Kind::History => {
                            this.preview_installed_history(choice.clone(), cx)
                        }
                    })),
            );
        }
        list.into_any_element()
    }

    fn bookmark_import_form(&self, cx: &mut Context<Self>) -> AnyElement {
        let busy = self.import_busy
            || self.profile_pending
            || self.history.busy()
            || self.workers.closed();
        let can_choose = self.engine.is_some() && self.snapshot.is_some();
        let form = div().flex().flex_col().gap_3();
        #[cfg(target_os = "macos")]
        let form = form.child(self.installed_browser_profiles(
            installed_import::Kind::Bookmarks,
            busy || !can_choose,
            cx,
        ));
        let mut form = form.child(
            div().flex().items_center().gap_2().flex_wrap().child(
                Button::new("browser-import-preview")
                    .label("Import from file…")
                    .small()
                    .disabled(busy || !can_choose)
                    .on_click(cx.listener(|this, _, _, cx| this.choose_import(cx))),
            ),
        );
        if !can_choose {
            form = form.child(
                div()
                    .text_xs()
                    .child("Open a conversation to import bookmarks."),
            );
        }
        if let Some(preview) = &self.preview {
            if preview.history != 0 {
                form = form.child(
                    div()
                        .text_xs()
                        .child("Use History to import the visits in this export."),
                );
            }
            if preview.profiles != 0 || preview.cookies_not_imported != 0 {
                let note = if preview.legacy_profile {
                    "The legacy profile and its sign-ins are skipped."
                } else {
                    "Profile and cookie records are skipped."
                };
                form = form.child(div().text_xs().child(note));
            }
            if let Some(problem) = &preview.bookmark_problem {
                form = form.child(problem.clone());
            } else if preview.bookmarks == 0 {
                form = form.child("The export contains no bookmarks.");
            }
        }
        if let Some(chosen) = &self.chosen {
            let count = chosen.plan.bookmarks.len();
            let pages = count.div_ceil(10).max(1);
            let page = self.preview_page.min(pages - 1);
            let mut review = div()
                .id("browser-bookmark-review")
                .flex()
                .flex_col()
                .gap_2();
            for bookmark in chosen.plan.bookmarks.iter().skip(page * 10).take(10) {
                review = review.child(
                    div()
                        .min_w_0()
                        .child(div().truncate().child(bookmark.title.clone()))
                        .child(div().text_xs().truncate().child(bookmark.url.clone())),
                );
            }
            form = form
                .child(format!(
                    "{count} bookmarks to import. Existing URLs are kept."
                ))
                .child(review);
            if pages > 1 {
                form = form.child(page_controls(
                    "bookmark-review-pages",
                    page,
                    pages,
                    busy,
                    cx.listener(|this, _, _, cx| {
                        this.preview_page = this.preview_page.saturating_sub(1);
                        cx.notify();
                    }),
                    cx.listener(|this, _, _, cx| {
                        this.preview_page += 1;
                        cx.notify();
                    }),
                ));
            }
            let action = if chosen.expected_revision.is_some() {
                Button::new("bookmark-import-save")
                    .primary()
                    .label(format!("Import {count} bookmarks"))
                    .disabled(busy || !can_choose || count == 0)
                    .on_click(cx.listener(|this, _, _, cx| this.save_bookmarks(cx)))
            } else {
                Button::new("bookmark-import-reload")
                    .label("Refresh saved bookmarks")
                    .disabled(busy || !can_choose)
                    .on_click(cx.listener(|this, _, _, cx| this.reload_bookmarks(cx)))
            };
            form = form.child(div().flex().justify_end().child(action.small()));
        }
        form.when(
            !self.status.is_empty() && self.status != "Bookmarks refreshed.",
            |form| form.child(div().text_xs().child(self.status.clone())),
        )
        .into_any_element()
    }
}

fn browser_logos() -> &'static [(&'static str, Arc<gpui_kit::Image>)] {
    // Browser Logos collection (alrra/browser-logos, 58881b84); Arc's site favicon.
    const LOGOS: [(&str, &[u8]); 8] = [
        ("Chrome", include_bytes!("../assets/browsers/chrome.png")),
        ("Safari", include_bytes!("../assets/browsers/safari.png")),
        ("Edge", include_bytes!("../assets/browsers/edge.png")),
        ("Brave", include_bytes!("../assets/browsers/brave.png")),
        ("Arc", include_bytes!("../assets/browsers/arc.png")),
        ("Vivaldi", include_bytes!("../assets/browsers/vivaldi.png")),
        ("Opera", include_bytes!("../assets/browsers/opera.png")),
        ("Firefox", include_bytes!("../assets/browsers/firefox.png")),
    ];
    static IMAGES: std::sync::OnceLock<[(&str, Arc<gpui_kit::Image>); 8]> =
        std::sync::OnceLock::new();
    IMAGES.get_or_init(|| {
        LOGOS.map(|(name, bytes)| {
            (
                name,
                Arc::new(gpui_kit::Image::from_bytes(
                    gpui_kit::ImageFormat::Png,
                    bytes.to_vec(),
                )),
            )
        })
    })
}

pub(super) fn browser_import_sources(cx: &App) -> impl IntoElement {
    let theme = cx.theme();
    div()
        .flex()
        .flex_wrap()
        .gap_1p5()
        .children(browser_logos().iter().map(|(name, image)| {
            div()
                .flex()
                .items_center()
                .gap_1p5()
                .px_2()
                .py_1()
                .rounded_md()
                .bg(theme.muted)
                .text_color(theme.foreground)
                .text_xs()
                .child(gpui_kit::img(image.clone()).size(px(15.)))
                .child(*name)
        }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui_kit::{AppContext, Modifiers, Render, TestAppContext, point};

    const CHILD: &str = "COINCIDE_HEADLESS_BROWSER_IMPORT_CHILD";

    struct Harness {
        panel: gpui_kit::Entity<BrowserSettings>,
        trigger: FocusHandle,
        behind_clicks: usize,
    }

    impl Render for Harness {
        fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
            div()
                .relative()
                .size_full()
                .child(
                    div()
                        .id("browser-settings-background")
                        .debug_selector(|| "browser-settings-background".into())
                        .size_full()
                        .child(
                            div()
                                .id("browser-import-trigger")
                                .track_focus(&self.trigger)
                                .w(px(100.))
                                .h(px(40.))
                                .on_click(cx.listener(|this, _, window, cx| {
                                    this.behind_clicks += 1;
                                    this.trigger.focus(window, cx);
                                    this.panel.update(cx, |panel, cx| {
                                        panel.open_import_dialog(window, cx)
                                    });
                                    cx.notify();
                                })),
                        ),
                )
                .when(self.panel.read(cx).import_dialog_open(), |view| {
                    view.child(
                        self.panel
                            .update(cx, |panel, cx| panel.render_import_dialog(cx)),
                    )
                })
        }
    }

    #[gpui_kit::test]
    #[ignore = "private-child wrapper only"]
    fn headless_browser_import_keeps_context_and_restores_focus(cx: &mut TestAppContext) {
        assert_eq!(std::env::var(CHILD).as_deref(), Ok("1"));
        cx.update(gpui_kit::init);
        let (root, vcx) = cx.add_window_view(|window, cx| {
            let panel = cx.new(|cx| BrowserSettings::new(window, cx).0);
            cx.observe(&panel, |_, _, cx| cx.notify()).detach();
            Harness {
                panel,
                trigger: cx.focus_handle(),
                behind_clicks: 0,
            }
        });
        let draw = |window: &mut Window, cx: &mut App| {
            window.refresh();
            window.draw(cx).clear(cx);
        };
        vcx.update(|window, cx| {
            window.activate_window();
            draw(window, cx);
        });
        let trigger = point(px(12.), px(12.));
        vcx.simulate_click(trigger, Modifiers::default());
        vcx.update(draw);
        assert!(vcx.debug_bounds("browser-settings-background").is_some());
        assert!(vcx.debug_bounds("browser-import-dialog").is_some());
        #[cfg(target_os = "macos")]
        {
            vcx.run_until_parked();
            vcx.update(draw);
            assert!(vcx.debug_bounds("Chrome · Default").is_some());
            let history = vcx.debug_bounds("History").expect("History tab");
            vcx.simulate_click(history.center(), Modifiers::default());
            vcx.update(draw);
            assert!(vcx.debug_bounds("Chrome · Default").is_none());
        }

        let cookies = vcx.debug_bounds("Cookies").expect("Cookies tab");
        vcx.simulate_click(cookies.center(), Modifiers::default());
        vcx.update(draw);
        assert!(
            root.read_with(vcx, |root, cx| root.panel.read(cx).import_dialog.kind
                == ImportKind::Cookies)
        );

        vcx.simulate_keystrokes("escape");
        vcx.update(draw);
        assert!(vcx.debug_bounds("browser-import-dialog").is_none());
        assert!(vcx.update(|window, cx| root.read(cx).trigger.is_focused(window)));

        vcx.simulate_click(trigger, Modifiers::default());
        vcx.update(draw);
        vcx.simulate_click(trigger, Modifiers::default());
        vcx.update(draw);
        assert!(vcx.debug_bounds("browser-import-dialog").is_none());
        assert_eq!(root.read_with(vcx, |root, _| root.behind_clicks), 2);
    }

    #[::core::prelude::v1::test]
    fn browser_import_dialog_headless() {
        if !cfg!(debug_assertions) {
            return;
        }
        let root =
            std::env::temp_dir().join(format!("coincide-browser-dialog-{}", uuid::Uuid::new_v4()));
        coincide_core::native_file::private_directory(&root).unwrap();
        #[cfg(target_os = "macos")]
        {
            let profile = root.join("Library/Application Support/Google/Chrome/Default");
            std::fs::create_dir_all(root.join("Applications/Google Chrome.app")).unwrap();
            std::fs::create_dir_all(&profile).unwrap();
            std::fs::write(profile.join("Bookmarks"), b"{}").unwrap();
        }
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--ignored",
                "headless_browser_import_keeps_context_and_restores_focus",
                "--nocapture",
            ])
            .env_clear()
            .env(CHILD, "1")
            .env("HOME", &root)
            .env("TMPDIR", &root)
            .current_dir(&root)
            .output()
            .unwrap();
        std::fs::remove_dir_all(&root).unwrap();
        assert!(
            output.status.success() && String::from_utf8_lossy(&output.stdout).contains("1 passed"),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
    }
}
