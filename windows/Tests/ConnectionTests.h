#pragma once
#include "../Runtime/RpcConnection.h"
#include "ProcessTests.h"
#include <fstream>

namespace coincide {
// A real local subprocess speaking the app-server framing contract. Never opens an account or network.
inline int rpc_fixture(std::wstring_view mode) {
    using Json = rpc_json::JsonValue;
    using Object = rpc_json::JsonObject;
    if (mode == L"blocked") {Sleep(30000); return 0;}
    LineFramer framer;
    std::array<char, 4096> buffer{};
    DWORD count{};
    bool initialized{};
    rpc_json::IJsonValue waiting{nullptr};
    bool exit{};
    const auto write = [](const Object& value) {fixture_write(GetStdHandle(STD_OUTPUT_HANDLE), winrt::to_string(value.Stringify()) + "\n");};
    auto receive = [&](const std::string& line) {
        const auto envelope = Object::Parse(winrt::to_hstring(line));
        const auto method = envelope.GetNamedString(L"method", L"");
        if (method == L"initialized") {initialized = true; return;}
        if (method == L"fixture/exit") {exit = true; return;}
        if (method == L"fixture/hang") return;
        const auto null = Json::CreateNullValue();
        const auto id = envelope.GetNamedValue(L"id", null);
        if (method.empty()) {
            if (waiting && id.ValueType() == rpc_json::JsonValueType::String && id.GetString() == L"approval-你好") {
                Object response; response.SetNamedValue(L"id", waiting);
                response.SetNamedValue(L"result", envelope.GetNamedValue(L"result", null)); write(response); waiting = nullptr;
            }
            return;
        }
        Object response;
        response.SetNamedValue(L"id", id);
        if (method == L"fixture/approval") {
            waiting = id;
            Object request;
            request.SetNamedValue(L"id", Json::CreateStringValue(L"approval-你好"));
            request.SetNamedValue(L"method", Json::CreateStringValue(L"item/commandExecution/requestApproval"));
            request.SetNamedValue(L"params", Object{}); write(request); return;
        }
        if (method == L"fixture/echo") {
            Object notice, params;
            params.SetNamedValue(L"delta", Json::CreateStringValue(L"नमस्ते 你好"));
            notice.SetNamedValue(L"method", Json::CreateStringValue(L"item/agentMessage/delta"));
            notice.SetNamedValue(L"params", params); write(notice);
            response.SetNamedValue(L"result", envelope.GetNamedValue(L"params", null));
        } else {
            Object result;
            result.SetNamedValue(L"initialized", Json::CreateBooleanValue(initialized));
            response.SetNamedValue(L"result", result);
        }
        write(response);
    };
    while (!exit && ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr) && count) {
        framer.consume(std::string_view(buffer.data(), count), receive);
    }
    return exit ? 7 : 0;
}

inline int connection_tests(const std::filesystem::path& report) {
    using namespace std::chrono_literals;
    using Object = rpc_json::JsonObject;
    int checks{};
    auto check = [&](bool value, const char* message) {++checks; if (!value) throw std::runtime_error(message);};
    auto get = [&](auto& future) {
        check(future.wait_for(5s) == std::future_status::ready, "the local agent subprocess must answer or fail within the deadline");
        return future.get();
    };
    auto rejects = [&](auto& future, const char* message) {
        check(future.wait_for(5s) == std::future_status::ready, "failed requests must release their waiting callers");
        bool failed{}; try {(void)future.get();} catch (...) {failed = true;} check(failed, message);
    };
    try {
        wchar_t module[32768]{};
        const auto count = GetModuleFileNameW(nullptr, module, 32768);
        if (!count || count >= 32768) throw std::runtime_error("Cannot locate the RPC fixture");
        const auto executable = std::filesystem::path(module);
        const auto cwd = executable.parent_path();
        std::atomic<int> notices{};
        std::promise<std::string> approval_id;
        auto approval = approval_id.get_future();
        RpcConnection connection(executable, {L"--rpc-fixture", L"normal"}, cwd,
            [&](auto method, auto params) {
                if (method == "item/agentMessage/delta" && Object::Parse(winrt::to_hstring(params)).GetNamedString(L"delta") == L"नमस्ते 你好") ++notices;
            }, [&](auto id, auto method, auto) {
                if (method == "item/commandExecution/requestApproval") approval_id.set_value(id);
            });
        auto initialized = connection.call("initialize", "{}");
        check(!Object::Parse(winrt::to_hstring(get(initialized))).GetNamedBoolean(L"initialized"), "initialize must precede the initialized notification");
        connection.notify("initialized");
        auto ready = connection.call("fixture/ready", "{}");
        check(Object::Parse(winrt::to_hstring(get(ready))).GetNamedBoolean(L"initialized"), "notifications and requests must retain their outgoing order");
        std::vector<std::future<std::string>> echoes;
        for (int i = 0; i < 8; ++i) echoes.push_back(connection.call("fixture/echo", "{\"marker\":" + std::to_string(i) + "}"));
        for (int i = 0; i < 8; ++i) {
            check(Object::Parse(winrt::to_hstring(get(echoes[i]))).GetNamedNumber(L"marker") == i, "concurrent callers must receive their own subprocess responses");
        }
        check(notices == 8, "the host must deliver Unicode streaming notifications alongside replies");

        auto pending_approval = connection.call("fixture/approval", "{}");
        const auto id = get(approval);
        check(id == "\"approval-你好\"", "approval identifiers must cross the thread boundary without losing type or Unicode");
        check(pending_approval.wait_for(20ms) == std::future_status::timeout, "a server request must wait for an explicit approval response");
        connection.respond(id, "{\"decision\":\"decline\"}");
        check(Object::Parse(winrt::to_hstring(get(pending_approval))).GetNamedString(L"decision") == L"decline", "the user's decision must reach the actual subprocess");

        auto timed = connection.call("fixture/hang", "{}", 40ms);
        rejects(timed, "unanswered subprocess requests must time out");
        auto after_timeout = connection.call("fixture/ready", "{}");
        (void)get(after_timeout);
        auto malformed = connection.call("fixture/echo", "not-json");
        rejects(malformed, "invalid request parameters must fail without crashing the connection");
        auto after_malformed = connection.call("fixture/ready", "{}");
        (void)get(after_malformed);

        auto abandoned = connection.call("fixture/hang", "{}");
        const auto close_start = std::chrono::steady_clock::now();
        connection.close();
        check(std::chrono::steady_clock::now() - close_start < 100ms, "requesting cancellation must not join workers on the UI thread");
        connection.shutdown();
        rejects(abandoned, "closing must resolve requests waiting on the host");

        RpcConnection exiting(executable, {L"--rpc-fixture", L"normal"}, cwd);
        auto exited = exiting.call("fixture/exit", "{}");
        rejects(exited, "a child exit must fail outstanding requests rather than hang");

        RpcConnection missing(cwd / L"missing-agent.exe", {}, cwd);
        auto missing_call = missing.call("initialize", "{}");
        rejects(missing_call, "startup failures must reach callers without launching a substitute");

        RpcConnection blocked(executable, {L"--rpc-fixture", L"blocked"}, cwd);
        auto blocked_call = blocked.call("fixture/hang", "{\"text\":\"" + std::string(1024 * 1024, 'x') + "\"}", 50ms);
        rejects(blocked_call, "deadlines must still fire when the child stops reading stdin");
        const auto stop_start = std::chrono::steady_clock::now();
        blocked.shutdown();
        check(std::chrono::steady_clock::now() - stop_start < 5s, "closing must release a blocked writer and terminate its owned job");

        std::ofstream output(report);
        output << "PASS: " << checks << " Windows RPC connection checks\n";
        return output ? 0 : 2;
    } catch (const winrt::hresult_error& e) {std::ofstream(report) << "FAIL: " << winrt::to_string(e.message()) << '\n';}
      catch (const std::exception& e) {std::ofstream(report) << "FAIL: " << e.what() << '\n';}
    return 1;
}
} // namespace coincide
