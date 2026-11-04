#pragma once
#include "ACPSession.h"
#include <fstream>

namespace coincide {
// A read-only installation/layout description, separate from account readiness. In particular a
// Cursor .cmd selection resolves to its bundled PE + index.js; no launcher text is executed.
struct ACPLaunchSpec {
    std::string provider;
    std::filesystem::path executable, harness, profile_directory;
    ACPLaunchOptions options;
};
class ACPVendorLaunch {
public:
    static ACPLaunchSpec inspect(const std::string& provider, const std::filesystem::path& selected) {
        ACPLaunchSpec result; result.provider = provider;
        if (!selected.is_absolute() || selected.wstring().starts_with(L"\\\\")) throw std::invalid_argument("Select an absolute local ACP program path");
        auto program = selected;
        if (provider == "cursor") {
            auto folder = std::filesystem::is_directory(program) ? program : program.parent_path();
            if (std::filesystem::is_regular_file(folder / L"dist-package/node.exe")) folder /= L"dist-package";
            const auto node = folder / L"node.exe", entry = folder / L"index.js", metadata = folder / L"package.json";
            if (native(node) && regular(entry, 64 * 1024 * 1024) && regular(metadata, 65536)) {
                std::ifstream stream(metadata, std::ios::binary); const std::string bytes((std::istreambuf_iterator<char>(stream)), {}); ACPProtocol::Object package{nullptr};
                if (!ACPProtocol::Object::TryParse(winrt::to_hstring(bytes), package) || ACPProtocol::text(package, L"name") != "@anysphere/agent-cli-runtime") throw std::invalid_argument("This is not a recognized Cursor CLI runtime package");
                result.executable = std::filesystem::canonical(node); result.options.command_prefix = {std::filesystem::canonical(entry).wstring()}; return result;
            }
            if (lower(program.filename().wstring()) != L"cursor-agent.exe") throw std::invalid_argument("Select a Cursor package containing its bundled node.exe and index.js");
        }
        if (provider != "cursor" && provider != "grok" && provider != "antigravity") throw std::invalid_argument("Unknown ACP provider");
        if (!native(program)) throw std::invalid_argument("The ACP agent must be a native Windows executable"); result.executable = std::filesystem::canonical(program);
        if (provider == "antigravity") {
            result.harness = result.executable.parent_path() / L"localharness_external.exe";
            if (!native(result.harness)) throw std::invalid_argument("Antigravity requires its Windows localharness_external.exe beside the agent");
        }
        return result;
    }
    // Called only after the app verified a non-secret native account identity. Profile and cache
    // folders already exist: this function does not create an account, copy credentials or sign in.
    static ACPLaunchSpec bind_profile(ACPLaunchSpec program, const std::filesystem::path& profile,
            const std::filesystem::path& compile_cache, AgentAccountScope account, bool identity_verified,
            bool resuming = false, bool antigravity_acknowledged = false, const std::wstring& verified_browser_command = {}) {
        if (program.provider == "antigravity" && !antigravity_acknowledged) throw std::runtime_error("Acknowledge the Antigravity provider notice in Settings before enabling it");
        if (!identity_verified || account.current.empty()) throw std::runtime_error("Verify the selected provider account before starting a conversation");
        if (resuming && account.saved.empty()) throw std::runtime_error("This saved conversation has no verified account binding; choose its original account explicitly");
        if (resuming) account.require_resume();
        auto lease = std::make_shared<ACPFileSystem>(profile); program.profile_directory = lease->root(); program.options.profile_lease = lease; program.options.account = std::move(account);
        auto& environment = program.options.environment;
        if (program.provider == "cursor") {
            if (compile_cache.empty()) throw std::invalid_argument("Cursor requires an app-owned compile cache folder"); ACPFileSystem cache(compile_cache);
            environment = {{L"CURSOR_CONFIG_DIR", program.profile_directory.wstring()}, {L"CURSOR_INVOKED_AS", L"cursor-agent"}, {L"NODE_COMPILE_CACHE", cache.root().wstring()},
                {L"CURSOR_DATA_DIR", program.profile_directory.wstring()}, {L"APPDATA", program.profile_directory.wstring()},
                {L"AGENT_CLI_CREDENTIAL_STORE", L"file"}, {L"NO_OPEN_BROWSER", L"1"},
                {L"NODE_OPTIONS", std::nullopt}, {L"ELECTRON_RUN_AS_NODE", std::nullopt}, {L"CURSOR_API_KEY", std::nullopt}};
            for(const auto* key:{L"HOME",L"USERPROFILE",L"LOCALAPPDATA",L"XDG_CONFIG_HOME",L"XDG_DATA_HOME",L"XDG_CACHE_HOME"})environment.emplace_back(key,program.profile_directory.wstring());
            for(const auto* key:{L"CURSOR_AUTH_TOKEN",L"CURSOR_AUTH_TOKEN_EXPIRES_AT",L"CURSOR_API_BASE_URL",L"CURSOR_API_ENDPOINT",L"CURSOR_API_URL",L"CURSOR_WEBSITE_URL",L"CURSOR_LOCAL_AGENT_BASE_URL",
                    L"CURSOR_AGENT_CLI_AUTHLESS_MODE",L"CURSOR_ENABLE_AUTHLESS",L"CURSOR_AGENT_CLI_LOCAL_MODE",L"CURSOR_AGENT_STORE",L"CURSOR_AGENT_STORE_FILES_DIR",L"CURSOR_AGENT_STORE_SHARED_PATHS",L"CURSOR_BEDROCK_AWS_AUTH_REFRESH",L"CURSOR_BEDROCK_BASE_URL"})environment.emplace_back(key,std::nullopt);
            program.options.cursor_settings_file = program.profile_directory / L"cli-config.json";
        } else if (program.provider == "grok") {
            environment = {{L"GROK_HOME", program.profile_directory.wstring()}, {L"GROK_MANAGED_BY_NPM", L"1"}, {L"GROK_DISABLE_AUTOUPDATER", L"1"}, {L"XAI_API_KEY", std::nullopt}, {L"GROK_AUTH", std::nullopt}};
            for (const auto* key : {L"GROK_OIDC_ISSUER", L"GROK_OIDC_CLIENT_ID", L"GROK_OAUTH2_ISSUER", L"GROK_OAUTH2_CLIENT_ID", L"GROK_OAUTH2_PRINCIPAL_TYPE", L"GROK_OAUTH2_PRINCIPAL_ID",
                    L"GROK_AUTH_PROVIDER_COMMAND", L"GROK_LOCAL_AUTH", L"GROK_CLI_CHAT_PROXY_BASE_URL", L"GROK_MODELS_BASE_URL", L"GROK_CONFIG", L"GROK_CONFIG_PATH"}) environment.emplace_back(key, std::nullopt);
        } else if (program.provider == "antigravity") {
            if (verified_browser_command.empty()) throw std::runtime_error("Antigravity's browser handoff must be verified before enabling its Windows agent");
            for (const auto* key : {L"GEMINI_API_KEY", L"GOOGLE_API_KEY", L"GOOGLE_APPLICATION_CREDENTIALS", L"GOOGLE_CLOUD_PROJECT", L"GOOGLE_CLOUD_LOCATION", L"GOOGLE_CLOUD_QUOTA_PROJECT",
                    L"GOOGLE_GENAI_USE_VERTEXAI", L"GCLOUD_PROJECT", L"CLOUDSDK_CORE_PROJECT", L"AGY_ACP_CCPA_PROJECT", L"AGY_ACP_ENABLE_OAUTH", L"ELECTRON_RUN_AS_NODE"}) environment.emplace_back(key, std::nullopt);
            environment.emplace_back(L"GEMINI_HOME", program.profile_directory.wstring()); environment.emplace_back(L"AGY_ACP_FORCE_FILE_STORAGE", L"1");
            environment.emplace_back(L"ANTIGRAVITY_HARNESS_PATH", program.harness.wstring()); environment.emplace_back(L"PYTHONUNBUFFERED", L"1"); environment.emplace_back(L"BROWSER", verified_browser_command);
        }
        return program;
    }
private:
    static std::wstring lower(std::wstring value) {std::transform(value.begin(), value.end(), value.begin(), [](wchar_t ch) {return static_cast<wchar_t>(std::towlower(ch));}); return value;}
    static bool regular(const std::filesystem::path& path, std::uintmax_t limit) {
        std::error_code error; return std::filesystem::is_regular_file(path, error) && std::filesystem::file_size(path, error) <= limit && !error;
    }
    static bool native(const std::filesystem::path& path) {DWORD type{}; return path.is_absolute() && !path.wstring().starts_with(L"\\\\") && regular(path, 512 * 1024 * 1024) && GetBinaryTypeW(path.c_str(), &type) && (type == SCS_32BIT_BINARY || type == SCS_64BIT_BINARY);}
};
} // namespace coincide
