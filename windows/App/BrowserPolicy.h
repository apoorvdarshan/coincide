#pragma once
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <algorithm>
#include <string>
#include <string_view>
#include <stdexcept>

namespace coincide {
inline winrt::hstring browser_origin(const winrt::Windows::Foundation::Uri& uri) {
    auto host = std::wstring(uri.Host());
    if (host.find(L':') != std::wstring::npos && !host.starts_with(L"[")) host = L"[" + host + L"]";
    auto value = std::wstring(uri.SchemeName()) + L"://" + host;
    const auto port = uri.Port();
    if (port > 0 && !(uri.SchemeName() == L"http" && port == 80) && !(uri.SchemeName() == L"https" && port == 443)) value += L":" + std::to_wstring(port);
    return winrt::hstring(value);
}
inline bool browser_url_allowed(std::string_view value) {
    if (value == "about:blank") return true;
    if (value.empty() || value.size() > 32768 || std::any_of(value.begin(), value.end(), [](unsigned char ch){return ch < 32;})) return false;
    try {
        const winrt::Windows::Foundation::Uri uri{winrt::to_hstring(value)};
        return (uri.SchemeName() == L"https" || uri.SchemeName() == L"http") && !uri.Host().empty()
            && uri.UserName().empty() && uri.Password().empty();
    } catch (...) {return false;}
}
inline bool browser_thread_id_allowed(std::string_view value) {
    return !value.empty() && value.size() <= 128 && std::all_of(value.begin(), value.end(), [](unsigned char ch) {
        return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '{' || ch == '}';
    });
}
inline std::wstring browser_private_profile_name(std::string_view session) {
    if (session.size() >= 2 && session.front() == '{' && session.back() == '}') session = session.substr(1, session.size() - 2);
    if (session.empty() || session.size() > 56 || !std::all_of(session.begin(), session.end(), [](unsigned char ch) {
            return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_';
        })) throw std::invalid_argument("Invalid private browser profile identity");
    return L"Private-" + std::wstring(session.begin(), session.end());
}
inline std::string browser_restore_url(std::string_view value) {
    if (!browser_url_allowed(value)) return "about:blank";
    if (value == "about:blank") return std::string(value);
    try {
        const winrt::Windows::Foundation::Uri uri{winrt::to_hstring(value)};
        bool sensitive{};
        for (const auto& entry : uri.QueryParsed()) {
            auto key = winrt::to_string(entry.Name());
            for (auto& ch : key) if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch + ('a' - 'A'));
            if (key == "code" || key == "state" || key == "key" || key == "api_key" || key == "apikey"
                    || key.find("token") != std::string::npos || key.find("password") != std::string::npos
                    || key == "code_verifier" || key == "signature" || key == "x-amz-signature") sensitive = true;
        }
        if (sensitive) return winrt::to_string(browser_origin(uri) + uri.Path());
        auto result = winrt::to_string(uri.AbsoluteUri());
        // OAuth implicit flows can carry tokens in fragments. Do not add a second plaintext copy to the tab index.
        if (const auto fragment = result.find('#'); fragment != std::string::npos) result.resize(fragment);
        return result;
    } catch (...) {return "about:blank";}
}
inline std::wstring browser_download_name(std::wstring value) {
    if (const auto slash = value.find_last_of(L"/\\"); slash != std::wstring::npos) value.erase(0, slash + 1);
    for (auto& ch : value) if (ch < 32 || std::wstring_view(L"<>:\"/\\|?*").find(ch) != std::wstring_view::npos) ch = L'_';
    while (!value.empty() && (value.back() == L'.' || value.back() == L' ')) value.pop_back();
    if (value.empty()) value = L"download.bin";
    if (value.size() > 200) {value.resize(200); if (value.back() >= 0xd800 && value.back() <= 0xdbff) value.pop_back();}
    auto base = value.substr(0, value.find(L'.'));
    for (auto& ch : base) if (ch >= L'a' && ch <= L'z') ch = static_cast<wchar_t>(ch + (L'A' - L'a'));
    if (base == L"CON" || base == L"PRN" || base == L"AUX" || base == L"NUL"
            || (base.size() == 4 && (base.starts_with(L"COM") || base.starts_with(L"LPT")) && base[3] >= L'1' && base[3] <= L'9')) value.insert(0, L"download-");
    return value;
}
} // namespace coincide
