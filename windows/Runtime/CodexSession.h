#pragma once
#include "CodexProtocol.h"
#include "RpcConnection.h"
#include <unordered_map>
#include <unordered_set>

namespace coincide {
struct CodexLaunch {
    std::filesystem::path executable;
    std::vector<std::wstring> arguments{L"app-server"};
    std::filesystem::path cwd;
    std::string session_id;
    std::chrono::milliseconds request_timeout{std::chrono::seconds(60)};
    std::chrono::milliseconds interrupt_grace{std::chrono::seconds(5)};
};

struct SessionEvent {
    enum class Kind { status, session, started, text_delta, text_complete, tool, prompt, resolved, completed, error };
    Kind kind;
    std::string id, text, detail;
};

// One worker owns session state. The RPC host and the UI exchange only UTF-8 values;
// neither a provider request nor a slow child pipe can block the WinUI dispatcher.
class CodexSession {
public:
    explicit CodexSession(CodexLaunch launch) : launch_(std::move(launch)), worker_([this] { run(); }) {}
    ~CodexSession() { shutdown(); }
    CodexSession(const CodexSession&) = delete;
    CodexSession& operator=(const CodexSession&) = delete;

    bool send(CodexTurn turn) {
        std::lock_guard lock(mutex_);
        if (stopping_ || busy_ || (turn.text.empty() && turn.image_paths.empty())) return false;
        cancel_ = false; busy_ = true; input_ = std::move(turn); cv_.notify_one(); return true;
    }
    bool busy() const noexcept { return busy_; }
    void interrupt() noexcept { cancel_ = true; cv_.notify_one(); }
    void respond(std::string id, std::string result) {
        std::lock_guard lock(mutex_);
        answers_.push_back({std::move(id), std::move(result)}); cv_.notify_one();
    }
    std::vector<SessionEvent> take_events() {
        std::lock_guard lock(mutex_);
        auto result = std::move(events_); events_.clear(); event_bytes_ = 0; return result;
    }
    void close() noexcept { stopping_ = true; cv_.notify_one(); }
    void shutdown() noexcept { close(); if (worker_.joinable()) worker_.join(); }

private:
    using Object = rpc_json::JsonObject;
    using Json = rpc_json::JsonValue;
    using Kind = SessionEvent::Kind;
    using Clock = std::chrono::steady_clock;
    struct Inbound { std::string method, params, id; };
    struct Prompt { std::string method, cancel; };
    struct Cancelled {};
    static constexpr std::size_t byte_limit = 64 * 1024 * 1024;
    CodexLaunch launch_;
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::atomic<bool> stopping_{}, cancel_{}, busy_{}, overflow_{};
    std::optional<CodexTurn> input_;
    std::deque<Inbound> incoming_;
    std::deque<std::pair<std::string, std::string>> answers_;
    std::vector<SessionEvent> events_;
    std::size_t incoming_bytes_{}, event_bytes_{};
    std::unique_ptr<RpcConnection> connection_;
    std::string turn_id_, model_, failure_;
    bool expecting_turn_{}, done_{}, started_{}, interrupted_{};
    Clock::time_point stop_deadline_{};
    std::unordered_set<std::string> finished_turns_;
    std::unordered_map<std::string, Prompt> prompts_;
    std::unordered_map<std::string, std::string> file_changes_;
    std::thread worker_; // Last: the worker never observes uninitialized state.

    static std::string text(const Object& value, const wchar_t* key) {
        const auto raw = value.GetNamedValue(key, Json::CreateNullValue());
        return raw.ValueType() == rpc_json::JsonValueType::String ? winrt::to_string(raw.GetString()) : "";
    }
    void emit(Kind kind, std::string id = {}, std::string value = {}, std::string detail = {}) {
        std::lock_guard lock(mutex_);
        const auto bytes = id.size() + value.size() + detail.size();
        if (kind != Kind::error && kind != Kind::completed && bytes > byte_limit - std::min(event_bytes_, byte_limit)) {
            throw RpcError("The conversation output queue is full");
        }
        event_bytes_ += bytes;
        if (kind == Kind::text_delta && !events_.empty() && events_.back().kind == kind && events_.back().id == id) {
            events_.back().text += value;
        } else events_.push_back({kind, std::move(id), std::move(value), std::move(detail)});
    }
    void receive(std::string method, std::string params, std::string id = {}) {
        std::lock_guard lock(mutex_);
        const auto bytes = method.size() + params.size() + id.size();
        if (incoming_.size() >= 65536 || bytes > byte_limit - incoming_bytes_) overflow_ = true;
        else { incoming_bytes_ += bytes; incoming_.push_back({std::move(method), std::move(params), std::move(id)}); }
        cv_.notify_one();
    }
    void disconnect() {
        if (connection_) {connection_->shutdown(); connection_.reset();}
        std::lock_guard lock(mutex_);
        incoming_.clear(); incoming_bytes_ = 0; answers_.clear(); overflow_ = false;
    }
    void connect() {
        if (connection_) return;
        emit(Kind::status, {}, "Connecting to Codex…");
        connection_ = std::make_unique<RpcConnection>(launch_.executable, launch_.arguments, launch_.cwd,
            [this](auto method, auto params) {receive(std::move(method), std::move(params));},
            [this](auto id, auto method, auto params) {receive(std::move(method), std::move(params), std::move(id));},
            [this](auto error) {receive("__closed", std::move(error));});
        (void)request("initialize", CodexProtocol::initialize());
        connection_->notify("initialized");
        const auto account = request("account/read", Object{});
        if (account.GetNamedBoolean(L"requiresOpenaiAuth", true) &&
                account.GetNamedValue(L"account", Json::CreateNullValue()).ValueType() == rpc_json::JsonValueType::Null) {
            throw RpcError("Sign in to the Codex CLI on this Windows account with codex login, then try again.");
        }
        const auto cwd = winrt::to_string(launch_.cwd.wstring());
        // A failed resume must not silently replace the user's existing session or discard its context.
        const auto opened = launch_.session_id.empty()
            ? request("thread/start", CodexProtocol::thread_start(cwd))
            : request("thread/resume", CodexProtocol::thread_resume(launch_.session_id, cwd));
        const auto id = text(opened.GetNamedObject(L"thread"), L"id");
        if (id.empty()) throw RpcError("Codex returned no conversation identity");
        launch_.session_id = id; model_ = text(opened, L"model");
        emit(Kind::session, id, model_);
    }
    Object request(const std::string& method, const Object& params) {
        auto future = connection_->call(method, winrt::to_string(params.Stringify()), launch_.request_timeout);
        for (;;) {
            pump();
            if (stopping_ || (cancel_ && !started_)) throw Cancelled{};
            if (future.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
                return Object::Parse(winrt::to_hstring(future.get()));
            }
            wait();
        }
    }
    void wait() {
        std::unique_lock lock(mutex_);
        cv_.wait_for(lock, std::chrono::milliseconds(10), [&] {return stopping_ || overflow_ || !incoming_.empty() || !answers_.empty();});
    }
    void decline_prompts() {
        for (const auto& [id, prompt] : prompts_) {
            connection_->respond(id, prompt.cancel); emit(Kind::resolved, id);
        }
        prompts_.clear();
    }
    void pump() {
        if (overflow_) throw RpcError("The Codex event queue is full");
        std::deque<Inbound> notices;
        std::deque<std::pair<std::string, std::string>> answers;
        { std::lock_guard lock(mutex_); notices.swap(incoming_); incoming_bytes_ = 0; answers.swap(answers_); }
        for (auto& notice : notices) {
            if (notice.method == "__closed") throw RpcError(notice.params);
            auto params = Object::Parse(winrt::to_hstring(notice.params));
            if (notice.id.empty()) notification(notice.method, params);
            else server_request(notice.id, notice.method, params);
        }
        for (const auto& [id, result] : answers) {
            const auto at = prompts_.find(id);
            if (at == prompts_.end() || cancel_ || done_) continue;
            auto parsed = Object::Parse(winrt::to_hstring(result));
            if (at->second.method != "item/tool/requestUserInput") {
                const auto decision = text(parsed, L"decision");
                if (decision != "accept" && decision != "decline" && decision != "cancel") throw RpcError("Unsupported approval decision");
            }
            connection_->respond(id, result); prompts_.erase(at); emit(Kind::resolved, id);
        }
        if (cancel_ && started_ && !interrupted_ && !done_) {
            decline_prompts();
            connection_->call("turn/interrupt", winrt::to_string(CodexProtocol::interrupt(launch_.session_id, turn_id_).Stringify()), launch_.interrupt_grace);
            interrupted_ = true; stop_deadline_ = Clock::now() + launch_.interrupt_grace;
            emit(Kind::status, {}, "Stopping…");
        }
        if (interrupted_ && !done_ && Clock::now() >= stop_deadline_) throw Cancelled{};
    }
    bool our_turn(const Object& params) const {
        return text(params, L"threadId") == launch_.session_id && !turn_id_.empty() && text(params, L"turnId") == turn_id_ && !done_;
    }
    void adopt_turn(const std::string& id, bool started) {
        if (id.empty() || finished_turns_.contains(id) || (!turn_id_.empty() && turn_id_ != id)) return;
        if (turn_id_.empty()) {turn_id_ = id; emit(Kind::started, id);}
        started_ = started_ || started;
    }
    void notification(const std::string& method, const Object& params) {
        if (method == "serverRequest/resolved") {
            const auto value = params.GetNamedValue(L"requestId", Json::CreateNullValue());
            const auto id = winrt::to_string(value.Stringify());
            if (prompts_.erase(id)) emit(Kind::resolved, id);
            return;
        }
        if (text(params, L"threadId") != launch_.session_id) return;
        if (method == "turn/started" && expecting_turn_ && !done_) {
            adopt_turn(text(params.GetNamedObject(L"turn"), L"id"), true); return;
        }
        if (method == "turn/completed" && !turn_id_.empty() && !done_) {
            const auto turn = params.GetNamedObject(L"turn");
            if (text(turn, L"id") != turn_id_) return;
            const auto status = text(turn, L"status");
            if (status == "failed" && failure_.empty()) {
                const auto error = turn.GetNamedValue(L"error", Json::CreateNullValue());
                failure_ = error.ValueType() == rpc_json::JsonValueType::Object ? text(error.GetObject(), L"message") : "Codex could not finish the turn.";
                if (failure_.empty()) failure_ = "Codex could not finish the turn.";
            }
            interrupted_ = interrupted_ || status == "interrupted"; done_ = true; return;
        }
        if (!our_turn(params)) return;
        const auto item_id = text(params, L"itemId");
        if (method == "item/agentMessage/delta" && !item_id.empty()) {
            emit(Kind::text_delta, turn_id_ + "/" + item_id, text(params, L"delta"));
        } else if (method == "item/completed" || method == "item/started") {
            const auto item = params.GetNamedObject(L"item");
            const auto type = text(item, L"type"), id = text(item, L"id");
            if (id.empty()) return;
            if (type == "agentMessage" && method == "item/completed") {
                emit(Kind::text_complete, turn_id_ + "/" + id, text(item, L"text"));
            } else if (type == "commandExecution" || type == "fileChange" || type == "mcpToolCall") {
                if (type == "fileChange") file_changes_[id] = winrt::to_string(item.Stringify());
                emit(Kind::tool, turn_id_ + "/" + id, winrt::to_string(item.Stringify()));
            }
        } else if (method == "error" && !params.GetNamedBoolean(L"willRetry", false)) {
            failure_ = text(params.GetNamedObject(L"error", Object{}), L"message");
        }
    }
    void server_request(const std::string& id, const std::string& method, Object params) {
        if (!our_turn(params) || cancel_) {connection_->reject(id, "This conversation is not accepting requests"); return;}
        if (method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" || method == "item/tool/requestUserInput") {
            if (prompts_.size() >= 64) throw RpcError("Too many unanswered Codex requests");
            const auto item = text(params, L"itemId");
            if (file_changes_.contains(item)) params.SetNamedValue(L"fileChangePreview", Json::Parse(winrt::to_hstring(file_changes_.at(item))));
            const auto decline = method == "item/tool/requestUserInput" ? "{\"answers\":{}}" : "{\"decision\":\"decline\"}";
            prompts_.insert_or_assign(id, Prompt{method, decline});
            emit(Kind::prompt, id, winrt::to_string(params.Stringify()), method);
        } else if (method == "item/permissions/requestApproval") {
            connection_->respond(id, "{\"permissions\":{},\"scope\":\"turn\"}");
            emit(Kind::status, {}, "An unsupported permission expansion was declined.");
        } else connection_->reject(id, "This Windows preview does not implement this request");
    }
    void run_turn(CodexTurn turn) {
        turn_id_.clear(); done_ = started_ = interrupted_ = expecting_turn_ = false; failure_.clear(); file_changes_.clear();
        try {
            connect();
            if (stopping_ || cancel_) throw Cancelled{};
            turn.cwd = winrt::to_string(launch_.cwd.wstring());
            if (turn.model.empty()) turn.model = model_;
            expecting_turn_ = true;
            const auto result = request("turn/start", CodexProtocol::turn_start(launch_.session_id, turn));
            const auto id = text(result.GetNamedObject(L"turn"), L"id");
            if (id.empty() || (!turn_id_.empty() && id != turn_id_)) throw RpcError("Codex returned an invalid turn identity");
            if (!done_) adopt_turn(id, false);
            while (!done_) {if (stopping_) throw Cancelled{}; pump(); wait();}
            decline_prompts();
            if (!failure_.empty()) emit(Kind::error, {}, failure_);
            emit(Kind::completed, turn_id_, interrupted_ || cancel_ ? "interrupted" : (failure_.empty() ? "completed" : "failed"));
        } catch (const Cancelled&) {
            disconnect(); prompts_.clear(); emit(Kind::completed, turn_id_, "interrupted");
        } catch (const winrt::hresult_error& error) {
            disconnect(); prompts_.clear(); emit(Kind::error, {}, winrt::to_string(error.message())); emit(Kind::completed, turn_id_, "failed");
        } catch (const std::exception& error) {
            disconnect(); prompts_.clear(); emit(Kind::error, {}, error.what()); emit(Kind::completed, turn_id_, "failed");
        }
        if (!turn_id_.empty()) finished_turns_.insert(turn_id_);
        busy_ = false;
    }
    void run() noexcept {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            struct Apartment {~Apartment(){winrt::uninit_apartment();}} apartment;
            while (!stopping_) {
                std::optional<CodexTurn> turn;
                { std::unique_lock lock(mutex_); cv_.wait(lock, [&] {return stopping_ || input_.has_value();}); turn.swap(input_); }
                if (turn && !stopping_) run_turn(std::move(*turn));
            }
            disconnect();
        } catch (...) {busy_ = false;}
    }
};
} // namespace coincide
