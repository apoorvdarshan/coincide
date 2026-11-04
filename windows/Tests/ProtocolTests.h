#pragma once
#include "../Runtime/CodexProtocol.h"
#include <atomic>
#include <filesystem>
#include <fstream>

namespace coincide {
inline int protocol_tests(const std::filesystem::path& report) {
    using namespace std::chrono_literals;
    using Json = rpc_json::JsonValue;
    using Object = rpc_json::JsonObject;
    int checks{};
    auto check = [&](bool condition, const char* message) { ++checks; if (!condition) throw std::runtime_error(message); };
    auto rejects = [&](auto&& operation, const char* message) {
        bool failed{}; try { operation(); } catch (const std::exception&) { failed = true; }
        check(failed, message);
    };
    auto reply = [](std::uint64_t id, const char* marker) {
        Object envelope, result;
        envelope.SetNamedValue(L"id", Json::CreateNumberValue(static_cast<double>(id)));
        CodexProtocol::text(result, L"marker", marker); envelope.SetNamedValue(L"result", result);
        return winrt::to_string(envelope.Stringify());
    };
    try {
        std::vector<std::string> sent;
        std::string notification_method, delta;
        rpc_json::IJsonValue approval_id{nullptr};
        std::string requested_method;
        RpcPeer peer([&](auto line){sent.push_back(std::move(line));},
            [&](auto method, auto value) { notification_method = method; delta = winrt::to_string(value.GetObject().GetNamedString(L"delta")); },
            [&](auto id, auto method, auto) { approval_id = id; requested_method = method; });

        auto first = peer.request("model/list", Object{});
        auto second = peer.request("thread/start", Object{});
        auto envelope = Object::Parse(winrt::to_hstring(sent.front()));
        check(!envelope.HasKey(L"jsonrpc") && envelope.GetNamedString(L"method") == L"model/list", "Codex wire messages omit the jsonrpc header");
        check(peer.receive(reply(second.id, "second")), "a valid response must be consumed");
        check(first.result.wait_for(0ms) == std::future_status::timeout, "out-of-order responses must not resolve another request");
        check(peer.receive(reply(first.id, "first")), "the first request must still accept its own reply");
        check(first.result.get().GetObject().GetNamedString(L"marker") == L"first" &&
              second.result.get().GetObject().GetNamedString(L"marker") == L"second", "responses must retain request identities");
        check(!peer.receive(reply(first.id, "duplicate")), "duplicate responses must be ignored");

        auto pending = peer.request("pending", Object{});
        check(!peer.receive("{\"id\":" + std::to_string(pending.id) + "}"), "responses need a result or error before resolving a request");
        check(!peer.receive("{\"id\":" + std::to_string(pending.id) + ",\"result\":null,\"error\":{}}"), "ambiguous success and error responses must be rejected");
        check(!peer.receive("not json") && !peer.receive("[]") &&
              !peer.receive("{\"id\":1.5,\"result\":null}"), "malformed and fractional identifiers must not be accepted");
        check(pending.result.wait_for(0ms) == std::future_status::timeout, "malformed frames must not resolve a request");
        peer.receive(reply(pending.id, "valid")); (void)pending.result.get();

        peer.receive(R"({"method":"item/agentMessage/delta","params":{"threadId":"thread-1","delta":"नमस्ते"}})");
        check(notification_method == "item/agentMessage/delta" && delta == "नमस्ते", "stream notifications must retain method and Unicode text");
        const auto before_approval = sent.size();
        peer.receive(R"({"id":"approval-你好","method":"item/commandExecution/requestApproval","params":{"command":"git status"}})");
        check(sent.size() == before_approval && requested_method == "item/commandExecution/requestApproval", "receiving an approval must never approve it automatically");
        check(approval_id && approval_id.GetString() == L"approval-你好", "server request identifiers must remain opaque Unicode values");
        Object decision; CodexProtocol::text(decision, L"decision", "decline");
        peer.respond(approval_id, decision);
        auto approved_response = Object::Parse(winrt::to_hstring(sent.back()));
        check(approved_response.GetNamedString(L"id") == L"approval-你好" &&
              approved_response.GetNamedObject(L"result").GetNamedString(L"decision") == L"decline", "approval responses must use the original server identifier and chosen decision");

        RpcPeer unsupported([&](auto line){sent.push_back(std::move(line));});
        unsupported.receive(R"({"id":91,"method":"unsupported/request","params":{}})");
        const auto unknown = Object::Parse(winrt::to_hstring(sent.back()));
        check(unknown.GetNamedObject(L"error").GetNamedNumber(L"code") == -32601 && !unknown.HasKey(L"result"),
            "unimplemented server requests must fail closed");

        auto failure = peer.request("error", Object{});
        Object error_reply, error;
        error_reply.SetNamedValue(L"id", Json::CreateNumberValue(static_cast<double>(failure.id)));
        error.SetNamedValue(L"code", Json::CreateNumberValue(-32000)); CodexProtocol::text(error, L"message", "fixture error");
        error_reply.SetNamedValue(L"error", error); peer.receive(winrt::to_string(error_reply.Stringify()));
        bool correct_error{};
        try {(void)failure.result.get();} catch(const RpcError& e) {correct_error = e.code == -32000 && std::string(e.what()) == "fixture error";}
        check(correct_error, "RPC errors must preserve their code and message");

        const auto now = RpcPeer::Clock::time_point{} + 1000s;
        auto timed = peer.request("thread/resume", Object{}, 50ms, now);
        peer.expire(now + 49ms);
        check(timed.result.wait_for(0ms) == std::future_status::timeout, "requests must not expire before their deadline");
        peer.expire(now + 50ms);
        check(timed.result.wait_for(0ms) == std::future_status::ready, "request deadlines must resolve waiting callers");
        rejects([&]{(void)timed.result.get();}, "timeouts must fail instead of fabricating a result");
        check(!peer.receive(reply(timed.id, "late")), "late replies must not resurrect expired requests");

        auto closed_a = peer.request("a", Object{}); auto closed_b = peer.request("b", Object{});
        peer.close(); peer.close();
        check(closed_a.result.wait_for(0ms) == std::future_status::ready && closed_b.result.wait_for(0ms) == std::future_status::ready,
            "closing the connection must release every pending caller");
        rejects([&]{(void)closed_a.result.get();}, "closed connections must fail pending requests");
        rejects([&]{(void)closed_b.result.get();}, "every pending request must receive the closure");
        rejects([&]{(void)peer.request("after-close", Object{});}, "closed peers must not send new work");
        check(!peer.receive(R"({"method":"late/notification","params":{}})"), "late notifications must be discarded after closure");

        RpcPeer broken([](auto){throw std::runtime_error("fixture write failure");});
        auto unsent = broken.request("initialize", Object{});
        check(unsent.result.wait_for(0ms) == std::future_status::ready, "a transport failure must not strand a request");
        rejects([&]{(void)unsent.result.get();}, "transport write failures must surface to the caller");

        RpcPeer confined([](auto){});
        std::atomic<bool> wrong_thread_rejected{};
        std::thread other([&]{try {confined.close();} catch(const std::logic_error&) {wrong_thread_rejected = true;}});
        other.join();
        check(wrong_thread_rejected, "reader threads must dispatch state changes to the owning host thread");

        const auto initialize = CodexProtocol::initialize();
        check(initialize.GetNamedObject(L"clientInfo").GetNamedString(L"name") == L"coincide" &&
              initialize.GetNamedObject(L"capabilities").GetNamedBoolean(L"experimentalApi"), "initialization must preserve Coincide client capabilities");
        const std::string cwd = "C:\\Projects\\会話 folder";
        const auto resume = CodexProtocol::thread_resume("native-session", cwd);
        check(resume.GetNamedString(L"cwd") == winrt::to_hstring(cwd) && resume.GetNamedBoolean(L"excludeTurns"), "resuming must preserve Windows paths without duplicating the stored transcript");
        check(!resume.HasKey(L"model"), "an unspecified model must use the provider's resolved model rather than a hardcoded replacement");

        CodexTurn input; input.cwd = cwd; input.text = "Line one\n\"quoted\" नमस्ते"; input.image_paths = {"C:\\Images\\画像.png"};
        auto turn = CodexProtocol::turn_start("native-session", input);
        check(turn.GetNamedString(L"approvalPolicy") == L"untrusted" &&
              turn.GetNamedObject(L"sandboxPolicy").GetNamedString(L"type") == L"readOnly", "approval mode must not silently grant full access");
        auto items = turn.GetNamedArray(L"input");
        check(items.Size() == 2 && items.GetAt(0).GetObject().GetNamedString(L"text") == winrt::to_hstring(input.text) &&
              items.GetAt(1).GetObject().GetNamedString(L"type") == L"localImage", "text and images must retain their native input types");
        input.access = AgentAccess::full_access; input.model = "model-from-catalog"; input.plan = true;
        turn = CodexProtocol::turn_start("native-session", input);
        check(turn.GetNamedString(L"approvalPolicy") == L"never" && turn.GetNamedObject(L"sandboxPolicy").GetNamedString(L"type") == L"dangerFullAccess",
            "explicit full access must use the intended provider policy");
        check(turn.GetNamedObject(L"collaborationMode").GetNamedString(L"mode") == L"plan", "plan mode must reach the provider");
        input.plan = false;
        turn = CodexProtocol::turn_start("native-session", input);
        check(turn.GetNamedObject(L"collaborationMode").GetNamedString(L"mode") == L"default", "leaving plan mode must explicitly clear it");
        input.plan = true; input.model.clear();
        rejects([&]{(void)CodexProtocol::turn_start("native-session", input);}, "plan mode must not silently turn into acting when the model is unresolved");
        rejects([&]{(void)CodexProtocol::thread_resume("", cwd);}, "resuming requires an actual native session identity");
        rejects([&]{(void)CodexProtocol::interrupt("thread", "");}, "interrupting must never target an unknown turn");

        std::ofstream output(report);
        output << "PASS: " << checks << " RPC/Codex protocol checks\n";
        return output ? 0 : 2;
    } catch(const winrt::hresult_error& e) {std::ofstream(report) << "FAIL: " << winrt::to_string(e.message()) << '\n';}
      catch(const std::exception& e) {std::ofstream(report) << "FAIL: " << e.what() << '\n';}
    return 1;
}
} // namespace coincide
