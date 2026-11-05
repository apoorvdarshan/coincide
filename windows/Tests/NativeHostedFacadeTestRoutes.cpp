#include <windows.h>
#undef GetCurrentTime
#undef GetObject
#include "NativeTestRoutes.h"
#include "NativeHostConnectionTests.h"
#include "HostedClientStateTests.h"
#include "HostedAgentSessionTests.h"
#include "NativeBackgroundHostTests.h"
#include "OpenCodeAccountScopeTests.h"
#include "NativeHostEntrypointTests.h"
#include "HostedAppBootstrapTests.h"
#include "HostedInputRecoveryTests.h"
#include <future>

namespace coincide::tests {
namespace {
template<class Test>int on_mta(Test test){
    return std::async(std::launch::async,[test=std::move(test)]{
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        struct Apartment{~Apartment(){winrt::uninit_apartment();}}apartment;
        return test();
    }).get();
}
}
std::optional<int> hosted_facade_test_route(int argc,wchar_t** argv){
    if(argc!=3&&argc!=4)return{};
    const std::wstring_view flag(argv[1]);const std::filesystem::path report(argv[2]);
    if(argc==4){
        const std::filesystem::path fixture(argv[3]);
        if(flag==L"--native-host-connection-tests")return on_mta([=]{return native_host_connection_tests(report,fixture);});
        if(flag==L"--hosted-agent-session-tests")return on_mta([=]{return hosted_agent_session_tests(report,fixture);});
        return{};
    }
    if(flag==L"--hosted-client-state-tests")return on_mta([=]{return hosted_client_state_tests(report);});
    if(flag==L"--native-background-host-tests")return on_mta([=]{return native_background_host_tests(report);});
    if(flag==L"--opencode-account-scope-tests")return on_mta([=]{return opencode_account_scope_tests(report);});
    if(flag==L"--hosted-app-bootstrap-tests")return on_mta([=]{return hosted_app_bootstrap_tests(report);});
    if(flag==L"--hosted-input-recovery-tests")return on_mta([=]{return hosted_input_recovery_tests(report);});
    if(flag==L"--native-host-entrypoint-tests")return on_mta([=]{return native_host_entrypoint_tests(report);});
    return{};
}
} // namespace coincide::tests
