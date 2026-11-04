#pragma once
#include "ClaudeProtocol.h"
#include "WindowsProcess.h"
#include "AgentAccountBinding.h"
#include <objbase.h>
#include <condition_variable>
#include <deque>
#include <unordered_map>
#include <unordered_set>

namespace coincide {
// Claude Code's stream-json SDK protocol, with an owned native Windows child and no shell launcher.
// The worker handles protocol/state; the writer may block without freezing WinUI or Stop deadlines.
class ClaudeSession : public AgentSession {
public:
    explicit ClaudeSession(CodexLaunch launch) : launch_(std::move(launch)), account_(launch_,"claude"), conversation_exists_(!launch_.session_id.empty()), worker_([this] {run();}) {}
    ~ClaudeSession() override {shutdown();}
    bool send(CodexTurn turn) override {
        std::lock_guard lock(mutex_);
        if (stopping_ || active_ || !queued_.empty() || !valid(turn)) return false;
        input_ = std::move(turn); active_ = true; busy_ = true; cancel_ = false; paused_ = false; cv_.notify_one(); return true;
    }
    bool busy() const noexcept override {return busy_;}
    void interrupt() noexcept override {std::lock_guard lock(mutex_); paused_ = true; cancel_ = active_; if (!active_) busy_ = false; cv_.notify_one();}
    bool refresh_models() override {std::lock_guard lock(mutex_); if (stopping_) return false; refresh_ = true; cv_.notify_one(); return true;}
    bool queue(CodexTurn turn, std::string id) override {
        std::lock_guard lock(mutex_);
        const auto bytes = input_size(turn);
        if (stopping_ || !valid(turn) || id.empty() || id.size() > 1024 || deliveries_.contains(id) || queued_.size() >= 64 || bytes > limit - queued_bytes_) return false;
        emit_locked(SessionEvent::Kind::queued, id, turn.text, "queued");
        deliveries_.insert(id); queued_bytes_ += bytes; queued_.push_back({std::move(id), std::move(turn)});
        if (!paused_) busy_ = true; cv_.notify_one(); return true;
    }
    std::vector<AgentQueuedTurn> queued() const override {std::lock_guard lock(mutex_); return {queued_.begin(), queued_.end()};}
    std::size_t queued_count() const override {std::lock_guard lock(mutex_); return queued_.size();}
    bool queue_paused() const override {std::lock_guard lock(mutex_); return paused_;}
    bool remove_queued(const std::string& id) override {
        std::lock_guard lock(mutex_);
        const auto at = std::find_if(queued_.begin(), queued_.end(), [&](const auto& value) {return value.id == id;});
        if (at == queued_.end()) return false;
        emit_locked(SessionEvent::Kind::queue_changed, id, {}, "removed"); queued_bytes_ -= input_size(at->turn); retire_locked(at->id); queued_.erase(at);
        if (!active_ && (queued_.empty() || paused_)) busy_ = false; return true;
    }
    bool resume_queue() override {
        std::lock_guard lock(mutex_); if (stopping_ || queued_.empty()) return false;
        emit_locked(SessionEvent::Kind::queue_changed, {}, {}, "resumed"); paused_ = false; busy_ = true; cv_.notify_one(); return true;
    }
    // Until Claude's background-task and segment acknowledgements are ported, preserve follow-ups as
    // explicit queued messages. Never claim a live steer was accepted or risk cutting off a streaming reply.
    bool steer(CodexTurn, std::string) override {return false;}
    void respond(std::string id, std::string result) override {
        std::lock_guard lock(mutex_);
        if (answers_.size() >= 1024 || result.size() > limit) throw RpcError("The Claude answer queue is full");
        answers_.push_back({std::move(id), std::move(result)}); cv_.notify_one();
    }
    std::vector<SessionEvent> take_events() override {
        std::lock_guard lock(mutex_); auto result = std::move(events_); events_.clear(); event_bytes_ = 0; return result;
    }
    void close() noexcept override {stopping_ = true; cv_.notify_all(); write_cv_.notify_all();}
    void shutdown() noexcept override {close(); if (worker_.joinable()) worker_.join();}
private:
    using Object = ClaudeProtocol::Object;
    using Array = ClaudeProtocol::Array;
    using Json = ClaudeProtocol::Json;
    using Kind = SessionEvent::Kind;
    using Clock = std::chrono::steady_clock;
    struct Prompt {Object request; bool question{};};
    struct Cancelled {};
    static constexpr std::size_t limit = 64 * 1024 * 1024;
    CodexLaunch launch_;
    AgentAccountBinding account_;
    std::string account_email_;
    mutable std::mutex mutex_, write_mutex_;
    std::condition_variable cv_, write_cv_;
    std::optional<CodexTurn> input_;
    std::deque<AgentQueuedTurn> queued_;
    std::unordered_set<std::string> deliveries_;
    std::deque<std::string> delivery_history_;
    std::deque<std::pair<std::string, std::string>> answers_;
    std::deque<std::string> lines_, writes_;
    std::vector<SessionEvent> events_;
    std::size_t queued_bytes_{}, line_bytes_{}, write_bytes_{}, event_bytes_{};
    bool active_{}, paused_{}, refresh_{};
    std::atomic<bool> stopping_{}, busy_{}, cancel_{}, overflow_{}, writer_failed_{}, stop_writer_{};
    std::unique_ptr<WindowsProcess> process_;
    std::thread writer_;
    std::unordered_map<std::string, Object> controls_, responses_;
    std::unordered_map<std::string, Prompt> prompts_;
    std::unordered_map<int, std::string> blocks_;
    std::unordered_set<std::string> finalized_;
    std::string current_, message_, failure_, catalog_;
    bool done_{}, sent_{}, saw_reply_{}, lifecycle_{}, started_{}, conversation_exists_{}, session_reported_{};
    std::optional<CodexTurn> live_;
    std::uint64_t next_control_{};
    std::thread worker_;

    static std::string text(const Object& value, const wchar_t* key) {return ClaudeProtocol::text(value, key);}
    static void put(Object value, const wchar_t* key, const std::string& value_text) {ClaudeProtocol::put(value, key, value_text);}
    static std::string uuid() {
        winrt::guid value; winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&value)));
        auto result = winrt::to_string(winrt::to_hstring(value));
        if (!result.empty() && result.front() == '{') result = result.substr(1, result.size() - 2); return result;
    }
    static std::size_t input_size(const CodexTurn& turn) {
        auto size = turn.text.size(); if (size > limit) return limit + 1;
        for (const auto& path : turn.image_paths) {if (path.size() > limit - size) return limit + 1; size += path.size();} return size;
    }
    static bool valid(const CodexTurn& turn) {return (!turn.text.empty() || !turn.image_paths.empty()) && input_size(turn) <= limit;}
    void retire_locked(const std::string& id) {
        delivery_history_.push_back(id); if (delivery_history_.size() > 4096) {deliveries_.erase(delivery_history_.front()); delivery_history_.pop_front();}
    }
    void emit_locked(Kind kind, std::string id, std::string body, std::string detail = {}) {
        const auto bytes = id.size() + body.size() + detail.size();
        if (kind != Kind::error && kind != Kind::completed && kind != Kind::queue_changed && bytes > limit - std::min(limit, event_bytes_)) throw RpcError("The Claude output queue is full");
        event_bytes_ += bytes;
        if (kind == Kind::text_delta && !events_.empty() && events_.back().kind == kind && events_.back().id == id) events_.back().text += body;
        else events_.push_back({kind, std::move(id), std::move(body), std::move(detail)});
    }
    void emit(Kind kind, std::string id = {}, std::string body = {}, std::string detail = {}) {
        std::lock_guard lock(mutex_); emit_locked(kind, std::move(id), std::move(body), std::move(detail));
    }
    void incoming(std::string line) {
        std::lock_guard lock(mutex_); if (line.size() > limit - line_bytes_ || lines_.size() >= 65536) overflow_ = true;
        else {line_bytes_ += line.size(); lines_.push_back(std::move(line));} cv_.notify_one();
    }
    void write(Object frame) {
        auto bytes = winrt::to_string(frame.Stringify()); std::lock_guard lock(write_mutex_);
        if (!process_ || stop_writer_ || bytes.size() > limit - write_bytes_) throw RpcError("The Claude input channel is closed or full");
        write_bytes_ += bytes.size(); writes_.push_back(std::move(bytes)); write_cv_.notify_one();
    }
    void writer_loop(WindowsProcess& process) noexcept {
        try {
            for (;;) {
                std::string line;
                {std::unique_lock lock(write_mutex_); write_cv_.wait(lock, [&] {return stop_writer_ || !writes_.empty();});
                    if (stop_writer_) return; line = std::move(writes_.front()); writes_.pop_front(); write_bytes_ -= line.size();}
                process.write_line(line);
            }
        } catch (...) {writer_failed_ = true; cv_.notify_one();}
    }
    void stop_process() noexcept {
        stop_writer_ = true; write_cv_.notify_one();
        if (process_) process_->stop();
        if (writer_.joinable()) writer_.join(); process_.reset(); live_.reset();
        {std::lock_guard lock(write_mutex_); writes_.clear(); write_bytes_ = 0;}
        {std::lock_guard lock(mutex_); lines_.clear(); line_bytes_ = 0;}
        controls_.clear(); responses_.clear(); prompts_.clear(); writer_failed_ = false; overflow_ = false;
    }
    void wait() {std::unique_lock lock(mutex_); cv_.wait_for(lock, std::chrono::milliseconds(10), [&] {return stopping_ || cancel_ || overflow_ || writer_failed_ || !lines_.empty() || !answers_.empty();});}
    void drain_lines() {
        if (overflow_) throw RpcError("Claude output exceeds its bounded queue");
        if (writer_failed_) throw RpcError("Claude stopped accepting protocol input");
        std::deque<std::string> lines;
        {std::lock_guard lock(mutex_); lines.swap(lines_); line_bytes_ = 0;}
        for (const auto& line : lines) {
            Object frame{nullptr}; if (!Object::TryParse(winrt::to_hstring(line), frame)) throw RpcError("Claude emitted an invalid stream-json frame");
            receive(frame);
        }
        std::deque<std::pair<std::string, std::string>> answers;
        {std::lock_guard lock(mutex_); answers.swap(answers_);}
        for (const auto& [raw_id, raw_answer] : answers) {
            const auto id_json = Json::Parse(winrt::to_hstring(raw_id));
            if (id_json.ValueType() != rpc_json::JsonValueType::String) continue;
            const auto id = winrt::to_string(id_json.GetString()); const auto at = prompts_.find(id);
            if (at == prompts_.end() || done_ || cancel_) continue;
            const auto answer = Object::Parse(winrt::to_hstring(raw_answer));
            const auto request = at->second.request; Object response;
            if (at->second.question) {
                Object input = request.GetNamedObject(L"input", Object{}), values;
                for (const auto& entry : answer.GetNamedObject(L"answers", Object{})) {
                    std::string joined;
                    for (const auto& value : entry.Value().GetObject().GetNamedArray(L"answers", Array{})) {
                        if (value.ValueType() != rpc_json::JsonValueType::String) continue;
                        if (!joined.empty()) joined += ", "; joined += winrt::to_string(value.GetString());
                    }
                    if (!joined.empty()) put(values, entry.Key().c_str(), joined);
                }
                if (values.Size()) {input.SetNamedValue(L"answers", values); response = ClaudeProtocol::allow(request, input);}
                else response = ClaudeProtocol::deny(request);
            } else {
                const auto decision = text(answer, L"decision");
                if (decision != "accept" && decision != "decline" && decision != "cancel") throw RpcError("Unsupported Claude approval decision");
                response = decision == "accept" ? ClaudeProtocol::allow(request, request.GetNamedObject(L"input", Object{})) : ClaudeProtocol::deny(request, decision == "cancel");
                if (decision == "cancel") cancel_ = true;
            }
            write(ClaudeProtocol::response(id, response)); prompts_.erase(at); emit(Kind::resolved, raw_id);
        }
    }
    void pump() {
        drain_lines();
        if (process_ && process_->wait(std::chrono::milliseconds(0))) {
            drain_lines(); if (!done_) throw RpcError("Claude Code exited before finishing the active request");
        }
    }
    Object control(Object request) {
        const auto id = "coincide-" + std::to_string(++next_control_); controls_.emplace(id, request); write(ClaudeProtocol::control(id, request));
        const auto deadline = Clock::now() + launch_.request_timeout;
        for (;;) {
            pump(); if (stopping_ || cancel_) throw Cancelled{};
            const auto at = responses_.find(id);
            if (at != responses_.end()) {
                auto response = at->second; responses_.erase(at); controls_.erase(id);
                if (text(response, L"subtype") != "success") throw RpcError(text(response, L"error").empty() ? "Claude rejected a control request" : text(response, L"error"));
                return response.GetNamedObject(L"response", Object{});
            }
            if (Clock::now() >= deadline) {controls_.erase(id); throw RpcError("Claude control request timed out");} wait();
        }
    }
    Object launch(const CodexTurn& turn, bool probe) {
        stop_process(); stop_writer_ = false; session_reported_ = false;
        if (!probe && launch_.session_id.empty()) launch_.session_id = uuid();
        const auto custom = !launch_.arguments.empty() && launch_.arguments != std::vector<std::wstring>{L"app-server"};
        auto args = custom ? launch_.arguments : ClaudeProtocol::arguments(turn, launch_.session_id, conversation_exists_, probe);
        WindowsProcess::Environment environment;
        for (const auto* name : {L"CLAUDECODE", L"CLAUDE_CODE_ENTRYPOINT", L"CLAUDE_CODE_SESSION_ID", L"CLAUDE_CODE_CHILD_SESSION", L"CLAUDE_CODE_BRIDGE_SESSION_ID",
                L"CLAUDE_CODE_MESSAGING_SOCKET", L"CLAUDE_CODE_MESSAGING_TOKEN", L"CLAUDE_CODE_SESSION_ATTENDED", L"CLAUDE_CODE_EXECPATH", L"CLAUDE_PID", L"CLAUDE_EFFORT"}) environment.emplace_back(name, std::nullopt);
        if (probe) {environment.emplace_back(L"ENABLE_CLAUDEAI_MCP_SERVERS", L"false"); environment.emplace_back(L"CLAUDE_CODE_AUTO_CONNECT_IDE", L"0"); environment.emplace_back(L"CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL", L"1");}
        const auto profile_environment=account_.environment();environment.insert(environment.end(),profile_environment.begin(),profile_environment.end());
        process_ = WindowsProcess::start(launch_.executable, args, launch_.cwd, [this](std::string line) {incoming(std::move(line));}, environment);
        writer_ = std::thread([this] {writer_loop(*process_);});
        Object request; put(request, L"subtype", "initialize");
        if (!probe && !launch_.instructions.empty()) put(request, L"appendSystemPrompt", launch_.instructions);
        const auto initialized = control(request); catalog_ = winrt::to_string(ClaudeProtocol::catalog(initialized).Stringify()); emit(Kind::models, {}, catalog_);
        if (!probe) {
            const auto account = initialized.GetNamedObject(L"account", Object{});
            if (text(account, L"tokenSource") == "none" && text(account, L"email").empty() && (text(account, L"apiKeySource").empty() || text(account, L"apiKeySource") == "none")
                    && (text(account, L"apiProvider").empty() || text(account, L"apiProvider") == "firstParty")) throw RpcError("Sign in to Claude Code on this Windows account with claude auth login");
            if(!account_.fixture()&&(text(account,L"email")!=account_email_||(!text(account,L"apiKeySource").empty()&&text(account,L"apiKeySource")!="none")||(!text(account,L"apiProvider").empty()&&text(account,L"apiProvider")!="firstParty")))
                throw RpcError("Claude Code initialized with a different or unverified account. The conversation was not delivered.");
            live_ = turn;
        }
        return initialized;
    }
    void connect(const CodexTurn& turn) {
        verify_account();
        if (process_ && process_->wait(std::chrono::milliseconds(0))) stop_process();
        if (!live_ || !process_ || live_->access != turn.access || (!live_->effort.empty() && turn.effort.empty())) {(void)launch(turn, false); return;}
        if (live_->model != turn.model) {Object request; put(request, L"subtype", "set_model"); put(request, L"model", turn.model.empty() ? "default" : turn.model); (void)control(request);}
        if (live_->effort != turn.effort || live_->service_tier != turn.service_tier) {
            if (!turn.service_tier.empty() && turn.service_tier != "default" && turn.service_tier != "fast") throw RpcError("This Claude Code service tier is not supported");
            Object request, settings; put(request, L"subtype", "apply_flag_settings");
            if (!turn.effort.empty()) put(settings, L"effortLevel", turn.effort);
            settings.SetNamedValue(L"fastMode", turn.service_tier == "fast" ? Json::CreateBooleanValue(true) : Json::CreateNullValue());
            request.SetNamedValue(L"settings", settings); (void)control(request);
        }
        if (live_->plan != turn.plan) {Object request; put(request, L"subtype", "set_permission_mode"); put(request, L"mode", ClaudeProtocol::permission_mode(turn)); (void)control(request);}
        live_ = turn;
    }
    void verify_account() {
        const auto environment=account_.environment();const auto before=account_.credential_revision();
        // This command reads authentication metadata only, before constructing any --resume or
        // --session-id stream process. It never starts a prompt, signs in or invokes a shell.
        const auto arguments=account_.fixture()?std::vector<std::wstring>{L"--claude-account-fixture",launch_.arguments[1]}:std::vector<std::wstring>{L"auth",L"status",L"--json"};
        std::mutex output_mutex;std::string output;
        auto probe=WindowsProcess::start_bytes(launch_.executable,arguments,launch_.cwd,[&](std::string_view bytes){std::lock_guard lock(output_mutex);output.append(bytes);},128*1024,environment,true);probe->close_input();
        const auto deadline=Clock::now()+std::min(launch_.request_timeout,std::chrono::milliseconds(std::chrono::seconds(45)));std::optional<WindowsProcess::Exit> exit;
        while(!(exit=probe->wait(std::chrono::milliseconds(25)))) {
            if(stopping_||cancel_){probe->stop();throw Cancelled{};}
            if(Clock::now()>=deadline){probe->stop();throw RpcError("Claude account verification timed out before conversation delivery");}
        }
        if(exit->status!=0||exit->stdout_truncated||!exit->channel_error.empty())throw RpcError("Claude account verification failed before conversation delivery");
        Object status{nullptr};if(!Object::TryParse(winrt::to_hstring(output),status))throw RpcError("Claude did not return verified account metadata; no conversation was delivered");
        if(!status.GetNamedBoolean(L"loggedIn",false))throw RpcError("Sign in to Claude Code on this Windows account with claude auth login");
        if(before!=account_.credential_revision())throw RpcError("Claude credentials changed during verification; verify the account again before continuing");
        account_email_=text(status,L"email");
        if(account_.accept(AgentAccountBinding::claude_subject(status),"claude-auth-status",account_email_))emit(Kind::account_scope,account_.profile_id(),account_.scope(),account_.detail());
    }
    void prompt(const Object& frame) {
        const auto id = text(frame, L"request_id"); const auto request = frame.GetNamedObject(L"request", Object{});
        if (id.empty() || prompts_.contains(id)) return;
        if (!active_ || done_ || prompts_.size() >= 64 || text(request, L"subtype") != "can_use_tool") {
            Object error; put(error, L"message", "This Windows client cannot answer that Claude control request"); write(ClaudeProtocol::response(id, error, true)); return;
        }
        Object normalized; const auto input = request.GetNamedObject(L"input", Object{}); const auto tool = text(request, L"tool_name");
        const auto encoded_id = winrt::to_string(Json::CreateStringValue(winrt::to_hstring(id)).Stringify());
        const auto question = tool == "AskUserQuestion";
        std::string detail = "item/commandExecution/requestApproval";
        if (question) {
            Array questions;
            for (const auto& raw : input.GetNamedArray(L"questions", Array{})) {
                auto q = raw.GetObject(); const auto title = text(q, L"question"); if (title.empty()) continue;
                put(q, L"id", title); questions.Append(q);
            }
            if (!questions.Size()) {write(ClaudeProtocol::response(id, ClaudeProtocol::deny(request))); return;}
            normalized.SetNamedValue(L"questions", questions); detail = "item/tool/requestUserInput";
        } else if (tool == "Write" || tool == "Edit" || tool == "NotebookEdit") {
            Array changes; Object change, preview; auto path = text(input, L"file_path"); if (path.empty()) path = text(input, L"notebook_path");
            if (!path.empty()) {
                put(change, L"path", path); put(change, L"diff", tool == "Write" ? "Proposed content:\n" + text(input, L"content")
                    : "Previous text:\n" + text(input, L"old_string") + "\nProposed text:\n" + text(input, L"new_string")); changes.Append(change);
            }
            preview.SetNamedValue(L"changes", changes); normalized.SetNamedValue(L"fileChangePreview", preview); detail = "item/fileChange/requestApproval";
        } else put(normalized, L"command", tool + "\n" + winrt::to_string(input.Stringify()));
        put(normalized, L"reason", text(request, L"decision_reason")); put(normalized, L"provider", "claude");
        prompts_.emplace(id, Prompt{request, question}); emit(Kind::prompt, encoded_id, winrt::to_string(normalized.Stringify()), detail);
    }
    void receive(const Object& frame) {
        const auto type = text(frame, L"type");
        if (type == "control_response") {
            const auto response = frame.GetNamedObject(L"response", Object{}); const auto id = text(response, L"request_id");
            if (controls_.contains(id)) responses_.insert_or_assign(id, response); return;
        }
        if (type == "control_request") {prompt(frame); return;}
        if (type == "control_cancel_request") {
            const auto id = text(frame, L"request_id"); if (prompts_.erase(id)) emit(Kind::resolved, winrt::to_string(Json::CreateStringValue(winrt::to_hstring(id)).Stringify())); return;
        }
        if (type == "system" && text(frame, L"subtype") == "init") {
            const auto id = text(frame, L"session_id");
            const auto parent = frame.GetNamedValue(L"parent_tool_use_id", Json::CreateNullValue());
            if (!id.empty() && parent.ValueType() != rpc_json::JsonValueType::String && (id != launch_.session_id || !session_reported_)) {
                launch_.session_id = id; conversation_exists_ = true; session_reported_ = true; emit(Kind::session, id, text(frame, L"model"));
            }
            return;
        }
        if (!sent_ || done_ || current_.empty()) return;
        const auto session = text(frame, L"session_id"); if (!session.empty() && session != launch_.session_id) return;
        if (!session.empty() && !session_reported_) {session_reported_ = true; emit(Kind::session, session, live_ ? live_->model : "");}
        const auto parent = frame.GetNamedValue(L"parent_tool_use_id", Json::CreateNullValue()); if (parent.ValueType() == rpc_json::JsonValueType::String) return;
        if (type == "command_lifecycle") {
            if (text(frame, L"command_uuid") != current_) return;
            lifecycle_ = true;
            const auto state = text(frame, L"state"); if (state == "started") started_ = true;
            else if (state == "cancelled") {cancel_ = true; done_ = true;} return;
        }
        if (type == "stream_event") {
            const auto event = frame.GetNamedObject(L"event", Object{}); const auto event_type = text(event, L"type");
            if (event_type == "message_start") {message_ = text(event.GetNamedObject(L"message", Object{}), L"id"); blocks_.clear();}
            else if (!message_.empty() && event_type == "content_block_start") {
                const auto block = event.GetNamedObject(L"content_block", Object{}); const auto index = static_cast<int>(event.GetNamedNumber(L"index", -1));
                if (index < 0 || index > 100000) return;
                if (text(block, L"type") == "text") {const auto id = current_ + "/" + message_ + "/" + std::to_string(index); blocks_[index] = id;
                    const auto initial = text(block, L"text"); if (!initial.empty()) {emit(Kind::text_delta, id, initial); saw_reply_ = true;}}
                else if (text(block, L"type") == "tool_use") emit(Kind::tool, current_ + "/tool/" + text(block, L"id"), winrt::to_string(block.Stringify()));
            } else if (event_type == "content_block_delta") {
                const auto index = static_cast<int>(event.GetNamedNumber(L"index", -1)); const auto at = blocks_.find(index); const auto delta = event.GetNamedObject(L"delta", Object{});
                if (at != blocks_.end() && !finalized_.contains(at->second) && text(delta, L"type") == "text_delta") {emit(Kind::text_delta, at->second, text(delta, L"text")); saw_reply_ = true;}
            } else if (event_type == "content_block_stop") blocks_.erase(static_cast<int>(event.GetNamedNumber(L"index", -1)));
        } else if (type == "assistant") {
            const auto error = text(frame, L"error"); if (!error.empty() && error != "max_output_tokens") {failure_ = "Claude Code reported an assistant error: " + error; return;}
            const auto message = frame.GetNamedObject(L"message", Object{}); const auto id = text(message, L"id"); if (id.empty()) return;
            int index{};
            for (const auto& raw : message.GetNamedArray(L"content", Array{})) {
                const auto block = raw.GetObject(); const auto item = current_ + "/" + id + "/" + std::to_string(index++);
                if (text(block, L"type") == "text" && finalized_.insert(item).second) {emit(Kind::text_complete, item, text(block, L"text")); saw_reply_ = true;}
                else if (text(block, L"type") == "tool_use") emit(Kind::tool, current_ + "/tool/" + text(block, L"id"), winrt::to_string(block.Stringify()));
            }
        } else if (type == "result") {
            const auto answered = text(frame, L"user_message_uuid");
            bool matching = answered == current_, echoed = !answered.empty();
            for (const auto& id : frame.GetNamedArray(L"user_message_uuids", Array{})) {echoed = true; if (id.ValueType() == rpc_json::JsonValueType::String && id.GetString() == winrt::to_hstring(current_)) matching = true;}
            if (echoed && !matching) return;
            const auto origin = text(frame.GetNamedObject(L"origin", Object{}), L"kind"); if (!origin.empty() && origin != "human" && !matching) return;
            if (!echoed && lifecycle_ && !started_) return;
            if (frame.GetNamedBoolean(L"is_error", false) || text(frame, L"subtype").starts_with("error")) failure_ = "Claude Code could not finish this turn";
            if (!saw_reply_ && failure_.empty() && !text(frame, L"result").empty()) emit(Kind::text_complete, current_ + "/result", text(frame, L"result"));
            done_ = true;
        }
    }
    void run_turn(CodexTurn turn) {
        done_ = sent_ = saw_reply_ = started_ = false; blocks_.clear(); finalized_.clear(); failure_.clear(); current_ = uuid(); message_.clear();
        std::string outcome = "failed";
        try {
            emit(Kind::status, {}, "Connecting to Claude Code…"); connect(turn); if (stopping_ || cancel_) throw Cancelled{};
            const auto adapted=with_current_tool_context(launch_,turn);if(stopping_||cancel_)throw Cancelled{};
            const auto user = ClaudeProtocol::user_message(adapted, current_); sent_ = true; write(user); conversation_exists_ = true; emit(Kind::started, current_);
            bool interrupted{}; Clock::time_point deadline{};
            while (!done_) {
                if (stopping_) throw Cancelled{};
                pump();
                if (cancel_ && !interrupted) {Object request; put(request, L"subtype", "interrupt"); write(ClaudeProtocol::control("interrupt-" + current_, request)); interrupted = true; deadline = Clock::now() + launch_.interrupt_grace;}
                if (interrupted && Clock::now() >= deadline) throw Cancelled{};
                if (!done_) wait();
            }
            outcome = cancel_ ? "interrupted" : failure_.empty() ? "completed" : "failed";
            if (!failure_.empty()) emit(Kind::error, {}, failure_);
        } catch (const Cancelled&) {stop_process(); outcome = "interrupted";}
          catch (const winrt::hresult_error& error) {stop_process(); emit(Kind::error, {}, winrt::to_string(error.message()));}
          catch (const std::exception& error) {stop_process(); emit(Kind::error, {}, error.what());}
        for (const auto& [id, prompt] : prompts_) {
            try {write(ClaudeProtocol::response(id, ClaudeProtocol::deny(prompt.request)));} catch (...) {}
            emit(Kind::resolved, winrt::to_string(Json::CreateStringValue(winrt::to_hstring(id)).Stringify()));
        }
        prompts_.clear(); done_ = true; emit(Kind::completed, current_, outcome);
        std::lock_guard lock(mutex_); active_ = false;
        if (outcome != "completed") {paused_ = true; if (!queued_.empty()) emit_locked(Kind::queue_changed, {}, {}, "paused");}
        busy_ = !paused_ && !queued_.empty();
    }
    void run() noexcept {
        try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            struct Apartment {~Apartment(){winrt::uninit_apartment();}} apartment;
            while (!stopping_) {
                std::optional<CodexTurn> turn; bool refresh{};
                {std::unique_lock lock(mutex_); cv_.wait_for(lock, std::chrono::milliseconds(20), [&] {return stopping_ || input_ || refresh_ || (!paused_ && !queued_.empty());});
                    if (stopping_) break;
                    if (input_) turn.swap(input_);
                    else if (refresh_) {refresh = true; refresh_ = false; cancel_ = false;}
                    else if (!paused_ && !queued_.empty()) {
                        emit_locked(Kind::input, queued_.front().id, queued_.front().turn.text, "queued");
                        auto next = std::move(queued_.front()); queued_.pop_front(); queued_bytes_ -= input_size(next.turn); retire_locked(next.id);
                        turn = std::move(next.turn); active_ = true; busy_ = true; cancel_ = false;
                    }}
                if (turn) run_turn(std::move(*turn));
                else if (refresh) {
                    try {if (process_ && live_ && !catalog_.empty()) {emit(Kind::models, {}, catalog_);}
                        else {(void)launch(CodexTurn{}, true); stop_process();}}
                    catch (const Cancelled&) {stop_process(); emit(Kind::catalog_error, {}, "Claude model refresh was cancelled");}
                    catch (const winrt::hresult_error& error) {stop_process(); emit(Kind::catalog_error, {}, winrt::to_string(error.message()));}
                    catch (const std::exception& error) {stop_process(); emit(Kind::catalog_error, {}, error.what());}
                } else if (process_) {try {pump();} catch (...) {stop_process(); emit(Kind::status, {}, "Claude Code disconnected; the next turn will resume its saved conversation");}}
            }
        } catch (const winrt::hresult_error& error) {try {emit(Kind::error, {}, winrt::to_string(error.message())); emit(Kind::completed, {}, "failed");} catch (...) {}}
          catch (const std::exception& error) {try {emit(Kind::error, {}, error.what()); emit(Kind::completed, {}, "failed");} catch (...) {}}
          catch (...) {}
        stop_process(); std::lock_guard lock(mutex_); stopping_ = true; active_ = false; busy_ = false;
    }
};
} // namespace coincide
