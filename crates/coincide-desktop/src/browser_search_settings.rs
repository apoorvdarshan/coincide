//! Settings › Browser › Search engine, as Swift's picker: what the address bar
//! searches with when the user types words instead of an address.
use super::*;
use crate::native_menu::AccessibleMenuExt as _;
use coincide_core::browser_address::SearchEngine;
use gpui_kit::component::menu::PopupMenuItem;

pub(super) const SEARCH_ENGINE_HELP: &str = "What the address bar searches with when you type words instead of an address. Addresses such as localhost:3000, IP addresses and file paths always open directly.";

impl BrowserSettings {
    /// The saved engine, read once the trusted engine is free.
    fn current_search_engine(&mut self) -> Option<SearchEngine> {
        if self.search_engine.is_none()
            && let Some(engine) = &self.engine
            && let Ok(engine) = engine.try_lock()
        {
            self.search_engine = Some(engine.browser_search_engine());
        }
        self.search_engine
    }

    fn choose_search_engine(&mut self, choice: SearchEngine, cx: &mut Context<Self>) {
        let Some(engine) = &self.engine else {
            return;
        };
        let saved = match engine.try_lock() {
            Ok(mut engine) => engine.set_browser_search_engine(choice),
            Err(_) => Err(anyhow::anyhow!("The app is busy")),
        };
        match saved {
            Ok(()) => self.search_engine = Some(choice),
            Err(error) => {
                self.status = format!("The search engine was not changed: {error}. Try again.")
            }
        }
        cx.notify();
    }

    pub(super) fn search_engine_row(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let current = self.current_search_engine();
        let parent = cx.entity().downgrade();
        let label = current.map_or("Loading…", SearchEngine::name);
        div()
            .flex()
            .items_center()
            .justify_between()
            .gap_3()
            .child(
                div().flex_1().child("Search engine").child(
                    div()
                        .text_xs()
                        .child("Used for searches typed in the address bar."),
                ),
            )
            .child(
                Button::new("browser-search-engine")
                    .label(label)
                    .small()
                    .dropdown_caret(true)
                    .disabled(current.is_none() || self.workers.closed())
                    .accessible_menu(move |mut menu, _, _| {
                        for engine in SearchEngine::ALL {
                            let parent = parent.clone();
                            menu = menu.item(
                                PopupMenuItem::new(engine.name())
                                    .checked(current == Some(engine))
                                    .on_click(move |_, _, cx| {
                                        let _ = parent.update(cx, |this, cx| {
                                            this.choose_search_engine(engine, cx)
                                        });
                                    }),
                            );
                        }
                        menu
                    }),
            )
            .into_any_element()
    }
}
