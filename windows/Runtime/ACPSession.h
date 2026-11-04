#pragma once
#include "ACPProtocol.h"
#include "ACPTerminals.h"
#include "AgentAccountScope.h"
#include "ClaudeProtocol.h"
#include "RpcConnection.h"
#include <condition_variable>
#include <unordered_set>

namespace coincide {
struct ACPLaunchOptions {
    AgentAccountScope account;
    std::vector<std::wstring> command_prefix;
    WindowsProcess::Environment environment;
};
// ACP v1 and the v2 acknowledgement/idle lifecycle, on the shared owned Windows JSON-RPC transport.
// Client filesystem/terminal requests always carry the native session identity. Approval mode asks
// before each write or command; Plan refuses them. No authentication method is invoked implicitly.
class ACPSession : public AgentSession {
public:
    ACPSession(std::string provider, CodexLaunch launch, ACPLaunchOptions options = {})
        : provider_(std::move(provider)), launch_(std::move(launch)), options_(std::move(options)), worker_([this] {run();}) {}
    ~ACPSession() override {shutdown();}
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
        emit_locked(Kind::queued, id, turn.text, "queued"); deliveries_.insert(id); queued_bytes_ += bytes; queued_.push_back({std::move(id), std::move(turn)}); if (!paused_) busy_ = true; cv_.notify_one(); return true;
    }
    std::vector<AgentQueuedTurn> queued() const override {std::lock_guard lock(mutex_); return {queued_.begin(), queued_.end()};}
    std::size_t queued_count() const override {std::lock_guard lock(mutex_); return queued_.size();}
    bool queue_paused() const override {std::lock_guard lock(mutex_); return paused_;}
    bool remove_queued(const std::string& id) override {
        std::lock_guard lock(mutex_); const auto at = std::find_if(queued_.begin(), queued_.end(), [&](const auto& entry) {return entry.id == id;});
        if (at == queued_.end()) return false; emit_locked(Kind::queue_changed, id, {}, "removed"); queued_bytes_ -= input_size(at->turn); retire_locked(id); queued_.erase(at);
        if (!active_ && (queued_.empty() || paused_)) busy_ = false; return true;
    }
    bool resume_queue() override {std::lock_guard lock(mutex_); if (stopping_ || queued_.empty()) return false; paused_ = false; busy_ = true; emit_locked(Kind::queue_changed, {}, {}, "resumed"); cv_.notify_one(); return true;}
    bool steer(CodexTurn, std::string) override {return false;}
    void respond(std::string id, std::string response) override {
        std::lock_guard lock(mutex_); if (answers_.size() >= 1024 || response.size() > limit - answer_bytes_) throw RpcError("The ACP answer queue is full");
        answer_bytes_ += response.size(); answers_.push_back({std::move(id), std::move(response)}); cv_.notify_one();
    }
    std::vector<SessionEvent> take_events() override {std::lock_guard lock(mutex_); auto result = std::move(events_); events_.clear(); event_bytes_ = 0; return result;}
    void close() noexcept override {stopping_ = true; cv_.notify_all();}
    void shutdown() noexcept override {close(); if (worker_.joinable()) worker_.join();}
private:
    using Object = ACPProtocol::Object; using Array = ACPProtocol::Array; using Json = ACPProtocol::Json; using Kind = SessionEvent::Kind; using Clock = std::chrono::steady_clock;
    struct Cancelled {};
    struct Incoming {std::string id, method, body; bool closed{};};
    struct Prompt {std::string method, kind; Object params, form;};
    static constexpr std::size_t limit = 64 * 1024 * 1024;
    std::string provider_; CodexLaunch launch_; ACPLaunchOptions options_;
    mutable std::mutex mutex_; std::condition_variable cv_;
    std::optional<CodexTurn> input_; std::deque<AgentQueuedTurn> queued_; std::unordered_set<std::string> deliveries_; std::deque<std::string> delivery_history_;
    std::deque<std::pair<std::string, std::string>> answers_; std::deque<Incoming> incoming_; std::vector<SessionEvent> events_;
    std::size_t queued_bytes_{}, event_bytes_{}, incoming_bytes_{}, answer_bytes_{}; bool active_{}, paused_{}, refresh_{};
    std::atomic<bool> stopping_{}, busy_{}, cancel_{}, overflow_{};
    std::unique_ptr<RpcConnection> connection_; std::unique_ptr<ACPFileSystem> files_; std::unique_ptr<ACPTerminals> terminals_;
    std::optional<CodexTurn> live_; Object initialized_{nullptr}, setup_{nullptr};
    AgentAccess process_access_{AgentAccess::approval};
    std::unordered_map<std::string, Prompt> prompts_;
    std::string current_, segment_, segment_text_, segment_message_, build_mode_, failure_, idle_reason_;
    std::unordered_set<std::string> current_messages_, finalized_messages_, retired_messages_; std::deque<std::string> retired_order_;
    unsigned segment_number_{}; bool sent_{}, generation_two_{}, idle_{}, reference_added_{};
    std::thread worker_;
    static std::string text(const Object& value, const wchar_t* key) {return ACPProtocol::text(value, key);}
    static void put(Object value, const wchar_t* key, const std::string& body) {ACPProtocol::put(value, key, body);}
    static std::string uuid() {winrt::guid id{}; winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&id))); return winrt::to_string(winrt::to_hstring(id));}
    static std::size_t input_size(const CodexTurn& turn) {auto bytes = turn.text.size(); if (bytes > limit) return limit + 1; for (const auto& path : turn.image_paths) {if (path.size() > limit - bytes) return limit + 1; bytes += path.size();} return bytes;}
    static bool valid(const CodexTurn& turn) {return (!turn.text.empty() || !turn.image_paths.empty()) && input_size(turn) <= limit;}
    void retire_locked(const std::string& id) {delivery_history_.push_back(id); if (delivery_history_.size() > 4096) {deliveries_.erase(delivery_history_.front()); delivery_history_.pop_front();}}
    void emit_locked(Kind kind, std::string id, std::string body, std::string detail = {}) {
        const auto bytes = id.size() + body.size() + detail.size();
        if (kind != Kind::error && kind != Kind::completed && kind != Kind::queue_changed && (events_.size() >= 65536 || bytes > limit - std::min(limit, event_bytes_))) throw RpcError("The ACP output queue is full");
        event_bytes_ += bytes;
        if (kind == Kind::text_delta && !events_.empty() && events_.back().kind == kind && events_.back().id == id) events_.back().text += body;
        else events_.push_back({kind, std::move(id), std::move(body), std::move(detail)});
    }
    void emit(Kind kind, std::string id = {}, std::string body = {}, std::string detail = {}) {std::lock_guard lock(mutex_); emit_locked(kind, std::move(id), std::move(body), std::move(detail));}
    void enqueue(Incoming value) {
        const auto size = value.id.size() + value.method.size() + value.body.size(); std::lock_guard lock(mutex_);
        if (incoming_.size() >= 65536 || size > limit - incoming_bytes_) overflow_ = true; else {incoming_bytes_ += size; incoming_.push_back(std::move(value));} cv_.notify_one();
    }
    void wait() {std::unique_lock lock(mutex_); cv_.wait_for(lock, std::chrono::milliseconds(10));}
    void flush_segment() {
        if (segment_.empty()) return;
        emit(Kind::text_complete, segment_, segment_text_); if (!segment_message_.empty()) finalized_messages_.insert(segment_message_);
        segment_.clear(); segment_text_.clear(); segment_message_.clear();
    }
    void stop_process() noexcept {
        if (terminals_) terminals_->stop(); terminals_.reset();
        connection_.reset(); files_.reset(); live_.reset(); initialized_ = nullptr; setup_ = nullptr;
        std::lock_guard lock(mutex_); incoming_.clear(); incoming_bytes_ = 0; overflow_ = false;
    }
    Object request(const std::string& method, const Object& params) {
        if (!connection_) throw RpcError("The ACP agent is not connected");
        auto future = connection_->call(method, winrt::to_string(params.Stringify()), launch_.request_timeout);
        for (;;) {if (stopping_ || cancel_) throw Cancelled{}; pump(); if (future.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {const auto result = Object::Parse(winrt::to_hstring(future.get())); pump(); return result;} wait();}
    }
    void publish_models() {
        if (!initialized_) return; const auto value = ACPProtocol::catalog(setup_ ? setup_ : Object{}, initialized_);
        if (value.GetNamedArray(L"data").Size()) emit(Kind::models, {}, winrt::to_string(value.Stringify()));
    }
    void launch(AgentAccess access) {
        stop_process(); files_ = std::make_unique<ACPFileSystem>(launch_.cwd); terminals_ = std::make_unique<ACPTerminals>(*files_);
        const auto custom = !launch_.arguments.empty() && launch_.arguments != std::vector<std::wstring>{L"app-server"}; auto arguments = launch_.arguments;
        if (!custom) {arguments = options_.command_prefix; const auto provider_arguments = ACPProtocol::arguments(provider_, access); arguments.insert(arguments.end(), provider_arguments.begin(), provider_arguments.end());}
        connection_ = std::make_unique<RpcConnection>(launch_.executable, arguments, launch_.cwd,
            [this](auto method, auto body) {enqueue({{}, std::move(method), std::move(body), false});},
            [this](auto id, auto method, auto body) {enqueue({std::move(id), std::move(method), std::move(body), false});},
            [this](auto body) {enqueue({{}, {}, std::move(body), true});}, options_.environment, true);
        initialized_ = request("initialize", ACPProtocol::initialize(provider_));
        const auto version = initialized_.GetNamedNumber(L"protocolVersion", 0);
        if (version != 1 && version != 2) throw RpcError("This ACP protocol version is not supported");
        generation_two_ = initialized_.HasKey(L"capabilities") || initialized_.HasKey(L"info"); process_access_ = access; publish_models();
    }
    void select_config(const Object& option, const std::string& value) {
        bool supported{}; for (const auto& raw : ACPProtocol::choices(option.GetNamedArray(L"options", Array{}))) if (text(raw.GetObject(), L"value") == value) supported = true;
        if (!supported) throw RpcError("This ACP setting value is not advertised by the current account");
        if (text(option, L"currentValue") == value) return;
        Object params; put(params, L"sessionId", launch_.session_id); put(params, L"configId", text(option, L"id")); put(params, L"value", value);
        const auto result = request("session/set_config_option", params);
        if (result.HasKey(L"configOptions")) setup_.SetNamedValue(L"configOptions", result.GetNamedArray(L"configOptions"));
        else for (const auto& raw : setup_.GetNamedArray(L"configOptions", Array{})) if (text(raw.GetObject(), L"id") == text(option, L"id")) put(raw.GetObject(), L"currentValue", value);
    }
    void set_mode(const std::string& value) {
        if (value.empty()) return;
        if (const auto config = ACPProtocol::config(setup_, "mode", "mode")) {select_config(*config, value); return;}
        const auto modes = setup_.GetNamedObject(L"modes", Object{}); if (text(modes, L"currentModeId") == value) return; bool supported{};
        for (const auto& raw : modes.GetNamedArray(L"availableModes", Array{})) if (text(raw.GetObject(), L"id") == value) supported = true;
        if (!supported) throw RpcError("This ACP interaction mode is not advertised by the agent");
        Object params; put(params, L"sessionId", launch_.session_id); put(params, L"modeId", value); request("session/set_mode", params); put(modes, L"currentModeId", value);
    }
    void configure(const CodexTurn& turn) {
        const auto catalog = CodexProtocol::catalog_entries(ACPProtocol::catalog(setup_, initialized_).GetNamedArray(L"data"));
        if (!turn.model.empty()) {
            const auto found = std::find_if(catalog.begin(), catalog.end(), [&](const auto& value) {return value.model == turn.model;});
            if (found == catalog.end()) throw RpcError("Choose a model advertised by this ACP account");
            if (provider_ == "grok" || !ACPProtocol::config(setup_, "model", "model")) {
                Object params; put(params, L"sessionId", launch_.session_id); put(params, L"modelId", turn.model);
                if (!turn.effort.empty()) {if (std::find(found->efforts.begin(), found->efforts.end(), turn.effort) == found->efforts.end()) throw RpcError("This reasoning level is not advertised by the ACP model"); Object meta; put(meta, L"reasoningEffort", turn.effort); params.SetNamedValue(L"_meta", meta);}
                request("session/set_model", params);
            } else select_config(*ACPProtocol::config(setup_, "model", "model"), turn.model);
        }
        if (!turn.effort.empty() && provider_ != "grok") {
            const auto option = ACPProtocol::config(setup_, "thought_level", "reasoning_effort"); if (!option) throw RpcError("This ACP agent does not advertise reasoning settings"); select_config(*option, turn.effort);
        }
        if (!turn.service_tier.empty() && turn.service_tier != "default") {
            const auto option = ACPProtocol::config(setup_, "speed", "speed"); if (!option) throw RpcError("This ACP agent does not advertise speed settings"); select_config(*option, turn.service_tier);
        }
        auto modes = setup_.GetNamedObject(L"modes", Object{}); auto current = text(modes, L"currentModeId");
        if (const auto config = ACPProtocol::config(setup_, "mode", "mode")) current = text(*config, L"currentValue");
        if (build_mode_.empty() && current != "plan" && current != "architect") build_mode_ = current;
        std::vector<std::string> available;
        if (const auto config = ACPProtocol::config(setup_, "mode", "mode")) for (const auto& raw : ACPProtocol::choices(config->GetNamedArray(L"options", Array{}))) available.push_back(text(raw.GetObject(), L"value"));
        else for (const auto& raw : modes.GetNamedArray(L"availableModes", Array{})) available.push_back(text(raw.GetObject(), L"id"));
        const auto offers = [&](const char* value) {return std::find(available.begin(), available.end(), value) != available.end();};
        if (turn.plan && (offers("plan") || offers("architect"))) set_mode(offers("plan") ? "plan" : "architect");
        else if (turn.plan && (current == "yolo" || current == "bypassPermissions")) {if (!offers("default")) throw RpcError("This ACP agent cannot enter a safe Plan mode"); set_mode("default");}
        else if (!turn.plan && !build_mode_.empty()) set_mode(build_mode_);
        if (!turn.plan && provider_ == "antigravity") {
            const auto target = turn.access == AgentAccess::full_access ? "yolo" : "default"; if (offers(target)) set_mode(target);
            else if (turn.access == AgentAccess::approval && (current == "yolo" || current == "bypassPermissions")) throw RpcError("The saved ACP mode bypasses approvals and cannot be reset safely");
        }
    }
    void connect(const CodexTurn& turn) {
        if (!launch_.session_id.empty()) options_.account.require_resume();
        const auto process_access = turn.plan ? AgentAccess::approval : turn.access;
        if (connection_ && process_access_ != process_access) stop_process();
        if (!connection_) launch(process_access);
        if (!live_) {
            auto params = ACPProtocol::session(launch_.session_id, winrt::to_string(files_->root().wstring())); std::string method = "session/new";
            if (!launch_.session_id.empty()) {
                const auto caps = initialized_.GetNamedObject(L"agentCapabilities", Object{}); const auto session_caps = caps.GetNamedObject(L"sessionCapabilities", Object{});
                if (generation_two_ || (provider_ == "antigravity" && session_caps.HasKey(L"resume"))) method = "session/resume";
                else if (caps.GetNamedBoolean(L"loadSession", false)) method = "session/load";
                else throw RpcError("This ACP agent cannot reopen the saved conversation; it was not replaced");
            }
            setup_ = request(method, params); const auto id = text(setup_, L"sessionId");
            if (launch_.session_id.empty()) {if (id.empty()) throw RpcError("ACP session/new returned no native session ID"); launch_.session_id = id;}
            else if (!id.empty() && id != launch_.session_id) throw RpcError("ACP returned a different conversation identity while resuming");
            if (options_.account.saved.empty() && !options_.account.current.empty()) options_.account.saved = options_.account.current;
            emit(Kind::session, launch_.session_id); publish_models(); live_ = turn;
        }
        configure(turn); live_ = turn;
    }
    Array prompt(const CodexTurn& turn) {
        auto adapted = turn;
        if (turn.plan) adapted.text = "<coincide_instructions>Plan mode: investigate with read-only actions and return a concrete plan. Do not write files or execute the implementation.</coincide_instructions>\n\n" + adapted.text;
        if (!reference_added_ && !launch_.instructions.empty()) adapted.text = launch_.instructions + "\n\n" + adapted.text;
        const auto source = ClaudeProtocol::user_message(adapted, current_).GetNamedObject(L"message"); Array result;
        const auto content = source.GetNamedValue(L"content");
        if (content.ValueType() == rpc_json::JsonValueType::String) {Object block; put(block, L"type", "text"); block.SetNamedValue(L"text", content); result.Append(block);}
        else for (const auto& raw : content.GetArray()) {
            const auto block = raw.GetObject(); if (text(block, L"type") == "text") result.Append(block);
            else {
                const auto capabilities = initialized_.GetNamedObject(L"agentCapabilities", Object{}).GetNamedObject(L"promptCapabilities", Object{});
                if (!capabilities.GetNamedBoolean(L"image", false) && provider_ != "grok" && provider_ != "antigravity") throw RpcError("This ACP agent does not advertise image input");
                Object image; put(image, L"type", "image"); const auto encoded = block.GetNamedObject(L"source"); put(image, L"mimeType", text(encoded, L"media_type")); put(image, L"data", text(encoded, L"data")); result.Append(image);
            }
        }
        return result;
    }
    bool owned(const Object& params) const {return !launch_.session_id.empty() && text(params, L"sessionId") == launch_.session_id;}
    void client_request(const Incoming& frame, const Object& params) {
        if (!connection_) return;
        const auto reject = [&](const char* message, int code = -32602) {connection_->reject(frame.id, message, code);};
        if (!owned(params)) {reject("The ACP request does not belong to this conversation"); return;}
        if (!sent_ || !live_) {reject("No ACP user turn is active"); return;}
        const auto method = frame.method;
        try {
            if (method == "fs/read_text_file") {
                auto body = files_->read(text(params, L"path")); const auto first = params.GetNamedNumber(L"line", 1), count = params.GetNamedNumber(L"limit", 4294967295.0);
                if (!std::isfinite(first) || !std::isfinite(count) || first < 0 || count < 0 || first != std::trunc(first) || count != std::trunc(count)) throw std::invalid_argument("Invalid ACP file line range");
                if (params.HasKey(L"line") || params.HasKey(L"limit")) {
                    const auto start = std::min<double>(first > 0 ? first - 1 : 0, 4294967295.0), amount = std::min<double>(count, 4294967295.0); std::size_t begin{}, end{}; double line{};
                    while (line < start && begin < body.size()) {const auto next = body.find('\n', begin); begin = next == std::string::npos ? body.size() : next + 1; ++line;}
                    end = begin; line = 0; while (line < amount && end < body.size()) {const auto next = body.find('\n', end); if (next == std::string::npos) {end = body.size(); break;} end = next + 1; ++line;}
                    if (end > begin && end <= body.size() && body[end - 1] == '\n') --end; body = body.substr(begin, end - begin);
                }
                Object result; put(result, L"content", body); connection_->respond(frame.id, winrt::to_string(result.Stringify())); return;
            }
            if (method.starts_with("terminal/") && method != "terminal/create") {
                if (auto result = terminals_->request(method, params, frame.id)) connection_->respond(frame.id, winrt::to_string(result->Stringify())); return;
            }
            if (method == "fs/write_text_file" || method == "terminal/create") {
                if (live_->plan) {reject("Plan mode does not permit file writes or terminal commands"); return;}
                if (method == "fs/write_text_file") {
                    if (params.GetNamedValue(L"content", Json::CreateNullValue()).ValueType() != rpc_json::JsonValueType::String) throw std::invalid_argument("ACP writes require an explicit text content field");
                    files_->literal(text(params, L"path")); if (text(params, L"content").size() > ACPFileSystem::max_bytes) throw std::invalid_argument("ACP write exceeds its size limit");
                }
                else {ACPTerminals::resolve(text(params, L"command")); files_->working_directory(text(params, L"cwd"));}
                if (live_->access == AgentAccess::full_access) {execute(frame.id, method, params); return;}
                Object normalized; put(normalized, L"cwd", winrt::to_string(files_->root().wstring()));
                if (method == "fs/write_text_file") {
                    Object preview, change; Array changes; put(change, L"path", text(params, L"path")); put(change, L"diff", text(params, L"content")); changes.Append(change); preview.SetNamedValue(L"changes", changes); normalized.SetNamedValue(L"fileChangePreview", preview);
                } else {
                    auto command = quote_windows_argument(ACPFileSystem::wide(text(params, L"command")));
                    for (const auto& arg : params.GetNamedArray(L"args", Array{})) command += L" " + quote_windows_argument(arg.GetString()); put(normalized, L"command", winrt::to_string(command));
                    normalized.SetNamedValue(L"additionalPermissions", params); // includes the exact cwd/env overrides being authorized
                }
                ask(frame, Prompt{method, "client", params, nullptr}, normalized, method == "fs/write_text_file" ? "item/fileChange/requestApproval" : "item/commandExecution/requestApproval"); return;
            }
            if (method == "session/request_permission") {
                if (live_->access == AgentAccess::full_access && !live_->plan) {connection_->respond(frame.id, winrt::to_string(ACPProtocol::permission(params, true).Stringify())); return;}
                const auto tool = params.GetNamedObject(L"toolCall", Object{}); const auto kind = text(tool, L"kind");
                if (live_->plan && kind != "read" && kind != "search" && kind != "fetch" && kind != "think") {connection_->respond(frame.id, winrt::to_string(ACPProtocol::permission(params, false).Stringify())); return;}
                Object normalized; put(normalized, L"command", text(tool, L"title")); normalized.SetNamedValue(L"additionalPermissions", params);
                Array available; if (text(ACPProtocol::permission(params, true).GetNamedObject(L"outcome"), L"outcome") == "selected") available.Append(Json::CreateStringValue(L"accept"));
                available.Append(Json::CreateStringValue(L"decline")); available.Append(Json::CreateStringValue(L"cancel")); normalized.SetNamedValue(L"availableDecisions", available);
                ask(frame, Prompt{method, "permission", params, nullptr}, normalized, "item/commandExecution/requestApproval"); return;
            }
            auto question_kind = method == "cursor/ask_question" ? "cursor" : (method == "elicitation/create" || method == "session/elicitation/create") ? "elicitation"
                : (method == "_x.ai/ask_user_question" || method == "x.ai/ask_user_question") ? "grok" : "";
            if (*question_kind) {
                const auto form = ACPProtocol::question_form(question_kind, params);
                if (!form) {reject("This ACP form cannot be represented safely", -32601); return;}
                ask(frame, Prompt{method, question_kind, params, *form}, *OpenCodeProtocol::questions(*form), "item/tool/requestUserInput"); return;
            }
            reject("This ACP client extension is not implemented", -32601);
        } catch (const std::exception& error) {connection_->reject(frame.id, error.what(), -32602);}
          catch (const winrt::hresult_error&) {reject("Invalid ACP client request parameters");}
    }
    void ask(const Incoming& frame, Prompt pending, const Object& normalized, const char* detail) {
        if (prompts_.size() >= 64 || prompts_.contains(frame.id)) {connection_->reject(frame.id, "Too many ACP requests are pending", -32603); return;}
        flush_segment(); prompts_.emplace(frame.id, std::move(pending)); emit(Kind::prompt, frame.id, winrt::to_string(normalized.Stringify()), detail);
    }
    void execute(const std::string& id, const std::string& method, const Object& params) {
        if (method == "fs/write_text_file") {files_->write(text(params, L"path"), text(params, L"content")); connection_->respond(id, "{}");}
        else connection_->respond(id, winrt::to_string(terminals_->create(params).Stringify()));
    }
    void answer() {
        std::deque<std::pair<std::string, std::string>> answers; {std::lock_guard lock(mutex_); answers.swap(answers_); answer_bytes_ = 0;}
        for (const auto& [id, bytes] : answers) {
            const auto at = prompts_.find(id); if (at == prompts_.end()) continue; const auto pending = at->second;
            try {
                const auto response = Object::Parse(winrt::to_hstring(bytes));
                if (pending.kind == "client" || pending.kind == "permission") {
                    const auto decision = text(response, L"decision"); if (decision != "accept" && decision != "decline" && decision != "cancel") throw std::invalid_argument("Unsupported ACP approval decision");
                    if (pending.kind == "permission") connection_->respond(id, winrt::to_string((decision == "cancel" ? ACPProtocol::cancelled() : ACPProtocol::permission(pending.params, decision == "accept")).Stringify()));
                    else if (decision == "accept") execute(id, pending.method, pending.params);
                    else connection_->reject(id, "The user declined this ACP operation", -32000);
                    if (decision == "cancel") cancel_ = true;
                } else connection_->respond(id, winrt::to_string(ACPProtocol::question_reply(pending.kind, pending.form, response).Stringify()));
                prompts_.erase(id); emit(Kind::resolved, id);
            } catch (const std::invalid_argument& error) {emit(Kind::status, {}, error.what());}
              catch (const winrt::hresult_error&) {emit(Kind::status, {}, "The ACP answer could not be parsed; the question is still pending");}
        }
    }
    void notification(const std::string& method, const Object& params) {
        if (method != "session/update" && method != "_x.ai/session_notification" && method != "x.ai/session_notification" && method != "_x.ai/session/update") return;
        if (!owned(params)) return; const auto update = params.GetNamedObject(L"update", Object{}); const auto type = text(update, L"sessionUpdate");
        if (type == "config_option_update") {if (setup_) {setup_.SetNamedValue(L"configOptions", update.GetNamedArray(L"configOptions", Array{})); publish_models();} return;}
        if (!sent_) return;
        const auto meta = params.GetNamedObject(L"_meta", Object{}); const auto prompt_id = text(meta, L"promptId"); if (!prompt_id.empty() && prompt_id != current_) return;
        if (type == "state_update" && text(update, L"state") == "idle") {idle_ = true; idle_reason_ = text(update, L"stopReason"); if (update.HasKey(L"error")) failure_ = "The ACP agent could not finish this turn"; return;}
        if (type == "agent_message_chunk" || type == "agent_message") {
            const auto message = text(update, L"messageId"); if (!message.empty() && (retired_messages_.contains(message) || finalized_messages_.contains(message))) return;
            if (!message.empty() && !segment_message_.empty() && message != segment_message_) flush_segment();
            std::string body; const auto content = update.GetNamedValue(L"content", Json::CreateNullValue());
            if (content.ValueType() == rpc_json::JsonValueType::Object) body = text(content.GetObject(), L"text");
            else if (content.ValueType() == rpc_json::JsonValueType::Array) for (const auto& raw : content.GetArray()) if (raw.ValueType() == rpc_json::JsonValueType::Object) body += text(raw.GetObject(), L"text");
            if (body.empty()) return; if (body.size() > limit - segment_text_.size()) throw RpcError("The ACP assistant segment is too large");
            if (segment_.empty()) {segment_ = current_ + "/message/" + std::to_string(++segment_number_); segment_message_ = message;}
            if (!message.empty()) current_messages_.insert(message); segment_text_ += body; emit(Kind::text_delta, segment_, body); return;
        }
        if (type == "tool_call" || type == "tool_call_update" || type == "tool_call_content_chunk" || type == "agent_thought_chunk" || type == "agent_thought") {
            flush_segment(); emit(Kind::tool, current_ + "/tool/" + text(update, L"toolCallId"), winrt::to_string(update.Stringify()), type); return;
        }
        if (type == "plan" || type == "plan_update" || type == "notice" || type == "usage_update") emit(Kind::tool, current_ + "/" + type, winrt::to_string(update.Stringify()), type);
    }
    void pump() {
        if (overflow_) throw RpcError("The ACP input queue exceeded its limit");
        std::deque<Incoming> frames; {std::lock_guard lock(mutex_); frames.swap(incoming_); incoming_bytes_ = 0;}
        for (const auto& frame : frames) {
            if (frame.closed) throw RpcError(frame.body);
            const auto params = Object::Parse(winrt::to_hstring(frame.body));
            if (frame.id.empty()) notification(frame.method, params); else client_request(frame, params);
        }
        if (terminals_) for (const auto& [id, result] : terminals_->completed()) connection_->respond(id, winrt::to_string(result.Stringify()));
        answer();
    }
    void cancel_remote() noexcept {
        try {if (connection_ && sent_ && !launch_.session_id.empty()) {Object params; put(params, L"sessionId", launch_.session_id); if (provider_ == "grok") {Object meta; put(meta, L"cancelTrigger", "ctrl_c"); params.SetNamedValue(L"_meta", meta);} connection_->notify("session/cancel", winrt::to_string(params.Stringify()));}}
        catch (...) {}
        // The owned Job also stops provider-native tools and pending client terminal Jobs.
        stop_process();
    }
    void run_turn(CodexTurn turn) {
        sent_ = idle_ = false; idle_reason_.clear(); failure_.clear(); current_ = uuid(); segment_.clear(); segment_text_.clear(); segment_message_.clear(); segment_number_ = 0; current_messages_.clear(); finalized_messages_.clear(); std::string outcome = "failed";
        try {
            emit(Kind::status, {}, "Connecting to the ACP agent…"); connect(turn); if (stopping_ || cancel_) throw Cancelled{};
            Object params; put(params, L"sessionId", launch_.session_id); params.SetNamedValue(L"prompt", prompt(turn)); Object meta; put(meta, L"promptId", current_); put(meta, L"requestId", current_); params.SetNamedValue(L"_meta", meta);
            auto response = connection_->call("session/prompt", winrt::to_string(params.Stringify()), std::chrono::hours(24)); sent_ = true; reference_added_ = true; emit(Kind::started, current_);
            bool acknowledged{}; std::string reason;
            for (;;) {
                if (stopping_ || cancel_) throw Cancelled{}; pump();
                if (!acknowledged && response.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {const auto result = Object::Parse(winrt::to_hstring(response.get())); acknowledged = true; reason = text(result, L"stopReason"); pump();}
                if (acknowledged && (!generation_two_ || idle_)) break; wait();
            }
            if (generation_two_) reason = idle_reason_; flush_segment();
            outcome = reason == "cancelled" ? "interrupted" : (reason.empty() || reason == "end_turn" || reason == "max_tokens" || reason == "max_turn_requests" || reason == "refusal") && failure_.empty() ? "completed" : "failed";
            if (outcome == "failed") emit(Kind::error, {}, failure_.empty() ? "The ACP agent could not finish this turn" : failure_);
        } catch (const Cancelled&) {cancel_remote(); outcome = "interrupted";}
          catch (const RpcError& error) {stop_process(); emit(Kind::error, {}, error.code == -32000 || error.code == -32001 ? "This ACP provider requires sign-in on this Windows account; no interactive authentication was started" : error.what());}
          catch (const winrt::hresult_error& error) {stop_process(); emit(Kind::error, {}, winrt::to_string(error.message()));}
          catch (const std::exception& error) {stop_process(); emit(Kind::error, {}, error.what());}
        flush_segment(); sent_ = false;
        for (const auto& message : current_messages_) {retired_messages_.insert(message); retired_order_.push_back(message);} while (retired_order_.size() > 65536) {retired_messages_.erase(retired_order_.front()); retired_order_.pop_front();}
        for (const auto& [id, pending] : prompts_) {if (connection_) {try {if (pending.kind == "permission") connection_->respond(id, winrt::to_string(ACPProtocol::cancelled().Stringify())); else connection_->reject(id, "The ACP turn has ended", -32000);} catch (...) {}} emit(Kind::resolved, id);}
        prompts_.clear(); if (terminals_) terminals_->stop(); emit(Kind::completed, current_, outcome);
        std::lock_guard lock(mutex_); active_ = false; if (outcome != "completed") {paused_ = true; if (!queued_.empty()) emit_locked(Kind::queue_changed, {}, {}, "paused");} busy_ = !paused_ && !queued_.empty();
    }
    void run() noexcept {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded); struct Apartment {~Apartment() {winrt::uninit_apartment();}} apartment;
            while (!stopping_) {
                std::optional<CodexTurn> turn; bool refresh{};
                {std::unique_lock lock(mutex_); cv_.wait_for(lock, std::chrono::milliseconds(20), [&] {return stopping_ || input_ || refresh_ || (!paused_ && !queued_.empty());});
                    if (stopping_) break; if (input_) turn.swap(input_); else if (refresh_) {refresh = true; refresh_ = false; cancel_ = false;}
                    else if (!paused_ && !queued_.empty()) {emit_locked(Kind::input, queued_.front().id, queued_.front().turn.text, "queued"); auto next = std::move(queued_.front()); queued_.pop_front(); queued_bytes_ -= input_size(next.turn); retire_locked(next.id); turn = std::move(next.turn); active_ = true; busy_ = true; cancel_ = false;}}
                if (turn) run_turn(std::move(*turn));
                else if (refresh) {
                    try {if (!connection_) launch(AgentAccess::approval); const auto models = ACPProtocol::catalog(setup_ ? setup_ : Object{}, initialized_); if (!models.GetNamedArray(L"data").Size()) throw RpcError("This ACP provider exposes its model catalog after a conversation starts"); emit(Kind::models, {}, winrt::to_string(models.Stringify()));}
                    catch (const Cancelled&) {stop_process(); emit(Kind::catalog_error, {}, "The ACP model refresh was cancelled");}
                    catch (const std::exception& error) {stop_process(); emit(Kind::catalog_error, {}, error.what());}
                    catch (const winrt::hresult_error& error) {stop_process(); emit(Kind::catalog_error, {}, winrt::to_string(error.message()));}
                } else if (connection_) {try {pump();} catch (...) {stop_process(); emit(Kind::status, {}, "The ACP agent disconnected; its saved conversation will be resumed on the next turn");}}
            }
        } catch (const std::exception& error) {try {emit(Kind::error, {}, error.what()); emit(Kind::completed, {}, "failed");} catch (...) {}}
          catch (const winrt::hresult_error& error) {try {emit(Kind::error, {}, winrt::to_string(error.message())); emit(Kind::completed, {}, "failed");} catch (...) {}}
          catch (...) {}
        stop_process(); std::lock_guard lock(mutex_); stopping_ = true; active_ = false; busy_ = false;
    }
};
} // namespace coincide
