//! The same product/help destinations as Swift's CoincideLinks. Links are only
//! opened by a native user click; rendering About performs no network requests.
use super::*;

fn version_report() -> String {
    format!(
        "Coincide {} · Rust desktop · {} {}",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH
    )
}
fn icon() -> Arc<Image> {
    static ICON: std::sync::OnceLock<Arc<Image>> = std::sync::OnceLock::new();
    ICON.get_or_init(|| {
        Arc::new(Image::from_bytes(
            ImageFormat::Png,
            include_bytes!("../assets/app-icon.png").to_vec(),
        ))
    })
    .clone()
}
impl Coincide {
    pub(super) fn about_settings(&self, cx: &mut Context<Self>) -> AnyElement {
        let report = version_report();
        let mut content = div().flex().flex_col().gap_3()
            .child(div().flex().flex_col().items_center().gap_2().p_4()
                .child(img(icon()).w(px(112.)).h(px(112.)))
                .child(div().text_xl().font_weight(FontWeight::SEMIBOLD).child("Coincide"))
                .child(report.clone())
                .child("One window for the coding agents you already use. Switch agents mid-thread while each keeps its own session.")
                .child(Button::new("about-copy-version").label("Copy Version Info").on_click(cx.listener(move |_,_,_,cx| {
                    cx.write_to_clipboard(ClipboardItem::new_string(report.clone()));
                }))))
            .child(self.updater_settings.clone())
            .child(div().text_lg().child("Help & Community"));
        for (id, label, detail, url) in [
            (
                "website",
                "Website and documentation",
                "coincide.dev",
                "https://coincide.dev",
            ),
            (
                "help",
                "Get Help",
                "Ask in the Discord help channel",
                "https://discord.com/channels/1566352780862427258/1566353949336797275",
            ),
            (
                "bug",
                "Report an Issue on GitHub",
                "Public bug report",
                "https://github.com/apoorvdarshan/coincide/issues/new?template=bug_report.yml",
            ),
            (
                "feature",
                "Request a Feature on GitHub",
                "Public feature request",
                "https://github.com/apoorvdarshan/coincide/issues/new?template=feature_request.yml",
            ),
            (
                "discord",
                "Join the Discord",
                "Reports can be submitted without a GitHub account",
                "https://discord.gg/DETrbhDVqw",
            ),
            (
                "github",
                "Star on GitHub",
                "Open source under the MIT License",
                "https://github.com/apoorvdarshan/coincide",
            ),
            (
                "releases",
                "Release notes and downloads",
                "Published Coincide releases",
                "https://github.com/apoorvdarshan/coincide/releases",
            ),
            (
                "product-hunt",
                "Upvote on Product Hunt",
                "producthunt.com/products/coincide",
                "https://www.producthunt.com/products/coincide",
            ),
            (
                "support",
                "Support on Ko-fi",
                "Buy Apoorv a coffee",
                "https://ko-fi.com/apoorvdarshan",
            ),
            ("x", "X", "@apoorvdarshan", "https://x.com/apoorvdarshan"),
            (
                "instagram",
                "Instagram",
                "@apoorvcodes",
                "https://instagram.com/apoorvcodes",
            ),
            (
                "linkedin",
                "LinkedIn",
                "Coincide",
                "https://www.linkedin.com/showcase/coincide-dev",
            ),
            (
                "contact",
                "Contact",
                "apoorv@fud-ai.app",
                "mailto:apoorv@fud-ai.app",
            ),
            (
                "privacy",
                "Privacy Policy",
                "coincide.dev/privacy",
                "https://coincide.dev/privacy",
            ),
            (
                "terms",
                "Terms of Service",
                "coincide.dev/terms",
                "https://coincide.dev/terms",
            ),
        ] {
            content = content.child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .gap_2()
                    .p_2()
                    .border_b_1()
                    .border_color(self.color(0x29303d))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .child(label)
                            .child(div().text_xs().child(detail)),
                    )
                    .child(
                        Button::new(SharedString::from(format!("about-link-{id}")))
                            .icon(gpui_kit::assets::IconName::ExternalLink)
                            .accessibility_label(label)
                            .ghost()
                            .on_click(cx.listener(move |_, _, _, cx| cx.open_url(url))),
                    ),
            );
        }
        content.child(div().mt_3().text_lg().child("Acknowledgements"))
            .child("Coincide ports the design and behavior of T3 Code by T3 Tools Inc., used under the MIT License. The Rust desktop interface uses GPUI Kit, GPUI and GPUI WebView under Apache-2.0.")
            .child(Button::new("about-license").label("License and third-party notices").on_click(cx.listener(|_,_,_,cx|cx.open_url("https://github.com/apoorvdarshan/coincide/blob/main/THIRD_PARTY_NOTICES.md"))))
            .child(div().text_xs().child("Copyright © 2026 Apoorv Darshan"))
            .into_any_element()
    }
}
