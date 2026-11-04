#pragma once
#include <winrt/Windows.Foundation.Collections.h>
#include "WindowsProcess.h"
#include <winrt/Windows.Data.Json.h>
#include <cwctype>
#include <regex>
#include <unordered_set>

namespace coincide {
enum class ProviderInstallation { missing, windows_executable, shell_wrapper, invalid_executable };
enum class ProviderAuthentication { unknown, signed_in, signed_out };
struct WindowsProviderStatus {
    std::string id, name, version, account, detail;
    std::filesystem::path executable;
    ProviderInstallation installation{ProviderInstallation::missing};
    ProviderAuthentication authentication{ProviderAuthentication::unknown};
    bool adapter_available{};
};
class ProviderDiscovery {
public:
    // Scanning is file-only. Account probes are explicit and belong on a worker thread.
    static std::vector<WindowsProviderStatus> scan(const std::vector<std::filesystem::path>& roots = search_roots(), bool environment_overrides = true) {
        std::vector<WindowsProviderStatus> result;
        for (const auto& definition : definitions()) result.push_back(scan_one(definition, roots, environment_overrides));
        return result;
    }
    static std::filesystem::path discover(const std::string& provider) {
        const auto statuses = scan();
        const auto at = std::find_if(statuses.begin(), statuses.end(), [&](const auto& value) {return value.id == provider;});
        if (at == statuses.end()) throw std::invalid_argument("Unknown agent provider");
        if (at->installation != ProviderInstallation::windows_executable) throw std::runtime_error(at->detail);
        return at->executable;
    }
    static std::vector<std::filesystem::path> search_roots() {
        std::vector<std::filesystem::path> roots;
        const auto add = [&](const std::filesystem::path& path) {
            if (!path.empty() && path.is_absolute() && !path.wstring().starts_with(L"\\\\")) roots.push_back(path);
        };
        const auto local = environment(L"LOCALAPPDATA"), profile = environment(L"USERPROFILE"), roaming = environment(L"APPDATA");
        if (!local.empty()) {
            add(std::filesystem::path(local) / L"Programs/Codex");
            add(std::filesystem::path(local) / L"Microsoft/WinGet/Links");
            add(std::filesystem::path(local) / L"Programs/Claude Code");
            add(std::filesystem::path(local) / L"Programs/OpenCode");
        }
        if (!profile.empty()) add(std::filesystem::path(profile) / L".local/bin");
        if (!roaming.empty()) add(std::filesystem::path(roaming) / L"npm");
        const auto path = environment(L"PATH");
        for (std::size_t start = 0; start <= path.size();) {
            const auto end = path.find(L';', start);
            auto entry = path.substr(start, end == std::wstring::npos ? path.size() - start : end - start);
            if (entry.size() >= 2 && entry.front() == L'"' && entry.back() == L'"') entry = entry.substr(1, entry.size() - 2);
            if (!entry.empty()) add(entry);
            if (end == std::wstring::npos) break;
            start = end + 1;
        }
        return roots;
    }
    static bool windows_executable(const std::filesystem::path& path) {
        DWORD type{}; return GetBinaryTypeW(path.c_str(), &type) && (type == SCS_32BIT_BINARY || type == SCS_64BIT_BINARY);
    }
    // No login command, saved credential, or model turn is used by this metadata-only probe.
    static WindowsProviderStatus probe(WindowsProviderStatus status, std::chrono::milliseconds timeout = std::chrono::seconds(15)) {
        if (status.installation != ProviderInstallation::windows_executable) return status;
        try {
            const auto version = run(status.executable, {L"--version"}, timeout);
            if (version.timed_out || version.status != 0) {status.detail = "The Windows agent executable did not return its version successfully"; return status;}
            std::smatch match;
            if (std::regex_search(version.output, match, std::regex(R"((\d+\.\d+(?:\.\d+)?(?:[-+][A-Za-z0-9.-]+)?))"))) status.version = match[1];
            if (status.id == "codex") {
                const auto account = run(status.executable, {L"login", L"status"}, timeout);
                const auto message = lower(account.output + "\n" + account.error);
                if (!account.timed_out && message.find("not logged in") != std::string::npos) status.authentication = ProviderAuthentication::signed_out;
                else if (!account.timed_out && account.status == 0 && message.find("logged in") != std::string::npos) status.authentication = ProviderAuthentication::signed_in;
            } else if (status.id == "claude") {
                const auto account = run(status.executable, {L"auth", L"status", L"--json"}, timeout);
                winrt::Windows::Data::Json::JsonObject value{nullptr};
                if (!account.timed_out && winrt::Windows::Data::Json::JsonObject::TryParse(winrt::to_hstring(account.output), value)) {
                    const auto logged = value.GetNamedValue(L"loggedIn", winrt::Windows::Data::Json::JsonValue::CreateNullValue());
                    if (logged.ValueType() == winrt::Windows::Data::Json::JsonValueType::Boolean) {
                        status.authentication = logged.GetBoolean() ? ProviderAuthentication::signed_in : ProviderAuthentication::signed_out;
                        status.account = winrt::to_string(value.GetNamedString(L"email", L""));
                    }
                }
            }
            if (status.authentication == ProviderAuthentication::signed_out) status.detail = status.id == "codex"
                ? "Codex is installed but not signed in. Run codex login on this Windows account."
                : "Claude Code is installed but not signed in. Run claude auth login on this Windows account.";
            else if (!status.adapter_available) status.detail = "A Windows executable was found; its Coincide adapter is not implemented yet";
            else if (status.authentication == ProviderAuthentication::signed_in) status.detail = "The installed Windows CLI reports an existing sign-in";
            else status.detail = "The installed Windows CLI runs; its sign-in could not be verified";
        } catch (const std::exception&) {status.detail = "The Windows agent metadata probe failed";}
          catch (const winrt::hresult_error&) {status.detail = "The Windows agent returned unsupported account metadata";}
        return status;
    }
private:
    struct Definition {std::string id, name; std::vector<std::wstring> names; bool adapter;};
    struct CommandResult {DWORD status{}; std::string output, error; bool timed_out{};};
    static std::vector<Definition> definitions() {
        return {{"claude", "Claude Code", {L"claude.exe"}, true}, {"codex", "Codex", {L"codex.exe"}, true},
            {"cursor", "Cursor", {L"cursor-agent.exe"}, false}, {"grok", "Grok Build", {L"grok.exe"}, false},
            {"opencode", "OpenCode", {L"opencode.exe"}, true}, {"antigravity", "Antigravity", {L"agy_acp_server.exe", L"agy_acp_server.par"}, false}};
    }
    static std::wstring environment(const wchar_t* name) {
        const auto count = GetEnvironmentVariableW(name, nullptr, 0); if (!count) return {};
        std::wstring value(count, L'\0');
        const auto written = GetEnvironmentVariableW(name, value.data(), count);
        if (!written || written >= count) return {}; value.resize(written); return value;
    }
    static std::string lower(std::string value) {
        for (auto& character : value) if (character >= 'A' && character <= 'Z') character = static_cast<char>(character + ('a' - 'A'));
        return value;
    }
    static WindowsProviderStatus scan_one(const Definition& definition, const std::vector<std::filesystem::path>& roots, bool environment_overrides) {
        WindowsProviderStatus value; value.id = definition.id; value.name = definition.name; value.adapter_available = definition.adapter;
        value.detail = "Install a native Windows " + definition.name + " agent CLI; no executable was found";
        if (environment_overrides) {
            std::wstring variable = L"COINCIDE_";
            for (const auto character : definition.id) variable.push_back(static_cast<wchar_t>(character >= 'a' && character <= 'z' ? character - ('a' - 'A') : character));
            variable += L"_EXE";
            const auto configured = environment(variable.c_str());
            if (!configured.empty()) {
                value.executable = configured;
                if (value.executable.is_absolute() && !configured.starts_with(L"\\\\") && windows_executable(value.executable)) {
                    value.installation = ProviderInstallation::windows_executable;
                    value.detail = "Explicit native Windows agent executable configured; sign-in has not been checked";
                } else {
                    value.installation = ProviderInstallation::invalid_executable;
                    value.detail = "The explicit agent override must be an existing absolute native Windows executable";
                }
                return value;
            }
        }
        std::filesystem::path invalid, wrapper;
        for (const auto& directory : roots) {
            if (!directory.is_absolute() || directory.wstring().starts_with(L"\\\\")) continue;
            for (const auto& name : definition.names) {
                const auto path = directory / name;
                std::error_code error;
                if (std::filesystem::is_regular_file(path, error)) {
                    if (windows_executable(path)) {value.installation = ProviderInstallation::windows_executable; value.executable = path;
                        value.detail = definition.adapter ? "Native Windows agent executable found; sign-in has not been checked"
                            : "Native Windows executable found; its Coincide adapter is not implemented yet"; return value;}
                    invalid = path;
                }
                for (const auto extension : {L".cmd", L".bat", L".ps1"}) {
                    auto launcher = path; launcher.replace_extension(extension);
                    if (std::filesystem::is_regular_file(launcher, error)) wrapper = launcher;
                }
            }
        }
        if (!wrapper.empty()) {value.installation = ProviderInstallation::shell_wrapper; value.executable = wrapper;
            value.detail = "A shell launcher was found for " + definition.name + "; select a native Windows agent executable. Shell wrappers are not executed implicitly.";}
        else if (!invalid.empty()) {value.installation = ProviderInstallation::invalid_executable; value.executable = invalid;
            value.detail = "The detected " + definition.name + " file is not a Windows executable; it cannot be launched as a native agent.";}
        return value;
    }
    static CommandResult run(const std::filesystem::path& executable, const std::vector<std::wstring>& arguments, std::chrono::milliseconds timeout) {
        if (timeout.count() <= 0 || timeout > std::chrono::minutes(2)) throw std::invalid_argument("Invalid metadata probe deadline");
        CommandResult result;
        auto process = WindowsProcess::start_bytes(executable, arguments, executable.parent_path(), [&](std::string_view bytes) {result.output.append(bytes);}, 64 * 1024);
        process->close_input();
        const auto exited = process->wait(timeout);
        if (!exited) {process->stop(); result.timed_out = true; return result;}
        result.status = exited->status; result.error = exited->stderr_tail;
        if (exited->stdout_truncated || !exited->channel_error.empty()) throw std::runtime_error("Metadata output exceeds its limit");
        return result;
    }
};
} // namespace coincide
