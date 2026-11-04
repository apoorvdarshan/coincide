#include <windows.h>
#undef GetCurrentTime
#undef GetObject
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include "NativeTestRoutes.h"
#include "BrowserLibraryTests.h"
#include "BrowserHistorySQLiteTests.h"
#include "BrowserLibraryPanelTests.h"
#include <future>

namespace coincide::tests {
std::optional<int> browser_library_test_route(int argc,wchar_t** argv){
    if(argc!=3)return{};const std::wstring_view flag(argv[1]);
    using Test=int(*)(const std::filesystem::path&);Test test{};
    if(flag==L"--browser-library-tests")test=browser_library_tests;
    else if(flag==L"--browser-history-sqlite-tests")test=browser_history_sqlite_tests;
    if(!test)return{};const std::filesystem::path report(argv[2]);
    return std::async(std::launch::async,[=]{
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        struct Apartment{~Apartment(){winrt::uninit_apartment();}}apartment;
        return test(report);
    }).get();
}
std::optional<int> browser_library_panel_test_route(std::string_view suite,const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& root){
    if(suite=="browser-library-panel")return browser_library_panel_tests(report,root);
    return{};
}
} // namespace coincide::tests
