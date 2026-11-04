#pragma once
#include "../Runtime/ACPSession.h"
#include "ProcessTests.h"
#include <fstream>
#include <winioctl.h>
#include <cstring>

namespace coincide {
inline int acp_session_fixture(std::wstring_view mode) {
    CO_MTA_USAGE_COOKIE cookie{}; winrt::check_hresult(CoIncrementMTAUsage(&cookie));
    struct MTA {CO_MTA_USAGE_COOKIE cookie; ~MTA() {CoDecrementMTAUsage(cookie);}} mta{cookie};
    using Object = ACPProtocol::Object; using Array = ACPProtocol::Array; using Json = ACPProtocol::Json;
    const auto text = [](const Object& value, const wchar_t* key) {return ACPProtocol::text(value, key);};
    const auto put = [](Object value, const wchar_t* key, const std::string& body) {ACPProtocol::put(value, key, body);};
    const auto write = [](Object value) {ACPProtocol::put(value, L"jsonrpc", "2.0"); fixture_write(GetStdHandle(STD_OUTPUT_HANDLE), winrt::to_string(value.Stringify()) + "\n");};
    const auto response = [&](rpc_json::IJsonValue id, Object value, bool error = false) {Object envelope; envelope.SetNamedValue(L"id", id); envelope.SetNamedValue(error ? L"error" : L"result", value); write(envelope);};
    const auto error = [&](rpc_json::IJsonValue id, const char* message) {Object value; value.SetNamedValue(L"code", Json::CreateNumberValue(-32602)); put(value, L"message", message); response(id, value, true);};
    const auto config = Object::Parse(LR"({"models":{"currentModelId":"fixture","availableModels":[{"modelId":"fixture","name":"Fixture","_meta":{"reasoningEfforts":[{"value":"low"},{"value":"high"}]}},{"modelId":"fixture-2","name":"Other Fixture"}]},"modes":{"currentModeId":"agent","availableModes":[{"id":"agent"},{"id":"plan"},{"id":"default"},{"id":"yolo"}]},"configOptions":[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"fixture","options":[{"value":"fixture","name":"Fixture"},{"value":"fixture-2","name":"Other"}]},{"id":"reasoning_effort","name":"Effort","category":"thought_level","type":"select","currentValue":"low","options":[{"value":"low"},{"value":"high"}]},{"id":"speed","name":"Speed","category":"speed","type":"select","currentValue":"default","options":[{"value":"default"},{"value":"fast"}]}]})");
    const std::string session = "fixture-acp-session"; std::string current, message, cwd, pending; unsigned sequence{};
    rpc_json::IJsonValue active{nullptr}; bool exit{};
    const auto update = [&](Object value, const std::string& owner = "") {Object params, frame, meta; put(params, L"sessionId", owner.empty() ? session : owner); params.SetNamedValue(L"update", value); put(meta, L"promptId", current); params.SetNamedValue(L"_meta", meta); put(frame, L"method", "session/update"); frame.SetNamedValue(L"params", params); write(frame);};
    const auto chunk = [&](const std::string& body, const std::string& owner = "", const std::string& id = "") {Object value, content; put(value, L"sessionUpdate", "agent_message_chunk"); put(value, L"messageId", id.empty() ? message : id); put(content, L"type", "text"); put(content, L"text", body); value.SetNamedValue(L"content", content); update(value, owner);};
    const auto finish = [&](const std::string& body) {
        chunk(body); Object result; if (mode != L"v2") put(result, L"stopReason", "end_turn"); response(active, result);
        if (mode == L"v2") {Object idle; put(idle, L"sessionUpdate", "state_update"); put(idle, L"state", "idle"); put(idle, L"stopReason", "end_turn"); update(idle);}
    };
    const auto request = [&](const char* method, Object params) {Object envelope; put(envelope, L"method", method); put(envelope, L"id", "acp-request-你好"); params.SetNamedValue(L"sessionId", Json::CreateStringValue(winrt::to_hstring(session))); envelope.SetNamedValue(L"params", params); write(envelope);};
    std::array<char, 4096> bytes{}; DWORD count{}; LineFramer framer;
    const auto receive = [&](const std::string& line) {
        const auto frame = Object::Parse(winrt::to_hstring(line)); if (text(frame, L"jsonrpc") != "2.0") {exit = true; return;}
        const auto method = text(frame, L"method"); const auto id = frame.GetNamedValue(L"id", Json::CreateNullValue()); const auto params = frame.GetNamedObject(L"params", Object{});
        if (method == "initialize") {
            const auto caps = params.GetNamedObject(L"clientCapabilities"); if (!caps.GetNamedBoolean(L"terminal", false) || !caps.GetNamedObject(L"fs").GetNamedBoolean(L"readTextFile", false)) {error(id, "Incorrect implemented capabilities"); return;}
            if (mode == L"environment") {wchar_t value[64]{}; GetEnvironmentVariableW(L"COINCIDE_ACP_FIXTURE", value, 64); if (std::wstring_view(value) != L"fixture-你好") {error(id, "Child environment did not arrive"); return;}}
            Object initialized, agent; initialized.SetNamedValue(L"protocolVersion", Json::CreateNumberValue(mode == L"v2" ? 2 : 1));
            if (mode == L"v2") {initialized.SetNamedValue(L"info", Object{}); Object capabilities; capabilities.SetNamedValue(L"session", Object{}); initialized.SetNamedValue(L"capabilities", capabilities);}
            else {agent.SetNamedValue(L"loadSession", Json::CreateBooleanValue(true)); Object image; image.SetNamedValue(L"image", Json::CreateBooleanValue(true)); agent.SetNamedValue(L"promptCapabilities", image); initialized.SetNamedValue(L"agentCapabilities", agent);}
            Object meta; meta.SetNamedValue(L"modelState", config.GetNamedObject(L"models")); initialized.SetNamedValue(L"_meta", meta); response(id, initialized); return;
        }
        if (method == "session/new" || method == "session/load" || method == "session/resume") {
            if (method != "session/new" && text(params, L"sessionId") != session) {error(id, "The saved fixture session is missing"); return;}
            cwd = text(params, L"cwd"); current.clear(); message = "replayed"; if (method != "session/new") chunk("OLD REPLAY");
            Object setup = Object::Parse(config.Stringify()); put(setup, L"sessionId", session); response(id, setup); return;
        }
        if (method == "session/set_mode" || method == "session/set_model") {response(id, Object{}); return;}
        if (method == "session/set_config_option") {
            const auto key = text(params, L"configId"), value = text(params, L"value"); for (const auto& raw : config.GetNamedArray(L"configOptions")) if (text(raw.GetObject(), L"id") == key) put(raw.GetObject(), L"currentValue", value);
            Object result; result.SetNamedValue(L"configOptions", config.GetNamedArray(L"configOptions")); response(id, result); return;
        }
        if (method == "session/cancel") return;
        if (method == "authenticate" || method == "auth/login") {exit = true; return;}
        if (method == "session/prompt") {
            active = id; current = text(params.GetNamedObject(L"_meta", Object{}), L"promptId"); message = "message-" + std::to_string(++sequence); std::string input;
            for (const auto& raw : params.GetNamedArray(L"prompt")) if (text(raw.GetObject(), L"type") == "text") input += text(raw.GetObject(), L"text");
            if (input == "wait") return;
            if (input == "exit") {chunk("partial before exit"); exit = true; return;}
            pending = input; Object call;
            if (input == "read" || input == "outside") {
                const auto root = std::filesystem::path(winrt::to_hstring(cwd).c_str()); const auto path = input == "read" ? root / L"read.txt" : root.parent_path() / L"outside.txt";
                put(call, L"path", winrt::to_string(path.wstring())); call.SetNamedValue(L"line", Json::CreateNumberValue(2)); call.SetNamedValue(L"limit", Json::CreateNumberValue(1)); request("fs/read_text_file", call); return;
            }
            if (input == "write") {put(call, L"path", winrt::to_string((std::filesystem::path(winrt::to_hstring(cwd).c_str()) / L"write.txt").wstring())); put(call, L"content", "approved 你好"); request("fs/write_text_file", call); return;}
            if (input == "terminal") {
                wchar_t path[32768]{}; GetModuleFileNameW(nullptr, path, 32768); put(call, L"command", winrt::to_string(path)); Array args; args.Append(Json::CreateStringValue(L"--acp-terminal-fixture")); args.Append(Json::CreateStringValue(L"normal")); call.SetNamedValue(L"args", args); request("terminal/create", call); return;
            }
            if (input == "permission") {
                Object tool; put(tool, L"title", "Synthetic fixture operation"); put(tool, L"kind", "execute"); call.SetNamedValue(L"toolCall", tool);
                call.SetNamedValue(L"options", Array::Parse(LR"([{"optionId":"allow","kind":"allow_once","name":"Allow once"},{"optionId":"persist","kind":"allow_always","name":"Always"},{"optionId":"deny","kind":"reject_once","name":"Decline"}])")); request("session/request_permission", call); return;
            }
            if (input == "question") {call.SetNamedValue(L"questions", Array::Parse(LR"([{"id":"pick","prompt":"Which answer?","options":[{"id":"native-choice","label":"Friendly label"}]}])")); request("cursor/ask_question", call); return;}
            if (input == "unknown") {request("unknown/operation", call); return;}
            chunk("FOREIGN", "other-thread"); if (sequence > 1) chunk("STALE", "", "message-1"); chunk("नमस्ते "); finish("你好"); return;
        }
        if (method.empty() && id.ValueType() == rpc_json::JsonValueType::String) {
            if (frame.HasKey(L"error")) {finish("denied"); return;}
            const auto result = frame.GetNamedObject(L"result", Object{});
            if (pending == "read") finish(text(result, L"content"));
            else if (pending == "write") finish("write accepted");
            else if (pending == "permission") finish(text(result.GetNamedObject(L"outcome", Object{}), L"optionId"));
            else if (pending == "question") finish(winrt::to_string(result.Stringify()));
            else if (pending == "terminal") {Object call; put(call, L"terminalId", text(result, L"terminalId")); pending = "terminal-wait"; request("terminal/wait_for_exit", call);}
            else if (pending == "terminal-wait") finish(result.GetNamedNumber(L"exitCode", -1) == 7 ? "terminal exited seven" : "wrong terminal exit");
            return;
        }
        if (!method.empty()) error(id, "Unsupported synthetic ACP request");
    };
    while (!exit && ReadFile(GetStdHandle(STD_INPUT_HANDLE), bytes.data(), static_cast<DWORD>(bytes.size()), &count, nullptr) && count) framer.consume(std::string_view(bytes.data(), count), receive);
    return exit ? 7 : 0;
}
inline int acp_terminal_fixture(std::wstring_view) {fixture_write(GetStdHandle(STD_OUTPUT_HANDLE), "terminal 你好\n"); fixture_write(GetStdHandle(STD_ERROR_HANDLE), "stderr fixture\n"); return 7;}

// A task-owned DOS drive alias reproduces runner TEMP spellings whose canonical path names another
// drive/long directory. No existing drive is changed, and the exact mapping is removed on every exit.
struct ACPTestDriveAlias {
    std::wstring drive, target;
    explicit ACPTestDriveAlias(const std::filesystem::path& folder) {
        target = L"\\??\\" + std::filesystem::canonical(folder).wstring();
        for (wchar_t letter = L'Z'; letter >= L'P'; --letter) {
            const auto candidate = std::wstring(1, letter) + L":"; wchar_t existing[32768]{};
            if (QueryDosDeviceW(candidate.c_str(), existing, 32768)) continue;
            if (GetLastError() != ERROR_FILE_NOT_FOUND) continue;
            if (DefineDosDeviceW(DDD_RAW_TARGET_PATH | DDD_NO_BROADCAST_SYSTEM, candidate.c_str(), target.c_str())) {drive = candidate; return;}
        }
        throw std::runtime_error("Could not create the isolated ACP drive-alias fixture");
    }
    ~ACPTestDriveAlias() {if (!drive.empty()) DefineDosDeviceW(DDD_REMOVE_DEFINITION | DDD_EXACT_MATCH_ON_REMOVE | DDD_RAW_TARGET_PATH | DDD_NO_BROADCAST_SYSTEM, drive.c_str(), target.c_str());}
    ACPTestDriveAlias(const ACPTestDriveAlias&) = delete;
    ACPTestDriveAlias& operator=(const ACPTestDriveAlias&) = delete;
};
inline void acp_test_junction(const std::filesystem::path& link, const std::filesystem::path& target) {
    std::filesystem::create_directory(link);
    NativeHandle handle(CreateFileW(link.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (handle.get() == INVALID_HANDLE_VALUE) throw std::runtime_error("Could not open the ACP junction fixture");
    struct Header {DWORD tag; WORD length, reserved, substitute_offset, substitute_length, print_offset, print_length;};
    static_assert(sizeof(Header) == 16);
    const auto print = std::filesystem::canonical(target).wstring(); const auto substitute = L"\\??\\" + print;
    const auto bytes = (substitute.size() + print.size() + 2) * sizeof(wchar_t);
    if (bytes > 16000) throw std::runtime_error("ACP junction fixture path is too long");
    std::vector<unsigned char> buffer(sizeof(Header) + bytes);
    const Header header{IO_REPARSE_TAG_MOUNT_POINT, static_cast<WORD>(bytes + 8), 0, 0, static_cast<WORD>(substitute.size() * sizeof(wchar_t)),
        static_cast<WORD>((substitute.size() + 1) * sizeof(wchar_t)), static_cast<WORD>(print.size() * sizeof(wchar_t))};
    std::memcpy(buffer.data(), &header, sizeof(header)); std::memcpy(buffer.data() + sizeof(header), substitute.c_str(), (substitute.size() + 1) * sizeof(wchar_t));
    std::memcpy(buffer.data() + sizeof(header) + (substitute.size() + 1) * sizeof(wchar_t), print.c_str(), (print.size() + 1) * sizeof(wchar_t));
    DWORD returned{};
    if (!DeviceIoControl(handle.get(), FSCTL_SET_REPARSE_POINT, buffer.data(), static_cast<DWORD>(buffer.size()), nullptr, 0, &returned, nullptr)) throw std::runtime_error("Could not create the ACP junction fixture");
}

inline int acp_tests(const std::filesystem::path& report) {
    using namespace std::chrono_literals; using Kind = SessionEvent::Kind; using Object = ACPProtocol::Object;
    int checks{}; const auto check = [&](bool value, const char* message) {++checks; if (!value) throw std::runtime_error(message);};
    const auto sandbox = std::filesystem::temp_directory_path() / (L"coincide-acp-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
    struct Cleanup {std::filesystem::path path; ~Cleanup() {std::error_code error; std::filesystem::remove_all(path, error);}} cleanup{sandbox};
    try {
        const auto root = sandbox / L"project"; std::filesystem::create_directories(root); std::ofstream(root / L"read.txt", std::ios::binary) << "first\r\n你好\nlast"; std::ofstream(sandbox / L"outside.txt") << "outside fixture";
        {
            ACPFileSystem files(root); check(files.read(winrt::to_string((root / L"read.txt").wstring())).find("你好") != std::string::npos, "ACP reads must retain project UTF-8 text");
            auto upper = (root / L"read.txt").wstring(); std::transform(upper.begin(), upper.end(), upper.begin(), [](wchar_t value) {return static_cast<wchar_t>(std::towupper(value));});
            check(files.read(winrt::to_string(upper)).find("你好") != std::string::npos, "ACP project drive and directory case must not change its identity");
            {
                ACPTestDriveAlias alias(sandbox); const auto aliased_root = std::filesystem::path(alias.drive + L"\\project"); ACPFileSystem aliased(aliased_root);
                check(aliased.read(winrt::to_string((aliased_root / L"read.txt").wstring())).find("你好") != std::string::npos, "ACP must read through its explicitly selected root alias after canonicalizing the project");
                aliased.write(winrt::to_string((aliased_root / L"alias write.txt").wstring()), "alias write");
                check(files.read(winrt::to_string((root / L"alias write.txt").wstring())) == "alias write", "Alias writes must remain inside the same pinned physical project");
                bool escaped{}; try {aliased.read(winrt::to_string((std::filesystem::path(alias.drive + L"\\outside.txt")).wstring()));} catch (const std::exception&) {escaped = true;}
                check(escaped, "Accepting a declared root alias must not grant its parent directory");
            }
            const auto outside = sandbox / L"outside directory"; std::filesystem::create_directory(outside); std::ofstream(outside / L"secret.txt") << "outside junction fixture";
            acp_test_junction(root / L"junction", outside);
            bool followed{}; try {files.read(winrt::to_string((root / L"junction" / L"secret.txt").wstring()));} catch (const std::exception&) {followed = true;}
            check(followed, "ACP must still refuse descendant junction reads after root-alias normalization");
            followed = false; try {files.write(winrt::to_string((root / L"junction" / L"secret.txt").wstring()), "unsafe");} catch (const std::exception&) {followed = true;}
            check(followed, "ACP must still refuse descendant junction writes after root-alias normalization");
            files.write(winrt::to_string((root / L"new folder" / L"literal & name.txt").wstring()), "written 你好");
            check(files.read(winrt::to_string((root / L"new folder" / L"literal & name.txt").wstring())) == "written 你好", "ACP writes must create literal paths without a shell");
            files.write(winrt::to_string((root / L"read.txt").wstring()), "first\r\n你好\nlast");
            for (const auto& path : std::vector<std::string>{"relative.txt", winrt::to_string((sandbox / L"outside.txt").wstring()), winrt::to_string((root / L".." / L"outside.txt").wstring()), winrt::to_string((root / L"read.txt:stream").wstring()), winrt::to_string((root / L"NUL.txt").wstring()), winrt::to_string((root / L"*.txt").wstring()), winrt::to_string((root / L"trailing.").wstring()), "\\\\server\\share\\file.txt"}) {
                bool refused{}; try {files.read(path);} catch (const std::exception&) {refused = true;} check(refused, "ACP must reject escapes, ADS, devices, wildcards, relative/remote and ambiguous paths");
            }
            const auto linked = root / L"hardlink.txt"; check(CreateHardLinkW(linked.c_str(), (sandbox / L"outside.txt").c_str(), nullptr) != FALSE, "The native hardlink regression fixture must be available");
            bool denied{}; try {files.read(winrt::to_string(linked.wstring()));} catch (const std::invalid_argument&) {denied = true;} check(denied, "Project-scope reads must reject an external hardlink");
        }
        const auto scope = AgentAccountScope::fingerprint("cursor", "fixture-account", "fixture-profile");
        check(scope.size() == 64 && scope == AgentAccountScope::fingerprint("cursor", "fixture-account", "fixture-profile"), "Non-secret account scope fingerprints must be stable");
        check(scope != AgentAccountScope::fingerprint("grok", "fixture-account", "fixture-profile"), "Account scope must isolate providers");
        bool mismatch{}; try {AgentAccountScope{"other", scope}.require_resume();} catch (const std::exception&) {mismatch = true;} check(mismatch, "Known account changes must refuse implicit conversation resume");
        mismatch = false; try {AgentAccountScope{"", scope}.require_resume();} catch (const std::exception&) {mismatch = true;} check(mismatch, "A missing current identity must not resume a known account's conversation");
        check(ACPProtocol::arguments("grok", AgentAccess::approval) == std::vector<std::wstring>{L"--permission-mode", L"default", L"agent", L"stdio"}, "Grok approval mode must explicitly override persistent always-approve defaults");
        check(ACPProtocol::arguments("cursor", AgentAccess::full_access) == std::vector<std::wstring>{L"--force", L"acp"}, "Only explicit full access may enable Cursor's force flag");
        wchar_t executable[32768]{}; GetModuleFileNameW(nullptr, executable, 32768);
        const auto launch = [&](const wchar_t* mode = L"normal") {CodexLaunch value; value.executable = executable; value.cwd = root; value.arguments = {L"--acp-session-fixture", mode}; value.request_timeout = 2s; return value;};
        const auto input = [](const char* body = "hello") {CodexTurn value; value.text = body; return value;};
        const auto has = [](const auto& events, Kind kind) {return std::any_of(events.begin(), events.end(), [&](const auto& event) {return event.kind == kind;});};
        const auto until = [&](ACPSession& session, auto predicate) {
            std::vector<SessionEvent> events; const auto deadline = std::chrono::steady_clock::now() + 6s;
            do {for (auto& event : session.take_events()) events.push_back(std::move(event)); if (predicate(events)) return events; Sleep(5);} while (std::chrono::steady_clock::now() < deadline);
            std::string failure; for (const auto& event : events) if (event.kind == Kind::error) failure += event.text; throw std::runtime_error("ACP fixture timed out: " + failure);
        };
        const auto finished = [&](ACPSession& session) {return until(session, [&](const auto& events) {return has(events, Kind::completed) && !session.busy();});};
        const auto combined = [](const auto& events, Kind kind) {std::string result; for (const auto& event : events) if (event.kind == kind) result += event.text; return result;};
        for (const auto* provider : {"cursor", "grok", "antigravity"}) {
            ACPSession session(provider, launch()); check(session.send(input()) && !session.send(input()), "ACP sessions must reject concurrent direct sends");
            const auto events = finished(session); check(!has(events, Kind::error) && combined(events, Kind::text_complete) == "नमस्ते 你好" && has(events, Kind::session), "Each ACP provider must stream Unicode through strict JSON-RPC 2.0 and expose its native session");
            session.send(input()); const auto again = finished(session);
            check(!has(again, Kind::error) && combined(again, Kind::text_complete) == "नमस्ते 你好",
                ("ACP replay/second-turn regression: " + combined(again, Kind::error) + " / " + combined(again, Kind::text_complete)).c_str());
        }
        ACPSession read("cursor", launch()); read.send(input("read")); check(combined(finished(read), Kind::text_complete) == "你好", "ACP client reads must honor one-based CRLF-safe line limits");
        read.send(input("outside")); check(combined(finished(read), Kind::text_complete) == "denied", "An agent cannot read outside its project by calling the client");
        for (const auto* operation : {"write", "permission", "question", "terminal"}) {
            ACPSession pending("cursor", launch()); pending.send(input(operation)); const auto events = until(pending, [&](const auto& values) {return has(values, Kind::prompt) || has(values, Kind::completed);});
            const auto at = std::find_if(events.begin(), events.end(), [](const auto& event) {return event.kind == Kind::prompt;}); check(at != events.end(), "Approval-mode writes, commands, questions and permissions must be explicit");
            pending.respond(at->id, std::string_view(operation) == "question" ? R"({"answers":{"pick":{"answers":["Friendly label"]}}})" : R"({"decision":"accept"})");
            const auto answered = finished(pending); check(!has(answered, Kind::error) && has(answered, Kind::resolved), "Native ACP request replies must preserve their opaque request IDs");
            if (std::string_view(operation) == "write") {std::ifstream written(root / L"write.txt", std::ios::binary); std::string value((std::istreambuf_iterator<char>(written)), {}); check(value == "approved 你好", "Client writes may happen only after approval");}
            if (std::string_view(operation) == "permission") check(combined(answered, Kind::text_complete) == "allow", "Approval must select allow_once, never a persistent allow_always option");
            if (std::string_view(operation) == "question") check(combined(answered, Kind::text_complete).find("native-choice") != std::string::npos, "Cursor displayed labels must map back to native option IDs");
            if (std::string_view(operation) == "terminal") check(combined(answered, Kind::text_complete) == "terminal exited seven", "Client terminal wait must return the real owned process exit status");
        }
        ACPLaunchOptions options; options.environment = {{L"COINCIDE_ACP_FIXTURE", L"fixture-你好"}}; ACPSession environment("grok", launch(L"environment"), options); environment.send(input()); check(!has(finished(environment), Kind::error), "ACP transport must apply per-child Unicode environment overrides");
        ACPSession metadata("grok", launch()); metadata.refresh_models(); const auto catalog = until(metadata, [&](const auto& events) {return has(events, Kind::models);});
        check(!has(catalog, Kind::started) && !has(catalog, Kind::session), "Initialize-only ACP catalog discovery must not create a session or prompt");
        ACPSession modern("antigravity", launch(L"v2")); modern.send(input()); check(!has(finished(modern), Kind::error), "ACP v2 must wait for both prompt acknowledgement and idle completion");
        ACPSession queue("grok", launch()); queue.send(input("wait")); until(queue, [&](const auto& events) {return has(events, Kind::started);}); queue.queue(input(), "queue-id"); queue.interrupt(); const auto stopped = finished(queue);
        check(combined(stopped, Kind::completed) == "interrupted" && queue.queue_paused() && queue.queued_count() == 1, "ACP Stop must own process cleanup while retaining queued drafts");
        queue.resume_queue(); const auto resumed = finished(queue); check(!has(resumed, Kind::error) && has(resumed, Kind::input), "ACP queue resume must reload the saved native session without replaying history");
        auto missing = launch(); missing.session_id = "missing"; ACPSession gone("cursor", missing); gone.send(input()); const auto failed = finished(gone);
        check(has(failed, Kind::error) && !has(failed, Kind::session), "A missing ACP saved session must fail instead of silently creating a replacement");
        ACPSession exiting("cursor", launch()); exiting.send(input("exit")); const auto ended = finished(exiting); check(has(ended, Kind::error) && combined(ended, Kind::text_complete) == "partial before exit", "Unexpected ACP exits must preserve partial finalized text and report failure");
        check(!read.steer(input(), "unsupported"), "Unavailable ACP live steering must not be falsely acknowledged");
        std::ofstream output(report); output << "PASS: " << checks << " ACP native contract checks\n"; return output ? 0 : 2;
    } catch (const winrt::hresult_error& error) {std::ofstream(report) << "FAIL after " << checks << " checks: " << winrt::to_string(error.message()) << '\n';}
      catch (const std::exception& error) {std::ofstream(report) << "FAIL after " << checks << " checks: " << error.what() << '\n';}
    return 1;
}
} // namespace coincide
