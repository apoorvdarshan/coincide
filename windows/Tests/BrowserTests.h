#pragma once
#include "../App/BrowserPolicy.h"
#include <filesystem>
#include <fstream>
#include <stdexcept>

namespace coincide {
inline int browser_tests(const std::filesystem::path& report) {
    int checks{};
    auto check = [&](bool value, const char* message) {++checks; if (!value) throw std::runtime_error(message);};
    try {
        check(browser_url_allowed("about:blank"), "the browser must support a network-free default page");
        check(browser_url_allowed("https://example.com/path?q=hello"), "normal HTTPS navigation must be allowed");
        check(browser_url_allowed("http://127.0.0.1:8765/fixture"), "local HTTP development and offline fixtures must work");
        check(!browser_url_allowed("javascript:alert(1)"), "address input must not execute JavaScript schemes");
        check(!browser_url_allowed("file:///C:/Windows/win.ini"), "web navigation must not grant arbitrary local-file access");
        check(!browser_url_allowed("data:text/html,private"), "ordinary navigation must not bypass the explicit fixture/preview path");
        check(!browser_url_allowed("https://user:password@example.com/"), "credentials must not be accepted in navigation URLs");
        check(!browser_url_allowed("mailto:person@example.com"), "web pages must not launch an external application implicitly");
        check(!browser_url_allowed("relative/path") && !browser_url_allowed("https://example.com/\nnext"), "invalid and control-character URLs must fail closed");
        check(browser_thread_id_allowed("{abcdef12-3456-7890-abcd-0123456789ab}"), "conversation identities must have stable profile folders");
        check(!browser_thread_id_allowed("../outside") && !browser_thread_id_allowed("C:\\outside"), "profile folder identities must not allow traversal");
        check(browser_private_profile_name("{abcdef12-3456-7890-abcd-0123456789ab}") == L"Private-abcdef12-3456-7890-abcd-0123456789ab", "private profile names must respect WebView2's restricted ASCII alphabet");
        check(browser_restore_url("https://example.com/callback?code=temporary&state=temporary") == "https://example.com/callback", "OAuth codes and state must not be copied into the plaintext tab index");
        check(browser_restore_url("https://example.com/path#access_token=temporary") == "https://example.com/path", "OAuth token fragments must not be restored from the tab index");
        check(browser_restore_url("https://example.com/search?q=hello") == "https://example.com/search?q=hello", "ordinary search parameters must remain restorable");
        check(browser_restore_url("https://example.com/path?to%6ben=temporary") == "https://example.com/path", "encoded sensitive query names must also be removed from saved tab URLs");
        check(browser_restore_url("http://127.0.0.1:1455/callback?code=temporary") == "http://127.0.0.1:1455/callback", "sensitive URL stripping must preserve an explicit loopback port");
        check(browser_restore_url("http://[::1]:8765/callback?state=temporary") == "http://[::1]:8765/callback", "IPv6 origins must retain brackets and explicit ports when restored");
        check(browser_download_name(L"C:\\folder\\report.txt") == L"report.txt", "download names must discard source directory components");
        check(browser_download_name(L"CON.txt") == L"download-CON.txt", "downloads must not resolve to a Windows device name");
        check(browser_download_name(L"..\\AUX") == L"download-AUX", "download device-name validation must follow basename extraction");
        check(browser_download_name(L"bad:name?.txt") == L"bad_name_.txt", "download names must be valid Windows basenames");
        check(browser_download_name(L"...") == L"download.bin", "empty dot-only download names need a safe basename");
        std::ofstream output(report); output << "PASS: " << checks << " Windows browser policy checks\n"; return output ? 0 : 2;
    } catch (const std::exception& error) {std::ofstream(report) << "FAIL: " << error.what() << '\n';}
      catch (const winrt::hresult_error& error) {std::ofstream(report) << "FAIL: " << winrt::to_string(error.message()) << '\n';}
    return 1;
}
} // namespace coincide
