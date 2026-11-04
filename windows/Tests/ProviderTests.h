#pragma once
#include "../Runtime/ProviderDiscovery.h"
#include <fstream>

namespace coincide {
inline int provider_tests(const std::filesystem::path& report) {
    int checks{};
    const auto check = [&](bool condition, const char* message) {++checks; if (!condition) throw std::runtime_error(message);};
    const auto root = std::filesystem::temp_directory_path() / (L"Coincide providers " + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
    struct Cleanup {std::filesystem::path path; ~Cleanup(){std::error_code ignored;std::filesystem::remove_all(path, ignored);}} cleanup{root};
    try {
        std::filesystem::create_directory(root);
        const auto find = [](const auto& statuses, const char* id) -> const WindowsProviderStatus& {
            const auto at = std::find_if(statuses.begin(), statuses.end(), [&](const auto& value) {return value.id == id;});
            if (at == statuses.end()) throw std::runtime_error("Provider missing from discovery catalog");
            return *at;
        };
        const auto empty = ProviderDiscovery::scan({root}, false);
        check(empty.size() == 6 && std::all_of(empty.begin(), empty.end(), [](const auto& value) {return value.installation == ProviderInstallation::missing;}),
            "discovery must report missing Windows CLIs instead of assuming they are available");
        {std::ofstream(root / L"claude.cmd") << "@echo wrapper must not execute\n";}
        {std::ofstream(root / L"grok.exe") << "This is not a Windows executable";}
        {std::ofstream(root / L"agy_acp_server.par") << "not a Windows runtime";}
        auto statuses = ProviderDiscovery::scan({root}, false);
        check(find(statuses, "claude").installation == ProviderInstallation::shell_wrapper, "a shell launcher must not be reported as a native executable");
        check(find(statuses, "grok").installation == ProviderInstallation::invalid_executable, "a renamed script must not be accepted as a Windows executable");
        check(find(statuses, "antigravity").installation == ProviderInstallation::invalid_executable && !find(statuses, "antigravity").adapter_available,
            "a foreign Antigravity runtime must not be reported as an implemented native provider");
        wchar_t module[32768]{};
        if (!GetModuleFileNameW(nullptr, module, 32768)) throw std::runtime_error("Cannot locate the provider fixture executable");
        std::filesystem::copy_file(module, root / L"codex.exe");
        std::filesystem::copy_file(module, root / L"claude.exe");
        statuses = ProviderDiscovery::scan({root}, false);
        check(find(statuses, "codex").installation == ProviderInstallation::windows_executable && find(statuses, "codex").adapter_available,
            "a detected native CLI must retain its exact executable path and available adapter");
        check(find(statuses, "claude").installation == ProviderInstallation::windows_executable,
            "a native executable must take precedence over a shell wrapper for the same CLI");
        check(find(statuses, "codex").authentication == ProviderAuthentication::unknown && find(statuses, "codex").version.empty(),
            "file-only discovery must not pretend to have checked account state or launched the CLI");
        std::filesystem::copy_file(module, root / L"cursor-agent.exe");
        statuses = ProviderDiscovery::scan({root}, false);
        check(find(statuses, "cursor").installation == ProviderInstallation::windows_executable && !find(statuses, "cursor").adapter_available,
            "finding a native binary must remain distinct from having a tested provider adapter");
        const auto relative = ProviderDiscovery::scan({std::filesystem::path(L".")}, false);
        check(std::all_of(relative.begin(), relative.end(), [](const auto& value) {return value.installation == ProviderInstallation::missing;}),
            "discovery must not implicitly search an untrusted current project directory");
        const auto wrapper = ProviderDiscovery::probe(find(empty, "claude"));
        check(wrapper.installation == ProviderInstallation::missing && wrapper.authentication == ProviderAuthentication::unknown,
            "metadata probing must leave missing providers alone without invoking a shell");
        const auto previous_size = GetEnvironmentVariableW(L"COINCIDE_CODEX_EXE", nullptr, 0);
        std::wstring previous_override(previous_size, L'\0');
        if (previous_size) previous_override.resize(GetEnvironmentVariableW(L"COINCIDE_CODEX_EXE", previous_override.data(), previous_size));
        struct RestoreOverride {bool existed; std::wstring value; ~RestoreOverride(){SetEnvironmentVariableW(L"COINCIDE_CODEX_EXE", existed ? value.c_str() : nullptr);}} restore{previous_size != 0, previous_override};
        const auto configured = root / L"codex.exe"; SetEnvironmentVariableW(L"COINCIDE_CODEX_EXE", configured.c_str());
        check(ProviderDiscovery::discover("codex") == configured, "an explicit absolute native Codex override must take precedence over discovered installations");
        SetEnvironmentVariableW(L"COINCIDE_CODEX_EXE", L"codex.exe");
        bool refused{}; try {(void)ProviderDiscovery::discover("codex");} catch (const std::runtime_error&) {refused = true;}
        check(refused, "an invalid explicit executable override must fail closed instead of falling back to another installation");
        std::ofstream output(report); output << "PASS: " << checks << " Windows provider discovery checks\n"; return output ? 0 : 2;
    } catch (const std::exception& error) {std::ofstream(report) << "FAIL: " << error.what() << '\n';}
      catch (const winrt::hresult_error& error) {std::ofstream(report) << "FAIL: " << winrt::to_string(error.message()) << '\n';}
    return 1;
}
} // namespace coincide
