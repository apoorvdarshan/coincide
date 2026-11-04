#include <windows.h>
#undef GetCurrentTime
#undef GetObject
#include "NativeTestRoutes.h"
#include "BackgroundHostTests.h"
#include "HostIPCTests.h"
#include "BackgroundAgentSessionTests.h"
#include "HostToolContextTests.h"
#include "HostedConversationReducerTests.h"
#include "NativeHostFactoryTests.h"

namespace coincide::tests {
std::optional<int> host_test_route(int argc,wchar_t** argv){
    if(argc==3&&std::wstring_view(argv[1])==L"--background-host-tests")return background_host_tests(std::filesystem::path(argv[2]));
    if(argc==4&&std::wstring_view(argv[1])==L"--host-ipc-tests")return host_ipc_tests(std::filesystem::path(argv[2]),std::filesystem::path(argv[3]));
    if(argc==4&&std::wstring_view(argv[1])==L"--background-agent-session-tests")return background_agent_session_tests(std::filesystem::path(argv[2]),std::filesystem::path(argv[3]));
    if(argc==4&&std::wstring_view(argv[1])==L"--host-tool-context-tests")return host_tool_context_tests(std::filesystem::path(argv[2]),std::filesystem::path(argv[3]));
    if(argc==3&&std::wstring_view(argv[1])==L"--hosted-conversation-reducer-tests")return hosted_conversation_reducer_tests(std::filesystem::path(argv[2]));
    if(argc==3&&std::wstring_view(argv[1])==L"--native-host-factory-tests")return std::async(std::launch::async,[report=std::filesystem::path(argv[2])]{winrt::init_apartment(winrt::apartment_type::multi_threaded);return native_host_factory_tests(report);}).get();
    return{};
}
} // namespace coincide::tests
