#pragma once
#include "../Runtime/CodexSession.h"
#include "ProcessTests.h"
#include <fstream>

namespace coincide {
// A deterministic local app-server stand-in. It never signs in, contacts a model, or executes a requested command.
inline int codex_session_fixture(std::wstring_view mode) {
    using Object = rpc_json::JsonObject;
    using Json = rpc_json::JsonValue;
    if (mode == L"startup-hang") {Sleep(30000); return 0;}
    const std::string thread = "fixture-thread";
    std::string active, previous, prompt_text;
    rpc_json::IJsonValue waiting{nullptr};
    int turn_number{};
    bool initialized{}, exit{};
    const auto write = [](const Object& value) {fixture_write(GetStdHandle(STD_OUTPUT_HANDLE), winrt::to_string(value.Stringify()) + "\n");};
    const auto notice = [&](const char* method, Object params) {
        Object value; CodexProtocol::text(value, L"method", method); value.SetNamedValue(L"params", params); write(value);
    };
    const auto reply = [&](const rpc_json::IJsonValue& id, Object result) {
        Object value; value.SetNamedValue(L"id", id); value.SetNamedValue(L"result", result); write(value);
    };
    const auto error = [&](const rpc_json::IJsonValue& id, const char* message) {
        Object value, detail; value.SetNamedValue(L"id", id); detail.SetNamedValue(L"code", Json::CreateNumberValue(-32000));
        CodexProtocol::text(detail, L"message", message); value.SetNamedValue(L"error", detail); write(value);
    };
    const auto params = [&](const std::string& turn) {
        Object value; CodexProtocol::text(value, L"threadId", thread); CodexProtocol::text(value, L"turnId", turn); return value;
    };
    const auto lifecycle = [&](const char* method, const char* status) {
        auto p = params(active); Object turn; CodexProtocol::text(turn, L"id", active); CodexProtocol::text(turn, L"status", status);
        p.SetNamedValue(L"turn", turn); notice(method, p);
    };
    const auto delta = [&](const std::string& value, const std::string& target = "") {
        auto p = params(target.empty() ? active : target); CodexProtocol::text(p, L"itemId", "answer"); CodexProtocol::text(p, L"delta", value);
        notice("item/agentMessage/delta", p);
    };
    const auto complete = [&](const std::string& value) {
        auto p = params(active); Object item; CodexProtocol::text(item, L"id", "answer"); CodexProtocol::text(item, L"type", "agentMessage");
        CodexProtocol::text(item, L"text", value); p.SetNamedValue(L"item", item); notice("item/completed", p);
        lifecycle("turn/completed", "completed"); previous = active;
    };
    LineFramer framer;
    std::array<char, 4096> buffer{}; DWORD count{};
    const auto receive = [&](const std::string& line) {
        const auto value = Object::Parse(winrt::to_hstring(line));
        const auto method = value.GetNamedString(L"method", L"");
        const auto id = value.GetNamedValue(L"id", Json::CreateNullValue());
        if (method == L"initialized") {initialized = true; return;}
        if (method.empty()) {
            if (!waiting || id.Stringify() != waiting.Stringify()) return;
            waiting = nullptr;
            if (prompt_text == "unsupported") {
                if (!value.HasKey(L"error")) throw std::runtime_error("Unknown requests must be rejected");
                delta("unsupported rejected"); complete("unsupported rejected"); return;
            }
            const auto result = value.GetNamedObject(L"result");
            const auto output = prompt_text == "question"
                ? winrt::to_string(result.GetNamedObject(L"answers").GetNamedObject(L"question-1").GetNamedArray(L"answers").GetAt(0).GetString())
                : winrt::to_string(result.GetNamedString(L"decision"));
            delta(output); complete(output); return;
        }
        if (method == L"initialize") {reply(id, Object{}); return;}
        if (!initialized) {error(id, "The initialized notification was not received"); return;}
        if (method == L"account/read") {
            Object result, account; CodexProtocol::text(account, L"type", "chatgpt");
            if (mode == L"signed-out") result.SetNamedValue(L"account", Json::CreateNullValue());
            else result.SetNamedValue(L"account", account);
            result.SetNamedValue(L"requiresOpenaiAuth", Json::CreateBooleanValue(true)); reply(id, result); return;
        }
        if (method == L"thread/start" || method == L"thread/resume") {
            if (mode == L"resume-error") {error(id, "The fixture cannot resume this session"); return;}
            Object result, t; CodexProtocol::text(t, L"id", thread); result.SetNamedValue(L"thread", t);
            CodexProtocol::text(result, L"model", "fixture-model"); reply(id, result); return;
        }
        if (method == L"turn/interrupt") {
            reply(id, Object{});
            if (mode != L"interrupt-hang") lifecycle("turn/completed", "interrupted");
            return;
        }
        if (method != L"turn/start") {error(id, "Unexpected fixture request"); return;}
        const auto input = value.GetNamedObject(L"params");
        if (input.GetNamedString(L"threadId") != winrt::to_hstring(thread)) {error(id, "Wrong thread identity"); return;}
        if (input.GetNamedObject(L"sandboxPolicy").GetNamedString(L"type") != L"readOnly") {error(id, "Unsafe implicit access"); return;}
        prompt_text = winrt::to_string(input.GetNamedArray(L"input").GetAt(0).GetObject().GetNamedString(L"text"));
        active = "turn-" + std::to_string(++turn_number);
        Object result, t; CodexProtocol::text(t, L"id", active); result.SetNamedValue(L"turn", t);
        if (mode != L"early-complete") reply(id, result);
        if (!previous.empty()) {
            auto stale = params(previous); Object old; CodexProtocol::text(old, L"id", previous); stale.SetNamedValue(L"turn", old);
            notice("turn/started", stale); delta("STALE", previous);
        }
        lifecycle("turn/started", "inProgress");
        auto unrelated = params(active); CodexProtocol::text(unrelated, L"threadId", "another-thread");
        CodexProtocol::text(unrelated, L"itemId", "answer"); CodexProtocol::text(unrelated, L"delta", "WRONG THREAD");
        notice("item/agentMessage/delta", unrelated);
        if (prompt_text == "wait") return;
        if (prompt_text == "exit") {delta("partial before exit"); exit = true; return;}
        if (prompt_text == "approval" || prompt_text == "file-approval" || prompt_text == "question" || prompt_text == "unsupported") {
            Object request; waiting = Json::CreateStringValue(L"request-你好"); request.SetNamedValue(L"id", waiting);
            auto p = params(active); CodexProtocol::text(p, L"itemId", "fixture-tool");
            if (prompt_text == "question") {
                CodexProtocol::text(request, L"method", "item/tool/requestUserInput");
                rpc_json::JsonArray questions; Object q; CodexProtocol::text(q, L"id", "question-1");
                CodexProtocol::text(q, L"question", "Which fixture answer?"); questions.Append(q); p.SetNamedValue(L"questions", questions);
            } else if (prompt_text == "file-approval") {
                Object item, change; rpc_json::JsonArray changes;
                CodexProtocol::text(change, L"path", "fixture.txt"); CodexProtocol::text(change, L"diff", "-before\n+after"); changes.Append(change);
                CodexProtocol::text(item, L"id", "fixture-tool"); CodexProtocol::text(item, L"type", "fileChange"); item.SetNamedValue(L"changes", changes);
                auto started = params(active); started.SetNamedValue(L"item", item); notice("item/started", started);
                CodexProtocol::text(request, L"method", "item/fileChange/requestApproval");
                CodexProtocol::text(p, L"reason", "Fixture change - never applied");
            } else {
                CodexProtocol::text(request, L"method", prompt_text == "approval" ? "item/commandExecution/requestApproval" : "fixture/unsupported");
                CodexProtocol::text(p, L"command", "fixture command - never executed");
                rpc_json::JsonArray choices; for (const auto* choice : {L"accept", L"decline", L"cancel"}) choices.Append(Json::CreateStringValue(choice));
                p.SetNamedValue(L"availableDecisions", choices);
            }
            request.SetNamedValue(L"params", p); write(request); return;
        }
        delta("नमस्ते "); Sleep(20); delta("你好"); complete("नमस्ते 你好");
        if (mode == L"early-complete") reply(id, result);
    };
    while (!exit && ReadFile(GetStdHandle(STD_INPUT_HANDLE), buffer.data(), static_cast<DWORD>(buffer.size()), &count, nullptr) && count) {
        framer.consume(std::string_view(buffer.data(), count), receive);
    }
    return exit ? 7 : 0;
}

inline int session_tests(const std::filesystem::path& report) {
    using namespace std::chrono_literals;
    using Kind = SessionEvent::Kind;
    int checks{};
    const auto check = [&](bool condition, const char* message) {++checks; if (!condition) throw std::runtime_error(message);};
    try {
        wchar_t module[32768]{};
        if (!GetModuleFileNameW(nullptr, module, 32768)) throw std::runtime_error("Cannot locate the session fixture");
        const auto launch = [&](const wchar_t* mode = L"normal", const std::string& resume = "") {
            CodexLaunch value; value.executable = module; value.cwd = value.executable.parent_path();
            value.arguments = {L"--codex-session-fixture", mode}; value.session_id = resume; value.interrupt_grace = 150ms; return value;
        };
        const auto input = [](const char* text = "hello") {CodexTurn turn; turn.text = text; return turn;};
        const auto until = [&](CodexSession& session, auto condition) {
            std::vector<SessionEvent> events;
            const auto end = std::chrono::steady_clock::now() + 5s;
            do {
                for (auto& event : session.take_events()) events.push_back(std::move(event));
                if (condition(events)) return events;
                Sleep(5);
            } while (std::chrono::steady_clock::now() < end);
            throw std::runtime_error("Session fixture timed out");
        };
        const auto has = [](const auto& events, Kind kind) {return std::any_of(events.begin(), events.end(), [&](const auto& e) {return e.kind == kind;});};
        const auto finished = [&](CodexSession& session) {return until(session, [&](const auto& e) {return has(e, Kind::completed) && !session.busy();});};
        const auto combined = [](const auto& events, Kind kind) {std::string s; for (const auto& e : events) if (e.kind == kind) s += e.text; return s;};

        CodexSession normal(launch());
        check(normal.send(input()), "a new session must accept input");
        check(!normal.send(input("duplicate")), "a busy session must not silently submit another turn");
        auto first = finished(normal);
        check(!has(first, Kind::error), "the initialization and first turn must succeed");
        check(combined(first, Kind::text_delta) == "नमस्ते 你好", "streaming must preserve Unicode and exclude other threads");
        check(combined(first, Kind::text_complete) == "नमस्ते 你好", "the final assistant item must retain its full text");
        check(combined(first, Kind::completed) == "completed", "normal completion must be reported");
        check(std::any_of(first.begin(), first.end(), [](const auto& e) {return e.kind == Kind::session && e.id == "fixture-thread";}), "the native session identity must be exposed for persistence");
        check(normal.send(input("second")), "a completed session must accept its next turn");
        const auto second = finished(normal);
        check(combined(second, Kind::text_delta) == "नमस्ते 你好", "late output from a previous turn must not leak into the next reply");
        check(!has(second, Kind::session), "an existing connection must retain its native session rather than creating another");

        CodexSession resumed(launch(L"normal", "fixture-thread"));
        check(resumed.send(input()), "a restored native session must accept input");
        check(!has(finished(resumed), Kind::error), "restored sessions must resume before sending");
        CodexSession early(launch(L"early-complete")); early.send(input());
        auto early_events = finished(early);
        check(combined(early_events, Kind::text_delta) == "नमस्ते 你好" && !has(early_events, Kind::error), "completion before the turn/start response must not lose the reply or hang");

        CodexSession approval(launch()); approval.send(input("approval"));
        auto prompt = until(approval, [&](const auto& e) {return has(e, Kind::prompt);});
        check(!has(prompt, Kind::completed) && approval.busy(), "approval must wait for an explicit response");
        const auto request = std::find_if(prompt.begin(), prompt.end(), [](const auto& e) {return e.kind == Kind::prompt;});
        check(request->id == "\"request-你好\"", "approval ids must preserve their opaque JSON representation");
        approval.respond(request->id, "{\"decision\":\"decline\"}");
        auto denied = finished(approval);
        check(combined(denied, Kind::text_complete) == "decline", "the user's denial must reach the real subprocess");
        check(has(denied, Kind::resolved), "answered approval cards must be cleared");

        CodexSession files(launch()); files.send(input("file-approval"));
        auto changes = until(files, [&](const auto& e) {return has(e, Kind::prompt);});
        const auto change = std::find_if(changes.begin(), changes.end(), [](const auto& e) {return e.kind == Kind::prompt;});
        check(change->text.find("fixture.txt") != std::string::npos && change->text.find("+after") != std::string::npos, "file approval must retain the proposed path and diff");
        files.respond(change->id, "{\"decision\":\"decline\"}");
        check(combined(finished(files), Kind::text_complete) == "decline", "file changes must require the user's explicit decision");

        CodexSession question(launch()); question.send(input("question"));
        auto questions = until(question, [&](const auto& e) {return has(e, Kind::prompt);});
        const auto q = std::find_if(questions.begin(), questions.end(), [](const auto& e) {return e.kind == Kind::prompt;});
        question.respond(q->id, "{\"answers\":{\"question-1\":{\"answers\":[\"fixture answer\"]}}}");
        check(combined(finished(question), Kind::text_complete) == "fixture answer", "question answers must retain their question identity and content");

        CodexSession unsupported(launch()); unsupported.send(input("unsupported"));
        check(combined(finished(unsupported), Kind::text_complete) == "unsupported rejected", "unimplemented server requests must fail closed without hanging the turn");
        for (const auto* mode : {L"normal", L"interrupt-hang"}) {
            CodexSession stopping(launch(mode)); stopping.send(input("wait"));
            until(stopping, [&](const auto& e) {return has(e, Kind::started);});
            const auto start = std::chrono::steady_clock::now(); stopping.interrupt();
            check(std::chrono::steady_clock::now() - start < 100ms, "Stop must not block the caller");
            check(combined(finished(stopping), Kind::completed) == "interrupted", "Stop must finish even when the server ignores interrupt");
        }
        CodexSession cancel_start(launch(L"startup-hang")); cancel_start.send(input());
        until(cancel_start, [&](const auto& e) {return has(e, Kind::status);}); cancel_start.interrupt();
        check(combined(finished(cancel_start), Kind::completed) == "interrupted", "Stop during initialization must terminate the owned process without waiting for startup");
        for (const auto* mode : {L"signed-out", L"resume-error"}) {
            CodexSession failed(launch(mode, mode == std::wstring_view(L"resume-error") ? "saved-thread" : "")); failed.send(input());
            const auto events = finished(failed);
            check(has(events, Kind::error) && combined(events, Kind::completed) == "failed", "authentication and resume failures must reach the caller");
            check(!has(events, Kind::session), "failed resume must never silently replace an existing native session");
        }
        CodexSession exiting(launch()); exiting.send(input("exit"));
        const auto exited = finished(exiting);
        check(combined(exited, Kind::text_delta) == "partial before exit" && has(exited, Kind::error), "an unexpected exit must preserve partial output and report failure");
        auto timeout_launch = launch(L"startup-hang"); timeout_launch.request_timeout = 60ms;
        CodexSession timeout(std::move(timeout_launch)); timeout.send(input());
        check(has(finished(timeout), Kind::error), "initialization deadlines must release the session");
        std::ofstream output(report); output << "PASS: " << checks << " Codex session lifecycle checks\n"; return output ? 0 : 2;
    } catch (const winrt::hresult_error& e) {std::ofstream(report) << "FAIL: " << winrt::to_string(e.message()) << '\n';}
      catch (const std::exception& e) {std::ofstream(report) << "FAIL: " << e.what() << '\n';}
    return 1;
}
} // namespace coincide
