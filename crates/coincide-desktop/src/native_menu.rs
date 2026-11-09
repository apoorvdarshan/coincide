//! Accessible activation for the shared dropdown component. The component opens
//! on mouse-down; a button without an on-click callback otherwise has no AXPress.
use gpui_kit::{
    Anchor, App, AppContext, ClickEvent, Context, ElementId, FocusHandle, InteractiveElement,
    IntoElement, RenderOnce, SharedString, Window,
    component::{
        button::Button,
        menu::{DropdownMenu, PopupMenu},
    },
};
use std::rc::Rc;

type Builder = Rc<dyn Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu>;

pub(crate) trait AccessibleMenuExt {
    fn accessible_menu(
        self,
        builder: impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static,
    ) -> AccessibleMenu;
    fn accessible_menu_with_anchor(
        self,
        anchor: Anchor,
        builder: impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static,
    ) -> AccessibleMenu;
}
impl AccessibleMenuExt for Button {
    fn accessible_menu(
        self,
        builder: impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static,
    ) -> AccessibleMenu {
        self.accessible_menu_with_anchor(Anchor::TopLeft, builder)
    }
    fn accessible_menu_with_anchor(
        mut self,
        anchor: Anchor,
        builder: impl Fn(PopupMenu, &mut Window, &mut Context<PopupMenu>) -> PopupMenu + 'static,
    ) -> AccessibleMenu {
        let id = self
            .interactivity()
            .element_id
            .clone()
            .expect("menu buttons have a stable id");
        AccessibleMenu {
            id,
            button: self,
            anchor,
            builder: Rc::new(builder),
        }
    }
}
#[derive(IntoElement)]
pub(crate) struct AccessibleMenu {
    id: ElementId,
    button: Button,
    anchor: Anchor,
    builder: Builder,
}
impl RenderOnce for AccessibleMenu {
    fn render(self, window: &mut Window, cx: &mut App) -> impl IntoElement {
        let focus = window.use_keyed_state(
            SharedString::from(format!("native-menu-focus:{:?}", self.id)),
            cx,
            |_, cx| cx.focus_handle().tab_index(0),
        );
        let handle: FocusHandle = focus.read(cx).clone();
        let click_focus = handle.clone();
        let button = self
            .button
            .track_focus(&handle)
            .on_click(move |event, window, cx| {
                // Mouse-down already toggled the menu. AXPress generates a keyboard
                // click; focus this trigger before dispatching its ancestor action.
                if matches!(event, ClickEvent::Keyboard(_)) {
                    click_focus.focus(window, cx);
                    window.dispatch_action(
                        Box::new(gpui_kit::base::actions::Confirm { secondary: false }),
                        cx,
                    );
                }
            });
        let builder = self.builder;
        button.dropdown_menu_with_anchor(self.anchor, move |menu, window, cx| {
            builder(menu, window, cx)
        })
    }
}
