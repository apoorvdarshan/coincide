#include <windows.h>
#undef GetCurrentTime
#include "NativeTestRoutes.h"
#include "SessionTests.h"
#include "ProtocolTests.h"
#include "ConnectionTests.h"
#include "ProviderTests.h"
#include "ClaudeTests.h"
#include "OpenCodeTests.h"
#include "ACPTests.h"
#include "ProviderAccountsTests.h"
#include "ToolContextTests.h"
#include "UsageTests.h"
#include "UsageRuntimeTests.h"

namespace coincide::tests {
std::optional<int> provider_test_route(int argc,wchar_t** argv){
    const std::wstring_view flag(argv[1]);if(flag==L"--provider-account-fixture"&&argc>=5)return provider_account_fixture(argc,argv);if(argc!=3)return{};
    const std::filesystem::path argument(argv[2]);
    const std::pair<std::wstring_view,int(*)(const std::filesystem::path&)> routes[]={{L"--protocol-tests",protocol_tests},{L"--connection-tests",connection_tests},{L"--session-tests",session_tests},{L"--provider-tests",provider_tests},{L"--claude-tests",claude_tests},{L"--opencode-tests",opencode_tests},{L"--acp-tests",acp_tests},{L"--provider-accounts-tests",provider_accounts_tests},{L"--tool-context-tests",tool_context_tests},{L"--usage-tests",usage_tests},{L"--usage-runtime-tests",usage_runtime_tests}};
    for(const auto& route:routes)if(route.first==flag)return route.second(argument);
    const std::wstring mode(argv[2]);if(flag==L"--codex-session-fixture")return codex_session_fixture(mode);if(flag==L"--claude-session-fixture")return claude_session_fixture(mode);if(flag==L"--claude-account-fixture")return claude_account_fixture(mode);if(flag==L"--opencode-http-fixture")return opencode_http_fixture(mode);if(flag==L"--acp-session-fixture")return acp_session_fixture(mode);if(flag==L"--acp-terminal-fixture")return acp_terminal_fixture(mode);if(flag==L"--rpc-fixture")return rpc_fixture(mode);return{};
}
} // namespace coincide::tests
