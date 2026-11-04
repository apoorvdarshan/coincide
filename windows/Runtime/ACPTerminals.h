#pragma once
#include "ACPProtocol.h"
#include "ACPFileSystem.h"
#include <limits>
#include <unordered_map>

namespace coincide {
class ACPTerminals {
public:
    using Object = ACPProtocol::Object; using Array = ACPProtocol::Array; using Json = ACPProtocol::Json;
    explicit ACPTerminals(ACPFileSystem& files) : files_(files) {}
    ~ACPTerminals() {stop();}
    Object create(const Object& params) {
        poll(); std::size_t live{}; for (const auto& [id, value] : terminals_) {static_cast<void>(id); if (!value->exit) ++live;}
        if (live >= 16 || terminals_.size() >= 64) throw std::invalid_argument("Too many ACP terminals are open");
        const auto command = ACPProtocol::text(params, L"command"); const auto executable = resolve(command);
        std::vector<std::wstring> arguments; std::size_t bytes = executable.wstring().size();
        for (const auto& raw : params.GetNamedArray(L"args", Array{})) {
            if (raw.ValueType() != rpc_json::JsonValueType::String || arguments.size() >= 1024) throw std::invalid_argument("Invalid ACP terminal arguments");
            auto value = ACPFileSystem::wide(winrt::to_string(raw.GetString())); bytes += value.size() * 2 + 3; if (bytes > 24000) throw std::invalid_argument("The ACP command line is too long"); arguments.push_back(std::move(value));
        }
        WindowsProcess::Environment environment; std::size_t env_bytes{};
        for (const auto& raw : params.GetNamedArray(L"env", Array{})) {
            if (raw.ValueType() != rpc_json::JsonValueType::Object || environment.size() >= 128) throw std::invalid_argument("Invalid ACP terminal environment");
            const auto entry = raw.GetObject(); const auto name = ACPProtocol::text(entry, L"name"), value = ACPProtocol::text(entry, L"value"); env_bytes += name.size() + value.size();
            if (entry.GetNamedValue(L"value", Json::CreateNullValue()).ValueType() != rpc_json::JsonValueType::String) throw std::invalid_argument("ACP terminal environment values must be strings");
            if (name.empty() || name.find('=') != std::string::npos || env_bytes > 65536) throw std::invalid_argument("Invalid ACP terminal environment"); environment.emplace_back(ACPFileSystem::wide(name), ACPFileSystem::wide(value));
        }
        const auto cwd = files_.working_directory(ACPProtocol::text(params, L"cwd"));
        const auto requested = params.GetNamedNumber(L"outputByteLimit", 4 * 1024 * 1024);
        if (!std::isfinite(requested) || requested < 0 || requested != std::trunc(requested)) throw std::invalid_argument("Invalid ACP output byte limit");
        auto value = std::make_unique<Terminal>(); value->buffer = std::make_shared<Buffer>(); value->buffer->limit = static_cast<std::size_t>(std::min<double>(requested, 8 * 1024 * 1024));
        value->session = ACPProtocol::text(params, L"sessionId"); const auto buffer = value->buffer;
        value->process = WindowsProcess::start_bytes(executable, arguments, cwd, [buffer](std::string_view output) {buffer->append(output);}, std::numeric_limits<std::size_t>::max(), environment, true);
        value->process->close_input(); const auto id = "coincide-acp-terminal-" + std::to_string(++number_); terminals_.emplace(id, std::move(value));
        Object result; ACPProtocol::put(result, L"terminalId", id); return result;
    }
    std::optional<Object> request(const std::string& method, const Object& params, const std::string& rpc_id) {
        poll(); const auto id = ACPProtocol::text(params, L"terminalId"); const auto at = terminals_.find(id);
        if (at == terminals_.end() || at->second->session != ACPProtocol::text(params, L"sessionId")) throw std::invalid_argument("Unknown ACP terminal identity");
        auto& terminal = *at->second;
        if (method == "terminal/output") {
            Object result; const auto [output, truncated] = terminal.buffer->snapshot(); ACPProtocol::put(result, L"output", output); result.SetNamedValue(L"truncated", Json::CreateBooleanValue(truncated));
            if (terminal.exit) result.SetNamedValue(L"exitStatus", status(*terminal.exit)); return result;
        }
        if (method == "terminal/wait_for_exit") {
            if (terminal.exit) return status(*terminal.exit);
            if (terminal.waiters.size() >= 128) throw std::invalid_argument("Too many waiters for the ACP terminal"); terminal.waiters.push_back(rpc_id); return std::nullopt;
        }
        if (method == "terminal/kill" || method == "terminal/release") {
            terminal.process->stop(); finish(terminal); if (method == "terminal/release") terminals_.erase(at); return Object{};
        }
        throw std::invalid_argument("Unsupported ACP terminal method");
    }
    std::vector<std::pair<std::string, Object>> completed() {poll(); auto result = std::move(completed_); completed_.clear(); return result;}
    void stop() noexcept {for (auto& [id, terminal] : terminals_) {static_cast<void>(id); terminal->process->stop();} terminals_.clear(); completed_.clear();}
    static std::filesystem::path resolve(const std::string& command) {
        const auto name = ACPFileSystem::wide(command); if (name.empty() || name.find_first_of(L"\r\n\0", 0, 3) != std::wstring::npos) throw std::invalid_argument("Invalid ACP terminal command");
        const auto native = [](const std::filesystem::path& path) {DWORD type{}; return path.is_absolute() && !path.wstring().starts_with(L"\\\\") && GetBinaryTypeW(path.c_str(), &type) && (type == SCS_32BIT_BINARY || type == SCS_64BIT_BINARY);};
        const std::filesystem::path requested(name);
        if (requested.is_absolute()) {if (native(requested)) return requested; throw std::invalid_argument("The ACP terminal command must be a native Windows executable");}
        if (requested.has_parent_path()) throw std::invalid_argument("ACP terminal commands must be absolute or resolved from explicit PATH entries");
        const auto count = GetEnvironmentVariableW(L"PATH", nullptr, 0); std::wstring path(count, '\0'); if (count) path.resize(GetEnvironmentVariableW(L"PATH", path.data(), count));
        for (std::size_t start = 0; start <= path.size();) {
            const auto end = path.find(';', start); const auto part = path.substr(start, end == std::wstring::npos ? path.size() - start : end - start); std::filesystem::path directory(part);
            if (directory.is_absolute() && !part.starts_with(L"\\\\")) {auto candidate = directory / requested; if (!candidate.has_extension()) candidate += L".exe"; if (native(candidate)) return candidate;}
            if (end == std::wstring::npos) break; start = end + 1;
        }
        throw std::invalid_argument("No native Windows executable was found for this ACP command; shell wrappers are not run implicitly");
    }
private:
    struct Buffer {
        std::mutex mutex; std::string bytes; std::size_t limit{}; bool truncated{};
        void append(std::string_view value) {
            std::lock_guard lock(mutex);
            if (value.size() >= limit) {truncated = truncated || !bytes.empty() || value.size() > limit; bytes.assign(value.substr(value.size() - limit));}
            else {bytes.append(value); if (bytes.size() > limit) {truncated = true; bytes.erase(0, bytes.size() - limit);}}
            while (!bytes.empty() && (static_cast<unsigned char>(bytes.front()) & 0xc0) == 0x80) {bytes.erase(bytes.begin()); truncated = true;}
        }
        std::pair<std::string, bool> snapshot() {
            std::lock_guard lock(mutex); if (ACPFileSystem::valid_utf8(bytes)) return {bytes, truncated};
            const auto count = MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), nullptr, 0); std::wstring wide(static_cast<std::size_t>(count), L'\0');
            MultiByteToWideChar(CP_UTF8, 0, bytes.data(), static_cast<int>(bytes.size()), wide.data(), count);
            const auto length = WideCharToMultiByte(CP_UTF8, 0, wide.data(), count, nullptr, 0, nullptr, nullptr); std::string output(static_cast<std::size_t>(length), '\0');
            WideCharToMultiByte(CP_UTF8, 0, wide.data(), count, output.data(), length, nullptr, nullptr); return {output, truncated};
        }
    };
    struct Terminal {std::string session; std::unique_ptr<WindowsProcess> process; std::shared_ptr<Buffer> buffer; std::optional<DWORD> exit; std::vector<std::string> waiters;};
    ACPFileSystem& files_; std::unordered_map<std::string, std::unique_ptr<Terminal>> terminals_;
    std::vector<std::pair<std::string, Object>> completed_; unsigned number_{};
    static Object status(DWORD code) {Object result; result.SetNamedValue(L"exitCode", Json::CreateNumberValue(code)); result.SetNamedValue(L"signal", Json::CreateNullValue()); return result;}
    void finish(Terminal& value) {
        if (value.exit) return;
        if (const auto exit = value.process->wait(std::chrono::milliseconds(0))) {value.exit = exit->status; for (const auto& id : value.waiters) completed_.push_back({id, status(exit->status)}); value.waiters.clear();}
    }
    void poll() {for (auto& [id, terminal] : terminals_) {static_cast<void>(id); finish(*terminal);}}
};
} // namespace coincide
