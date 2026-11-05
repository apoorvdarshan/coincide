//! Native Edit selectors and coalesced app commands. Global handlers never
//! change an Engine, Store, draft, focus, window or retained shutdown driver.
use gpui_kit::{App, Global, KeyBinding, Menu, MenuItem, OsAction, actions, base::input};
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU8, Ordering},
};

actions!(
    coincide_app_menu,
    [
        Quit,
        RequestSettings,
        RequestNewConversation,
        RequestHide,
        RequestHideOthers,
        RequestShowAll
    ]
);
/// The parent supplies actual focus ownership. This module never guesses from
/// visibility or stale GPUI focus when a terminal/native responder owns input.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EditContext {
    #[default]
    Unverified,
    StandardResponder,
    Terminal,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MenuRequest {
    Settings,
    NewConversation,
    Hide,
    HideOthers,
    ShowAll,
}
impl MenuRequest {
    fn bit(self) -> u8 {
        match self {
            Self::Settings => 1,
            Self::NewConversation => 2,
            Self::Hide => 4,
            Self::HideOthers => 8,
            Self::ShowAll => 16,
        }
    }
}
#[derive(Clone, Default)]
struct Pending(Arc<AtomicU8>);
impl Pending {
    fn request(&self, request: MenuRequest) {
        self.0.fetch_or(request.bit(), Ordering::AcqRel);
    }
    fn take(&self) -> Vec<MenuRequest> {
        let bits = self.0.swap(0, Ordering::AcqRel);
        [
            MenuRequest::Settings,
            MenuRequest::NewConversation,
            MenuRequest::Hide,
            MenuRequest::HideOthers,
            MenuRequest::ShowAll,
        ]
        .into_iter()
        .filter(|request| bits & request.bit() != 0)
        .collect()
    }
}
struct MenuState {
    pending: Pending,
    context: EditContext,
}
impl Global for MenuState {}

fn menus(context: EditContext) -> Vec<Menu> {
    let mut app = vec![
        MenuItem::action("Settings…", RequestSettings),
        MenuItem::separator(),
    ];
    #[cfg(target_os = "macos")]
    app.extend([
        MenuItem::action("Hide Coincide Rust", RequestHide),
        MenuItem::action("Hide Others", RequestHideOthers),
        MenuItem::action("Show All", RequestShowAll),
        MenuItem::separator(),
    ]);
    app.push(MenuItem::action("Quit Coincide Rust", Quit));
    let disabled = context != EditContext::StandardResponder;
    vec![
        Menu::new("Coincide Rust").items(app),
        Menu::new("File").items([MenuItem::action("New Conversation", RequestNewConversation)]),
        Menu::new("Edit").items([
            MenuItem::os_action("Cut", input::Cut, OsAction::Cut).disabled(disabled),
            MenuItem::os_action("Copy", input::Copy, OsAction::Copy).disabled(disabled),
            MenuItem::os_action("Paste", input::Paste, OsAction::Paste).disabled(disabled),
            MenuItem::separator(),
            MenuItem::os_action("Select All", input::SelectAll, OsAction::SelectAll)
                .disabled(disabled),
        ]),
    ]
}
/// Coalesced Quit admission signal, unchanged. Non-edit menu requests are also
/// retained in App Global until the parent's ordinary tick consumes them.
pub fn install(cx: &mut App) -> Arc<AtomicBool> {
    let requested = Arc::new(AtomicBool::new(false));
    let signal = requested.clone();
    cx.on_action(move |_: &Quit, _| {
        signal.store(true, Ordering::Release);
    });
    let pending = Pending::default();
    let signal = pending.clone();
    cx.on_action(move |_: &RequestSettings, _| signal.request(MenuRequest::Settings));
    let signal = pending.clone();
    cx.on_action(move |_: &RequestNewConversation, _| signal.request(MenuRequest::NewConversation));
    let signal = pending.clone();
    cx.on_action(move |_: &RequestHide, _| signal.request(MenuRequest::Hide));
    let signal = pending.clone();
    cx.on_action(move |_: &RequestHideOthers, _| signal.request(MenuRequest::HideOthers));
    let signal = pending.clone();
    cx.on_action(move |_: &RequestShowAll, _| signal.request(MenuRequest::ShowAll));
    #[cfg(target_os = "macos")]
    cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
    #[cfg(not(target_os = "macos"))]
    cx.bind_keys([KeyBinding::new("ctrl-q", Quit, None)]);
    cx.set_global(MenuState {
        pending,
        context: EditContext::Unverified,
    });
    cx.set_menus(menus(EditContext::Unverified));
    requested
}
/// Parent calls outside any Engine guard; consumption itself has no effects.
/// Duplicate requests coalesce, and Quit remains its separate retained signal.
pub fn take_requests(cx: &mut App) -> Vec<MenuRequest> {
    if !cx.has_global::<MenuState>() {
        return Vec::new();
    }
    cx.global::<MenuState>().pending.take()
}
/// Rebuild only when the parent-provided focus policy changes. Terminal Edit
/// stays disabled until its own narrow action listeners are separately wired.
pub fn set_context(cx: &mut App, context: EditContext) {
    if !cx.has_global::<MenuState>() || cx.global::<MenuState>().context == context {
        return;
    }
    cx.global_mut::<MenuState>().context = context;
    cx.set_menus(menus(context));
}

#[cfg(test)]
mod tests {
    use super::*;
    #[::core::prelude::v1::test]
    fn native_selector_menu_uses_real_focused_input_actions_and_omits_unsafe_fallbacks() {
        let menu = menus(EditContext::StandardResponder);
        let edit = menu.iter().find(|m| m.name == "Edit").unwrap();
        let mut count = 0;
        for item in &edit.items {
            let MenuItem::Action {
                name,
                action,
                os_action,
                disabled,
                ..
            } = item
            else {
                continue;
            };
            assert!(!*disabled);
            match name.as_ref() {
                "Cut" => {
                    assert!(action.as_any().is::<input::Cut>());
                    assert!(matches!(os_action, Some(OsAction::Cut)));
                }
                "Copy" => {
                    assert!(action.as_any().is::<input::Copy>());
                    assert!(matches!(os_action, Some(OsAction::Copy)));
                }
                "Paste" => {
                    assert!(action.as_any().is::<input::Paste>());
                    assert!(matches!(os_action, Some(OsAction::Paste)));
                }
                "Select All" => {
                    assert!(action.as_any().is::<input::SelectAll>());
                    assert!(matches!(os_action, Some(OsAction::SelectAll)));
                }
                other => panic!("Unsupported Edit menu action: {other}"),
            }
            count += 1;
        }
        assert_eq!(count, 4);
    }
    #[::core::prelude::v1::test]
    fn unverified_or_terminal_focus_never_enables_stale_composer_edits() {
        for context in [EditContext::Unverified, EditContext::Terminal] {
            let menu = menus(context);
            let edit = menu.iter().find(|m| m.name == "Edit").unwrap();
            for item in &edit.items {
                if let MenuItem::Action { disabled, .. } = item {
                    assert!(*disabled);
                }
            }
        }
    }
    #[::core::prelude::v1::test]
    fn non_edit_requests_coalesce_and_drain_once() {
        let pending = Pending::default();
        let producer = pending.clone();
        producer.request(MenuRequest::Settings);
        producer.request(MenuRequest::Settings);
        producer.request(MenuRequest::NewConversation);
        assert_eq!(
            pending.take(),
            vec![MenuRequest::Settings, MenuRequest::NewConversation]
        );
        assert!(pending.take().is_empty());
        producer.request(MenuRequest::Hide);
        producer.request(MenuRequest::HideOthers);
        producer.request(MenuRequest::ShowAll);
        assert_eq!(
            pending.take(),
            vec![
                MenuRequest::Hide,
                MenuRequest::HideOthers,
                MenuRequest::ShowAll
            ]
        );
    }
}
