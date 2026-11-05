#include <windows.h>
#undef GetCurrentTime
#undef GetObject
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include "NativeTestRoutes.h"
#include "InstructionGitSyncTests.h"
#include "InstructionGitPanelTests.h"
#include <future>

namespace coincide::tests {
std::optional<int> instruction_git_test_route(int argc,wchar_t** argv){
    if(argc!=3||std::wstring_view(argv[1])!=L"--instruction-git-sync-tests")return{};
    const std::filesystem::path report(argv[2]);
    return std::async(std::launch::async,[=]{
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        struct Apartment{~Apartment(){winrt::uninit_apartment();}}apartment;
        return instruction_git_sync_tests(report);
    }).get();
}
std::optional<int> instruction_git_panel_test_route(std::string_view suite,const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& root){
    if(suite=="instruction-git-panel")return instruction_git_panel_tests(report,root);
    return{};
}
} // namespace coincide::tests
