#pragma once
#include "CodexSession.h"
#include "ClaudeSession.h"
#include "OpenCodeSession.h"
#include "ProviderDiscovery.h"

namespace coincide {
inline std::unique_ptr<AgentSession> make_agent_session(const std::string& provider, CodexLaunch launch) {
    if (provider == "codex") return std::make_unique<CodexSession>(std::move(launch));
    if (provider == "claude") return std::make_unique<ClaudeSession>(std::move(launch));
    if (provider == "opencode") return std::make_unique<OpenCodeSession>(std::move(launch));
    throw std::invalid_argument("This Windows provider adapter is not implemented yet");
}
} // namespace coincide
