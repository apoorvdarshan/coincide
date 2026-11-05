#pragma once
#include "AgentSession.h"
#include "RpcConnection.h"
#include "AgentAccountBinding.h"
#include <unordered_map>
#include <unordered_set>

namespace coincide {
// One worker owns session state. The RPC host and the UI exchange only UTF-8 values;
// neither a provider request nor a slow child pipe can block the WinUI dispatcher.
class CodexSession : public AgentSession {
public:
    using QueuedTurn = AgentQueuedTurn;
    explicit CodexSession(CodexLaunch launch) : launch_(std::move(launch)), account_(launch_,"codex"), worker_([this] { run(); }) {}
    ~CodexSession() { shutdown(); }
    CodexSession(const CodexSession&) = delete;
    CodexSession& operator=(const CodexSession&) = delete;

    bool send(CodexTurn turn) {
        std::lock_guard lock(mutex_);
        if (stopping_ || active_ || !queued_.empty() || !valid_input(turn)) return false;
        cancel_ = false; queue_paused_ = false; busy_ = active_ = true; ++generation_;
        input_ = std::move(turn); cv_.notify_one(); return true;
    }
    bool busy() const noexcept { return busy_; }
    // Queued work is retained but paused after Stop or failure; it cannot run unexpectedly afterwards.
    void interrupt() noexcept {
        std::lock_guard lock(mutex_);
        queue_paused_ = true; cancel_ = active_; if (!active_) busy_ = false; cv_.notify_one();
    }
    bool refresh_models() {
        std::lock_guard lock(mutex_);
        if (stopping_) return false;
        models_requested_ = true; cv_.notify_one(); return true;
    }
    bool queue(CodexTurn turn, std::string id) {
        std::lock_guard lock(mutex_);
        if (stopping_ || !valid_input(turn) || !valid_delivery_id(id) || queued_.size() >= 64
                || delivery_bytes(turn) > byte_limit - queued_bytes_) return false;
        if (std::any_of(queued_.begin(), queued_.end(), [&](const auto& value) {return value.id == id;})
                || std::any_of(steering_.begin(), steering_.end(), [&](const auto& value) {return value.id == id;})
                || known_deliveries_.contains(id)) return false;
        append_event_locked(Kind::queued, id, turn.text, "queued");
        known_deliveries_.insert(id); delivery_order_[id] = ++next_delivery_order_; queued_bytes_ += delivery_bytes(turn); queued_.push_back({std::move(id), std::move(turn)});
        if (!queue_paused_) busy_ = true;
        cv_.notify_one(); return true;
    }
    std::vector<QueuedTurn> queued() const {
        std::lock_guard lock(mutex_); return {queued_.begin(), queued_.end()};
    }
    std::size_t queued_count() const { std::lock_guard lock(mutex_); return queued_.size(); }
    bool queue_paused() const { std::lock_guard lock(mutex_); return queue_paused_; }
    bool remove_queued(const std::string& id) {
        std::lock_guard lock(mutex_);
        const auto at = std::find_if(queued_.begin(), queued_.end(), [&](const auto& value) {return value.id == id;});
        if (at == queued_.end()) return false;
        append_event_locked(Kind::queue_changed, id, {}, "removed");
        queued_bytes_ -= delivery_bytes(at->turn); remember_delivery_locked(at->id); queued_.erase(at);
        if (!active_ && (queued_.empty() || queue_paused_)) busy_ = false;
        return true;
    }
    bool resume_queue() {
        std::lock_guard lock(mutex_);
        if (stopping_ || queued_.empty()) return false;
        append_event_locked(Kind::queue_changed, {}, {}, "resumed");
        queue_paused_ = false; busy_ = true; cv_.notify_one(); return true;
    }
    // Delivery waits for the current assistant item to finish; native steering otherwise cuts off its text.
    bool steer(CodexTurn turn, std::string id) {
        std::lock_guard lock(mutex_);
        if (stopping_ || cancel_ || !active_ || !valid_input(turn) || !valid_delivery_id(id)
                || steering_.size() >= 64 || delivery_bytes(turn) > byte_limit - steering_bytes_
                || known_deliveries_.contains(id)
                || std::any_of(queued_.begin(), queued_.end(), [&](const auto& value) {return value.id == id;})
                || std::any_of(steering_.begin(), steering_.end(), [&](const auto& value) {return value.id == id;})) return false;
        known_deliveries_.insert(id); delivery_order_[id] = ++next_delivery_order_; steering_bytes_ += delivery_bytes(turn);
        steering_.push_back({std::move(id), std::move(turn), generation_, Clock::now() + std::chrono::seconds(10)});
        cv_.notify_one(); return true;
    }
    void respond(std::string id, std::string result) {
        std::lock_guard lock(mutex_);
        answers_.push_back({std::move(id), std::move(result)}); cv_.notify_one();
    }
    std::vector<SessionEvent> take_events() {
        std::lock_guard lock(mutex_);
        auto result = std::move(events_); events_.clear(); event_bytes_ = 0; return result;
    }
    void close() noexcept {
        // The idle worker checks this predicate while holding mutex_. Pair the
        // transition with that same mutex so notification cannot precede its wait.
        {std::lock_guard lock(mutex_); stopping_ = true;}
        cv_.notify_one();
    }
    void shutdown() noexcept { close(); if (worker_.joinable()) worker_.join(); }

private:
    using Object = rpc_json::JsonObject;
    using Json = rpc_json::JsonValue;
    using Kind = SessionEvent::Kind;
    using Clock = std::chrono::steady_clock;
    struct Inbound { std::string method, params, id; };
    struct Prompt { std::string method, cancel; };
    struct Cancelled {};
    struct Steering { std::string id; CodexTurn turn; std::uint64_t generation; Clock::time_point deadline; };
    struct PendingSteer { Steering input; std::future<std::string> result; };
    static constexpr std::size_t byte_limit = 64 * 1024 * 1024;
    CodexLaunch launch_;
    AgentAccountBinding account_;
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::atomic<bool> stopping_{}, cancel_{}, busy_{}, overflow_{};
    std::optional<CodexTurn> input_;
    std::deque<QueuedTurn> queued_;
    std::deque<Steering> steering_;
    std::unordered_set<std::string> known_deliveries_;
    std::unordered_map<std::string, std::uint64_t> delivery_order_;
    std::uint64_t next_delivery_order_{};
    std::deque<std::string> delivery_history_;
    bool active_{}, queue_paused_{}, models_requested_{};
    std::uint64_t generation_{}, worker_generation_{};
    std::size_t queued_bytes_{}, steering_bytes_{};
    std::deque<Inbound> incoming_;
    std::deque<std::pair<std::string, std::string>> answers_;
    std::vector<SessionEvent> events_;
    std::size_t incoming_bytes_{}, event_bytes_{};
    std::unique_ptr<RpcConnection> connection_;
    std::optional<PendingSteer> pending_steer_;
    std::string turn_id_, model_, failure_;
    std::unordered_set<std::string> streaming_items_, finalized_items_;
    bool running_turn_{}, opened_session_{}, transport_ready_{};
    bool expecting_turn_{}, done_{}, started_{}, interrupted_{};
    Clock::time_point stop_deadline_{};
    std::unordered_set<std::string> finished_turns_;
    std::unordered_map<std::string, Prompt> prompts_;
    std::unordered_map<std::string, std::string> file_changes_;
    std::thread worker_; // Last: the worker never observes uninitialized state.

    static bool valid_delivery_id(const std::string& id) {return !id.empty() && id.size() <= 1024;}
    static std::size_t delivery_bytes(const CodexTurn& turn) {
        std::size_t bytes = turn.text.size();
        if (bytes > byte_limit) return byte_limit + 1;
        for (const auto& path : turn.image_paths) {
            if (path.size() > byte_limit - bytes) return byte_limit + 1;
            bytes += path.size();
        }
        return bytes;
    }
    static bool valid_input(const CodexTurn& turn) {
        return (!turn.text.empty() || !turn.image_paths.empty()) && delivery_bytes(turn) <= byte_limit;
    }

    static std::string text(const Object& value, const wchar_t* key) {
        const auto raw = value.GetNamedValue(key, Json::CreateNullValue());
        return raw.ValueType() == rpc_json::JsonValueType::String ? winrt::to_string(raw.GetString()) : "";
    }
    void emit(Kind kind, std::string id = {}, std::string value = {}, std::string detail = {}) {
        std::lock_guard lock(mutex_);
        append_event_locked(kind, std::move(id), std::move(value), std::move(detail));
    }
    void append_event_locked(Kind kind, std::string id, std::string value, std::string detail) {
        const auto bytes = id.size() + value.size() + detail.size();
        if (kind != Kind::error && kind != Kind::completed && kind != Kind::delivery_failed && kind != Kind::queue_changed
                && bytes > byte_limit - std::min(event_bytes_, byte_limit)) {
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
        incoming_.clear(); incoming_bytes_ = 0; answers_.clear(); overflow_ = false; transport_ready_ = opened_session_ = false;
    }
    void connect_transport() {
        if (connection_ && transport_ready_) return;
        emit(Kind::status, {}, "Connecting to Codex…");
        connection_ = std::make_unique<RpcConnection>(launch_.executable, launch_.arguments, launch_.cwd,
            [this](auto method, auto params) {receive(std::move(method), std::move(params));},
            [this](auto id, auto method, auto params) {receive(std::move(method), std::move(params), std::move(id));},
            [this](auto error) {receive("__closed", std::move(error));}, account_.environment());
        (void)request("initialize", CodexProtocol::initialize());
        connection_->notify("initialized");
        transport_ready_ = true;
    }
    void connect() {
        if (account_.credentials_changed()) disconnect();
        connect_transport();
        const auto credential_revision=account_.credential_revision();
        const auto account = request("account/read", Object{});
        if (account.GetNamedBoolean(L"requiresOpenaiAuth", true) &&
                account.GetNamedValue(L"account", Json::CreateNullValue()).ValueType() == rpc_json::JsonValueType::Null) {
            throw RpcError("Sign in to the Codex CLI on this Windows account with codex login, then try again.");
        }
        if(!account.GetNamedBoolean(L"requiresOpenaiAuth",true)&&!account_.fixture())throw RpcError("This model provider has no verified account-routing identity. Review its account before conversation delivery.");
        if(credential_revision!=account_.credential_revision())throw RpcError("The Codex sign-in changed during verification; verify its account before continuing.");
        const auto subject=AgentAccountBinding::codex_subject(account);
        if(account_.accept(subject,"codex-account-read",subject))emit(Kind::account_scope,account_.profile_id(),account_.scope(),account_.detail());
        if (connection_ && opened_session_) return;
        const auto cwd = winrt::to_string(launch_.cwd.wstring());
        // A failed resume must not silently replace the user's existing session or discard its context.
        const auto opened = launch_.session_id.empty()
            ? request("thread/start", CodexProtocol::thread_start(cwd, {}, launch_.instructions))
            : request("thread/resume", CodexProtocol::thread_resume(launch_.session_id, cwd, {}, launch_.instructions));
        const auto id = text(opened.GetNamedObject(L"thread"), L"id");
        if (id.empty()) throw RpcError("Codex returned no conversation identity");
        launch_.session_id = id; model_ = text(opened, L"model");
        opened_session_ = true;
        emit(Kind::session, id, model_);
    }
    void load_models() {
        connect_transport();
        rpc_json::JsonArray entries;
        std::string cursor;
        std::unordered_set<std::string> cursors;
        for (std::size_t page_number = 0; page_number < 100; ++page_number) {
            const auto page = request("model/list", CodexProtocol::model_list(cursor));
            for (const auto& entry : page.GetNamedArray(L"data", rpc_json::JsonArray{})) {
                if (entries.Size() >= 1000) throw RpcError("The Codex model catalog exceeds its read limit");
                entries.Append(entry);
            }
            cursor = text(page, L"nextCursor");
            if (cursor.empty()) {
                Object catalog; catalog.SetNamedValue(L"data", entries);
                catalog.SetNamedValue(L"nextCursor", Json::CreateNullValue());
                emit(Kind::models, {}, winrt::to_string(catalog.Stringify())); return;
            }
            if (!cursors.insert(cursor).second) throw RpcError("Codex repeated a model catalog page");
        }
        throw RpcError("The Codex model catalog exceeds its page limit");
    }
    void remember_delivery_locked(const std::string& id) {
        delivery_history_.push_back(id);
        while (delivery_history_.size() > 4096) {
            known_deliveries_.erase(delivery_history_.front()); delivery_order_.erase(delivery_history_.front()); delivery_history_.pop_front();
        }
    }
    void reject_delivery(const std::string& id, const std::string& message) {
        std::lock_guard lock(mutex_);
        append_event_locked(Kind::delivery_failed, id, message.substr(0, 65536), "steer"); remember_delivery_locked(id);
    }
    void order_queue_locked() {
        std::stable_sort(queued_.begin(), queued_.end(), [&](const auto& a, const auto& b) {return delivery_order_.at(a.id) < delivery_order_.at(b.id);});
    }
    bool queue_fallback(Steering& input) {
        std::lock_guard lock(mutex_);
        if (cancel_ || stopping_ || queue_paused_ || queued_.size() >= 64 || delivery_bytes(input.turn) > byte_limit - queued_bytes_) return false;
        try {append_event_locked(Kind::queued, input.id, input.turn.text, "steer-fallback");} catch (const RpcError&) {return false;}
        queued_bytes_ += delivery_bytes(input.turn); queued_.push_back({std::move(input.id), std::move(input.turn)});
        order_queue_locked(); return true;
    }
    void pump_steering() {
        if (pending_steer_ && pending_steer_->result.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) {
            auto pending = std::move(*pending_steer_); pending_steer_.reset();
            try {
                const auto reply = Object::Parse(winrt::to_hstring(pending.result.get()));
                if (text(reply, L"turnId") != turn_id_) throw RpcError("Codex acknowledged a different turn for this follow-up");
                emit(Kind::input, pending.input.id, pending.input.turn.text, "steered");
                std::lock_guard lock(mutex_); remember_delivery_locked(pending.input.id);
            } catch (const RpcError& error) {
                // A server rejection proves this steer was not accepted. A completion can race the
                // request even after the assistant item's stream boundary; retain it as the next input.
                // Transport errors/timeouts have code zero and are not retried because delivery is unknown.
                if (error.code == 0 || !queue_fallback(pending.input)) reject_delivery(pending.input.id, error.what());
            } catch (const winrt::hresult_error& error) {reject_delivery(pending.input.id, winrt::to_string(error.message()));}
              catch (const std::exception& error) {reject_delivery(pending.input.id, error.what());}
        }
        if (pending_steer_ || !running_turn_ || done_ || cancel_ || stopping_) return;
        std::optional<Steering> input;
        bool expired{};
        {
            std::lock_guard lock(mutex_);
            if (steering_.empty() || steering_.front().generation != worker_generation_) return;
            expired = turn_id_.empty() && Clock::now() >= steering_.front().deadline;
            if (!expired && (!started_ || turn_id_.empty() || !streaming_items_.empty())) return;
            input = std::move(steering_.front()); steering_.pop_front(); steering_bytes_ -= delivery_bytes(input->turn);
        }
        if (expired) {reject_delivery(input->id, "Codex did not identify a turn for this follow-up in time"); return;}
        try {
            if(account_.credentials_changed())throw RpcError("The Codex account changed; this follow-up was not delivered. Verify the original account before continuing.");
            const auto adapted=with_current_tool_context(launch_,input->turn);if(stopping_||cancel_){reject_delivery(input->id,"This follow-up was stopped before delivery");return;}
            auto response = connection_->call("turn/steer",
                winrt::to_string(CodexProtocol::steer(launch_.session_id, turn_id_, adapted).Stringify()),
                std::min(launch_.request_timeout, std::chrono::milliseconds(10000)));
            pending_steer_.emplace(PendingSteer{std::move(*input), std::move(response)});
        } catch (const winrt::hresult_error& error) {reject_delivery(input->id, winrt::to_string(error.message()));}
          catch (const std::exception& error) {reject_delivery(input->id, error.what());}
    }
    void finish_steering(bool completed) {
        if (pending_steer_) {
            reject_delivery(pending_steer_->input.id, "Codex did not confirm this follow-up before its connection ended");
            pending_steer_.reset();
        }
        std::lock_guard lock(mutex_);
        // A follow-up that waited for a streaming item is sent next if its turn ended normally.
        // It is never silently sent after Stop, a failed approval, or a transport failure.
        completed = completed && !cancel_ && !stopping_ && !queue_paused_;
        std::deque<Steering> waiting; waiting.swap(steering_); steering_bytes_ = 0;
        std::deque<QueuedTurn> promoted;
        for (auto& input : waiting) {
            bool accepted{};
            if (completed && input.generation == worker_generation_ && queued_.size() + promoted.size() < 64
                    && delivery_bytes(input.turn) <= byte_limit - queued_bytes_) {
                try {
                    append_event_locked(Kind::queued, input.id, input.turn.text, "steer-fallback");
                    queued_bytes_ += delivery_bytes(input.turn);
                    promoted.push_back({std::move(input.id), std::move(input.turn)}); accepted = true;
                } catch (const RpcError&) {}
            }
            if (!accepted) {
                append_event_locked(Kind::delivery_failed, input.id, "This follow-up was not sent to Codex", "steer");
                remember_delivery_locked(input.id);
            }
        }
        while (!promoted.empty()) {queued_.push_front(std::move(promoted.back())); promoted.pop_back();}
        order_queue_locked();
    }
    Object request(const std::string& method, const Object& params) {
        auto future = connection_->call(method, winrt::to_string(params.Stringify()), launch_.request_timeout);
        for (;;) {
            pump();
            if (stopping_ || (cancel_ && (!running_turn_ || !started_))) throw Cancelled{};
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
        pump_steering();
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
        if(method=="thread/tokenUsage/updated"){
            if(done_||turn_id_.empty())return;if(const auto usage=UsageProtocol::normalize([&]{return UsageProtocol::codex(params);},launch_.session_id,turn_id_))emit(Kind::usage,turn_id_,*usage,method);return;
        }
        if (!our_turn(params)) return;
        const auto item_id = text(params, L"itemId");
        if (method == "item/agentMessage/delta" && !item_id.empty()) {
            if (finalized_items_.contains(item_id)) return;
            streaming_items_.insert(item_id);
            emit(Kind::text_delta, turn_id_ + "/" + item_id, text(params, L"delta"));
        } else if (method == "item/completed" || method == "item/started") {
            const auto item = params.GetNamedObject(L"item");
            const auto type = text(item, L"type"), id = text(item, L"id");
            if (id.empty()) return;
            if (type == "agentMessage") {
                if (finalized_items_.contains(id)) return;
                if (method == "item/started") streaming_items_.insert(id);
                else {
                    streaming_items_.erase(id); finalized_items_.insert(id);
                    emit(Kind::text_complete, turn_id_ + "/" + id, text(item, L"text"));
                }
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
        turn_id_.clear(); done_ = started_ = interrupted_ = expecting_turn_ = false;
        running_turn_ = true; failure_.clear(); file_changes_.clear(); streaming_items_.clear(); finalized_items_.clear();
        std::string outcome = "failed";
        try {
            connect();
            if (stopping_ || cancel_) throw Cancelled{};
            turn.cwd = winrt::to_string(launch_.cwd.wstring());
            if (turn.model.empty()) turn.model = model_;
            turn=with_current_tool_context(launch_,turn);if(stopping_||cancel_)throw Cancelled{};
            expecting_turn_ = true;
            const auto result = request("turn/start", CodexProtocol::turn_start(launch_.session_id, turn));
            const auto id = text(result.GetNamedObject(L"turn"), L"id");
            if (id.empty() || (!turn_id_.empty() && id != turn_id_)) throw RpcError("Codex returned an invalid turn identity");
            if (!done_) adopt_turn(id, false);
            while (!done_) {if (stopping_) throw Cancelled{}; pump(); wait();}
            // Keep accepted follow-ups ordered before completion/persistence even if Codex completes
            // the turn before acknowledging a steering RPC that was already sent.
            while (pending_steer_ && !stopping_) {pump(); if (pending_steer_) wait();}
            decline_prompts();
            if (!failure_.empty()) emit(Kind::error, {}, failure_);
            outcome = interrupted_ || cancel_ ? "interrupted" : (failure_.empty() ? "completed" : "failed");
        } catch (const Cancelled&) {
            disconnect(); prompts_.clear(); outcome = "interrupted";
        } catch (const winrt::hresult_error& error) {
            disconnect(); prompts_.clear(); emit(Kind::error, {}, winrt::to_string(error.message()));
        } catch (const std::exception& error) {
            disconnect(); prompts_.clear(); emit(Kind::error, {}, error.what());
        }
        done_ = true; running_turn_ = false;
        finish_steering(outcome == "completed");
        if (!turn_id_.empty()) finished_turns_.insert(turn_id_);
        emit(Kind::completed, turn_id_, outcome);
        {
            std::lock_guard lock(mutex_);
            active_ = false;
            if (outcome != "completed") {
                queue_paused_ = true;
                if (!queued_.empty()) append_event_locked(Kind::queue_changed, {}, {}, "paused");
            }
            busy_ = !queue_paused_ && !queued_.empty();
        }
    }
    void run() noexcept {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            struct Apartment {~Apartment(){winrt::uninit_apartment();}} apartment;
            while (!stopping_) {
                std::optional<CodexTurn> turn;
                std::string queued_id;
                bool models{};
                {
                    std::unique_lock lock(mutex_);
                    cv_.wait(lock, [&] {return stopping_ || input_.has_value() || models_requested_ || (!queue_paused_ && !queued_.empty());});
                    if (stopping_) break;
                    // An explicit send wins over metadata; refreshes otherwise run before the next queued turn.
                    if (input_) {turn.swap(input_); worker_generation_ = generation_;}
                    else if (models_requested_) {models = true; models_requested_ = false; cancel_ = false;}
                    else if (!queue_paused_ && !queued_.empty()) {
                        append_event_locked(Kind::input, queued_.front().id, queued_.front().turn.text, "queued");
                        auto next = std::move(queued_.front()); queued_.pop_front(); queued_bytes_ -= delivery_bytes(next.turn);
                        queued_id = std::move(next.id); turn = std::move(next.turn);
                        cancel_ = false; busy_ = active_ = true; worker_generation_ = ++generation_;
                        remember_delivery_locked(queued_id);
                    }
                }
                if (models) {
                    try {load_models();}
                    catch (const Cancelled&) {disconnect(); emit(Kind::catalog_error, {}, "The Codex model refresh was cancelled");}
                    catch (const winrt::hresult_error& error) {disconnect(); emit(Kind::catalog_error, {}, winrt::to_string(error.message()));}
                    catch (const std::exception& error) {disconnect(); emit(Kind::catalog_error, {}, error.what());}
                }
                if (turn && !stopping_) run_turn(std::move(*turn));
            }
            disconnect();
        } catch (const winrt::hresult_error& error) {
            try {emit(Kind::error, {}, winrt::to_string(error.message())); emit(Kind::completed, {}, "failed");} catch (...) {}
        } catch (const std::exception& error) {
            try {emit(Kind::error, {}, error.what()); emit(Kind::completed, {}, "failed");} catch (...) {}
        } catch (...) {}
        try {disconnect();} catch (...) {}
        std::lock_guard lock(mutex_); stopping_ = true; active_ = false; busy_ = false;
    }
};
} // namespace coincide
