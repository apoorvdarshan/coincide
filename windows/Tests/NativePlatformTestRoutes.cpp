#include <winsock2.h>
#include <windows.h>
#undef GetCurrentTime
#include "NativeTestRoutes.h"
#include "TerminalTests.h"
#include "BrowserTests.h"
#include "PreviewTests.h"
#include "CredentialTests.h"
#include "BrowserCredentialTests.h"
#include "DesktopServicesTests.h"
#include "WindowsNotificationsTests.h"
#include "VoiceSettingsTests.h"
#include "GlobalVoiceShortcutTests.h"
#include "VoiceTests.h"
#include "ComputerUseTests.h"
#include "ComputerUseProcessTests.h"
#include "ComputerUseSettingsTests.h"
#include "ComputerUseDesktopLeaseTests.h"
#include "AppToolBridgeTests.h"
#include "ScheduleToolTests.h"

namespace coincide::tests {
std::optional<int> platform_test_route(int argc,wchar_t** argv){
    const std::wstring_view flag(argv[1]);if(argc==4){const std::filesystem::path report(argv[2]),fixture(argv[3]);if(flag==L"--voice-tests")return voice_tests(report,fixture);if(flag==L"--computer-use-process-tests")return computer_use_process_tests(report,fixture);if(flag==L"--computer-use-desktop-lease-tests")return computer_use_desktop_lease_tests(report,fixture);return{};}if(argc!=3)return{};
    const std::filesystem::path argument(argv[2]);if(flag==L"--terminal-tests")return terminal_tests(argument);if(flag==L"--voice-shortcut-tests")return global_voice_shortcut_tests(argument);
    const std::pair<std::wstring_view,int(*)(const std::filesystem::path&)> routes[]={{L"--browser-tests",browser_tests},{L"--preview-tests",preview_tests},{L"--credential-tests",credential_tests},{L"--browser-credential-tests",browser_credential_tests},{L"--desktop-services-tests",desktop_services_tests},{L"--notifications-tests",windows_notifications_tests},{L"--voice-settings-tests",voice_settings_tests},{L"--computer-use-tests",computer_use_tests},{L"--computer-use-settings-tests",computer_use_settings_tests},{L"--app-tool-bridge-tests",app_tool_bridge_tests},{L"--schedule-tool-tests",schedule_tool_tests}};
    for(const auto& route:routes)if(route.first==flag)return route.second(argument);return{};
}
} // namespace coincide::tests
