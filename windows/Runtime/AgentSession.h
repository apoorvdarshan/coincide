#pragma once
#include "CodexProtocol.h"
#include <filesystem>

namespace coincide {
struct CodexLaunch {
    std::filesystem::path executable;
    std::vector<std::wstring> arguments{L"app-server"};
    std::filesystem::path cwd;
    std::string session_id;
    std::string instructions;
    std::chrono::milliseconds request_timeout{std::chrono::seconds(60)};
    std::chrono::milliseconds interrupt_grace{std::chrono::seconds(5)};
};

using AgentLaunch = CodexLaunch;

// Shared plain-value boundary between native provider workers and WinUI. No COM/UI object crosses it.
struct SessionEvent {
    enum class Kind { status, session, started, text_delta, text_complete, tool, prompt, resolved, completed, error,
        models, catalog_error, queued, queue_changed, input, delivery_failed };
    Kind kind;
    std::string id, text, detail;
};
struct AgentQueuedTurn { std::string id; CodexTurn turn; };
class AgentSession {
public:
    virtual ~AgentSession() = default;
    virtual bool send(CodexTurn) = 0;
    virtual bool busy() const noexcept = 0;
    virtual void interrupt() noexcept = 0;
    virtual bool refresh_models() = 0;
    virtual bool queue(CodexTurn, std::string) = 0;
    virtual std::vector<AgentQueuedTurn> queued() const = 0;
    virtual std::size_t queued_count() const = 0;
    virtual bool queue_paused() const = 0;
    virtual bool remove_queued(const std::string&) = 0;
    virtual bool resume_queue() = 0;
    virtual bool steer(CodexTurn, std::string) = 0;
    virtual void respond(std::string, std::string) = 0;
    virtual std::vector<SessionEvent> take_events() = 0;
    virtual void close() noexcept = 0;
    virtual void shutdown() noexcept = 0;
};
} // namespace coincide
