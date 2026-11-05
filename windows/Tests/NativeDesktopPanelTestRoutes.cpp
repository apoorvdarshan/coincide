#include <windows.h>
#undef GetCurrentTime
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include "NativeTestRoutes.h"
#include "VoicePanelTests.h"
#include "ComputerUsePanelTests.h"
#include "GitPanelTests.h"
#include "TerminalPanelTests.h"

namespace coincide::tests {
std::optional<int> desktop_panel_test_route(std::string_view suite,const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& root){
    using Test=int(*)(const std::filesystem::path&,const winrt::Microsoft::UI::Xaml::XamlRoot&);const std::pair<std::string_view,Test> routes[]={{"voice-panel",voice_panel_tests},{"computer-use-panel",computer_use_panel_tests},{"git-panel",git_panel_tests},{"terminal-panel",terminal_panel_tests}};
    for(const auto& route:routes)if(route.first==suite)return route.second(report,root);return{};
}
} // namespace coincide::tests
