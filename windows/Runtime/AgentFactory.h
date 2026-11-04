#pragma once
#include "CodexSession.h"
#include "ClaudeSession.h"
#include "OpenCodeSession.h"
#include "ProviderDiscovery.h"
#include "VerifiedACPLaunch.h"

namespace coincide {
inline std::unique_ptr<AgentSession> make_agent_session(const std::string& provider, CodexLaunch launch,std::optional<ACPLaunchOptions> acp=std::nullopt) {
    if(provider=="cursor"||provider=="grok"||provider=="antigravity") {
        if(!acp||!acp->verify_account||!acp->credential_revision||!acp->profile_lease||acp->profile_id.empty()||acp->provider!=provider||acp->account.current.size()!=64||acp->account.current.find_first_not_of("0123456789abcdef")!=std::string::npos)throw std::invalid_argument("Choose a current verified provider profile before enabling this ACP adapter");
        wchar_t current[32768]{};const auto count=GetModuleFileNameW(nullptr,current,32768);std::error_code error;
        const bool fixture=launch.fixture_account_reviewed&&launch.arguments.size()==2&&launch.arguments.front()==L"--acp-session-fixture"&&count&&count<32768&&std::filesystem::equivalent(launch.executable,std::filesystem::path(current),error)&&!error;
        if(provider!="cursor"&&!fixture)throw std::invalid_argument("This ACP provider's Windows account identity is not verified yet");
        if(!fixture&&launch.profile_directory.empty())throw std::invalid_argument("The selected ACP account requires its explicit private profile folder");
        if(!fixture&&!launch.session_id.empty()&&(launch.saved_profile_id.empty()||launch.saved_account_scope.empty()))throw std::invalid_argument("This saved ACP conversation needs owner review of its original verified account");
        if(launch.profile_id!=acp->profile_id||(!launch.saved_account_scope.empty()&&launch.saved_account_scope!=acp->account.current)||(!launch.saved_profile_id.empty()&&launch.saved_profile_id!=launch.profile_id))throw std::invalid_argument("The selected ACP profile does not match this conversation's saved account");
        if(!launch.profile_directory.empty()&&(!std::filesystem::equivalent(launch.profile_directory,acp->profile_lease->root(),error)||error))throw std::invalid_argument("The ACP launch profile folder differs from its verified account");
        return std::make_unique<ACPSession>(provider,std::move(launch),std::move(*acp));
    }
    if(acp)throw std::invalid_argument("ACP account options cannot be applied to another provider");
    if (provider == "codex") return std::make_unique<CodexSession>(std::move(launch));
    if (provider == "claude") return std::make_unique<ClaudeSession>(std::move(launch));
    if (provider == "opencode") return std::make_unique<OpenCodeSession>(std::move(launch));
    throw std::invalid_argument("This Windows provider adapter is not implemented yet");
}
} // namespace coincide
