#pragma once
#include "OpenCodeProtocol.h"
#include "OpenCodeHTTP.h"
#include "WindowsProcess.h"
#include <bcrypt.h>
#include <objbase.h>
#include <condition_variable>
#include <cstdlib>
#include <cwctype>
#include <fstream>
#include <unordered_set>
#pragma comment(lib, "bcrypt.lib")

namespace coincide {
// OpenCode 2's native authenticated HTTP/SSE API. A thread owns its server Job, so Stop can bound a
// stalled request without terminating another thread. Native session IDs survive server restarts.
class OpenCodeSession : public AgentSession {
public:
    explicit OpenCodeSession(CodexLaunch launch) : launch_(std::move(launch)), worker_([this] {run();}) {}
    ~OpenCodeSession() override {shutdown();}
    bool send(CodexTurn turn) override {
        std::lock_guard lock(mutex_); if (stopping_ || active_ || !queued_.empty() || !valid(turn)) return false;
        input_ = std::move(turn); active_ = true; busy_ = true; cancel_ = false; paused_ = false; cv_.notify_one(); return true;
    }
    bool busy() const noexcept override {return busy_;}
    void interrupt() noexcept override {std::lock_guard lock(mutex_); paused_ = true; cancel_ = active_; if (!active_) busy_ = false; cv_.notify_one();}
    bool refresh_models() override {std::lock_guard lock(mutex_); if (stopping_) return false; refresh_ = true; cv_.notify_one(); return true;}
    bool queue(CodexTurn turn, std::string id) override {
        std::lock_guard lock(mutex_); const auto bytes = input_size(turn);
        if (stopping_ || !valid(turn) || id.empty() || id.size() > 1024 || deliveries_.contains(id) || queued_.size() >= 64 || bytes > limit - queued_bytes_) return false;
        emit_locked(Kind::queued, id, turn.text, "queued"); deliveries_.insert(id); queued_bytes_ += bytes; queued_.push_back({std::move(id), std::move(turn)});
        if (!paused_) busy_ = true; cv_.notify_one(); return true;
    }
    std::vector<AgentQueuedTurn> queued() const override {std::lock_guard lock(mutex_); return {queued_.begin(), queued_.end()};}
    std::size_t queued_count() const override {std::lock_guard lock(mutex_); return queued_.size();}
    bool queue_paused() const override {std::lock_guard lock(mutex_); return paused_;}
    bool remove_queued(const std::string& id) override {
        std::lock_guard lock(mutex_); const auto at = std::find_if(queued_.begin(), queued_.end(), [&](const auto& entry) {return entry.id == id;});
        if (at == queued_.end()) return false; emit_locked(Kind::queue_changed, id, {}, "removed");
        queued_bytes_ -= input_size(at->turn); retire_locked(id); queued_.erase(at); if (!active_ && (queued_.empty() || paused_)) busy_ = false; return true;
    }
    bool resume_queue() override {
        std::lock_guard lock(mutex_); if (stopping_ || queued_.empty()) return false;
        paused_ = false; busy_ = true; emit_locked(Kind::queue_changed, {}, {}, "resumed"); cv_.notify_one(); return true;
    }
    bool steer(CodexTurn, std::string) override {return false;}
    void respond(std::string id, std::string response) override {
        std::lock_guard lock(mutex_); if (answers_.size() >= 1024 || response.size() > limit) throw RpcError("The OpenCode answer queue is full");
        answers_.push_back({std::move(id), std::move(response)}); cv_.notify_one();
    }
    std::vector<SessionEvent> take_events() override {std::lock_guard lock(mutex_); auto result = std::move(events_); events_.clear(); event_bytes_ = 0; return result;}
    void close() noexcept override {stopping_ = true; cv_.notify_all();}
    void shutdown() noexcept override {close(); if (worker_.joinable()) worker_.join();}
private:
    using Object = OpenCodeProtocol::Object; using Array = OpenCodeProtocol::Array; using Json = OpenCodeProtocol::Json;
    using Kind = SessionEvent::Kind; using Clock = std::chrono::steady_clock;
    struct Cancelled {};
    struct Prompt {Object raw; bool form{};};
    static constexpr std::size_t limit = 64 * 1024 * 1024;
    CodexLaunch launch_;
    mutable std::mutex mutex_; std::condition_variable cv_;
    std::optional<CodexTurn> input_;
    std::deque<AgentQueuedTurn> queued_;
    std::unordered_set<std::string> deliveries_;
    std::unordered_set<std::string> current_usage_messages_,retired_usage_messages_;
    std::deque<std::string> retired_usage_history_;
    std::deque<std::string> delivery_history_;
    std::deque<std::pair<std::string, std::string>> answers_;
    std::vector<SessionEvent> events_;
    std::deque<std::string> server_lines_;
    std::size_t queued_bytes_{}, event_bytes_{}, line_bytes_{};
    bool active_{}, paused_{}, refresh_{};
    std::atomic<bool> stopping_{}, busy_{}, cancel_{}, overflow_{};
    std::unique_ptr<WindowsProcess> process_;
    std::unique_ptr<OpenCodeHTTP> stream_;
    OpenCodeSSE sse_;
    unsigned short port_{}; std::wstring authorization_;
    std::unordered_map<std::string, Prompt> prompts_;
    std::deque<std::pair<std::string, std::string>> declined_;
    std::unordered_set<std::string> blocks_, finalized_, retired_blocks_;
    std::deque<std::string> block_history_;
    std::string current_, directory_, failure_, outcome_;
    bool sent_{}, delivered_{}, execution_{}, done_{}, reference_added_{};
    std::thread worker_;
    static std::string text(const Object& value, const wchar_t* key) {return OpenCodeProtocol::text(value, key);}
    static void put(Object object, const wchar_t* key, const std::string& value) {OpenCodeProtocol::put(object, key, value);}
    static std::string uuid() {
        winrt::guid value{}; winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&value))); auto id = winrt::to_string(winrt::to_hstring(value));
        id.erase(std::remove(id.begin(), id.end(), '-'), id.end()); if (!id.empty() && id.front() == '{') id = id.substr(1, id.size() - 2); return id;
    }
    static std::string base64(const std::string& bytes) {
        static constexpr char digits[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"; std::string result;
        for (std::size_t index = 0; index < bytes.size(); index += 3) {
            const auto a = static_cast<unsigned char>(bytes[index]); const unsigned char b = index + 1 < bytes.size() ? static_cast<unsigned char>(bytes[index + 1]) : 0,
                c = index + 2 < bytes.size() ? static_cast<unsigned char>(bytes[index + 2]) : 0;
            result += digits[a >> 2]; result += digits[((a & 3) << 4) | (b >> 4)]; result += index + 1 < bytes.size() ? digits[((b & 15) << 2) | (c >> 6)] : '='; result += index + 2 < bytes.size() ? digits[c & 63] : '=';
        }
        return result;
    }
    static std::size_t input_size(const CodexTurn& turn) {auto bytes = turn.text.size(); if (bytes > limit) return limit + 1; for (const auto& path : turn.image_paths) {if (path.size() > limit - bytes) return limit + 1; bytes += path.size();} return bytes;}
    static bool valid(const CodexTurn& turn) {return (!turn.text.empty() || !turn.image_paths.empty()) && input_size(turn) <= limit;}
    void retire_locked(const std::string& id) {delivery_history_.push_back(id); if (delivery_history_.size() > 4096) {deliveries_.erase(delivery_history_.front()); delivery_history_.pop_front();}}
    void emit_locked(Kind kind, std::string id, std::string body, std::string detail = {}) {
        const auto bytes = id.size() + body.size() + detail.size();
        if (kind != Kind::error && kind != Kind::completed && kind != Kind::queue_changed && (events_.size() >= 65536 || bytes > limit - std::min(limit, event_bytes_))) throw RpcError("The OpenCode output queue is full");
        event_bytes_ += bytes;
        if (kind == Kind::text_delta && !events_.empty() && events_.back().kind == kind && events_.back().id == id) events_.back().text += body;
        else events_.push_back({kind, std::move(id), std::move(body), std::move(detail)});
    }
    void emit(Kind kind, std::string id = {}, std::string body = {}, std::string detail = {}) {std::lock_guard lock(mutex_); emit_locked(kind, std::move(id), std::move(body), std::move(detail));}
    void wait() {std::unique_lock lock(mutex_); cv_.wait_for(lock, std::chrono::milliseconds(10));}
    void stop_server() noexcept {
        stream_.reset(); if (process_) process_->stop(); process_.reset(); port_ = 0; authorization_.clear(); sse_ = OpenCodeSSE{};
        std::lock_guard lock(mutex_); server_lines_.clear(); line_bytes_ = 0; overflow_ = false;
    }
    std::string path() const {return "/api/session/" + OpenCodeProtocol::encode(launch_.session_id);}
    std::unique_ptr<OpenCodeHTTP> request(const std::string& method, const std::string& target, const std::string& body = {}, bool stream = false) {
        return std::make_unique<OpenCodeHTTP>(port_, authorization_, winrt::to_hstring(method).c_str(), winrt::to_hstring(target).c_str(), body, stream);
    }
    Object api(const std::string& method, const std::string& target, const Object& body = nullptr, bool permit_missing = false) {
        auto operation = request(method, target, body ? winrt::to_string(body.Stringify()) : ""); const auto deadline = Clock::now() + launch_.request_timeout;
        for (;;) {
            if (stopping_ || cancel_) throw Cancelled{};
            pump(); const auto response = operation->take();
            if (response.done) {
                if (response.error) throw RpcError("OpenCode loopback HTTP request failed (Windows error " + std::to_string(response.error) + ")");
                if (permit_missing && (response.status == 404 || response.status == 409)) return Object{};
                if (response.status < 200 || response.status >= 300) throw RpcError("OpenCode rejected the API request (HTTP " + std::to_string(response.status) + ")");
                if (response.body.empty()) return Object{};
                if (!OpenCodeSSE::valid_utf8(response.body)) throw RpcError("OpenCode returned invalid UTF-8");
                Object value{nullptr}; if (!Object::TryParse(winrt::to_hstring(response.body), value)) throw RpcError("OpenCode returned invalid API JSON"); return value;
            }
            if (Clock::now() >= deadline) throw RpcError(std::string("OpenCode loopback API ") + method + " request timed out during " +
                (target == "/api/info" ? "server info" : target.ends_with("/prompt") ? "prompt admission" : target.ends_with("/agent") ? "agent settings" : target.ends_with("/model") ? "model settings" : "session setup")); wait();
        }
    }
    void start_server() {
        if (process_ && !process_->wait(std::chrono::milliseconds(0))) return;
        stop_server(); std::string secret(32, '\0');
        if (BCryptGenRandom(nullptr, reinterpret_cast<PUCHAR>(secret.data()), static_cast<ULONG>(secret.size()), BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) throw RpcError("Could not generate OpenCode server authentication");
        auto password = base64(secret); std::replace(password.begin(), password.end(), '+', '-'); std::replace(password.begin(), password.end(), '/', '_');
        authorization_ = L"Basic " + std::wstring(winrt::to_hstring(base64("opencode:" + password)));
        const auto custom = !launch_.arguments.empty() && launch_.arguments != std::vector<std::wstring>{L"app-server"};
        const auto arguments = custom ? launch_.arguments : std::vector<std::wstring>{L"serve", L"--hostname=127.0.0.1", L"--port=0"};
        WindowsProcess::Environment environment{{L"OPENCODE_PASSWORD", std::wstring(winrt::to_hstring(password))}, {L"OPENCODE_SERVER_PASSWORD", std::nullopt}};
        process_ = WindowsProcess::start(launch_.executable, arguments, launch_.cwd, [this](std::string line) {
            std::lock_guard lock(mutex_); if (line.size() > 1024 * 1024 - std::min<std::size_t>(1024 * 1024, line_bytes_) || server_lines_.size() >= 1024) overflow_ = true;
            else {line_bytes_ += line.size(); server_lines_.push_back(std::move(line));} cv_.notify_one();
        }, environment);
        const auto deadline = Clock::now() + launch_.request_timeout;
        while (!port_) {
            if (stopping_ || cancel_) throw Cancelled{}; if (overflow_) throw RpcError("OpenCode startup output exceeded its limit");
            std::deque<std::string> lines; {std::lock_guard lock(mutex_); lines.swap(server_lines_); line_bytes_ = 0;}
            for (const auto& line : lines) {
                constexpr std::string_view prefix = "server listening on http://127.0.0.1:"; const auto at = line.find(prefix);
                if (at == std::string::npos) continue; const auto number = line.substr(at + prefix.size()); std::size_t end{}; const auto value = std::stoul(number, &end);
                if (!value || value > 65535 || number.find_first_not_of(" \r\n", end) != std::string::npos) throw RpcError("OpenCode advertised an invalid loopback address"); port_ = static_cast<unsigned short>(value);
            }
            if (process_->wait(std::chrono::milliseconds(0))) throw RpcError("OpenCode exited before its API was ready");
            if (Clock::now() >= deadline) throw RpcError("OpenCode did not start its loopback API in time"); if (!port_) wait();
        }
        const auto info = api("GET", "/api/info"); const auto version = text(info, L"version");
        if (version.empty() || std::strtol(version.c_str(), nullptr, 10) < 2 || info.GetNamedNumber(L"pid", 0) <= 0) throw RpcError("OpenCode 2 or newer is required for the Windows HTTP adapter");
        stream_ = request("GET", "/api/event", {}, true);
        const auto stream_deadline = Clock::now() + launch_.request_timeout;
        for (;;) {
            if (stopping_ || cancel_) throw Cancelled{};
            const auto state = stream_->take();
            for (const auto& chunk : state.chunks) sse_.consume(chunk, [this](std::string event) {receive(std::move(event));});
            if (state.done || state.error || (state.headers && state.status != 200)) throw RpcError("OpenCode could not open its event stream");
            if (state.headers) break;
            if (Clock::now() >= stream_deadline) throw RpcError("OpenCode event stream startup timed out"); wait();
        }
    }
    void connect(const CodexTurn& turn) {
        start_server(); directory_ = turn.cwd.empty() ? winrt::to_string(launch_.cwd.wstring()) : turn.cwd;
        if (!turn.service_tier.empty() && turn.service_tier != "default") throw RpcError("OpenCode does not advertise speed tiers through this API");
        if (turn.model.empty() && !turn.effort.empty()) throw RpcError("Select an OpenCode model before selecting its reasoning variant");
        if (launch_.session_id.empty()) {
            const auto created = api("POST", "/api/session", OpenCodeProtocol::create(turn, directory_)).GetNamedObject(L"data", Object{});
            launch_.session_id = text(created, L"id"); if (launch_.session_id.empty()) throw RpcError("OpenCode did not return a native session ID");
        } else {
            const auto existing = api("GET", path()).GetNamedObject(L"data", Object{});
            if (text(existing, L"id") != launch_.session_id) throw RpcError("The saved OpenCode conversation is unavailable; it was not replaced");
            const auto location = text(existing.GetNamedObject(L"location", Object{}), L"directory");
            if (!location.empty()) {
                auto actual = std::filesystem::path(winrt::to_hstring(location).c_str()).lexically_normal().generic_wstring();
                auto intended = std::filesystem::path(winrt::to_hstring(directory_).c_str()).lexically_normal().generic_wstring();
                std::transform(actual.begin(), actual.end(), actual.begin(), [](wchar_t value) {return static_cast<wchar_t>(std::towlower(value));});
                std::transform(intended.begin(), intended.end(), intended.begin(), [](wchar_t value) {return static_cast<wchar_t>(std::towlower(value));});
                if (actual != intended) throw RpcError("The saved OpenCode conversation belongs to another working directory");
            }
            Object permissions; permissions.SetNamedValue(L"permissions", OpenCodeProtocol::permissions(turn)); api("PATCH", path(), permissions);
            Object agent; put(agent, L"agent", turn.plan ? "plan" : "build"); api("POST", path() + "/agent", agent);
            if (!turn.model.empty()) {Object selected; selected.SetNamedValue(L"model", OpenCodeProtocol::model(turn)); api("POST", path() + "/model", selected);}
        }
        emit(Kind::session, launch_.session_id);
        if (!reference_added_ && !launch_.instructions.empty()) {
            Object reference; put(reference, L"text", launch_.instructions); put(reference, L"delivery", "steer"); reference.SetNamedValue(L"resume", Json::CreateBooleanValue(false));
            api("POST", path() + "/synthetic", reference); reference_added_ = true;
        }
    }
    Object prompt_body(const CodexTurn& turn) {
        Object body; put(body, L"id", current_); put(body, L"text", turn.text);
        Array files; std::size_t total{};
        if (turn.image_paths.size() > 64) throw RpcError("OpenCode image attachments exceed the local count limit");
        for (const auto& name : turn.image_paths) {
            const auto file = std::filesystem::absolute(std::filesystem::path(winrt::to_hstring(name).c_str()));
            if (file.wstring().starts_with(L"\\\\") || !std::filesystem::is_regular_file(file)) throw RpcError("An OpenCode local image attachment is unavailable");
            auto extension = file.extension().wstring();
            std::transform(extension.begin(), extension.end(), extension.begin(), [](wchar_t value) {return static_cast<wchar_t>(std::towlower(value));});
            if (extension != L".png" && extension != L".jpg" && extension != L".jpeg" && extension != L".gif" && extension != L".webp") throw RpcError("OpenCode image attachments must be PNG, JPEG, GIF or WebP");
            const auto size = std::filesystem::file_size(file);
            if (size > 8 * 1024 * 1024 || size > 16 * 1024 * 1024 - total) throw RpcError("OpenCode image attachments exceed the local size limit"); total += static_cast<std::size_t>(size);
            std::ifstream input(file, std::ios::binary); std::array<char, 16> signature{}; input.read(signature.data(), static_cast<std::streamsize>(signature.size()));
            const auto prefix = std::string(signature.data(), static_cast<std::size_t>(input.gcount()));
            if (!prefix.starts_with("\x89PNG\r\n\x1a\n") && !prefix.starts_with("GIF87a") && !prefix.starts_with("GIF89a")
                    && !(prefix.size() >= 3 && static_cast<unsigned char>(prefix[0]) == 0xff && static_cast<unsigned char>(prefix[1]) == 0xd8 && static_cast<unsigned char>(prefix[2]) == 0xff)
                    && !(prefix.size() >= 12 && prefix.starts_with("RIFF") && prefix.substr(8, 4) == "WEBP")) throw RpcError("An OpenCode attachment does not contain a supported image");
            // Percent encode path bytes, retaining separators. No network URI or query is accepted.
            auto generic = winrt::to_string(file.generic_wstring()); std::string uri = "file:///";
            for (const auto ch : generic) {if (ch == '/' || ch == ':') uri += ch; else uri += OpenCodeProtocol::encode(std::string_view(&ch, 1));}
            Object entry; put(entry, L"uri", uri); put(entry, L"name", winrt::to_string(file.filename().wstring())); files.Append(entry);
        }
        if (files.Size()) body.SetNamedValue(L"files", files); return body;
    }
    void permission(const Object& request_data) {
        const auto id = text(request_data, L"id"); if (id.empty() || prompts_.contains(id)) return;
        if (!sent_ || done_ || prompts_.size() >= 64) {declined_.push_back({"permission", id}); return;}
        Object normalized; const auto metadata = request_data.GetNamedObject(L"metadata", Object{}); const auto action = text(request_data, L"action");
        auto command = text(metadata, L"command"); if (command.empty()) command = action;
        for (const auto& raw : request_data.GetNamedArray(L"resources", Array{})) if (raw.ValueType() == rpc_json::JsonValueType::String) {command += "\n" + winrt::to_string(raw.GetString());}
        put(normalized, L"command", command); put(normalized, L"reason", text(request_data, L"message")); put(normalized, L"cwd", directory_);
        // Unknown permission types remain explicit approvals, with all resource/metadata detail visible.
        normalized.SetNamedValue(L"additionalPermissions", request_data); prompts_.emplace(id, Prompt{request_data, false});
        emit(Kind::prompt, winrt::to_string(Json::CreateStringValue(winrt::to_hstring(id)).Stringify()), winrt::to_string(normalized.Stringify()), "item/commandExecution/requestApproval");
    }
    void receive(std::string bytes) {
        Object event{nullptr}; if (!Object::TryParse(winrt::to_hstring(bytes), event)) throw RpcError("OpenCode emitted invalid event JSON");
        const auto type = text(event, L"type"); const auto data = event.GetNamedObject(L"data", Object{});
        if (type == "form.created") {
            const auto form = data.GetNamedObject(L"form", Object{}); if (text(form, L"sessionID") != launch_.session_id || launch_.session_id.empty()) return;
            const auto id = text(form, L"id"); if (id.empty() || prompts_.contains(id)) return;
            const auto question = OpenCodeProtocol::questions(form);
            if (!sent_ || done_ || !question || prompts_.size() >= 64) {declined_.push_back({"form", id}); return;}
            prompts_.emplace(id, Prompt{form, true}); emit(Kind::prompt, winrt::to_string(Json::CreateStringValue(winrt::to_hstring(id)).Stringify()), winrt::to_string(question->Stringify()), "item/tool/requestUserInput"); return;
        }
        if (type == "permission.replied" || type == "form.replied" || type == "form.cancelled") {
            const auto owner = text(data, L"sessionID"); if (!owner.empty() && owner != launch_.session_id) return;
            const auto id = text(data, type == "permission.replied" ? L"requestID" : L"id");
            if (prompts_.erase(id)) emit(Kind::resolved, winrt::to_string(Json::CreateStringValue(winrt::to_hstring(id)).Stringify())); return;
        }
        if (launch_.session_id.empty() || text(data, L"sessionID") != launch_.session_id) return;
        if (type == "permission.asked") {permission(data); return;}
        if (type == "session.deleted") throw RpcError("The OpenCode conversation was deleted; it was not replaced");
        if (!sent_ || done_) return;
        if (type == "session.inbox.delivered") {if (text(data, L"inboxID") == current_) delivered_ = true; return;}
        if (type == "session.inbox.cancelled" && text(data, L"inboxID") == current_) {done_ = true; outcome_ = "interrupted"; return;}
        if (type == "session.execution.started") {if (delivered_) execution_ = true; return;}
        if (type.starts_with("session.execution.") && execution_ && delivered_) {
            if (type == "session.execution.succeeded" || type == "session.execution.interrupted" || type == "session.execution.failed") {
                done_ = true; outcome_ = type == "session.execution.succeeded" ? "completed" : type == "session.execution.interrupted" ? "interrupted" : "failed";
                if (outcome_ == "failed") failure_ = "OpenCode could not finish this execution"; return;
            }
        }
        if (!execution_ || !delivered_) return;
        if(type=="session.step.ended"||type=="session.step.failed"||type=="session.usage.updated"){
            const auto message=text(data,L"assistantMessageID");if(!message.empty()&&retired_usage_messages_.contains(message))return;
            if(const auto usage=UsageProtocol::normalize([&]{return UsageProtocol::opencode(type,data);},launch_.session_id,current_)){if(!message.empty()){if(current_usage_messages_.size()>=65536&&!current_usage_messages_.contains(message))throw RpcError("OpenCode emitted too many usage identities");current_usage_messages_.insert(message);}emit(Kind::usage,current_,*usage,type);}return;
        }
        if (type == "session.step.started") {
            const auto model = data.GetNamedObject(L"model", Object{}); const auto provider = text(model, L"providerID"), id = text(model, L"id");
            if (!provider.empty() && !id.empty()) emit(Kind::status, {}, provider + "/" + id, "model"); return;
        }
        if (type == "session.text.delta" || type == "session.text.ended" || type == "session.reasoning.delta" || type == "session.reasoning.ended") {
            const auto message = text(data, L"assistantMessageID"); const auto ordinal = data.GetNamedNumber(L"ordinal", -1);
            if (message.empty() || ordinal < 0 || ordinal != std::trunc(ordinal) || ordinal > 1000000) return;
            const auto reasoning = type.starts_with("session.reasoning."); const auto block = message + (reasoning ? "/reasoning/" : "/text/") + std::to_string(static_cast<int>(ordinal));
            if (retired_blocks_.contains(block) || finalized_.contains(block)) return;
            if (blocks_.size() >= 65536 && !blocks_.contains(block)) throw RpcError("OpenCode streamed too many assistant blocks"); blocks_.insert(block);
            const auto item = current_ + "/" + block;
            if (type.ends_with(".ended")) {finalized_.insert(block); emit(reasoning ? Kind::tool : Kind::text_complete, item, text(data, L"text"), reasoning ? "reasoning" : "");}
            else emit(reasoning ? Kind::tool : Kind::text_delta, item, text(data, L"delta"), reasoning ? "reasoning" : ""); return;
        }
        if (type.starts_with("session.tool.")) emit(Kind::tool, current_ + "/tool/" + text(data, L"id"), winrt::to_string(data.Stringify()), type);
    }
    void pump() {
        if (overflow_) throw RpcError("OpenCode server output exceeded its limit");
        {std::lock_guard lock(mutex_); server_lines_.clear(); line_bytes_ = 0;}
        if (stream_) {
            auto state = stream_->take();
            for (const auto& chunk : state.chunks) sse_.consume(chunk, [this](std::string event) {receive(std::move(event));});
            if (state.done || state.error || (state.headers && state.status != 200)) throw RpcError("OpenCode's event stream disconnected; this request was not replayed");
            if (Clock::now() - state.activity > std::chrono::seconds(45)) throw RpcError("OpenCode's event stream stopped responding");
        }
        if (process_ && process_->wait(std::chrono::milliseconds(0))) throw RpcError("OpenCode's owned server exited; this request was not replayed");
    }
    void answers() {
        // Automatic declines never grant access and tell unsupported forms to ask in plain text.
        while (!declined_.empty()) {
            const auto [kind, id] = declined_.front(); declined_.pop_front();
            if (kind == "form") api("DELETE", path() + "/form/" + OpenCodeProtocol::encode(id) + "?message=" + OpenCodeProtocol::encode("This client cannot render that form. Ask the user in plain text instead."), nullptr, true);
            else {Object body; put(body, L"decision", "reject"); put(body, L"message", "Coincide cannot approve this request outside an active turn."); api("POST", path() + "/permission/" + OpenCodeProtocol::encode(id) + "/reply", body, true);}
        }
        std::deque<std::pair<std::string, std::string>> responses; {std::lock_guard lock(mutex_); responses.swap(answers_);}
        for (const auto& [raw_id, bytes] : responses) {
            const auto json = Json::Parse(winrt::to_hstring(raw_id)); if (json.ValueType() != rpc_json::JsonValueType::String) continue;
            const auto id = winrt::to_string(json.GetString()); const auto at = prompts_.find(id); if (at == prompts_.end()) continue;
            const auto pending = at->second; const auto response = Object::Parse(winrt::to_hstring(bytes)); Object body;
            try {
                if (pending.form) {
                    const auto value = OpenCodeProtocol::form_answer(pending.raw, response);
                    if (value.Size()) {body.SetNamedValue(L"answer", value); api("POST", path() + "/form/" + OpenCodeProtocol::encode(id) + "/reply", body, true);}
                    else api("DELETE", path() + "/form/" + OpenCodeProtocol::encode(id) + "?message=" + OpenCodeProtocol::encode("The user dismissed this question."), nullptr, true);
                } else {
                    const auto decision = text(response, L"decision");
                    if (decision != "accept" && decision != "decline" && decision != "cancel") throw std::invalid_argument("Unsupported OpenCode approval decision");
                    put(body, L"decision", decision == "accept" ? "once" : "reject");
                    if (decision == "decline") put(body, L"message", "The user declined this request. Do not retry it; continue without it or ask how to proceed.");
                    api("POST", path() + "/permission/" + OpenCodeProtocol::encode(id) + "/reply", body, true);
                    if (decision == "cancel") cancel_ = true;
                }
                if (prompts_.erase(id)) emit(Kind::resolved, raw_id);
            } catch (const std::invalid_argument& error) {emit(Kind::status, {}, error.what());}
        }
    }
    void cancel_remote() noexcept {
        try {
            if (port_ && !launch_.session_id.empty() && sent_) {
                auto interrupt = request("POST", path() + "/interrupt");
                auto withdraw = request("DELETE", path() + "/inbox/" + OpenCodeProtocol::encode(current_));
                const auto deadline = Clock::now() + launch_.interrupt_grace;
                while (Clock::now() < deadline) {if (interrupt->take().done && withdraw->take().done) break; wait();}
            }
        } catch (...) {}
        // Closing our Job is also the bounded fallback for an unacknowledged admission or Stop.
        stop_server();
    }
    void run_turn(CodexTurn turn) {
        current_ = "msg_coincide_" + uuid(); sent_ = delivered_ = execution_ = done_ = false; failure_.clear(); outcome_ = "failed"; blocks_.clear(); finalized_.clear();current_usage_messages_.clear();
        try {
            emit(Kind::status, {}, "Connecting to OpenCode…"); connect(turn); if (stopping_ || cancel_) throw Cancelled{};
            const auto adapted=with_current_tool_context(launch_,turn);if(stopping_||cancel_)throw Cancelled{};
            const auto body = prompt_body(adapted); sent_ = true; emit(Kind::started, current_); api("POST", path() + "/prompt", body);
            while (!done_) {if (stopping_ || cancel_) throw Cancelled{}; pump(); answers(); if (!done_) wait();}
            if (cancel_) throw Cancelled{};
            if (!failure_.empty()) emit(Kind::error, {}, failure_);
        } catch (const Cancelled&) {cancel_remote(); outcome_ = "interrupted";}
          catch (const winrt::hresult_error& error) {stop_server(); outcome_ = "failed"; emit(Kind::error, {}, winrt::to_string(error.message()));}
          catch (const std::exception& error) {stop_server(); outcome_ = "failed"; emit(Kind::error, {}, error.what());}
        for (const auto& block : blocks_) {retired_blocks_.insert(block); block_history_.push_back(block);}
        while (block_history_.size() > 65536) {retired_blocks_.erase(block_history_.front()); block_history_.pop_front();}
        for (const auto& [id, unused] : prompts_) {static_cast<void>(unused); emit(Kind::resolved, winrt::to_string(Json::CreateStringValue(winrt::to_hstring(id)).Stringify()));}
        for(const auto& id:current_usage_messages_)if(retired_usage_messages_.insert(id).second)retired_usage_history_.push_back(id);while(retired_usage_history_.size()>65536){retired_usage_messages_.erase(retired_usage_history_.front());retired_usage_history_.pop_front();}
        prompts_.clear(); declined_.clear(); emit(Kind::completed, current_, outcome_);
        std::lock_guard lock(mutex_); active_ = false;
        if (outcome_ != "completed") {paused_ = true; if (!queued_.empty()) emit_locked(Kind::queue_changed, {}, {}, "paused");}
        busy_ = !paused_ && !queued_.empty();
    }
    void run() noexcept {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded); struct Apartment {~Apartment() {winrt::uninit_apartment();}} apartment;
            while (!stopping_) {
                std::optional<CodexTurn> turn; bool refresh{};
                {std::unique_lock lock(mutex_); cv_.wait_for(lock, std::chrono::milliseconds(20), [&] {return stopping_ || input_ || refresh_ || (!paused_ && !queued_.empty());});
                    if (stopping_) break; if (input_) turn.swap(input_);
                    else if (refresh_) {refresh = true; refresh_ = false; cancel_ = false;}
                    else if (!paused_ && !queued_.empty()) {
                        emit_locked(Kind::input, queued_.front().id, queued_.front().turn.text, "queued"); auto next = std::move(queued_.front()); queued_.pop_front(); queued_bytes_ -= input_size(next.turn); retire_locked(next.id);
                        turn = std::move(next.turn); active_ = true; busy_ = true; cancel_ = false;
                    }}
                if (turn) run_turn(std::move(*turn));
                else if (refresh) {
                    try {start_server(); const auto directory = winrt::to_string(launch_.cwd.wstring());
                        const auto raw = api("GET", "/api/model?location%5Bdirectory%5D=" + OpenCodeProtocol::encode(directory)); emit(Kind::models, {}, winrt::to_string(OpenCodeProtocol::catalog(raw).Stringify()));}
                    catch (const Cancelled&) {stop_server(); emit(Kind::catalog_error, {}, "OpenCode model refresh was cancelled");}
                    catch (const winrt::hresult_error& error) {stop_server(); emit(Kind::catalog_error, {}, winrt::to_string(error.message()));}
                    catch (const std::exception& error) {stop_server(); emit(Kind::catalog_error, {}, error.what());}
                } else if (process_) {try {pump(); answers();} catch (...) {stop_server(); emit(Kind::status, {}, "OpenCode disconnected; the next turn will resume its saved conversation");}}
            }
        } catch (const winrt::hresult_error& error) {try {emit(Kind::error, {}, winrt::to_string(error.message())); emit(Kind::completed, {}, "failed");} catch (...) {}}
          catch (const std::exception& error) {try {emit(Kind::error, {}, error.what()); emit(Kind::completed, {}, "failed");} catch (...) {}}
          catch (...) {}
        stop_server(); std::lock_guard lock(mutex_); stopping_ = true; active_ = false; busy_ = false;
    }
};
} // namespace coincide
