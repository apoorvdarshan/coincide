#pragma once
#include <winsock2.h>
#include <ws2tcpip.h>
#include "../Runtime/OpenCodeSession.h"
#include <fstream>
#pragma comment(lib, "ws2_32.lib")

namespace coincide {
// A real native child, owned by the same Job machinery as the production server. It serves only
// synthetic HTTP/SSE contracts on a dynamic loopback port and never contacts an account or a model.
inline int opencode_http_fixture(std::wstring_view mode) {
    // The WinUI executable's entrypoint is already STA; pin MTA lifetime without changing that
    // apartment. Keeping MTA alive also prevents activation teardown between HTTP worker threads.
    CO_MTA_USAGE_COOKIE cookie{}; winrt::check_hresult(CoIncrementMTAUsage(&cookie));
    struct MTA {CO_MTA_USAGE_COOKIE cookie; ~MTA() {CoDecrementMTAUsage(cookie);}} mta{cookie};
    using Object = OpenCodeProtocol::Object; using Array = OpenCodeProtocol::Array; using Json = OpenCodeProtocol::Json;
    const auto put = [](Object value, const wchar_t* key, const std::string& text) {OpenCodeProtocol::put(value, key, text);};
    const auto text = [](const Object& value, const wchar_t* key) {return OpenCodeProtocol::text(value, key);};
    wchar_t password[256]{}; if (GetEnvironmentVariableW(L"OPENCODE_PASSWORD", password, 256) < 40 || GetEnvironmentVariableW(L"OPENCODE_SERVER_PASSWORD", nullptr, 0)) return 8;
    const auto encoded = [](const std::string& value) {
        static constexpr char chars[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; std::string output; unsigned bits{}, count{};
        for (const unsigned char byte : value) {bits = (bits << 8) | byte; count += 8; while (count >= 6) {count -= 6; output += chars[(bits >> count) & 63];}}
        if (count) output += chars[(bits << (6 - count)) & 63]; while (output.size() % 4) output += '='; return output;
    };
    const auto authorization = "Authorization: Basic " + encoded("opencode:" + winrt::to_string(password));
    WSADATA data{}; if (WSAStartup(MAKEWORD(2, 2), &data)) return 8;
    const auto listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); if (listener == INVALID_SOCKET) return 8;
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(listener, SOMAXCONN)) return 8;
    int size = sizeof(address); if (getsockname(listener, reinterpret_cast<sockaddr*>(&address), &size)) return 8;
    const auto announced = "server listening on http://127.0.0.1:" + std::to_string(ntohs(address.sin_port)) + "\n";
    DWORD written{}; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), announced.data(), static_cast<DWORD>(announced.size()), &written, nullptr);
    struct State {std::mutex mutex, stream_mutex; SOCKET stream{INVALID_SOCKET}; std::string current, previous, message, directory; unsigned sequence{}; bool settings{};};
    auto state = std::make_shared<State>(); const auto session_id = std::string("ses_fixture/你好"); const auto session_path = "/api/session/" + OpenCodeProtocol::encode(session_id);
    const auto send_all = [](SOCKET socket, const std::string& bytes) {
        std::size_t offset{}; while (offset < bytes.size()) {const auto count = send(socket, bytes.data() + offset, static_cast<int>(std::min<std::size_t>(65536, bytes.size() - offset)), 0); if (count <= 0) return false; offset += static_cast<std::size_t>(count);} return true;
    };
    const auto event = [=](const char* type, Object event_data) {
        Object value; put(value, L"type", type); value.SetNamedValue(L"data", event_data);
        const auto bytes = "data: " + winrt::to_string(value.Stringify()) + "\r\n\r\n";
        std::lock_guard lock(state->stream_mutex); if (state->stream != INVALID_SOCKET) send_all(state->stream, bytes);
    };
    const auto frame = [=] {Object value; put(value, L"sessionID", session_id); return value;};
    const auto finish = [=](const std::string& value) {
        auto response = frame(); put(response, L"assistantMessageID", state->message); response.SetNamedValue(L"ordinal", Json::CreateNumberValue(0)); put(response, L"text", value);
        event("session.text.ended", response); event("session.execution.succeeded", frame());
    };
    for (;;) {
        const auto client = accept(listener, nullptr, nullptr); if (client == INVALID_SOCKET) return 8;
        std::thread([=] {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            struct Apartment {~Apartment() {winrt::uninit_apartment();}} apartment;
            const auto close = [&] {shutdown(client, SD_BOTH); closesocket(client);};
            const auto respond = [&](unsigned status, const std::string& body = "{}", const char* extra = "") {
                send_all(client, "HTTP/1.1 " + std::to_string(status) + " Fixture\r\nContent-Type: application/json\r\nContent-Length: " + std::to_string(body.size())
                    + "\r\nConnection: close\r\n" + extra + "\r\n" + body); close();
            };
            try {
                std::string request; std::array<char, 8192> bytes{}; std::size_t header_end{};
                while ((header_end = request.find("\r\n\r\n")) == std::string::npos) {const auto count = recv(client, bytes.data(), static_cast<int>(bytes.size()), 0); if (count <= 0) {close(); return;} request.append(bytes.data(), count); if (request.size() > 65536) {respond(413); return;}}
                const auto headers = request.substr(0, header_end); const auto space = headers.find(' '), end = headers.find(' ', space + 1);
                const auto method = headers.substr(0, space), target = headers.substr(space + 1, end - space - 1);
                if (headers.find(authorization) == std::string::npos || headers.find("Cookie:") != std::string::npos || target.find("password") != std::string::npos) {respond(401); return;}
                std::size_t length{}; const auto content_length = headers.find("Content-Length:"); if (content_length != std::string::npos) length = std::stoull(headers.substr(content_length + 15));
                if (length > 64 * 1024 * 1024) {respond(413); return;}
                auto body = request.substr(header_end + 4);
                while (body.size() < length) {const auto count = recv(client, bytes.data(), static_cast<int>(bytes.size()), 0); if (count <= 0) {close(); return;} body.append(bytes.data(), count);}
                if (target == "/api/event") {
                    if (mode == L"bad-content-type") {send_all(client, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}"); close(); return;}
                    {std::lock_guard lock(state->stream_mutex); state->stream = client; send_all(client, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n: ready\r\n\r\n");}
                    while (recv(client, bytes.data(), static_cast<int>(bytes.size()), 0) > 0) {}
                    {std::lock_guard lock(state->stream_mutex); if (state->stream == client) state->stream = INVALID_SOCKET;}
                    close(); return;
                }
                if (target == "/api/info") {
                    if (mode == L"redirect") {respond(302, "{}", "Location: http://example.invalid/credentials-must-not-follow\r\n"); return;}
                    Object info; put(info, L"version", mode == L"old-version" ? "1.19.5" : "2.2.5"); info.SetNamedValue(L"pid", Json::CreateNumberValue(GetCurrentProcessId())); respond(200, winrt::to_string(info.Stringify())); return;
                }
                if (target.starts_with("/api/model?")) {
                    respond(200, R"({"data":[{"providerID":"fixture","id":"model","name":"Fixture Model","enabled":true,"variants":[{"id":"low"},{"id":"high"}],"capabilities":{"input":["text","image"]}},{"providerID":"fixture","id":"disabled","enabled":false}]})"); return;
                }
                const auto parsed = body.empty() ? Object{} : Object::Parse(winrt::to_hstring(body));
                if (mode == L"cancel-endpoints-hang" && (target.ends_with("/interrupt") || target.find("/inbox/") != std::string::npos)) {Sleep(30000); close(); return;}
                std::lock_guard lock(state->mutex);
                if (method == "POST" && target == "/api/session") {
                    state->directory = text(parsed.GetNamedObject(L"location", Object{}), L"directory");
                    if (state->directory.empty() || !parsed.GetNamedArray(L"permissions", Array{}).Size()) {respond(400); return;}
                    Object value, item; put(item, L"id", session_id); value.SetNamedValue(L"data", item); respond(200, winrt::to_string(value.Stringify())); return;
                }
                if (method == "GET" && target == session_path) {Object value, item, location; put(item, L"id", session_id); put(location, L"directory", state->directory); item.SetNamedValue(L"location", location); value.SetNamedValue(L"data", item); respond(200, winrt::to_string(value.Stringify())); return;}
                if (target == session_path + "/agent") {state->settings = text(parsed, L"agent") == "plan"; respond(204, ""); return;}
                if (target == session_path + "/model") {const auto model = parsed.GetNamedObject(L"model", Object{}); state->settings = state->settings && text(model, L"providerID") == "fixture" && text(model, L"id") == "model" && text(model, L"variant") == "high"; respond(204, ""); return;}
                if ((method == "PATCH" && target == session_path) || target == session_path + "/synthetic") {respond(204, ""); return;}
                if (target == session_path + "/interrupt") {respond(200, R"({"interrupted":true})"); if (mode != L"interrupt-hang") event("session.execution.interrupted", frame()); return;}
                if (target.starts_with(session_path + "/inbox/")) {respond(204, ""); return;}
                if (target.find("/permission/") != std::string::npos && target.ends_with("/reply")) {respond(204, ""); finish(text(parsed, L"decision")); return;}
                if (target.find("/form/") != std::string::npos) {
                    respond(204, ""); if (method == "DELETE") finish("form declined"); else finish(winrt::to_string(parsed.GetNamedObject(L"answer", Object{}).Stringify())); return;
                }
                if (target != session_path + "/prompt") {respond(404); return;}
                state->current = text(parsed, L"id"); const auto input = text(parsed, L"text");
                if (input == "admission-hang") {Sleep(30000); close(); return;}
                respond(204, "");
                if (!state->previous.empty()) {
                    auto stale = frame(); put(stale, L"assistantMessageID", state->previous); stale.SetNamedValue(L"ordinal", Json::CreateNumberValue(0)); put(stale, L"delta", "STALE"); event("session.text.delta", stale); event("session.execution.succeeded", frame());
                }
                auto delivered = frame(); put(delivered, L"inboxID", state->current); event("session.inbox.delivered", delivered); event("session.execution.started", frame());
                state->message = "assistant-"+std::to_string(GetCurrentProcessId())+"-"+std::to_string(++state->sequence);
                if(mode==L"context"){
                    const auto boundary=input.find("</coincide_current_tools>\n\n");const auto original=boundary==std::string::npos?input:input.substr(boundary+27);
                    if(original=="wait")return;finish(input);return;
                }
                if (!state->previous.empty()) {auto stale = frame(); put(stale, L"assistantMessageID", state->previous); stale.SetNamedValue(L"ordinal", Json::CreateNumberValue(0)); put(stale, L"delta", "STALE"); event("session.text.delta", stale);}
                if (input == "wait") return;
                if(mode==L"usage"){
                    const auto step=[&](const std::string& message,double input,const std::string& owner=""){auto data=frame();if(!owner.empty())put(data,L"sessionID",owner);put(data,L"assistantMessageID",message);auto tokens=Object::Parse(LR"({"input":10,"output":3,"reasoning":2,"cache":{"read":3,"write":2}})");tokens.SetNamedValue(L"input",Json::CreateNumberValue(input));data.SetNamedValue(L"tokens",tokens);data.SetNamedValue(L"cost",Json::CreateNumberValue(0.01));event("session.step.ended",data);};
                    if(!state->previous.empty())step(state->previous,99999);step(state->message,-1);step(state->message,99999,"another-session");step(state->message,10);step(state->message,10);auto cumulative=frame();cumulative.SetNamedValue(L"cost",Json::CreateNumberValue(25));event("session.usage.updated",cumulative);
                }
                if (input == "fail") {event("session.execution.failed", frame()); return;}
                if (input == "question" || input == "hiddenform") {
                    auto event_data = frame(); Object form, field, option; Array fields, options;
                    put(form, L"sessionID", session_id); put(form, L"id", "form/你好"); put(field, L"key", "choice"); put(field, L"type", "string"); put(field, L"title", "Which answer?");
                    if (input == "hiddenform") field.SetNamedValue(L"hidden", Json::CreateBooleanValue(true));
                    put(option, L"label", "Friendly label"); put(option, L"value", "native-value"); options.Append(option); field.SetNamedValue(L"options", options); fields.Append(field); form.SetNamedValue(L"fields", fields); event_data.SetNamedValue(L"form", form); event("form.created", event_data); return;
                }
                if (input == "approval") {auto pending = frame(); Object metadata; put(pending, L"id", "permission/你好"); put(pending, L"action", "shell"); put(metadata, L"command", "fixture command — never executed"); pending.SetNamedValue(L"metadata", metadata); event("permission.asked", pending); return;}
                auto response = frame(); put(response, L"assistantMessageID", state->message); response.SetNamedValue(L"ordinal", Json::CreateNumberValue(0));
                auto foreign = response; put(foreign, L"sessionID", "another-thread"); put(foreign, L"delta", "FOREIGN"); event("session.text.delta", foreign);
                // JsonObject is a reference type; create a fresh value after testing the foreign frame.
                response = frame(); put(response, L"assistantMessageID", state->message); response.SetNamedValue(L"ordinal", Json::CreateNumberValue(0));
                put(response, L"delta", input == "disconnect" ? "partial before disconnect" : "नमस्ते "); event("session.text.delta", response);
                if (input == "disconnect") {std::lock_guard stream_lock(state->stream_mutex); shutdown(state->stream, SD_BOTH); return;}
                if (input == "partial-wait") return;
                put(response, L"delta", "你好"); event("session.text.delta", response);
                put(response, L"text", input == "settings" ? (state->settings ? "settings okay" : "SETTINGS WRONG") : "नमस्ते 你好"); event("session.text.ended", response); event("session.text.ended", response);
                put(response, L"delta", "LATE"); event("session.text.delta", response); state->previous = state->message; event("session.execution.succeeded", frame());
            } catch (...) {respond(500);}
        }).detach();
    }
}

inline int opencode_tests(const std::filesystem::path& report) {
    using namespace std::chrono_literals; using Kind = SessionEvent::Kind; using Object = OpenCodeProtocol::Object;
    int checks{}; const auto check = [&](bool value, const char* message) {++checks; if (!value) throw std::runtime_error(message);};
    try {
        std::vector<std::string> decoded; OpenCodeSSE parser;
        const std::string wire = "\xef\xbb\xbf: ping\r\ndata: {\"text\":\"你好\"}\r\n\r\ndata: first\rdata: second\r\r";
        for (const auto byte : wire) parser.consume(std::string_view(&byte, 1), [&](auto value) {decoded.push_back(std::move(value));});
        check(decoded == std::vector<std::string>{"{\"text\":\"你好\"}", "first\nsecond"}, "SSE must survive split UTF-8, CRLF, bare CR, BOM and multiline data");
        bool invalid{}; try {OpenCodeSSE tiny(16); tiny.consume("data: " + std::string(30, 'x'), [](auto) {});} catch (const std::length_error&) {invalid = true;}
        check(invalid, "SSE must bound incomplete lines"); invalid = false;
        try {OpenCodeSSE bad; bad.consume("data: \xff\n\n", [](auto) {});} catch (const std::exception&) {invalid = true;}
        check(invalid, "SSE must reject malformed UTF-8 rather than replace bytes");
        check(OpenCodeProtocol::encode("/你好?& x") == "%2F%E4%BD%A0%E5%A5%BD%3F%26%20x", "API path/query segments must percent encode UTF-8 and separators");
        CodexTurn safe; safe.text = "hello"; safe.plan = true; const auto rules = OpenCodeProtocol::permissions(safe);
        check(rules.Size() == 4 && OpenCodeProtocol::text(rules.GetAt(3).GetObject(), L"effect") == "deny", "Plan must retain approval rules and end with an edit deny");
        safe.access = AgentAccess::full_access; check(OpenCodeProtocol::permissions(safe).Size() == 2, "Only explicit full access may create a wildcard allow, with Plan still denying edits");
        const auto form = Object::Parse(LR"({"id":"form","fields":[{"key":"pick","type":"multiselect","options":[{"label":"One","value":"1"},{"label":"Two","value":"2"}]},{"key":"number","type":"integer"},{"key":"yes","type":"boolean"}]})");
        check(OpenCodeProtocol::questions(form).has_value(), "Supported forms must retain typed field identities");
        const auto values = OpenCodeProtocol::form_answer(form, Object::Parse(LR"({"answers":{"pick":{"answers":["Two","One"]},"number":{"answers":["42"]},"yes":{"answers":["Yes"]}}})"));
        check(values.GetNamedArray(L"pick").GetAt(0).GetString() == L"2" && values.GetNamedNumber(L"number") == 42 && values.GetNamedBoolean(L"yes"), "Forms must map labels to values and preserve multiple selections, integers and booleans");
        invalid = false; try {OpenCodeProtocol::form_answer(form, Object::Parse(LR"({"answers":{"number":{"answers":["1.5"]}}})"));} catch (const std::invalid_argument&) {invalid = true;}
        check(invalid, "Invalid typed answers must leave the form pending");
        check(!OpenCodeProtocol::questions(Object::Parse(LR"({"id":"form","fields":[{"key":"x","type":"string","hidden":true}]})")), "Hidden forms must be declined, never silently answered");
        check(!OpenCodeProtocol::questions(Object::Parse(LR"({"id":"form","fields":[{"key":"x","type":"string","options":[{"label":"Same","value":"1"},{"label":"Same","value":"2"}]}]})")), "Ambiguous duplicate labels must not submit the wrong protocol value");
        wchar_t executable[32768]{}; if (!GetModuleFileNameW(nullptr, executable, 32768)) throw std::runtime_error("Cannot locate the OpenCode fixture");
        const auto launch = [&](const wchar_t* mode = L"normal") {CodexLaunch value; value.executable = executable; value.cwd = value.executable.parent_path(); value.arguments = {L"--opencode-http-fixture", mode}; value.request_timeout = 3s; value.interrupt_grace = 100ms; return value;};
        const auto input = [](const char* value = "hello") {CodexTurn turn; turn.text = value; return turn;};
        const auto has = [](const auto& events, Kind kind) {return std::any_of(events.begin(), events.end(), [&](const auto& event) {return event.kind == kind;});};
        const auto until = [&](OpenCodeSession& session, auto predicate) {
            std::vector<SessionEvent> events; const auto deadline = std::chrono::steady_clock::now() + 7s;
            do {for (auto& event : session.take_events()) events.push_back(std::move(event)); if (predicate(events)) return events; Sleep(5);} while (std::chrono::steady_clock::now() < deadline);
            std::string detail; for (const auto& event : events) detail += " [" + std::to_string(static_cast<int>(event.kind)) + ": " + event.text + "]";
            throw std::runtime_error("OpenCode fixture timed out: " + detail);
        };
        const auto finished = [&](OpenCodeSession& session) {return until(session, [&](const auto& events) {return has(events, Kind::completed) && !session.busy();});};
        const auto combined = [](const auto& events, Kind kind) {std::string result; for (const auto& event : events) if (event.kind == kind) result += event.text; return result;};
        OpenCodeSession normal(launch()); check(normal.send(input()) && !normal.send(input()), "OpenCode must reject concurrent direct submissions");
        const auto first = finished(normal);
        check(!has(first, Kind::error) && combined(first, Kind::text_delta) == "नमस्ते 你好" && combined(first, Kind::text_complete) == "नमस्ते 你好", "Native HTTP/SSE must stream Unicode and ignore duplicate finals, late deltas and foreign sessions");
        check(std::any_of(first.begin(), first.end(), [](const auto& event) {return event.kind == Kind::session && event.id == "ses_fixture/你好";}), "Only the actual server-assigned session ID may be exposed");
        check(normal.send(input()), "OpenCode must resume its idle native session"); const auto second = finished(normal);
        check(!has(second, Kind::error) && combined(second, Kind::text_delta) == "नमस्ते 你好", "Old assistant blocks and pre-delivery execution replays must not contaminate another turn");
        auto selected = input("settings"); selected.plan = true; selected.model = "fixture/model"; selected.effort = "high"; selected.access = AgentAccess::full_access;
        normal.send(selected); check(combined(finished(normal), Kind::text_complete) == "settings okay", "Existing sessions must receive native agent, model and reasoning settings before the next prompt");
        OpenCodeSession metadata(launch()); metadata.refresh_models(); const auto catalog = until(metadata, [&](const auto& events) {return has(events, Kind::models) || has(events, Kind::catalog_error);});
        check(has(catalog, Kind::models) && !has(catalog, Kind::started) && !has(catalog, Kind::session), "Catalog discovery must neither start a turn nor invent a conversation");
        const auto entries = CodexProtocol::catalog_entries(Object::Parse(winrt::to_hstring(combined(catalog, Kind::models))).GetNamedArray(L"data"));
        check(entries.size() == 1 && entries[0].model == "fixture/model" && entries[0].efforts.size() == 2 && entries[0].supports_images, "OpenCode catalogs must expose only enabled native models and advertised variants/modalities");
        for (const auto* kind : {"approval", "question"}) {
            OpenCodeSession pending(launch()); pending.send(input(kind)); const auto events = until(pending, [&](const auto& values) {return has(values, Kind::prompt) || has(values, Kind::completed);});
            const auto at = std::find_if(events.begin(), events.end(), [](const auto& event) {return event.kind == Kind::prompt;});
            check(at != events.end(), "Native OpenCode permission/forms must become explicit UI prompts");
            pending.respond(at->id, std::string_view(kind) == "question" ? R"({"answers":{"choice":{"answers":["Friendly label"]}}})" : R"({"decision":"decline"})");
            const auto answered = finished(pending); check(has(answered, Kind::resolved) && combined(answered, Kind::text_complete) == (std::string_view(kind) == "question" ? R"({"choice":"native-value"})" : "reject"), "Question/permission replies must preserve opaque IDs, native values and explicit rejection");
        }
        OpenCodeSession hidden(launch()); hidden.send(input("hiddenform")); check(combined(finished(hidden), Kind::text_complete) == "form declined", "Unrenderable forms must be explicitly declined with guidance");
        OpenCodeSession queue(launch()); queue.send(input("wait")); until(queue, [&](const auto& events) {return has(events, Kind::started);});
        check(queue.queue(input("next"), "queued") && !queue.queue(input("duplicate"), "queued"), "OpenCode queues must retain bounded unique delivery identities"); queue.interrupt();
        const auto stopped = finished(queue); check(combined(stopped, Kind::completed) == "interrupted" && queue.queue_paused() && queue.queued_count() == 1, "Stop must terminate only the owned server and retain queued drafts");
        check(queue.resume_queue(), "Retained OpenCode queues require explicit resume"); const auto resumed = finished(queue);
        if (has(resumed, Kind::error)) throw std::runtime_error("OpenCode queue resume failed: " + combined(resumed, Kind::error));
        check(std::count_if(resumed.begin(), resumed.end(), [](const auto& event) {return event.kind == Kind::input && event.id == "queued";}) == 1, "A restarted server must resume the same native session and deliver a queued draft once");
        for (const auto* mode : {L"normal", L"interrupt-hang", L"cancel-endpoints-hang"}) {
            OpenCodeSession stalled(launch(mode)); stalled.send(input(std::wstring_view(mode) == L"normal" ? "admission-hang" : "wait")); until(stalled, [&](const auto& events) {return has(events, Kind::started);});
            const auto before = std::chrono::steady_clock::now(); stalled.interrupt(); const auto stopped_events = finished(stalled);
            check(std::chrono::steady_clock::now() - before < 2s && combined(stopped_events, Kind::completed) == "interrupted", "Stop must remain bounded during admission stalls and unacknowledged interrupts");
        }
        {
            auto closing = std::make_unique<OpenCodeSession>(launch()); closing->send(input("partial-wait")); until(*closing, [&](const auto& events) {return has(events, Kind::text_delta);});
            const auto before = std::chrono::steady_clock::now(); closing.reset();
            check(std::chrono::steady_clock::now() - before < 2s, "Destruction must cancel an outstanding SSE read without retaining the session or its Job");
        }
        check(normal.send(input()) && !has(finished(normal), Kind::error), "Stopping/destructing one owned OpenCode server must leave a sibling session alive");
        OpenCodeSession disconnected(launch()); disconnected.send(input("disconnect")); const auto lost = finished(disconnected);
        check(has(lost, Kind::error) && combined(lost, Kind::completed) == "failed" && combined(lost, Kind::text_delta) == "partial before disconnect", "SSE loss must preserve partial text and fail honestly without replaying the prompt");
        for (const auto* mode : {L"old-version", L"redirect", L"bad-content-type"}) {
            OpenCodeSession rejected(launch(mode)); rejected.send(input()); const auto events = finished(rejected);
            check(has(events, Kind::error) && combined(events, Kind::completed) == "failed", "Legacy API, redirects and non-SSE responses must fail closed");
        }
        auto missing = launch(); missing.session_id = "missing/session?secret=not-a-token"; OpenCodeSession gone(missing); gone.send(input()); const auto absent = finished(gone);
        check(has(absent, Kind::error) && !has(absent, Kind::session), "A missing saved conversation must never be silently replaced");
        check(!normal.steer(input(), "unsupported"), "Unimplemented live steering must never be falsely acknowledged");
        std::ofstream output(report); output << "PASS: " << checks << " OpenCode native HTTP/SSE checks\n"; return output ? 0 : 2;
    } catch (const winrt::hresult_error& error) {std::ofstream(report) << "FAIL: " << winrt::to_string(error.message()) << '\n';}
      catch (const std::exception& error) {std::ofstream(report) << "FAIL after " << checks << " checks: " << error.what() << '\n';}
    return 1;
}
} // namespace coincide
