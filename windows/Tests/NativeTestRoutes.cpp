#include "NativeTestRoutes.h"
#include <array>

namespace coincide::tests {
std::optional<int> provider_test_route(int,wchar_t**);
std::optional<int> data_test_route(int,wchar_t**);
std::optional<int> platform_test_route(int,wchar_t**);
std::optional<int> host_test_route(int,wchar_t**);
std::optional<int> browser_tool_test_route(int,wchar_t**);
std::optional<int> common_panel_test_route(std::string_view,const std::filesystem::path&,const winrt::Microsoft::UI::Xaml::XamlRoot&);
std::optional<int> desktop_panel_test_route(std::string_view,const std::filesystem::path&,const winrt::Microsoft::UI::Xaml::XamlRoot&);
std::optional<int> browser_panel_test_route(std::string_view,const std::filesystem::path&,const winrt::Microsoft::UI::Xaml::XamlRoot&);

std::optional<int> run_contract_test(int argc,wchar_t** argv){
    if(!argv||argc<2)return{};for(const auto route:{provider_test_route,data_test_route,platform_test_route,host_test_route,browser_tool_test_route})if(const auto result=route(argc,argv))return result;return{};
}
std::optional<std::string> ui_test_suite(std::wstring_view flag){
    if(flag==L"--persona-panel-tests")return "persona-panel";
    if(flag==L"--browser-tool-panel-tests")return "browser-tool-panel";
    if(flag==L"--credentials-controller-panel-tests")return "credentials-controller-panel";
    if(flag==L"--native-user-prompt-tests")return "native-user-prompt";
    if(flag==L"--code-hosting-panel-tests")return "code-hosting-panel";
    constexpr std::pair<std::wstring_view,std::string_view> routes[]={{L"--question-tests","question"},{L"--schedule-panel-tests","schedule-panel"},{L"--preferences-panel-tests","preferences-panel"},{L"--instruction-import-panel-tests","instruction-import-panel"},{L"--provider-accounts-panel-tests","provider-accounts-panel"},{L"--voice-panel-tests","voice-panel"},{L"--computer-use-panel-tests","computer-use-panel"},{L"--git-panel-tests","git-panel"},{L"--terminal-panel-tests","terminal-panel"},{L"--usage-panel-tests","usage-panel"},{L"--credentials-panel-tests","credentials-panel"}};
    for(const auto& route:routes)if(route.first==flag)return std::string(route.second);return{};
}
int run_ui_test(std::string_view suite,const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& root){
    if(const auto result=common_panel_test_route(suite,report,root))return *result;if(const auto result=desktop_panel_test_route(suite,report,root))return *result;if(const auto result=browser_panel_test_route(suite,report,root))return *result;return 2;
}
} // namespace coincide::tests
