#pragma once
#include "../Runtime/WindowsCredentials.h"
#include <array>
#include <filesystem>
#include <fstream>

namespace coincide {
template<class Check, class Rejects> void credential_tests(Check&& check, Rejects&& rejects) {
    const auto scope = L"fixture-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64());
    WindowsCredentials owner(scope), sibling(scope + L"-sibling");
    struct Cleanup {const WindowsCredentials& owner; ~Cleanup(){try {owner.erase(L"owned-fixture");} catch (...) {}}} cleanup{owner};
    const std::array<std::uint8_t, 8> fixture{0, 1, 2, 0, 255, 13, 10, 42};
    check(!owner.load(L"owned-fixture"), "a unique credential fixture namespace must start empty");
    owner.save(L"owned-fixture", L"local-fixture-你好", fixture);
    auto loaded = owner.load(L"owned-fixture");
    check(loaded && loaded->username == L"local-fixture-你好" && std::ranges::equal(loaded->secret.bytes(), fixture), "protected credentials must round-trip Unicode metadata and exact binary bytes");
    check(!sibling.load(L"owned-fixture") && sibling.names().empty(), "credential owner scopes must not read or enumerate each other's entries");
    check(owner.names() == std::vector<std::wstring>{L"owned-fixture"}, "credential enumeration must return only owned names");
    owner.save(L"owned-fixture", L"updated-fixture", std::span<const std::uint8_t>(fixture).first(3));
    loaded = owner.load(L"owned-fixture");
    check(loaded && loaded->username == L"updated-fixture" && loaded->secret.bytes().size() == 3, "updating an owned credential must replace its metadata and bytes");
    rejects([&]{owner.load(L"../outside");}, "credential names must reject path traversal and namespace escape");
    rejects([&]{WindowsCredentials invalid(L"invalid/scope");}, "credential owners must use a bounded opaque identifier");
    rejects([&]{owner.save(L"owned-fixture", std::wstring_view(L"x\0y",3), fixture);}, "credential metadata must reject embedded NULs");
    rejects([&]{owner.save(L"owned-fixture", L"fixture", std::vector<std::uint8_t>(CRED_MAX_CREDENTIAL_BLOB_SIZE + 1));}, "credential secrets must respect Windows blob bounds");
    check(owner.erase(L"owned-fixture") && !owner.erase(L"owned-fixture") && !owner.load(L"owned-fixture"), "owned fixture entries must be removable without touching other credentials");
}
inline int credential_tests(const std::filesystem::path& report) {
    int checks{};
    const auto check = [&](bool value, const char* message) {++checks; if (!value) throw std::runtime_error(message);};
    const auto rejects = [&](auto action, const char* message) {bool rejected{}; try {action();} catch (...) {rejected = true;} check(rejected, message);};
    try {credential_tests(check, rejects); std::ofstream output(report); output << "PASS: " << checks << " Windows credential checks\n"; return output ? 0 : 2;}
    catch (const std::exception& error) {std::ofstream(report) << "FAIL: " << error.what() << '\n'; return 1;}
}
} // namespace coincide
