#include <windows.h>
#include <objbase.h>
#undef GetCurrentTime
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include "NativeTestRoutes.h"
#include "QuestionFormTests.h"
#include "SchedulePanelTests.h"
#include "PreferencesPanelTests.h"
#include "InstructionImportPanelTests.h"
#include "ProviderAccountsPanelTests.h"
#include "UsagePanelTests.h"
#include "CredentialsPanelTests.h"
#include "PersonaPanelTests.h"

namespace coincide::tests {
std::optional<int> common_panel_test_route(std::string_view suite,const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& root){
    using Test=int(*)(const std::filesystem::path&,const winrt::Microsoft::UI::Xaml::XamlRoot&);const std::pair<std::string_view,Test> routes[]={{"question",question_form_tests},{"schedule-panel",schedule_panel_tests},{"preferences-panel",preferences_panel_tests},{"instruction-import-panel",instruction_import_panel_tests},{"provider-accounts-panel",provider_accounts_panel_tests},{"usage-panel",usage_panel_tests},{"credentials-panel",credentials_panel_tests}};
    if(suite=="persona-panel")return persona_panel_tests(report,root);
    for(const auto& route:routes)if(route.first==suite)return route.second(report,root);return{};
}
} // namespace coincide::tests
