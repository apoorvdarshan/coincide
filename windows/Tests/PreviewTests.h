#pragma once
#include "../App/PreviewPolicy.h"
#include <filesystem>
#include <fstream>

namespace coincide {
inline int preview_tests(const std::filesystem::path& report) {
    int checks{};
    const auto check = [&](bool passed, const char* message) {++checks; if (!passed) throw std::runtime_error(message);};
    try {
        const auto document = preview_document("<h1>Offline</h1><script>document.body.dataset.test='ok'</script>");
        check(document.find("sandbox=\"allow-scripts\"") != std::string::npos, "inline interaction needs an opaque sandboxed document");
        check(document.find("allow-same-origin") == std::string::npos, "generated content must not acquire the parent's origin");
        check(document.find("connect-src 'none'") != std::string::npos, "preview CSP must prohibit outgoing connections");
        check(document.find("worker-src 'none'") != std::string::npos, "preview CSP must prohibit worker contexts");
        check(document.find("&lt;script&gt;") != std::string::npos, "generated scripts belong inside escaped srcdoc only");
        const auto escaped = preview_document("\"></iframe><script>parent.escape=true</script>");
        check(escaped.find("&quot;&gt;&lt;/iframe&gt;") != std::string::npos, "generated markup must not escape the srcdoc attribute");
        check(escaped.find("</iframe>") == escaped.rfind("</iframe>"), "untrusted HTML must not add an outer iframe terminator");
        check(preview_document("<svg viewBox='0 0 10 10'></svg>", true).find("svg{max-width:100%") != std::string::npos, "inline SVG must fit its preview");
        check(!preview_inline_navigation("https://example.invalid", true) && !preview_inline_navigation("file:///C:/Windows/win.ini", true), "preview top-level navigation must reject network and files");
        check(preview_inline_navigation("about:srcdoc", false) && !preview_inline_navigation("about:blank", false), "only the sandboxed inline frame can navigate");
        bool rejected{}; try {preview_document(std::string("a\0b", 3));} catch (const std::invalid_argument&) {rejected = true;} check(rejected, "embedded NUL content must be rejected");
        rejected = false; try {preview_document(std::string(2 * 1024 * 1024 + 1, 'x'));} catch (const std::invalid_argument&) {rejected = true;} check(rejected, "oversized preview content must be bounded");
        rejected = false; try {preview_document(std::string(600000, '"'));} catch (const std::invalid_argument&) {rejected = true;} check(rejected, "inline browser limits apply after srcdoc attribute escaping");
        std::ofstream output(report); output << "PASS: " << checks << " Windows preview policy checks\n"; return output ? 0 : 2;
    } catch (const std::exception& error) {std::ofstream(report) << "FAIL: " << error.what() << '\n'; return 1;}
}
} // namespace coincide
