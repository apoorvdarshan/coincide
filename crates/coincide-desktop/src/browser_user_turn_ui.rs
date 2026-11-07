//! The agent's "Your turn" banner above the page, and the page area itself,
//! which keeps an agent's fixed testing viewport inside the panel.
use super::*;

/// How much a fixed viewport must shrink to fit the page area. Native views
/// cannot be clipped inside a scrolling canvas without window composition, so
/// a larger viewport is shown scaled with the engine's page zoom: the page
/// still lays out at the requested CSS size.
fn viewport_scale(requested: (u32, u32), area: Option<Bounds<Pixels>>) -> f32 {
    let Some(area) = area else {
        return 1.;
    };
    let width = f32::from(area.size.width) / requested.0 as f32;
    let height = f32::from(area.size.height) / requested.1 as f32;
    width.min(height).clamp(0.1, 1.)
}

impl Coincide {
    pub(super) fn browser_user_turn_banner(
        &mut self,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let thread = self.selected.as_ref().map(|thread| text(thread, "id"))?;
        let message = self.browser.as_ref()?.user_turn(&thread)?.to_owned();
        let done_thread = thread.clone();
        Some(
            div()
                .id("browser-user-turn")
                .flex()
                .flex_col()
                .flex_shrink_0()
                .gap_1()
                .mx_2()
                .mb_2()
                .p_3()
                .rounded_md()
                .border_1()
                .border_color(self.color(0x29303d))
                .bg(self.color(0x181d28))
                .child(
                    div()
                        .text_xs()
                        .font_weight(FontWeight::SEMIBOLD)
                        .child("Your turn"),
                )
                .child(
                    div()
                        .id("browser-user-turn-message")
                        .text_sm()
                        .max_h(px(110.))
                        .overflow_y_scroll()
                        .child(message),
                )
                .child(
                    div()
                        .flex()
                        .justify_end()
                        .gap_2()
                        .pt_1()
                        .child(
                            Button::new("browser-user-turn-decline")
                                .label("Not Now")
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(browser) = &mut this.browser {
                                        browser.answer_user_turn(&thread, false);
                                    }
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("browser-user-turn-done")
                                .label("Done")
                                .primary()
                                .on_click(cx.listener(move |this, _, _, cx| {
                                    if let Some(browser) = &mut this.browser {
                                        browser.answer_user_turn(&done_thread, true);
                                    }
                                    cx.notify();
                                })),
                        ),
                )
                .into_any_element(),
        )
    }

    /// The page: filling the panel, or at an agent's fixed testing size from
    /// the top-left corner, as Swift's `PreviewPageContainer`.
    pub(super) fn browser_page(
        &self,
        thread: &str,
        webview: Option<Entity<gpui_webview::WebView>>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let viewport = self
            .browser
            .as_ref()
            .and_then(|browser| browser.active_viewport(thread));
        let area = self.browser_page_bounds.clone();
        let measured = area.get();
        let scale = viewport.map_or(1., |size| viewport_scale(size, measured));
        let zoom = f64::from(scale);
        // WebKitGTK does not apply a page zoom, so a fixed viewport is laid out
        // at its exact size and clipped by the panel instead of scaled.
        #[cfg(target_os = "linux")]
        let (zoom, dimensions) = (
            1.0,
            viewport.map(|(width, height)| (width as f32, height as f32)),
        );
        #[cfg(not(target_os = "linux"))]
        let dimensions =
            viewport.map(|(width, height)| (width as f32 * scale, height as f32 * scale));
        #[cfg(target_os = "windows")]
        let (zoom, dimensions) = {
            let (mut zoom, mut dimensions) = (zoom, dimensions);
            if let (Some(size), Some(area), Some(view)) = (viewport, measured, webview.as_ref()) {
                use windows::Win32::{Foundation::HWND, UI::HiDpi::GetDpiForWindow};
                use wry::WebViewExtWindows;
                let mut parent = HWND::default();
                if unsafe { view.read(cx).raw().controller().ParentWindow(&mut parent) }.is_ok() {
                    let dpi = unsafe { GetDpiForWindow(parent) };
                    if dpi > 0 {
                        let fit = (f64::from(f32::from(area.size.width)) / f64::from(size.0))
                            .min(f64::from(f32::from(area.size.height)) / f64::from(size.1))
                            .clamp(0.1, 1.);
                        if let Some(layout) = crate::browser_viewport_geometry::aligned(
                            size,
                            fit,
                            f64::from(dpi) / 96.,
                        ) {
                            zoom = layout.zoom;
                            dimensions = Some((layout.width, layout.height));
                        }
                    }
                }
            }
            (zoom, dimensions)
        };
        if let Some(view) = &webview {
            if (view.read(cx).zoom() - zoom).abs()
                > if cfg!(target_os = "windows") {
                    1e-9
                } else {
                    0.001
                }
            {
                let _ = view.read(cx).set_zoom(zoom);
            }
        }
        let page = div().flex_1().min_h_0().relative().child(
            canvas(
                move |bounds, window, _| {
                    // A new size lays the fixed viewport out again.
                    if area.replace(Some(bounds)) != Some(bounds) {
                        window.refresh();
                    }
                },
                |_, _, _, _| {},
            )
            .absolute()
            .size_full(),
        );
        match (webview, dimensions) {
            (Some(view), Some((width, height))) => page.child(
                div()
                    .absolute()
                    .top_0()
                    .left_0()
                    .w(px(width))
                    .h(px(height))
                    .child(view),
            ),
            (Some(view), None) => page.child(div().absolute().size_full().child(view)),
            (None, _) => page,
        }
        .into_any_element()
    }
}

#[cfg(test)]
mod viewport_tests {
    use super::*;

    #[::core::prelude::v1::test]
    fn fixed_viewports_fit_the_panel_and_never_grow() {
        let area = |w: f32, h: f32| Some(Bounds::new(point(px(0.), px(0.)), size(px(w), px(h))));
        assert_eq!(viewport_scale((390, 844), area(800., 900.)), 1.);
        assert_eq!(viewport_scale((1280, 860), area(640., 900.)), 0.5);
        assert_eq!(viewport_scale((390, 844), area(800., 422.)), 0.5);
        assert_eq!(viewport_scale((390, 844), None), 1.);
        assert_eq!(viewport_scale((2560, 2560), area(10., 10.)), 0.1);
    }
}
