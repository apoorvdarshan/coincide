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
    const auto complete = [&](const std::string& value, const std::string& item_id = "answer") {
        auto p = params(active); Object item; CodexProtocol::text(item, L"id", item_id); CodexProtocol::text(item, L"type", "agentMessage");
        CodexProtocol::text(item, L"text", value); p.SetNamedValue(L"item", item); notice("item/completed", p);
        if (mode == L"late-item") delta("LATE AFTER FINAL");
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
            if (prompt_text == "stream-finish" || prompt_text == "stream-then-wait") {
                if (prompt_text == "stream-finish") complete("whole reply");
                else {
                    auto p = params(active); Object item; CodexProtocol::text(item, L"id", "answer");
                    CodexProtocol::text(item, L"type", "agentMessage"); CodexProtocol::text(item, L"text", "whole reply");
                    p.SetNamedValue(L"item", item); notice("item/completed", p);
                }
                return;
            }
            if (mode == L"approval-failure") {lifecycle("turn/completed", "failed"); previous = active; return;}
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
        if (method == L"model/list") {
            const auto p = value.GetNamedObject(L"params");
            const auto cursor = p.GetNamedString(L"cursor", L"");
            Object result; rpc_json::JsonArray models;
            Object model; CodexProtocol::text(model, L"id", cursor.empty() ? "first" : "second");
            CodexProtocol::text(model, L"model", cursor.empty() ? "fixture-model" : "fixture-default");
            CodexProtocol::text(model, L"displayName", cursor.empty() ? "Fixture Model" : "Fixture Default");
            model.SetNamedValue(L"isDefault", Json::CreateBooleanValue(!cursor.empty())); models.Append(model);
            result.SetNamedValue(L"data", models);
            result.SetNamedValue(L"nextCursor", mode == L"model-loop" || cursor.empty() ? Json::CreateStringValue(L"page-two") : Json::CreateNullValue());
            reply(id, result); return;
        }
        if (method == L"thread/start" || method == L"thread/resume") {
            if (mode == L"resume-error") {error(id, "The fixture cannot resume this session"); return;}
            Object result, t; CodexProtocol::text(t, L"id", thread); result.SetNamedValue(L"thread", t);
            CodexProtocol::text(result, L"model", "fixture-model"); reply(id, result); return;
        }
        if (method == L"turn/steer") {
            const auto p = value.GetNamedObject(L"params");
            if (p.GetNamedString(L"threadId") != winrt::to_hstring(thread) || p.GetNamedString(L"expectedTurnId") != winrt::to_hstring(active)) {
                error(id, "Steering targeted a different turn"); return;
            }
            const auto more = winrt::to_string(p.GetNamedArray(L"input").GetAt(0).GetObject().GetNamedString(L"text"));
            if (prompt_text == "stream-finish") {error(id, "A streaming reply was cut off by steering"); return;}
            Object result; CodexProtocol::text(result, L"turnId", mode == L"steer-wrong-turn" ? "unrelated-turn" : active);
            if (mode == L"steer-wrong-turn") {reply(id, result); return;}
            if (mode == L"steer-early-complete") {complete("steered " + more, "followup"); Sleep(20); reply(id, result);}
            else {reply(id, result); complete("steered " + more, "followup");}
            return;
        }
        if (method == L"turn/interrupt") {
            reply(id, Object{});
            if (mode != L"interrupt-hang") lifecycle("turn/completed", "interrupted");
            return;
        }
        if (method != L"turn/start") {error(id, "Unexpected fixture request"); return;}
        const auto input = value.GetNamedObject(L"params");
        if (input.GetNamedString(L"threadId") != winrt::to_hstring(thread)) {error(id, "Wrong thread identity"); return;}
        const auto expected_access = mode == L"settings" ? L"dangerFullAccess" : L"readOnly";
        if (input.GetNamedObject(L"sandboxPolicy").GetNamedString(L"type") != expected_access) {error(id, "Unsafe implicit access"); return;}
        if (mode == L"settings" && (input.GetNamedString(L"model", L"") != L"fixture-advanced"
                || input.GetNamedString(L"effort", L"") != L"high" || input.GetNamedString(L"serviceTier", L"") != L"priority"
                || input.GetNamedObject(L"collaborationMode").GetNamedString(L"mode") != L"plan")) {
            error(id, "The selected model controls did not reach Codex"); return;
        }
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
        if (prompt_text == "fail") {lifecycle("turn/completed", "failed"); previous = active; return;}
        if (prompt_text == "stream-then-wait" || prompt_text == "stream-finish") {
            delta("partial");
            // An explicit fixture approval is a deterministic stream-boundary barrier; no timing sleeps.
            Object request; waiting = Json::CreateStringValue(L"stream-boundary"); request.SetNamedValue(L"id", waiting);
            CodexProtocol::text(request, L"method", "item/commandExecution/requestApproval");
            auto p = params(active); CodexProtocol::text(p, L"itemId", "stream-boundary");
            CodexProtocol::text(p, L"command", "fixture barrier - never executed"); request.SetNamedValue(L"params", p); write(request); return;
        }
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
        CodexSession models(launch());
        check(models.refresh_models(), "model refresh must be a nonblocking worker request");
        const auto model_events = until(models, [&](const auto& e) {return has(e, Kind::models);});
        const auto listed = std::find_if(model_events.begin(), model_events.end(), [](const auto& e) {return e.kind == Kind::models;});
        const auto catalog = CodexProtocol::catalog_entries(rpc_json::JsonObject::Parse(winrt::to_hstring(listed->text)).GetNamedArray(L"data"));
        check(catalog.size() == 2 && catalog.front().model == "fixture-default", "model refresh must collect every page and retain the catalog default");
        check(!has(model_events, Kind::session) && !has(model_events, Kind::started), "reading model metadata must not create a conversation or model turn");
        CodexSession bad_catalog(launch(L"model-loop")); bad_catalog.refresh_models();
        const auto bad_models = until(bad_catalog, [&](const auto& e) {return has(e, Kind::catalog_error);});
        check(!has(bad_models, Kind::models), "a repeated model page must fail clearly instead of hanging or publishing a partial catalog");
        check(bad_catalog.send(input()) && !has(finished(bad_catalog), Kind::error), "a catalog read failure must not prevent a later normal conversation");

        CodexSession settings(launch(L"settings"));
        auto selected_settings = input(); selected_settings.model = "fixture-advanced"; selected_settings.effort = "high";
        selected_settings.service_tier = "priority"; selected_settings.plan = true; selected_settings.access = AgentAccess::full_access;
        check(settings.send(std::move(selected_settings)) && !has(finished(settings), Kind::error), "explicit model, reasoning, service tier, plan and access settings must reach the subprocess");

        CodexSession queued(launch()); queued.send(input("approval"));
        const auto queue_prompt = until(queued, [&](const auto& e) {return has(e, Kind::prompt);});
        const auto queue_request = std::find_if(queue_prompt.begin(), queue_prompt.end(), [](const auto& e) {return e.kind == Kind::prompt;});
        check(queued.queue(input("first queued"), "queue-1") && queued.queue(input("second queued"), "queue-2"), "busy sessions must accept explicit FIFO queued inputs");
        check(!queued.queue(input("duplicate"), "queue-1") && queued.queued_count() == 2, "duplicate delivery identities must never submit a queued message twice");
        check(queued.queued().front().turn.text == "first queued", "queue snapshots must retain each draft before it is submitted");
        queued.respond(queue_request->id, "{\"decision\":\"decline\"}");
        const auto queue_events = finished(queued);
        std::vector<std::string> accepted_queue;
        int queue_completions{};
        for (const auto& event : queue_events) {
            if (event.kind == Kind::input) accepted_queue.push_back(event.id + ":" + event.text);
            if (event.kind == Kind::completed) ++queue_completions;
        }
        check(accepted_queue == std::vector<std::string>{"queue-1:first queued", "queue-2:second queued"} && queue_completions == 3,
            "a completed turn must precede the next queued input and preserve FIFO request identities");
        check(queued.queued_count() == 0 && !queued.busy(), "drained queues must return to an idle state");
        check(!queued.queue(input(), "queue-1"), "a completed queue delivery must not be replayed with the same identity");

        CodexSession paused(launch()); paused.send(input("wait"));
        until(paused, [&](const auto& e) {return has(e, Kind::started);});
        paused.queue(input("remove me"), "removed"); paused.queue(input("retain me"), "retained");
        check(paused.remove_queued("removed") && !paused.remove_queued("removed"), "removing queued work must be explicit and idempotent");
        paused.interrupt();
        check(combined(finished(paused), Kind::completed) == "interrupted" && paused.queue_paused() && paused.queued_count() == 1,
            "Stop must retain but pause queued drafts rather than executing them afterwards");
        check(!paused.send(input("skip queue")), "a direct send must not overtake retained queued drafts");
        check(paused.resume_queue(), "a paused queue requires an explicit resume");
        const auto resumed_queue = finished(paused);
        check(std::any_of(resumed_queue.begin(), resumed_queue.end(), [](const auto& e) {return e.kind == Kind::input && e.id == "retained" && e.text == "retain me";}),
            "resuming must submit the retained queued draft exactly once");

        CodexSession failed_queue(launch(L"approval-failure")); failed_queue.send(input("approval"));
        const auto failure_prompt = until(failed_queue, [&](const auto& e) {return has(e, Kind::prompt);});
        const auto failure_request = std::find_if(failure_prompt.begin(), failure_prompt.end(), [](const auto& e) {return e.kind == Kind::prompt;});
        failed_queue.queue(input("retain after failure"), "failure-retained");
        failed_queue.respond(failure_request->id, "{\"decision\":\"decline\"}");
        const auto failed_queue_events = finished(failed_queue);
        check(has(failed_queue_events, Kind::error) && !has(failed_queue_events, Kind::input) && failed_queue.queue_paused() && failed_queue.queued_count() == 1,
            "a failed turn must retain and pause later messages without submitting them automatically");

        CodexSession bounded_queue(launch()); bounded_queue.send(input("wait"));
        until(bounded_queue, [&](const auto& e) {return has(e, Kind::started);});
        bool accepted_limit = true;
        for (int index = 0; index < 64; ++index) accepted_limit = accepted_limit && bounded_queue.queue(input("bounded"), "bounded-" + std::to_string(index));
        check(accepted_limit && !bounded_queue.queue(input("overflow"), "overflow") && bounded_queue.queued_count() == 64,
            "the pending message queue must have a bounded capacity without dropping accepted drafts");
        bounded_queue.interrupt(); (void)finished(bounded_queue);

        CodexSession streamed(launch()); streamed.send(input("stream-then-wait"));
        const auto stream_barrier = until(streamed, [&](const auto& e) {return has(e, Kind::prompt);});
        const auto stream_request = std::find_if(stream_barrier.begin(), stream_barrier.end(), [](const auto& e) {return e.kind == Kind::prompt;});
        check(streamed.steer(input("follow-up"), "steer-1") && !streamed.steer(input("duplicate"), "steer-1"),
            "steering must retain its delivery identity and reject duplicates");
        streamed.respond(stream_request->id, "{\"decision\":\"decline\"}");
        const auto steered = finished(streamed);
        const auto final_item = std::find_if(steered.begin(), steered.end(), [](const auto& e) {return e.kind == Kind::text_complete && e.text == "whole reply";});
        const auto steer_input = std::find_if(steered.begin(), steered.end(), [](const auto& e) {return e.kind == Kind::input && e.id == "steer-1" && e.detail == "steered";});
        check(final_item != steered.end() && steer_input != steered.end() && final_item < steer_input,
            "a streaming assistant item must finish before a follow-up is steered into the live turn");
        check(combined(steered, Kind::text_complete) == "whole replysteered follow-up" && !has(steered, Kind::error),
            "safe steering must retain the complete original reply and its separate follow-up item");
        check(!streamed.steer(input("too late"), "late-steer"), "an idle session must not send a follow-up to an old turn");

        CodexSession fallback(launch()); fallback.send(input("stream-finish"));
        const auto fallback_barrier = until(fallback, [&](const auto& e) {return has(e, Kind::prompt);});
        const auto fallback_request = std::find_if(fallback_barrier.begin(), fallback_barrier.end(), [](const auto& e) {return e.kind == Kind::prompt;});
        check(fallback.steer(input("send next"), "fallback-1") && fallback.steer(input("send after that"), "fallback-2"), "a streaming turn must retain pending follow-ups");
        fallback.respond(fallback_request->id, "{\"decision\":\"decline\"}");
        const auto deferred = finished(fallback);
        check(std::any_of(deferred.begin(), deferred.end(), [](const auto& e) {return e.kind == Kind::queued && e.id == "fallback-1" && e.detail == "steer-fallback";}),
            "a follow-up waiting for a stream boundary must become queued if the turn finishes normally");
        const auto prior_completed = std::find_if(deferred.begin(), deferred.end(), [](const auto& e) {return e.kind == Kind::completed;});
        const auto next_input = std::find_if(deferred.begin(), deferred.end(), [](const auto& e) {return e.kind == Kind::input && e.id == "fallback-1";});
        check(prior_completed != deferred.end() && next_input != deferred.end() && prior_completed < next_input,
            "a deferred follow-up must not enter the stored transcript until after the earlier turn completes");

        std::vector<std::string> fallback_ids;
        for (const auto& event : deferred) if (event.kind == Kind::input) fallback_ids.push_back(event.id);
        check(fallback_ids == std::vector<std::string>{"fallback-1", "fallback-2"}, "a completion/steer rejection race must preserve the order of multiple pending follow-ups");

        CodexSession cancelled_steer(launch()); cancelled_steer.send(input("stream-then-wait"));
        until(cancelled_steer, [&](const auto& e) {return has(e, Kind::prompt);});
        cancelled_steer.steer(input("do not send after Stop"), "cancelled-steer"); cancelled_steer.interrupt();
        const auto cancelled_followup = finished(cancelled_steer);
        check(has(cancelled_followup, Kind::delivery_failed) && !has(cancelled_followup, Kind::input) && cancelled_steer.queued_count() == 0,
            "Stop must reject a follow-up waiting for a streaming item instead of silently starting it afterwards");

        CodexSession early_steer(launch(L"steer-early-complete")); early_steer.send(input("wait"));
        until(early_steer, [&](const auto& e) {return has(e, Kind::started);}); early_steer.steer(input("confirmed"), "early-steer");
        const auto early_steer_events = finished(early_steer);
        const auto accepted_early = std::find_if(early_steer_events.begin(), early_steer_events.end(), [](const auto& e) {return e.kind == Kind::input;});
        const auto completed_early = std::find_if(early_steer_events.begin(), early_steer_events.end(), [](const auto& e) {return e.kind == Kind::completed;});
        check(accepted_early != early_steer_events.end() && completed_early != early_steer_events.end() && accepted_early < completed_early,
            "a confirmed steering input must be persisted before completion even when the server completes before acknowledging it");

        CodexSession wrong_steer(launch(L"steer-wrong-turn")); wrong_steer.send(input("wait"));
        until(wrong_steer, [&](const auto& e) {return has(e, Kind::started);}); wrong_steer.steer(input("reject"), "wrong-turn");
        const auto rejected_steer = until(wrong_steer, [&](const auto& e) {return has(e, Kind::delivery_failed);});
        check(!has(rejected_steer, Kind::input) && wrong_steer.busy(), "an acknowledgement for another turn must not fabricate a submitted input or finish the active turn");
        wrong_steer.interrupt(); (void)finished(wrong_steer);

        CodexSession immutable_item(launch(L"late-item")); immutable_item.send(input());
        const auto immutable = finished(immutable_item);
        check(combined(immutable, Kind::text_delta) == "नमस्ते 你好" && combined(immutable, Kind::text_complete) == "नमस्ते 你好",
            "late deltas for an already completed assistant item must not corrupt its authoritative final text");

        std::ofstream output(report); output << "PASS: " << checks << " Codex session lifecycle checks\n"; return output ? 0 : 2;
    } catch (const winrt::hresult_error& e) {std::ofstream(report) << "FAIL: " << winrt::to_string(e.message()) << '\n';}
      catch (const std::exception& e) {std::ofstream(report) << "FAIL: " << e.what() << '\n';}
    return 1;
}
} // namespace coincide
