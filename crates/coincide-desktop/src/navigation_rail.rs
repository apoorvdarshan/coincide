//! Persistent navigation beside the independently collapsible conversation list.
//! Matches the Swift rail order; each destination invokes its existing controller.
use super::*;
use gpui_kit::assets::IconName;
use gpui_kit::component::menu::{ContextMenuExt, PopupMenuItem};

impl Coincide {
    pub(super) fn navigation_rail(&self, window: &Window, cx: &mut Context<Self>) -> AnyElement {
        let button = |id: &'static str, icon: IconName, label: &'static str| {
            Button::new(id)
                .icon(icon)
                .accessibility_label(label)
                .tooltip(label)
                .ghost()
                .compact()
                .w(px(38.))
                .h(px(38.))
                .flex_shrink_0()
                .rounded(px(10.))
        };
        div()
            .id("navigation-rail")
            .track_focus(&self.navigation_focus)
            .flex()
            .flex_col()
            .items_center()
            .w(px(60.))
            .flex_shrink_0()
            .h_full()
            .pt(px(6.))
            .pb(px(12.))
            .gap(px(6.))
            .bg(self.color(0x151922))
            .border_r_1()
            .border_color(self.color(0x29303d))
            .child(
                button("navigation-threads", IconName::PanelLeft, "Threads")
                    .tooltip(if self.thread_list_open {
                        "Hide conversations"
                    } else {
                        "Show conversations"
                    })
                    .selected(self.thread_list_open)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.toggle_sidebar(window, cx);
                    })),
            )
            .child(
                button("new", IconName::SquarePen, "New Thread")
                    .on_click(cx.listener(|this, _, window, cx| this.new_thread(window, cx))),
            )
            .child(
                button("navigation-search", IconName::Search, "Search")
                    .selected(self.command_palette.read(cx).is_open())
                    .on_click(cx.listener(|this, _, window, cx| this.toggle_palette(window, cx))),
            )
            .child(div().w(px(24.)).h(px(1.)).my_1().bg(self.color(0x29303d)))
            .child(
                button("navigation-terminal", IconName::SquareTerminal, "Terminal")
                    .selected(self.terminal_visible_thread.is_some())
                    .disabled(self.selected.is_none())
                    .on_click(cx.listener(|this, _, window, cx| this.terminal(window, cx))),
            )
            .child({
                let preferred =
                    open_targets::preferred(&self.open_targets, &self.settings).cloned();
                let targets = self.open_targets.clone();
                let parent = cx.entity().downgrade();
                let label = preferred
                    .as_ref()
                    .map(|target| format!("Open in {}", target.name))
                    .unwrap_or_else(|| "Open In".into());
                let parent_click = parent.clone();
                // The wrapper owns right-click even while the primary action
                // is disabled, so a default may be chosen before a folder exists.
                div()
                    .id("navigation-open-in-menu")
                    .child(
                        button(
                            "navigation-open-in",
                            IconName::SquareArrowOutUpRight,
                            "Open In",
                        )
                        .tooltip(label)
                        .disabled(self.open_folder().is_none() || preferred.is_none())
                        .on_click(move |_, window, cx| {
                            if let Some(target) = preferred.clone() {
                                let _ = parent_click.update(cx, |this, cx| {
                                    this.open_in_target(target, false, window, cx)
                                });
                            }
                        }),
                    )
                    .context_menu(move |mut menu, _, _| {
                        for target in &targets {
                            let parent = parent.clone();
                            let target = target.clone();
                            menu = menu.item(PopupMenuItem::new(target.name).on_click(
                                move |_, window, cx| {
                                    let _ = parent.update(cx, |this, cx| {
                                        this.open_in_target(target.clone(), true, window, cx)
                                    });
                                },
                            ));
                        }
                        menu
                    })
            })
            .child(div().flex_1())
            // The same links as Settings > About; never fetched during render.
            // Keep essential destinations reachable in short windows: Swift
            // hides Ko-fi, Product Hunt, GitHub, then Discord in that order.
            .children(
                community_links(f32::from(window.viewport_size().height))
                    .into_iter()
                    .map(|link| {
                        button(link.id, link.icon, link.label)
                            .on_click(cx.listener(move |_, _, _, cx| cx.open_url(link.url)))
                    }),
            )
            .child(
                button("navigation-usage", IconName::ChartNoAxesColumn, "Usage")
                    .selected(
                        self.settings_open
                            && self.settings_section == settings::SettingsSection::Usage,
                    )
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.open_settings_panel(window, cx);
                        this.settings_search
                            .update(cx, |input, cx| input.set_value("", window, cx));
                        this.settings_section = settings::SettingsSection::Usage;
                        this.sync_transcription_binding(cx);
                        cx.notify();
                    })),
            )
            .child(
                button(
                    "navigation-instructions",
                    IconName::BookOpen,
                    "Instructions",
                )
                .selected(
                    self.settings_open
                        && self.settings_section == settings::SettingsSection::Instructions,
                )
                .on_click(cx.listener(|this, _, window, cx| {
                    this.open_settings_panel(window, cx);
                    this.settings_search
                        .update(cx, |input, cx| input.set_value("", window, cx));
                    this.settings_section = settings::SettingsSection::Instructions;
                    this.sync_transcription_binding(cx);
                    cx.notify();
                })),
            )
            .child(
                button("navigation-providers", IconName::Cpu, "Agents")
                    .selected(
                        self.settings_open
                            && self.settings_section == settings::SettingsSection::Accounts,
                    )
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.open_settings_panel(window, cx);
                        this.settings_search
                            .update(cx, |input, cx| input.set_value("", window, cx));
                        this.settings_section = settings::SettingsSection::Accounts;
                        this.sync_transcription_binding(cx);
                        cx.notify();
                    })),
            )
            .child(
                button("settings", IconName::Settings, "Settings")
                    .selected(self.settings_open)
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.open_settings_panel(window, cx);
                        this.sync_transcription_binding(cx);
                        cx.notify();
                    })),
            )
            .into_any_element()
    }
}

#[derive(Clone, Copy)]
struct CommunityLink {
    id: &'static str,
    icon: IconName,
    label: &'static str,
    url: &'static str,
    priority: usize,
}
fn community_links(height: f32) -> Vec<CommunityLink> {
    // 3 top + 2 panel + 4 essential bottom squares, 6px spacing,
    // divider/margins and the minimum 12px between panel and bottom groups.
    let slots = ((height - 444.).max(0.) / 44.).floor() as usize;
    [
        CommunityLink {
            id: "navigation-github",
            icon: IconName::Star,
            label: "Star on GitHub",
            url: "https://github.com/apoorvdarshan/coincide",
            priority: 1,
        },
        CommunityLink {
            id: "navigation-product-hunt",
            icon: IconName::CircleArrowUp,
            label: "Upvote on Product Hunt",
            url: "https://www.producthunt.com/products/coincide",
            priority: 2,
        },
        CommunityLink {
            id: "navigation-discord",
            icon: IconName::MessagesSquare,
            label: "Join the Discord",
            url: "https://discord.gg/DETrbhDVqw",
            priority: 0,
        },
        CommunityLink {
            id: "navigation-support",
            icon: IconName::Heart,
            label: "Support on Ko-fi",
            url: "https://ko-fi.com/apoorvdarshan",
            priority: 3,
        },
    ]
    .into_iter()
    .filter(|link| link.priority < slots)
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn short_rail_preserves_community_priority_without_reordering_survivors() {
        let labels = |height| {
            community_links(height)
                .iter()
                .map(|link| link.id)
                .collect::<Vec<_>>()
        };
        assert!(labels(440.).is_empty());
        assert_eq!(labels(488.), ["navigation-discord"]);
        assert_eq!(labels(532.), ["navigation-github", "navigation-discord"]);
        assert_eq!(
            labels(576.),
            [
                "navigation-github",
                "navigation-product-hunt",
                "navigation-discord"
            ]
        );
        assert_eq!(
            labels(620.),
            [
                "navigation-github",
                "navigation-product-hunt",
                "navigation-discord",
                "navigation-support"
            ]
        );
    }
}
