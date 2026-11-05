#include <windows.h>
#include <objbase.h>
#undef GetCurrentTime
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include "NativeTestRoutes.h"
#include "StoreTests.h"
#include "DisplayTests.h"
#include "GitTests.h"
#include "GitManagementTests.h"
#include "WindowsCalendarTests.h"
#include "ScheduleStoreTests.h"
#include "PreferencesTests.h"
#include "InstructionImportTests.h"
#include "ImportStoreTests.h"
#include "BotTests.h"
#include "BotWorkspaceTests.h"
#include "HostPersistenceTests.h"
#include "RepositoryLeaseTests.h"
#include "ConversationSearchStoreTests.h"
#include "ProjectFileIndexTests.h"

namespace coincide::tests {
std::optional<int> data_test_route(int argc,wchar_t** argv){
    if(argc!=3)return{};const std::wstring_view flag(argv[1]);const std::filesystem::path argument(argv[2]);
    const std::pair<std::wstring_view,int(*)(const std::filesystem::path&)> routes[]={{L"--store-tests",store_tests},{L"--display-tests",display_tests},{L"--git-tests",git_tests},{L"--git-management-tests",git_management_tests},{L"--calendar-tests",windows_calendar_tests},{L"--schedule-tests",schedule_store_tests},{L"--preferences-tests",preferences_tests},{L"--instructions-tests",instruction_tests},{L"--imports-tests",import_tests},{L"--import-store-tests",import_store_tests}};
    if(flag==L"--bot-tests")return bot_tests(argument);if(flag==L"--bot-workspace-tests")return bot_workspace_tests(argument);
    if(flag==L"--host-persistence-tests")return host_persistence_tests(argument);
    if(flag==L"--git-repository-identity-tests")return git_repository_identity_tests(argument);
    if(flag==L"--repository-lease-tests")return repository_lease_tests(argument);
    if(flag==L"--conversation-search-store-tests")return conversation_search_store_tests(argument);
    if(flag==L"--project-file-index-tests")return project_file_index_tests(argument);
    for(const auto& route:routes)if(route.first==flag)return route.second(argument);return{};
}
} // namespace coincide::tests
