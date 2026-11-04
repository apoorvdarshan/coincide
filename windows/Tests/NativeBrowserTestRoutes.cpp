#include <windows.h>
#undef GetCurrentTime
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include "NativeTestRoutes.h"
#include "BrowserToolTests.h"
#include "BrowserToolPanelTests.h"
#include "CredentialsControllerTests.h"
#include "NativeUserPromptTests.h"
#include "CodeHostingTests.h"
#include "CodeHostingPanelTests.h"
#include <future>

namespace coincide::tests {
std::optional<int> browser_tool_test_route(int argc,wchar_t** argv){
    if(argc!=3)return{};const std::wstring_view flag(argv[1]);const std::filesystem::path report(argv[2]);
    if(flag==L"--browser-tool-tests")return browser_tool_tests(report);
    if(flag==L"--credentials-controller-tests")return std::async(std::launch::async,[report]{winrt::init_apartment(winrt::apartment_type::multi_threaded);return credentials_controller_tests(report);}).get();
    if(flag==L"--code-hosting-tests")return code_hosting_tests(report);return{};
}
std::optional<int> browser_panel_test_route(std::string_view suite,const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& root){
    if(suite=="browser-tool-panel")return browser_tool_panel_tests(report,root);
    if(suite=="credentials-controller-panel")return credentials_controller_panel_tests(report,root);
    if(suite=="native-user-prompt")return native_user_prompt_tests(report,root);
    if(suite=="code-hosting-panel")return code_hosting_panel_tests(report,root);return{};
}
} // namespace coincide::tests
