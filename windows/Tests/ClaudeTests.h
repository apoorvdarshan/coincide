#pragma once
#include "../Runtime/ClaudeSession.h"
#include "ProcessTests.h"
#include "FixturePrompt.h"
#include <fstream>

namespace coincide {
inline int claude_account_fixture(std::wstring_view mode) {
    if(mode==L"startup-hang"||mode==L"account-hang"){Sleep(30000);return 0;}
    auto status=ClaudeProtocol::Object::Parse(LR"({"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"fixture@example.invalid","orgId":"fixture-org"})");
    if(mode==L"signed-out")status.SetNamedValue(L"loggedIn",ClaudeProtocol::Json::CreateBooleanValue(false));
    wchar_t profile[32768]{};const auto count=GetEnvironmentVariableW(L"CLAUDE_CONFIG_DIR",profile,32768);
    if(count&&count<32768){std::ifstream selected(std::filesystem::path(profile)/L"account-email.txt");std::string email;if(std::getline(selected,email)&&!email.empty())ClaudeProtocol::put(status,L"email",email);}
    fixture_write(GetStdHandle(STD_OUTPUT_HANDLE),winrt::to_string(status.Stringify())+"\n");return 0;
}
inline int claude_session_fixture(std::wstring_view mode) {
    using Object = ClaudeProtocol::Object; using Array = ClaudeProtocol::Array; using Json = ClaudeProtocol::Json;
    if (mode == L"startup-hang") {Sleep(30000); return 0;}
    const auto put = [](Object object, const wchar_t* key, const std::string& value) {ClaudeProtocol::put(object, key, value);};
    const auto write = [](Object frame) {fixture_write(GetStdHandle(STD_OUTPUT_HANDLE), winrt::to_string(frame.Stringify()) + "\n");};
    const std::string session = "claude-fixture-session";
    std::string current, previous, pending, prompt; int message_count{}; bool exit{};Object previous_assistant{nullptr};
    const auto control_reply = [&](const std::string& id, Object value, bool error = false) {write(ClaudeProtocol::response(id, value, error));};
    const auto result = [&](bool failed = false, const std::string& target = "") {
        Object frame; put(frame, L"type", "result"); put(frame, L"session_id", session); put(frame, L"user_message_uuid", target.empty() ? current : target);
        put(frame, L"subtype", failed ? "error_during_execution" : "success"); frame.SetNamedValue(L"is_error", Json::CreateBooleanValue(failed)); write(frame); previous = current;
    };
    const auto answer = [&](const std::string& value) {
        Object frame, message, block; Array content;
        put(frame, L"type", "assistant"); put(frame, L"session_id", session); put(message, L"id", "fixture-message-"+std::to_string(GetCurrentProcessId())+"-"+std::to_string(++message_count));
        put(block, L"type", "text"); put(block, L"text", value); content.Append(block); message.SetNamedValue(L"content", content);if(mode==L"usage")message.SetNamedValue(L"usage",Object::Parse(LR"({"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2})"));frame.SetNamedValue(L"message", message);write(frame);if(mode==L"usage"){write(frame);previous_assistant=frame;Object snapshot;put(snapshot,L"type","result");put(snapshot,L"session_id",session);put(snapshot,L"user_message_uuid",current);snapshot.SetNamedValue(L"total_cost_usd",Json::CreateNumberValue(12.75));write(snapshot);}else result();
    };
    const auto event = [&](const char* kind, Object value) {Object frame; put(frame, L"type", "stream_event"); put(frame, L"session_id", session); put(value, L"type", kind); frame.SetNamedValue(L"event", value); write(frame);};
    LineFramer framer; std::array<char, 4096> bytes{}; DWORD count{};
    const auto receive = [&](const std::string& line) {
        const auto frame = Object::Parse(winrt::to_hstring(line)); const auto type = ClaudeProtocol::text(frame, L"type");
        if (type == "control_request") {
            const auto id = ClaudeProtocol::text(frame, L"request_id"); const auto request = frame.GetNamedObject(L"request"); const auto subtype = ClaudeProtocol::text(request, L"subtype");
            Object response;
            if (subtype == "initialize") {
                Array models, efforts; Object model, account; put(model, L"value", "claude-fixture"); put(model, L"displayName", "Claude Fixture");
                efforts.Append(Json::CreateStringValue(L"low")); efforts.Append(Json::CreateStringValue(L"high")); model.SetNamedValue(L"supportedEffortLevels", efforts);
                model.SetNamedValue(L"supportsFastMode", Json::CreateBooleanValue(true)); models.Append(model); response.SetNamedValue(L"models", models);
                put(account, L"tokenSource", mode == L"signed-out" ? "none" : "fixture-only"); response.SetNamedValue(L"account", account);
                control_reply(id, response); if (mode == L"blocked-input") Sleep(30000); return;
            }
            if (subtype == "interrupt") {control_reply(id, response); if (mode != L"interrupt-hang") result(); return;}
            if (subtype == "set_model" || subtype == "set_permission_mode" || subtype == "apply_flag_settings") {control_reply(id, response); return;}
            put(response, L"message", "Unsupported fixture control"); control_reply(id, response, true); return;
        }
        if (type == "control_response") {
            const auto response = frame.GetNamedObject(L"response"); if (ClaudeProtocol::text(response, L"request_id") != pending) return;
            pending.clear();
            if (prompt == "unknown") {answer(ClaudeProtocol::text(response, L"subtype") == "error" ? "unsupported rejected" : "UNSAFE UNKNOWN RESPONSE"); return;}
            const auto decision = response.GetNamedObject(L"response");
            if (prompt == "question" && ClaudeProtocol::text(decision, L"behavior") == "allow") answer(ClaudeProtocol::text(decision.GetNamedObject(L"updatedInput").GetNamedObject(L"answers"), L"Which answer?"));
            else answer(ClaudeProtocol::text(decision, L"behavior"));
            return;
        }
        if (type != "user") return;
        previous = current; current = ClaudeProtocol::text(frame, L"uuid"); const auto message = frame.GetNamedObject(L"message");
        if (message.GetNamedValue(L"content").ValueType() != rpc_json::JsonValueType::String) {answer("image received"); return;}
        prompt = ClaudeProtocol::text(message, L"content");
        Object initialized; put(initialized, L"type", "system"); put(initialized, L"subtype", "init"); put(initialized, L"session_id", session); write(initialized);
        if (!previous.empty()) result(true, previous);
        Object lifecycle; put(lifecycle, L"type", "command_lifecycle"); put(lifecycle, L"command_uuid", current); put(lifecycle, L"state", "started"); write(lifecycle);
        if(mode==L"context"){
            const auto original=fixture_prompt::user_text(prompt);
            if(original=="wait")return;answer(prompt);return;
        }
        // Normal fixture controls inspect only the original user text; context mode echoes wire.
        prompt=std::string(fixture_prompt::user_text(prompt));
        if (prompt == "wait") return;
        if(mode==L"usage"){
            if(previous_assistant)write(previous_assistant);Object malformed,bad_message;put(malformed,L"type","assistant");put(malformed,L"session_id",session);put(bad_message,L"id","invalid-metric");bad_message.SetNamedValue(L"content",Array{});bad_message.SetNamedValue(L"usage",Object::Parse(LR"({"input_tokens":-1})"));malformed.SetNamedValue(L"message",bad_message);write(malformed);answer("usage reply");return;
        }
        if (prompt == "fail") {result(true); return;}
        if (prompt == "approval" || prompt == "file" || prompt == "question" || prompt == "unknown") {
            pending = "claude-request-你好"; Object request, value, input;
            put(request, L"type", "control_request"); put(request, L"request_id", pending); put(value, L"subtype", prompt == "unknown" ? "unknown_protocol" : "can_use_tool");
            put(value, L"tool_name", prompt == "question" ? "AskUserQuestion" : prompt == "file" ? "Edit" : "Bash"); put(value, L"tool_use_id", "fixture-tool");
            if (prompt == "question") {Array questions; Object q; put(q, L"question", "Which answer?"); questions.Append(q); input.SetNamedValue(L"questions", questions);}
            else if (prompt == "file") {put(input, L"file_path", "fixture.txt"); put(input, L"old_string", "before"); put(input, L"new_string", "after");}
            else put(input, L"command", "fixture command - never executed");
            value.SetNamedValue(L"input", input); request.SetNamedValue(L"request", value); write(request); return;
        }
        const auto native_id = "fixture-message-"+std::to_string(GetCurrentProcessId())+"-"+std::to_string(++message_count);
        Object start, native; put(native, L"id", native_id); start.SetNamedValue(L"message", native); event("message_start", start);
        Object block, initial; initial.SetNamedValue(L"index", Json::CreateNumberValue(0)); put(block, L"type", "text"); put(block, L"text", ""); initial.SetNamedValue(L"content_block", block); event("content_block_start", initial);
        Object delta, part; delta.SetNamedValue(L"index", Json::CreateNumberValue(0)); put(part, L"type", "text_delta"); put(part, L"text", prompt == "exit" ? "partial before exit" : "नमस्ते "); delta.SetNamedValue(L"delta", part); event("content_block_delta", delta);
        if (prompt == "exit") {exit = true; return;}
        put(part, L"text", "你好"); delta.SetNamedValue(L"delta", part); event("content_block_delta", delta);
        Object snapshot, complete, text; Array content; put(snapshot, L"type", "assistant"); put(snapshot, L"session_id", session); put(complete, L"id", native_id);
        put(text, L"type", "text"); put(text, L"text", "नमस्ते 你好"); content.Append(text); complete.SetNamedValue(L"content", content); snapshot.SetNamedValue(L"message", complete); write(snapshot); write(snapshot);
        put(part, L"text", "LATE"); delta.SetNamedValue(L"delta", part); event("content_block_delta", delta); result();
    };
    while (!exit && ReadFile(GetStdHandle(STD_INPUT_HANDLE), bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr) && count) framer.consume(std::string_view(bytes.data(), count), receive);
    return exit ? 7 : 0;
}

inline int claude_tests(const std::filesystem::path& report) {
    using namespace std::chrono_literals; using Kind = SessionEvent::Kind; int checks{};
    const auto check = [&](bool value, const char* message) {++checks; if (!value) throw std::runtime_error(message);};
    try {
        wchar_t executable[32768]{}; if (!GetModuleFileNameW(nullptr, executable, 32768)) throw std::runtime_error("Cannot locate the Claude fixture");
        const auto launch = [&](const wchar_t* mode = L"normal") {CodexLaunch value; value.executable = executable; value.cwd = value.executable.parent_path(); value.arguments = {L"--claude-session-fixture", mode}; value.interrupt_grace = 100ms;value.fixture_account_reviewed=true; return value;};
        const auto input = [](const char* body = "hello") {CodexTurn value; value.text = body; return value;};
        const auto has = [](const auto& events, Kind kind) {return std::any_of(events.begin(), events.end(), [&](const auto& event) {return event.kind == kind;});};
        const auto until = [&](ClaudeSession& session, auto test) {
            std::vector<SessionEvent> events; const auto deadline = std::chrono::steady_clock::now() + 5s;
            do {for (auto& event : session.take_events()) events.push_back(std::move(event)); if (test(events)) return events; Sleep(5);} while (std::chrono::steady_clock::now() < deadline);
            throw std::runtime_error("Claude fixture timed out");
        };
        const auto finished = [&](ClaudeSession& session) {return until(session, [&](const auto& events) {return has(events, Kind::completed) && !session.busy();});};
        const auto combined = [](const auto& events, Kind kind) {std::string output; for (const auto& event : events) if (event.kind == kind) output += event.text; return output;};
        ClaudeSession normal(launch()); check(normal.send(input()) && !normal.send(input("duplicate")), "Claude must reject a second direct send while busy");
        const auto first = finished(normal);
        check(!has(first, Kind::error) && combined(first, Kind::text_delta) == "नमस्ते 你好" && combined(first, Kind::text_complete) == "नमस्ते 你好", "Claude streaming/snapshots must retain Unicode without duplicate or late-delta corruption");
        check(std::any_of(first.begin(), first.end(), [](const auto& event) {return event.kind == Kind::session && event.id == "claude-fixture-session";}), "Claude must expose its actual native session identity");
        check(normal.send(input()), "an idle Claude session must accept its next input");
        check(!has(finished(normal), Kind::error), "late results from an older Claude input must not end the new turn");
        auto selected = input(); selected.model = "selected-model"; selected.effort = "high"; selected.service_tier = "fast"; selected.plan = true;
        check(normal.send(selected) && !has(finished(normal), Kind::error), "Claude must apply model, effort, speed and plan controls through its control channel");
        normal.refresh_models(); check(has(until(normal, [&](const auto& events) {return has(events, Kind::models);}), Kind::models), "refreshing a live Claude catalog must not reinitialize or terminate its conversation");
        ClaudeSession metadata(launch()); metadata.refresh_models();
        const auto models = until(metadata, [&](const auto& events) {return has(events, Kind::models);});
        check(!has(models, Kind::session) && !has(models, Kind::started), "Claude model discovery must not create or run a conversation");
        ClaudeSession signed_out(launch(L"signed-out")); signed_out.send(input());
        check(has(finished(signed_out), Kind::error), "Claude must report an explicitly missing account instead of pretending to be authenticated");
        for (const auto* kind : {"approval", "file", "question", "unknown"}) {
            ClaudeSession pending(launch()); pending.send(input(kind));
            if (std::string_view(kind) == "unknown") {check(combined(finished(pending), Kind::text_complete) == "unsupported rejected", "unknown Claude control requests must fail closed"); continue;}
            const auto requests = until(pending, [&](const auto& events) {return has(events, Kind::prompt);});
            const auto request = std::find_if(requests.begin(), requests.end(), [](const auto& event) {return event.kind == Kind::prompt;});
            if (std::string_view(kind) == "file") check(request->text.find("fixture.txt") != std::string::npos && request->text.find("after") != std::string::npos, "Claude file approval must include the proposed path and content");
            pending.respond(request->id, std::string_view(kind) == "question" ? "{\"answers\":{\"Which answer?\":{\"answers\":[\"fixture answer\"]}}}" : "{\"decision\":\"decline\"}");
            const auto answered = finished(pending);
            check(combined(answered, Kind::text_complete) == (std::string_view(kind) == "question" ? "fixture answer" : "deny") && has(answered, Kind::resolved), "Claude decisions and question answers must preserve their original request identity");
        }
        ClaudeSession queue(launch()); queue.send(input("wait")); until(queue, [&](const auto& events) {return has(events, Kind::started);});
        check(queue.queue(input("next"), "queue-id") && !queue.queue(input("duplicate"), "queue-id"), "Claude queues must retain distinct bounded delivery identities");
        queue.interrupt(); const auto stopped = finished(queue);
        check(combined(stopped, Kind::completed) == "interrupted" && queue.queue_paused() && queue.queued_count() == 1, "Stop must retain and pause Claude's queued drafts");
        check(queue.resume_queue(), "Claude's queue must resume only on explicit request");
        const auto resumed = finished(queue);
        check(std::any_of(resumed.begin(), resumed.end(), [](const auto& event) {return event.kind == Kind::input && event.id == "queue-id";}), "Claude must submit the retained queue entry exactly once after resume");
        for (const auto* mode : {L"interrupt-hang", L"blocked-input"}) {
            ClaudeSession stopping(launch(mode)); auto turn = input("wait"); if (std::wstring_view(mode) == L"blocked-input") turn.text = std::string(256 * 1024, 'x');
            stopping.send(std::move(turn)); until(stopping, [&](const auto& events) {return has(events, Kind::started);});
            const auto start = std::chrono::steady_clock::now(); stopping.interrupt();
            check(std::chrono::steady_clock::now() - start < 100ms && combined(finished(stopping), Kind::completed) == "interrupted", "Claude Stop must remain responsive even when its child ignores input or interrupt");
        }
        ClaudeSession exiting(launch()); exiting.send(input("exit")); const auto exited = finished(exiting);
        check(has(exited, Kind::error) && combined(exited, Kind::text_delta) == "partial before exit", "unexpected Claude exit must preserve partial output and explain failure");
        check(!normal.steer(input(), "unsupported"), "an unimplemented Claude live steer must be refused rather than falsely acknowledged");
        CodexTurn approval; approval.text = "text";
        const auto safe_args = ClaudeProtocol::arguments(approval, "id", false);
        check(std::find(safe_args.begin(), safe_args.end(), L"--allow-dangerously-skip-permissions") == safe_args.end(), "approval-mode Claude must never inherit a bypass-permissions capability");
        approval.access = AgentAccess::full_access; const auto full_args = ClaudeProtocol::arguments(approval, "id", true);
        check(std::find(full_args.begin(), full_args.end(), L"--allow-dangerously-skip-permissions") != full_args.end() && std::find(full_args.begin(), full_args.end(), L"--resume=id") != full_args.end(), "explicit full access and resume must use their intended native CLI flags");
        check(ClaudeProtocol::base64("f") == "Zg==" && ClaudeProtocol::base64("fo") == "Zm8=" && ClaudeProtocol::base64("foo") == "Zm9v", "Claude image encoding must preserve all base64 padding cases");
        {
            const auto folder=std::filesystem::temp_directory_path()/(L"coincide-claude-account-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));std::filesystem::create_directories(folder);
            struct Cleanup{std::filesystem::path path;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(path,ignored);}}cleanup{folder};
            auto scoped_launch=launch();scoped_launch.profile_directory=folder;ClaudeSession scoped(scoped_launch);scoped.send(input());const auto verified=finished(scoped);
            const auto scope=std::find_if(verified.begin(),verified.end(),[](const auto& value){return value.kind==Kind::account_scope;});const auto native=std::find_if(verified.begin(),verified.end(),[](const auto& value){return value.kind==Kind::session;});
            check(scope!=verified.end()&&native!=verified.end()&&scope<native&&scope->text.size()==64&&scope->id=="default","Claude must verify its current account before native session persistence or user delivery");
            const auto saved_scope=scope->text;std::ofstream(folder/L"account-email.txt")<<"another@example.invalid\n";
            scoped.queue(input("keep original account"),"scope-first");scoped.queue(input("retained original-account draft"),"scope-second");const auto blocked=finished(scoped);
            check(has(blocked,Kind::error)&&!has(blocked,Kind::started)&&!has(blocked,Kind::session)&&scoped.queue_paused()&&scoped.queued_count()==1,"Claude must pause queued work when native status reports another account, preserving remaining drafts");
            std::ofstream(folder/L"account-email.txt")<<"fixture@example.invalid\n";check(scoped.resume_queue(),"Claude must resume its retained original-account queue only after explicit action");const auto recovered=finished(scoped);check(!has(recovered,Kind::error)&&std::any_of(recovered.begin(),recovered.end(),[](const auto& value){return value.kind==Kind::input&&value.id=="scope-second";}),"Returning to the original Claude account must retain native conversation ownership and its queued input identity");
            std::ofstream(folder/L"account-email.txt")<<"another@example.invalid\n";
            auto scoped_resume=scoped_launch;scoped_resume.session_id="claude-fixture-session";scoped_resume.saved_profile_id="default";scoped_resume.saved_account_scope=saved_scope;ClaudeSession mismatch(scoped_resume);mismatch.send(input());const auto denied=finished(mismatch);
            check(has(denied,Kind::error)&&!has(denied,Kind::started)&&!has(denied,Kind::session),"Claude account mismatch must fail before constructing a native --resume stream process");
            auto unreviewed=launch();unreviewed.fixture_account_reviewed=false;ClaudeSession missing_gate(unreviewed);missing_gate.send(input());const auto rejected=finished(missing_gate);check(has(rejected,Kind::error)&&!has(rejected,Kind::started),"Claude's synthetic account review opt-in must never be assumed automatically");
            auto hung=launch(L"account-hang");hung.request_timeout=10s;ClaudeSession cancellable(hung);cancellable.send(input());Sleep(100);const auto start=std::chrono::steady_clock::now();cancellable.interrupt();const auto cancelled=finished(cancellable);check(combined(cancelled,Kind::completed)=="interrupted"&&std::chrono::steady_clock::now()-start<2s,"A stalled metadata-only auth check must stay cancellable before any user conversation begins");
            const auto api=ClaudeProtocol::Object::Parse(LR"({"loggedIn":true,"authMethod":"api_key","email":"fixture@example.invalid"})");check(AgentAccountBinding::claude_subject(api).empty(),"API-key credentials without nonsecret provider ownership metadata must not impersonate an OAuth account scope");
        }
        for(const auto* context:{"","SYNTHETIC-CURRENT-TOOLS"}){
            std::atomic_uint reads{};auto wrapped_launch=launch();wrapped_launch.tool_context=[&]{++reads;return std::string(context);};ClaudeSession wrapped(wrapped_launch);
            check(wrapped.send(input("approval")),"A normal owned Claude fixture must accept its approval input with current tool context");const auto pending=until(wrapped,[&](const auto& values){return has(values,Kind::prompt);});const auto request=std::find_if(pending.begin(),pending.end(),[](const auto& event){return event.kind==Kind::prompt;});
            check(wrapped.busy()&&!has(pending,Kind::completed)&&!has(pending,Kind::error),"Current tool context must preserve the normal Claude explicit approval barrier");
            wrapped.respond(request->id,"{\"decision\":\"decline\"}");const auto denied=finished(wrapped);
            check(has(denied,Kind::resolved)&&combined(denied,Kind::text_complete)=="deny"&&!has(denied,Kind::error),"A wrapped Claude normal approval must honor the owner's decline");
            check(wrapped.send(input("wait")),"A wrapped Claude wait control must remain interruptible");until(wrapped,[&](const auto& values){return has(values,Kind::started);});
            check(wrapped.queue(input("wrapped original queued draft"),"wrapped-claude-queue")&&wrapped.queued().front().turn.text=="wrapped original queued draft","Claude queued records must retain only the user's original text");wrapped.interrupt();
            check(combined(finished(wrapped),Kind::completed)=="interrupted"&&wrapped.queue_paused(),"Wrapped Claude Stop must retain and pause the original queued draft");check(wrapped.resume_queue(),"The wrapped Claude retained queue still requires explicit resume");const auto wrapped_resumed=finished(wrapped);
            check(!has(wrapped_resumed,Kind::error)&&reads==3&&std::any_of(wrapped_resumed.begin(),wrapped_resumed.end(),[](const auto& event){return event.kind==Kind::input&&event.id=="wrapped-claude-queue"&&event.text=="wrapped original queued draft";}),"Wrapped Claude resume must evaluate current context at delivery while preserving original input identity");
        }
        std::ofstream output(report); output << "PASS: " << checks << " Claude stream-json checks\n"; return output ? 0 : 2;
    } catch (const winrt::hresult_error& error) {std::ofstream(report) << "FAIL: " << winrt::to_string(error.message()) << '\n';}
      catch (const std::exception& error) {std::ofstream(report) << "FAIL: " << error.what() << '\n';}
    return 1;
}
} // namespace coincide
