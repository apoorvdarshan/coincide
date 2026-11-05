#pragma once
#include <winrt/Windows.Data.Json.h>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdint>
#include <functional>
#include <future>
#include <map>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>

namespace coincide {
namespace rpc_json = winrt::Windows::Data::Json;

struct RpcError : std::runtime_error {
    int code;
    explicit RpcError(std::string message, int value = 0) : std::runtime_error(std::move(message)), code(value) {}
};

// A host-thread-confined JSONL peer. Pipe readers enqueue bytes to the owning host, never call UI objects.
// Outgoing writes are queued by Send; this peer never waits for a subprocess or blocks a window's UI thread.
class RpcPeer {
public:
    using Clock = std::chrono::steady_clock;
    using Value = rpc_json::IJsonValue;
    using Send = std::function<void(std::string)>;
    using Notification = std::function<void(std::string, Value)>;
    using ServerRequest = std::function<void(Value, std::string, Value)>;
    struct Call { std::uint64_t id; std::future<Value> result; };

    explicit RpcPeer(Send send, Notification notification = {}, ServerRequest request = {})
        : send_(std::move(send)), notification_(std::move(notification)), server_request_(std::move(request)),
          owner_(std::this_thread::get_id()) {}
    ~RpcPeer() {
        // The owner closes explicitly before destroying the transport. Futures must never be stranded.
        for (auto& [id, pending] : pending_) {
            (void)id;
            pending.promise.set_exception(std::make_exception_ptr(RpcError("The agent connection was destroyed")));
        }
    }
    RpcPeer(const RpcPeer&) = delete;
    RpcPeer& operator=(const RpcPeer&) = delete;

    Call request(const std::string& method, const Value& params,
            std::chrono::milliseconds timeout = std::chrono::seconds(30), Clock::time_point now = Clock::now()) {
        owning_thread();
        if (closed_) throw RpcError("The agent connection is closed");
        if (method.empty() || timeout.count() <= 0 || timeout > std::chrono::hours(24)) {
            throw std::invalid_argument("An RPC request needs a method and a deadline between zero and 24 hours");
        }
        if (next_id_ >= 9007199254740991ULL) throw std::overflow_error("RPC request identifiers exhausted");
        const auto id = next_id_++;
        rpc_json::JsonObject envelope;
        envelope.SetNamedValue(L"id", rpc_json::JsonValue::CreateNumberValue(static_cast<double>(id)));
        envelope.SetNamedValue(L"method", rpc_json::JsonValue::CreateStringValue(winrt::to_hstring(method)));
        envelope.SetNamedValue(L"params", params);
        Pending pending{method, {}, now + timeout};
        auto future = pending.promise.get_future();
        pending_.emplace(id, std::move(pending));
        send(envelope);
        return {id, std::move(future)};
    }

    void notify(const std::string& method, const Value& params = rpc_json::JsonObject{}) {
        owning_thread();
        if (closed_) return;
        rpc_json::JsonObject envelope;
        envelope.SetNamedValue(L"method", rpc_json::JsonValue::CreateStringValue(winrt::to_hstring(method)));
        envelope.SetNamedValue(L"params", params);
        send(envelope);
    }

    void respond(const Value& id, const Value& result) {
        owning_thread();
        if (closed_) return;
        rpc_json::JsonObject envelope;
        envelope.SetNamedValue(L"id", id); envelope.SetNamedValue(L"result", result);
        send(envelope);
    }

    void respond_error(const Value& id, int code, const std::string& message) {
        owning_thread();
        if (closed_) return;
        rpc_json::JsonObject error, envelope;
        error.SetNamedValue(L"code", rpc_json::JsonValue::CreateNumberValue(code));
        error.SetNamedValue(L"message", rpc_json::JsonValue::CreateStringValue(winrt::to_hstring(message)));
        envelope.SetNamedValue(L"id", id); envelope.SetNamedValue(L"error", error);
        send(envelope);
    }

    bool receive(std::string_view line) {
        owning_thread();
        if (closed_) return false;
        rpc_json::JsonObject envelope{nullptr};
        try {
            if (!rpc_json::JsonObject::TryParse(winrt::to_hstring(line), envelope)) return false;
        } catch (const winrt::hresult_error&) { return false; }
        const auto null = rpc_json::JsonValue::CreateNullValue();
        const auto method = envelope.GetNamedValue(L"method", null);
        const auto id = envelope.GetNamedValue(L"id", null);
        if (method.ValueType() != rpc_json::JsonValueType::Null && method.ValueType() != rpc_json::JsonValueType::String) return false;
        if (method.ValueType() == rpc_json::JsonValueType::String) {
            auto name = winrt::to_string(method.GetString());
            const auto params = envelope.GetNamedValue(L"params", null);
            if (id.ValueType() == rpc_json::JsonValueType::Null) {
                if (notification_) notification_(std::move(name), params);
            } else if (id.ValueType() == rpc_json::JsonValueType::String || id.ValueType() == rpc_json::JsonValueType::Number) {
                if (server_request_) server_request_(id, std::move(name), params);
                else respond_error(id, -32601, "The client does not implement this request");
            } else { return false; }
            return true;
        }
        if (id.ValueType() != rpc_json::JsonValueType::Number) return false;
        const auto number = id.GetNumber();
        if (!std::isfinite(number) || number < 1 || number >= 9007199254740991.0 || std::floor(number) != number) return false;
        const auto key = static_cast<std::uint64_t>(number);
        const auto at = pending_.find(key);
        if (at == pending_.end()) return false; // Includes duplicate and late replies after a timeout.
        // An identifier by itself is not a successful response. Leave the request pending so
        // malformed frames cannot turn a failed operation into a fabricated null result.
        if (envelope.HasKey(L"result") == envelope.HasKey(L"error")) return false;
        const auto error = envelope.GetNamedValue(L"error", null);
        if (envelope.HasKey(L"error")) {
            std::string message = "The agent returned an invalid RPC error";
            int code{};
            if (error.ValueType() == rpc_json::JsonValueType::Object) {
                const auto value = error.GetObject();
                message = winrt::to_string(value.GetNamedString(L"message", winrt::to_hstring(message)));
                const auto raw = value.GetNamedNumber(L"code", 0);
                if (std::isfinite(raw) && raw >= INT_MIN && raw <= INT_MAX) code = static_cast<int>(raw);
            }
            at->second.promise.set_exception(std::make_exception_ptr(RpcError(std::move(message), code)));
        } else {
            at->second.promise.set_value(envelope.GetNamedValue(L"result", null));
        }
        pending_.erase(at);
        return true;
    }

    void expire(Clock::time_point now = Clock::now()) {
        owning_thread();
        for (auto at = pending_.begin(); at != pending_.end();) {
            if (now < at->second.deadline) { ++at; continue; }
            at->second.promise.set_exception(std::make_exception_ptr(RpcError("The agent timed out answering " + at->second.method)));
            at = pending_.erase(at);
        }
    }

    void close(const std::string& reason = "The agent connection closed") {
        owning_thread();
        if (closed_) return;
        closed_ = true;
        for (auto& [id, pending] : pending_) {
            (void)id;
            pending.promise.set_exception(std::make_exception_ptr(RpcError(reason)));
        }
        pending_.clear();
    }

private:
    struct Pending { std::string method; std::promise<Value> promise; Clock::time_point deadline; };
    Send send_;
    Notification notification_;
    ServerRequest server_request_;
    std::thread::id owner_;
    std::map<std::uint64_t, Pending> pending_;
    std::uint64_t next_id_{1};
    bool closed_{};

    void owning_thread() const {
        if (std::this_thread::get_id() != owner_) throw std::logic_error("Dispatch RPC work to its owning host thread");
    }
    void send(const rpc_json::JsonObject& value) {
        try { send_(winrt::to_string(value.Stringify())); }
        catch (...) { close("The agent transport failed while sending a message"); }
    }
};
} // namespace coincide
