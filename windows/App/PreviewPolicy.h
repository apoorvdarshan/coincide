#pragma once
#include <stdexcept>
#include <string>
#include <string_view>

namespace coincide {
inline std::string preview_attribute(std::string_view value) {
    std::string result; result.reserve(value.size());
    for (const auto ch : value) switch (ch) {
        case '&': result += "&amp;"; break;
        case '"': result += "&quot;"; break;
        case '<': result += "&lt;"; break;
        case '>': result += "&gt;"; break;
        default: result += ch; break;
    }
    return result;
}
inline std::string preview_document(std::string_view source, bool svg = false) {
    if (source.size() > 2 * 1024 * 1024 || source.find('\0') != std::string_view::npos)
        throw std::invalid_argument("Preview content is too large or contains a NUL byte");
    // The first policy cannot be relaxed by a later policy in generated content. No origin is
    // granted to the inner document: scripts can draw/interact, but cannot access a parent app.
    const std::string policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'\">";
    std::string inner = "<!doctype html><meta charset=\"utf-8\">" + policy;
    if (svg) inner += "<style>html,body{margin:0;width:100%;height:100%}svg{max-width:100%;max-height:100%}</style>";
    inner.append(source);
    auto document = "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src about:; child-src about:; img-src data: blob:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'\"><meta name=\"referrer\" content=\"no-referrer\"><title>Coincide Preview</title><style>html,body{margin:0;width:100%;height:100%;overflow:hidden}iframe{width:100%;height:100%;border:0}</style><iframe id=\"coincide-preview-content\" sandbox=\"allow-scripts\" referrerpolicy=\"no-referrer\" allow=\"\" srcdoc=\"" + preview_attribute(inner) + "\"></iframe>";
    // NavigateToString's limit applies after attribute escaping too.
    if (document.size() > 2 * 1024 * 1024) throw std::invalid_argument("Preview content exceeds the inline browser limit after escaping");
    return document;
}
inline bool preview_inline_navigation(std::string_view uri, bool top_level) {
    if (top_level) return uri.empty() || uri == "about:blank" || uri.starts_with("data:text/html");
    return uri == "about:srcdoc";
}
} // namespace coincide
