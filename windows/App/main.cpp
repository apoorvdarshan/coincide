#include <windows.h>
#include <shellapi.h>
#undef GetCurrentTime
#include <shlobj.h>
#include <shobjidl.h>
#include <microsoft.ui.xaml.window.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.Windows.ApplicationModel.Resources.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.System.h>
#include "WorkspaceStore.h"
#include "../Runtime/CodexSession.h"
#include "../Runtime/AgentFactory.h"
#include "../Core/Handoff.h"
#include "DisplayItem.h"
#include "GitPanel.h"
#include "QuestionForm.h"
#include "BrowserPanel.h"
#include "TerminalPanel.h"
#include "PreviewPanel.h"
#include "PreferencesPanel.h"
#include "SchedulePanel.h"
#include "../Runtime/DesktopServices.h"
#include "InstructionsPanel.h"
#include "ImportPanel.h"
#include "ProviderAccountsPanel.h"
#include "../Runtime/WindowsNotifications.h"
#include "VoicePanel.h"
#include "../Runtime/ComputerUseNative.h"
#include "../Runtime/ComputerUseProcess.h"
#include "ComputerUsePanel.h"
#include "../Runtime/AppToolBridge.h"
#include "../Runtime/VerifiedACPLaunch.h"
#include "../Tests/NativeTestRoutes.h"
#include "UsagePanel.h"
#include "PersonaPanel.h"
#include "BotWorkspace.h"
#include "CredentialsController.h"
#include "NativeUserPrompt.h"
#include "CodeHostingPanel.h"
#include "../Runtime/RepositoryLease.h"
#include <winrt/Windows.Globalization.h>
#include <memory>
#include <chrono>
#include <ctime>
#include <iomanip>
#include <sstream>

namespace xaml = winrt::Microsoft::UI::Xaml;
namespace controls = winrt::Microsoft::UI::Xaml::Controls;
namespace foundation = winrt::Windows::Foundation;
using winrt::hstring;

namespace {
void diagnostic(const hstring& message) noexcept {
    try {
        wchar_t path[32768]{};
        const auto length = GetEnvironmentVariableW(L"COINCIDE_DIAGNOSTICS_PATH", path, 32768);
        if (length > 0 && length < 32768) {
            std::ofstream output(std::filesystem::path(path), std::ios::app);
            output << winrt::to_string(message) << '\n';
        }
    } catch (...) { }
}
hstring label(const wchar_t* key, const wchar_t* fallback) {
    try {
        winrt::Microsoft::Windows::ApplicationModel::Resources::ResourceLoader resources;
        const auto value = resources.GetString(key);
        if (!value.empty()) return value;
    } catch (const winrt::hresult_error&) { }
    return coincide::ui_text(fallback);
}
void identify(const xaml::DependencyObject& element, const wchar_t* id) {
    xaml::Automation::AutomationProperties::SetAutomationId(element, id);
}
controls::Button button(const wchar_t* resource, const wchar_t* fallback, const wchar_t* id) {
    controls::Button value;
    value.Content(winrt::box_value(label(resource, fallback)));
    identify(value, id);
    return value;
}
void add_choice(const controls::ComboBox& picker,const hstring& title){picker.DisplayMemberPath(L"Text");picker.Items().Append(coincide::display_item(winrt::to_string(title)));}
controls::AppBarButton toolbar_button(const wchar_t* resource,const wchar_t* fallback,const wchar_t* id){controls::AppBarButton value;value.Label(label(resource,fallback));identify(value,id);return value;}
std::filesystem::path data_directory() {
    wchar_t override_path[32768]{};
    const auto length = GetEnvironmentVariableW(L"COINCIDE_DATA_DIR", override_path, 32768);
    if (length >= 32768) throw std::runtime_error("The data directory path is too long");
    if (length) return override_path;
    PWSTR local{};
    winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr, &local));
    const std::filesystem::path root(local);
    CoTaskMemFree(local);
    return root / L"Coincide Windows Preview";
}

struct App : xaml::ApplicationT<App, xaml::Markup::IXamlMetadataProvider> {
    xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider metadata;
    xaml::Window window{nullptr};
    controls::Grid root{nullptr};
    controls::Grid tools_host{nullptr};
    controls::ContentControl tools_content{nullptr};
    controls::Grid tool_views{nullptr};
    controls::ScrollViewer git_view{nullptr};
    controls::TextBlock tools_title{nullptr};
    controls::ColumnDefinition tools_column{nullptr};
    std::shared_ptr<coincide::GitPanel> git_panel;
    std::string git_project;
    std::shared_ptr<coincide::code_hosting_panel::Panel> hosting_panel;
    controls::ScrollViewer hosting_view{nullptr};
    std::string hosting_project;
    std::shared_ptr<coincide::BrowserPanel> browser_panel;
    std::shared_ptr<coincide::TerminalPanel> terminal_panel;
    std::shared_ptr<coincide::PreviewPanel> preview_panel;
    std::string visible_tool;
    std::uint64_t latest_scroll_generation{};
    bool latest_scroll_pending{true},latest_layout_active{};
    std::string latest_scroll_trace;
    coincide::Preferences preferences;
    std::unique_ptr<coincide::PreferencesStore> preferences_store;
    std::unique_ptr<coincide::DesktopServices> desktop;
    coincide::PowerRequest power_request;
    std::shared_ptr<coincide::SchedulePanel> schedule_panel;
    std::shared_ptr<coincide::InstructionsPanel> instructions_panel;
    std::shared_ptr<coincide::ImportPanel> import_panel;
    std::shared_ptr<coincide::ProviderAccountsPanel> accounts_panel;
    std::shared_ptr<coincide::VoicePanel> voice_panel;
    std::uint64_t draft_revision{};
    std::shared_ptr<coincide::WindowsNotifications> notifications;
    std::shared_ptr<coincide::computer_use::Controller> computer_use;
    std::shared_ptr<coincide::app_tools::AppToolBridge> tool_bridge;
    std::unordered_set<std::string> terminal_tool_threads;
    std::vector<std::future<void>> tool_workers;
    std::shared_ptr<coincide::UsageStore> usage_store;
    std::shared_ptr<coincide::UsagePanel> usage_panel;
    std::shared_ptr<coincide::BotStore> bot_store;
    std::unique_ptr<coincide::BotWorkspace> bot_workspace;
    std::shared_ptr<coincide::PersonaPanel> persona_panel;
    std::shared_ptr<coincide::CredentialsController> credentials_controller;
    controls::ScrollViewer credentials_view{nullptr};
    std::deque<coincide::UsageRecord> pending_usage;
    std::string usage_warning;
    std::uint64_t usage_retry_at{};
    std::unordered_map<std::string,coincide::ProviderAccountMetadata> account_metadata;
    std::string account_browser_context;
    std::vector<coincide::StoredSessionIdentity> import_identities;
    bool imports_loading{};

    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer platform_timer{nullptr};
    bool preferences_writable{},quitting{},quit_when_safe{},schedule_wake_pending{};
    std::string preferences_error,platform_error;
    std::uint64_t last_platform_tick{};


    controls::ListView sidebar{nullptr};
    controls::ListView transcript{nullptr};
    controls::TextBox composer{nullptr};
    controls::TextBox search{nullptr};
    controls::TextBlock title{nullptr};
    controls::TextBlock state{nullptr};
    controls::ComboBox providers{nullptr};
    controls::ComboBox thread_filter{nullptr};
    controls::StackPanel attachments_view{nullptr};
    controls::StackPanel queued_view{nullptr};
    controls::Button queue_button{nullptr},steer_button{nullptr},models_button{nullptr};
    controls::ComboBox model_picker{nullptr},effort_picker{nullptr},tier_picker{nullptr};
    controls::TextBox custom_model{nullptr};
    std::vector<std::string> model_ids,effort_ids,tier_ids;
    std::vector<coincide::CodexModel> dialog_models;
    controls::Button send_button{nullptr}, stop_button{nullptr};
    controls::StackPanel prompts_view{nullptr};
    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer save_timer{nullptr};
    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer session_timer{nullptr};
    std::unique_ptr<coincide::WorkspaceStore> store;
    coincide::Workspace workspace;
    std::vector<std::string> visible;
    std::string selected;
    bool selecting{};
    bool archived{};
    bool writable{};
    bool dirty_index{};
    std::string persistence_error;
    bool closing{};
    bool fixture_preview{},desktop_fixture{};
    std::filesystem::path question_test_report;
    int* question_test_result{};
    std::string native_ui_suite{"question"};
    coincide::ThreadView thread_view{coincide::ThreadView::inbox};
    bool dialog_open{};
    struct RunningThread {
        std::unique_ptr<coincide::AgentSession> session;
        std::unordered_map<std::string, coincide::SessionEvent> prompts;
        std::string status;
        std::string provider;
        std::string profile_id{"default"},account_scope;
        std::filesystem::path cwd;
        std::vector<coincide::CodexModel> models;
        bool failed{};
        // The worker can finish before its final output reaches the UI and the store.
        bool awaiting_completion{};
        bool completion_received{};
        std::string schedule_id,schedule_delivery;
        bool schedule_success{},schedule_uncertain{},schedule_result_pending{},notify_completion{};
        std::string schedule_status;
        std::unique_ptr<coincide::UsageTurn> usage;
    };
    std::unordered_map<std::string, RunningThread> running;
    std::unordered_set<std::string> dirty_threads;

    explicit App(bool fixture = false,bool desktop_test=false) : fixture_preview(fixture),desktop_fixture(desktop_test) {
        diagnostic(L"Application constructed");
        UnhandledException([this](const auto&, const xaml::UnhandledExceptionEventArgs& args) {
            diagnostic(args.Message());
            args.Handled(true);
            show_error(args.Message());
        });
        diagnostic(L"Application handlers registered");
    }

    xaml::Markup::IXamlType GetXamlType(const winrt::Windows::UI::Xaml::Interop::TypeName& name) {
        return metadata.GetXamlType(name);
    }
    xaml::Markup::IXamlType GetXamlType(const hstring& name) { return metadata.GetXamlType(name); }
    winrt::com_array<xaml::Markup::XmlnsDefinition> GetXmlnsDefinitions() { return metadata.GetXmlnsDefinitions(); }

    void OnLaunched(const xaml::LaunchActivatedEventArgs&) {
        diagnostic(L"OnLaunched");
        if (window) return;
        Resources().MergedDictionaries().Append(controls::XamlControlsResources{});
        diagnostic(L"Control resources initialized");
        if(!question_test_report.empty()){
            window=xaml::Window{};window.Title(L"Coincide — Question Fixture Test");root=controls::Grid{};window.Content(root);
            root.Loaded([this](const auto&,const auto&){window.DispatcherQueue().TryEnqueue([this]{
                const auto result=coincide::tests::run_ui_test(native_ui_suite,question_test_report,root.XamlRoot());if(question_test_result)*question_test_result=result;
                window.Close();xaml::Application::Current().Exit();
            });});
            if(native_ui_suite=="browser-tool-panel")window.AppWindow().Resize({1100,1150});window.Activate();if(native_ui_suite!="browser-tool-panel")window.AppWindow().Hide();return;
        }
        try{
            preferences_store=std::make_unique<coincide::PreferencesStore>(data_directory());preferences=preferences_store->open();preferences_writable=true;
            if(!preferences.language.empty())winrt::Windows::Globalization::ApplicationLanguages::PrimaryLanguageOverride(winrt::to_hstring(preferences.language));
        }catch(const winrt::hresult_error& error){preferences_error=winrt::to_string(error.message());}catch(const std::exception& error){preferences_error=error.what();}
        if(!fixture_preview||desktop_fixture){desktop=std::make_unique<coincide::DesktopServices>(data_directory());if(!desktop->primary()){xaml::Application::Current().Exit();return;}}
        window = xaml::Window{};
        window.Title(fixture_preview ? L"Coincide — Protocol Fixture Test" : L"Coincide — Windows Preview");
        window.AppWindow().Resize({1100, 780});
        root = controls::Grid{};
        auto left = controls::ColumnDefinition{}; left.Width({260, xaml::GridUnitType::Pixel});
        root.ColumnDefinitions().Append(left);
        root.ColumnDefinitions().Append(controls::ColumnDefinition{});
        tools_column=controls::ColumnDefinition{};tools_column.Width({0,xaml::GridUnitType::Pixel});root.ColumnDefinitions().Append(tools_column);
        window.Content(root);apply_appearance();
        tools_host=controls::Grid{};tools_host.Visibility(xaml::Visibility::Collapsed);tools_host.RowDefinitions().Append(controls::RowDefinition{});tools_host.RowDefinitions().GetAt(0).Height({1,xaml::GridUnitType::Auto});tools_host.RowDefinitions().Append(controls::RowDefinition{});
        controls::StackPanel tools_header;tools_header.Orientation(controls::Orientation::Horizontal);tools_header.Spacing(12);tools_header.Padding({12,8,12,8});
        tools_title=controls::TextBlock{};tools_title.VerticalAlignment(xaml::VerticalAlignment::Center);tools_header.Children().Append(tools_title);
        auto close_tools=button(L"Close",L"Close",L"CloseTools");close_tools.Click([this](const auto&,const auto&){hide_tools();});tools_header.Children().Append(close_tools);tools_host.Children().Append(tools_header);
        tools_content=controls::ContentControl{};tool_views=controls::Grid{};tools_content.Content(tool_views);tools_content.HorizontalContentAlignment(xaml::HorizontalAlignment::Stretch);tools_content.VerticalContentAlignment(xaml::VerticalAlignment::Stretch);controls::Grid::SetRow(tools_content,1);tools_host.Children().Append(tools_content);controls::Grid::SetColumn(tools_host,2);root.Children().Append(tools_host);

        auto sidebar_grid = controls::Grid{};
        sidebar_grid.Padding({12, 12, 12, 12});
        auto sidebar_header = controls::RowDefinition{}; sidebar_header.Height({1, xaml::GridUnitType::Auto});
        sidebar_grid.RowDefinitions().Append(sidebar_header);
        sidebar_grid.RowDefinitions().Append(controls::RowDefinition{});
        auto sidebar_footer = controls::RowDefinition{}; sidebar_footer.Height({1, xaml::GridUnitType::Auto});
        sidebar_grid.RowDefinitions().Append(sidebar_footer);
        root.Children().Append(sidebar_grid);

        controls::StackPanel sidebar_top;
        sidebar_top.Spacing(8);
        auto create = button(L"NewChat", L"New Chat", L"NewChat");
        create.HorizontalAlignment(xaml::HorizontalAlignment::Stretch);
        create.Click([this](const auto&, const auto&) { create_thread(); });
        sidebar_top.Children().Append(create);
        auto bots=button(L"Bots",L"Bots",L"OpenBots");bots.HorizontalAlignment(xaml::HorizontalAlignment::Stretch);
        bots.Click([this](const auto&,const auto&){show_bots();});sidebar_top.Children().Append(bots);
        auto project = button(L"AddProject", L"Add Project…", L"AddProject");
        project.HorizontalAlignment(xaml::HorizontalAlignment::Stretch);
        project.Click([this](const auto&, const auto&) { add_project(); });
        sidebar_top.Children().Append(project);
        search = controls::TextBox{};
        search.PlaceholderText(label(L"Search", L"Search"));
        identify(search, L"ThreadSearch");
        search.TextChanged([this](const auto&, const auto&) { refresh_sidebar(); });
        sidebar_top.Children().Append(search);
        thread_filter = controls::ComboBox{}; identify(thread_filter, L"ThreadFilter");
        for (const auto& key : {std::pair{L"Threads",L"Threads"}, {L"ArchivedThreads",L"Archived threads"}, {L"Snooze",L"Snooze"}, {L"Settled",L"Settled"}, {L"DeletedThreads",L"Deleted Threads"}, {L"AllThreads",L"All Threads"}}) {
            add_choice(thread_filter,label(key.first,key.second));
        }
        thread_filter.SelectedIndex(0);
        thread_filter.SelectionChanged([this](const auto&, const auto&) {
            if (selecting || thread_filter.SelectedIndex() < 0) return;
            thread_view = static_cast<coincide::ThreadView>(thread_filter.SelectedIndex());
            archived = thread_view == coincide::ThreadView::archived; refresh_sidebar();
        });
        sidebar_top.Children().Append(thread_filter);
        sidebar_grid.Children().Append(sidebar_top);

        sidebar = controls::ListView{};
        identify(sidebar, L"Threads");
        sidebar.DisplayMemberPath(L"Text");
        sidebar.SelectionMode(controls::ListViewSelectionMode::Extended);
        sidebar.SelectionChanged([this](const auto&, const auto&) {
            const auto index = sidebar.SelectedIndex();
            if (!selecting && sidebar.SelectedItems().Size() == 1 && index >= 0 && static_cast<std::size_t>(index) < visible.size()) open_thread(visible[index]);
        });
        controls::Grid::SetRow(sidebar, 1);
        sidebar_grid.Children().Append(sidebar);

        controls::StackPanel footer;
        footer.Spacing(8);
        auto archive_toggle = controls::ToggleSwitch{};
        archive_toggle.Header(winrt::box_value(label(L"ShowArchived", L"Show Archived Threads")));
        archive_toggle.Toggled([this, archive_toggle](const auto&, const auto&) {
            archived = archive_toggle.IsOn(); thread_view = archived ? coincide::ThreadView::archived : coincide::ThreadView::inbox;
            selecting = true; thread_filter.SelectedIndex(archived ? 1 : 0); selecting = false; refresh_sidebar();
        });
        footer.Children().Append(archive_toggle);
        auto settings = button(L"Settings", L"Settings", L"Settings");
        settings.Click([this](const auto&, const auto&) { show_status(); });
        footer.Children().Append(settings);
        controls::Grid::SetRow(footer, 2);
        sidebar_grid.Children().Append(footer);

        controls::Grid content;
        content.Padding({16, 12, 16, 12});
        auto header = controls::RowDefinition{}; header.Height({1, xaml::GridUnitType::Auto});
        content.RowDefinitions().Append(header);
        content.RowDefinitions().Append(controls::RowDefinition{});
        auto prompts_row=controls::RowDefinition{};prompts_row.Height({1,xaml::GridUnitType::Auto});content.RowDefinitions().Append(prompts_row);
        auto composer_row = controls::RowDefinition{}; composer_row.Height({1, xaml::GridUnitType::Auto});
        content.RowDefinitions().Append(composer_row);
        controls::Grid::SetColumn(content, 1);
        root.Children().Append(content);

        controls::CommandBar toolbar;toolbar.DefaultLabelPosition(controls::CommandBarDefaultLabelPosition::Right);toolbar.IsDynamicOverflowEnabled(true);
        title = controls::TextBlock{};
        title.Text(L"Coincide"); title.FontSize(20);
        title.VerticalAlignment(xaml::VerticalAlignment::Center);
        title.TextTrimming(xaml::TextTrimming::CharacterEllipsis);title.MaxWidth(260);toolbar.Content(title);
        auto actions_menu = toolbar_button(L"ThreadActions", L"Thread actions", L"ThreadActions");
        controls::MenuFlyout thread_actions;
        auto action = [&](const wchar_t* resource, const wchar_t* fallback, const wchar_t* id, auto handler) {
            controls::MenuFlyoutItem item; item.Text(label(resource, fallback)); identify(item, id); item.Click(handler); thread_actions.Items().Append(item);
        };
        action(L"Rename", L"Rename", L"RenameThread", [this](const auto&, const auto&) {rename_thread();});
        action(L"TogglePin", L"Pin or Unpin Thread", L"PinThread", [this](const auto&, const auto&) {
            mutate_selection([&](const auto& ids) {workspace.pin(ids, !workspace.thread(ids.front()).pinned);}, true);
        });
        action(L"Settle", L"Settle", L"SettleThread", [this](const auto&, const auto&) {
            mutate_selection([&](const auto& ids) {workspace.settle(ids, !coincide::Workspace::is_settled(workspace.thread(ids.front())));});
        });
        action(L"Snooze", L"Snooze", L"SnoozeThread", [this](const auto&, const auto&) {snooze_thread();});
        action(L"MoveToProject", L"Move to Project", L"MoveThread", [this](const auto&, const auto&) {move_threads();});
        action(L"Delete", L"Delete", L"DeleteThread", [this](const auto&, const auto&) {mutate_selection([&](const auto& ids) {workspace.delete_threads(ids);});});
        action(L"Restore", L"Restore", L"RestoreThread", [this](const auto&, const auto&) {mutate_selection([&](const auto& ids) {workspace.restore_threads(ids);});});
        action(L"Projects", L"Projects", L"ManageProjects", [this](const auto&, const auto&) {manage_projects();});
        actions_menu.Flyout(thread_actions); toolbar.PrimaryCommands().Append(actions_menu);
        auto archive = toolbar_button(L"Archive", L"Archive", L"Archive");
        archive.Click([this](const auto&, const auto&) {
            mutate_selection([&](const auto& ids) {workspace.archive(ids, !workspace.thread(ids.front()).archived);});
        });
        toolbar.PrimaryCommands().Append(archive);
        auto undo = toolbar_button(L"Undo", L"Undo", L"Undo");
        undo.Click([this](const auto&, const auto&) { history(false); }); toolbar.PrimaryCommands().Append(undo);
        auto redo = toolbar_button(L"Redo", L"Redo", L"Redo");
        redo.Click([this](const auto&, const auto&) { history(true); }); toolbar.PrimaryCommands().Append(redo);
        auto git=toolbar_button(L"Git",L"Git",L"OpenGit");git.Click([this](const auto&,const auto&){show_git();});toolbar.PrimaryCommands().Append(git);
        auto hosting=toolbar_button(L"PullRequests",L"Pull requests",L"OpenPullRequests");hosting.Click([this](const auto&,const auto&){show_hosting();});toolbar.PrimaryCommands().Append(hosting);
        auto browser=toolbar_button(L"Browser",L"Browser",L"OpenBrowser");browser.Click([this](const auto&,const auto&){show_browser();});toolbar.PrimaryCommands().Append(browser);
        auto terminal=toolbar_button(L"Terminal",L"Terminal",L"OpenTerminal");terminal.Click([this](const auto&,const auto&){show_terminal();});toolbar.PrimaryCommands().Append(terminal);
        auto schedules=toolbar_button(L"Schedules",L"Schedules",L"OpenSchedules");schedules.Click([this](const auto&,const auto&){show_schedules();});toolbar.PrimaryCommands().Append(schedules);
        auto instructions=toolbar_button(L"Instructions",L"Instructions",L"OpenInstructions");instructions.Click([this](const auto&,const auto&){show_instructions();});toolbar.PrimaryCommands().Append(instructions);
        auto imports=toolbar_button(L"ImportSessions",L"Import Sessions",L"OpenImports");imports.Click([this](const auto&,const auto&){show_imports();});toolbar.PrimaryCommands().Append(imports);
        auto accounts=toolbar_button(L"Accounts",L"Accounts",L"OpenAccounts");accounts.Click([this](const auto&,const auto&){show_accounts();});toolbar.PrimaryCommands().Append(accounts);
        auto passwords=toolbar_button(L"Passwords",L"Passwords",L"OpenPasswords");passwords.Click([this](const auto&,const auto&){show_credentials();});toolbar.PrimaryCommands().Append(passwords);
        auto voice=toolbar_button(L"Voice",L"Voice",L"OpenVoice");voice.Click([this](const auto&,const auto&){show_voice();});toolbar.PrimaryCommands().Append(voice);
        auto tools=toolbar_button(L"AgentTools",L"Agent tools",L"AgentToolAccess");tools.Click([this](const auto&,const auto&){show_tool_access();});toolbar.PrimaryCommands().Append(tools);
        auto usage=toolbar_button(L"Usage",L"Usage",L"OpenUsage");usage.Click([this](const auto&,const auto&){show_usage();});toolbar.PrimaryCommands().Append(usage);
        content.Children().Append(toolbar);

        transcript = controls::ListView{};
        identify(transcript, L"Transcript");
        transcript.Loaded([this](const auto&, const auto&) { show_latest(true); });
        transcript.LayoutUpdated([weak=get_weak()](const auto&,const auto&){if(const auto self=weak.get();self&&!self->closing)self->follow_latest_layout();});
        const auto stop_follow=xaml::Input::PointerEventHandler([weak=get_weak()](const auto&,const auto&){if(const auto self=weak.get())self->latest_scroll_pending=false;});
        transcript.AddHandler(xaml::UIElement::PointerWheelChangedEvent(),winrt::box_value(stop_follow),true);transcript.AddHandler(xaml::UIElement::PointerPressedEvent(),winrt::box_value(stop_follow),true);
        transcript.KeyDown([weak=get_weak()](const auto&,const xaml::Input::KeyRoutedEventArgs& args){if(const auto self=weak.get()){const auto key=args.Key();if(key==winrt::Windows::System::VirtualKey::End)self->show_latest(true);else if(key==winrt::Windows::System::VirtualKey::Home||key==winrt::Windows::System::VirtualKey::PageUp||key==winrt::Windows::System::VirtualKey::Up)self->latest_scroll_pending=false;}});
        transcript.SelectionMode(controls::ListViewSelectionMode::None);
        transcript.HorizontalContentAlignment(xaml::HorizontalAlignment::Stretch);
        transcript.ItemTemplate(xaml::Markup::XamlReader::Load(
            LR"(<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><ContentPresenter Content="{Binding Content}" HorizontalContentAlignment="Stretch"/></DataTemplate>)"
        ).as<xaml::DataTemplate>());
        controls::Grid::SetRow(transcript, 1);
        content.Children().Append(transcript);

        controls::StackPanel compose;
        compose.Spacing(8);
        providers = controls::ComboBox{};
        identify(providers, L"Provider");
        for (const auto name : {L"Claude Code", L"Codex", L"Cursor", L"Grok Build", L"OpenCode", L"Antigravity"}) {
            providers.Items().Append(winrt::box_value(name));
        }
        providers.SelectedIndex(0);
        providers.SelectionChanged([this](const auto&, const auto&) {
            const auto index = providers.SelectedIndex();
            if (!selecting && !selected.empty() && writable && index >= 0 && index < 6) {
                try {
                    if(thread_busy(selected))throw std::runtime_error("Stop the agent before changing providers.");
                    if(!workspace.thread(selected).queued_inputs.empty())throw std::runtime_error("Finish or remove this conversation's queued messages before changing providers.");
                    const auto before=workspace.thread(selected);
                    try{workspace.select_provider(selected,std::string(coincide::provider_ids[index]));workspace.thread(selected).preferred_profile_id.reset();store->save_index(workspace);}catch(...){workspace.thread(selected)=before;throw;}
                    const auto at=running.find(selected);if(at!=running.end()){at->second.session->shutdown();running.erase(at);}
                    render_prompts();update_composer();
                } catch (...) { selecting=true;const auto& provider=workspace.thread(selected).provider;providers.SelectedIndex(static_cast<int32_t>(std::distance(coincide::provider_ids.begin(),std::find(coincide::provider_ids.begin(),coincide::provider_ids.end(),provider))));selecting=false;report_exception(); }
            }
        });
        compose.Children().Append(providers);
        models_button=button(L"ModelSettings",L"Model Settings",L"ModelSettings");models_button.IsEnabled(false);models_button.Click([this](const auto&,const auto&){choose_model();});compose.Children().Append(models_button);
        composer = controls::TextBox{};
        identify(composer, L"Composer");
        composer.PlaceholderText(label(L"Message", L"Message"));
        composer.AcceptsReturn(true); composer.TextWrapping(xaml::TextWrapping::Wrap);
        composer.MinHeight(80); composer.MaxHeight(240);
        composer.IsEnabled(false);
        composer.TextChanged([this](const auto&, const auto&) {
            ++draft_revision;
            if (selecting || selected.empty() || !writable) return;
            workspace.thread(selected).draft = winrt::to_string(composer.Text());
            dirty_threads.insert(selected); save_timer.Stop(); save_timer.Start(); update_composer();
        });
        composer.KeyDown([this](const auto&, const xaml::Input::KeyRoutedEventArgs& args) {
            if(args.Key()==winrt::Windows::System::VirtualKey::Enter&&((GetKeyState(VK_CONTROL)&0x8000)||(preferences.send_on_return&&!(GetKeyState(VK_SHIFT)&0x8000)&&!(GetKeyState(VK_MENU)&0x8000)))){
                args.Handled(true);if(!selected.empty()&&thread_busy(selected))queue_message(false);else send_message();
            }
        });
        compose.Children().Append(composer);
        attachments_view = controls::StackPanel{}; attachments_view.Spacing(4); identify(attachments_view, L"Attachments");
        compose.Children().Append(attachments_view);
        controls::StackPanel actions;
        actions.Orientation(controls::Orientation::Horizontal); actions.Spacing(8);
        send_button = button(L"Send", L"Send", L"Send"); send_button.IsEnabled(false);
        send_button.Click([this](const auto&, const auto&) {send_message();});
        stop_button = button(L"Stop", L"Stop", L"Stop"); stop_button.IsEnabled(false);
        stop_button.Click([this](const auto&, const auto&) {
            const auto at = running.find(selected);
            if (at != running.end()) at->second.session->interrupt();
        });
        actions.Children().Append(send_button); actions.Children().Append(stop_button); compose.Children().Append(actions);
        auto attach = button(L"Attach", L"Attach", L"AttachFiles"); attach.Click([this](const auto&, const auto&) {attach_files();});
        actions.Children().Append(attach);
        queue_button=button(L"Queue",L"Queue",L"QueueMessage");queue_button.IsEnabled(false);queue_button.Click([this](const auto&,const auto&){queue_message(false);});actions.Children().Append(queue_button);
        steer_button=button(L"Steer",L"Steer",L"SteerMessage");steer_button.IsEnabled(false);steer_button.Click([this](const auto&,const auto&){queue_message(true);});actions.Children().Append(steer_button);
        queued_view=controls::StackPanel{};queued_view.Spacing(4);identify(queued_view,L"QueuedMessages");compose.Children().Append(queued_view);
        controls::ScrollViewer prompts_scroll;
        prompts_scroll.MaxHeight(220);
        prompts_scroll.VerticalScrollBarVisibility(controls::ScrollBarVisibility::Auto);
        prompts_view = controls::StackPanel{}; prompts_view.Spacing(12); identify(prompts_view, L"AgentPrompts");
        prompts_scroll.Content(prompts_view);controls::Grid::SetRow(prompts_scroll,2);content.Children().Append(prompts_scroll);
        state = controls::TextBlock{};
        identify(state, L"AgentStatus");
        state.TextWrapping(xaml::TextWrapping::Wrap);
        state.Text(L"Select a conversation to begin.");
        compose.Children().Append(state);
        controls::ScrollViewer compose_scroll; compose_scroll.MaxHeight(420);
        compose_scroll.VerticalScrollBarVisibility(controls::ScrollBarVisibility::Auto);compose_scroll.Content(compose);
        controls::Grid::SetRow(compose_scroll, 3);
        content.Children().Append(compose_scroll);
        root.SizeChanged([compose_scroll,prompts_scroll](const auto&,const xaml::SizeChangedEventArgs& args){const auto height=static_cast<double>(args.NewSize().Height);compose_scroll.MaxHeight(std::max(160.0,std::min(400.0,height*0.50)));prompts_scroll.MaxHeight(std::max(90.0,std::min(240.0,height*0.28)));});

        save_timer = window.DispatcherQueue().CreateTimer();
        save_timer.Interval(std::chrono::milliseconds(400)); save_timer.IsRepeating(false);
        save_timer.Tick([this](const auto&, const auto&) { flush_dirty(); });
        session_timer = window.DispatcherQueue().CreateTimer();
        session_timer.Interval(std::chrono::milliseconds(40));
        session_timer.Tick([this](const auto&, const auto&) { drain_sessions(); });
        session_timer.Start();
        platform_timer=window.DispatcherQueue().CreateTimer();platform_timer.Interval(std::chrono::seconds(1));
        platform_timer.Tick([this](const auto&,const auto&){platform_tick();});
        window.AppWindow().Closing([this](const auto&,const winrt::Microsoft::UI::Windowing::AppWindowClosingEventArgs& args){
            close_voice();
            if(repository_mutating()){
                args.Cancel(true);
                if(!quitting&&preferences.background&&desktop&&desktop->tray_available()){hide_tools();window.AppWindow().Hide();}
                else{quit_when_safe=true;quitting=true;state.Text(coincide::ui_text(L"Finishing the repository operation before quitting…"));}
                return;
            }
            if((!fixture_preview||desktop_fixture)&&!quitting&&preferences.background&&desktop&&desktop->tray_available()&&background_work()){
                args.Cancel(true);hide_tools();window.AppWindow().Hide();
            }
        });
        window.Closed([this](const auto&, const auto&) {
            if(fixture_preview)diagnostic(L"Window closed; stopping owned work");
            closing = true; save_timer.Stop(); session_timer.Stop();if(platform_timer)platform_timer.Stop();
            if(tool_bridge)tool_bridge->stop();
            for (auto& [id, run] : running) {(void)id; run.session->close();}
            for (auto& [id, run] : running) {(void)id; run.session->shutdown();}
            drain_sessions(); flush_dirty(); save_current();
            if(git_panel)git_panel->close();if(browser_panel)browser_panel->close();if(terminal_panel)terminal_panel->close();if(preview_panel)preview_panel->close();
            if(hosting_panel)hosting_panel->close();
            if(schedule_panel)schedule_panel->close();if(instructions_panel)instructions_panel->close();if(import_panel)import_panel->close();if(accounts_panel)accounts_panel->close();if(usage_panel)usage_panel->close();if(persona_panel)persona_panel->close();if(credentials_controller)credentials_controller->close();flush_usage();close_voice();if(computer_use)computer_use->stop();if(notifications)notifications->close();power_request.close();if(desktop)desktop->close();
        });

        try {
            store = std::make_unique<coincide::WorkspaceStore>(data_directory());
            workspace = store->open();
            writable = true;
            diagnostic(hstring{L"Workspace threads: " + std::to_wstring(workspace.threads.size())});
        } catch (...) {
            writable = false;
            report_exception();
        }
        if(writable){try{ensure_bots();}catch(...){report_exception();}try{ensure_schedules();}catch(...){report_exception();}}
        if(desktop){HWND handle{};winrt::check_hresult(window.as<IWindowNative>()->get_WindowHandle(&handle));desktop->attach(handle,[this]{show_window();},[this]{quit_app();},[this](std::string id){show_window();if(!id.empty())try{open_thread(id);}catch(...){report_exception();}},[this]{schedule_wake_pending=true;});}
        install_shortcuts();platform_timer.Start();platform_tick();
        window.Activate();
        if(writable){configure_notifications();try{ensure_computer_use();}catch(...){report_exception();}}
        diagnostic(L"Window activated");
        refresh_sidebar();
        if (!visible.empty()) open_thread(visible.front());
    }

    void refresh_sidebar() {
        if (!sidebar || !search) return;
        const auto previous_selection = selected_thread_ids();
        selecting = true;
        visible = workspace.listed_threads(thread_view, winrt::to_string(search.Text()));
        const auto active_bot=selected.empty()?std::optional<std::string>{}:workspace.thread(selected).bot_id;
        std::erase_if(visible,[&](const auto& id){const auto& thread=workspace.thread(id);return thread.bot_id&&bot_store&&bot_store->find(*thread.bot_id)&&thread.bot_id!=active_bot;});
        sidebar.Items().Clear();
        for (const auto& id : visible) {
            const auto& t = workspace.thread(id);
            std::string display = t.title;
            if (t.project_id) {
                const auto p = std::find_if(workspace.projects.begin(), workspace.projects.end(), [&](const auto& p) {return p.id == *t.project_id;});
                if (p != workspace.projects.end()) display = p->name + " / " + display;
            }
            sidebar.Items().Append(coincide::display_item(display));
        }
        for (const auto& id : previous_selection) {
            const auto at = std::find(visible.begin(), visible.end(), id);
            if (at != visible.end()) sidebar.SelectedItems().Append(sidebar.Items().GetAt(static_cast<uint32_t>(std::distance(visible.begin(), at))));
        }
        const auto at = std::find(visible.begin(), visible.end(), selected);
        if (sidebar.SelectedItems().Size() == 0 && at != visible.end()) sidebar.SelectedIndex(static_cast<int32_t>(std::distance(visible.begin(), at)));
        selecting = false;
    }

    void open_thread(const std::string& id) {
        if (!writable) return;
        save_current();
        try {
            auto& t = workspace.thread(id);
            store->load_thread(t);
            diagnostic(hstring{L"Loaded messages: " + std::to_wstring(t.messages.size())});
            selecting = true;
            selected = id;
            title.Text(winrt::to_hstring(t.title));
            composer.Text(winrt::to_hstring(t.draft)); composer.IsEnabled(t.deleted_at == 0);
            providers.SelectedIndex(static_cast<int32_t>(std::distance(coincide::provider_ids.begin(),
                std::find(coincide::provider_ids.begin(), coincide::provider_ids.end(), t.provider))));
            transcript.Items().Clear();
            for (const auto& m : t.messages) {
                const auto speaker = m.role == "user" ? winrt::to_string(label(L"You", L"You")) : m.provider;
                transcript.Items().Append(message_row(m,speaker));
            }
            selecting = false;
            render_prompts(); render_attachments();render_queue(); update_composer();
            // Let WinUI lay out at the final width before requesting the latest virtualized row.
            window.DispatcherQueue().TryEnqueue([this, id] {
                if (selected == id) show_latest(true);
            });
            refresh_sidebar();
            dismiss_notification(id);
            if(schedule_panel)schedule_panel->select_thread(id);
            if(browser_panel)browser_panel->select_thread(id);
            if(credentials_controller)credentials_controller->select_thread(id);
            if(terminal_panel)terminal_panel->select_thread(id,working_directory(t));
            if(visible_tool=="git"||visible_tool=="hosting")hide_tools();else if(visible_tool=="instructions")show_instructions();
        } catch (...) { selecting = false; report_exception(); }
    }

    coincide::Inspectable message_row(const coincide::Message& message,const std::string& speaker){
        const auto weak=get_weak();
        return coincide::display_message(message,speaker,[weak](std::string url){
            const auto self=weak.get();if(!self||self->closing)return;
            if(url.starts_with("http://")||url.starts_with("https://"))self->show_browser(std::move(url));
            else if(url.starts_with("mailto:"))(void)winrt::Windows::System::Launcher::LaunchUriAsync(foundation::Uri(winrt::to_hstring(url)));
        },[weak](std::string content,bool svg){const auto self=weak.get();if(self&&!self->closing)self->show_preview(std::move(content),svg);},preferences.font_size,message.role=="user"?hstring(L"Segoe UI"):preferences.reply_font=="serif"?hstring(L"Georgia"):preferences.reply_font=="mono"?hstring(L"Consolas"):hstring(L"Segoe UI"));
    }

    static controls::ScrollViewer scroll_host(const controls::ListView& list){
        // Follow the items panel's ancestors; a rendered message may contain its own ScrollViewer.
        xaml::DependencyObject value=list.ItemsPanelRoot();
        while(value&&value!=list){if(const auto scroll=value.try_as<controls::ScrollViewer>())return scroll;value=xaml::Media::VisualTreeHelper::GetParent(value);}
        return nullptr;
    }

    void follow_latest_layout(){
        if(!latest_scroll_pending||latest_layout_active||closing||!transcript||!transcript.IsLoaded()||!transcript.Items().Size()||transcript.ActualHeight()<=0)return;
        latest_layout_active=true;struct Reset{bool& value;~Reset(){value=false;}} reset{latest_layout_active};
        const auto item=transcript.Items().GetAt(transcript.Items().Size()-1);
        const auto container=transcript.ContainerFromItem(item).try_as<xaml::FrameworkElement>();
        const auto scroll=scroll_host(transcript);
        const auto trace=[&](std::string bounds){if(!fixture_preview||selected.empty())return;const auto& messages=workspace.thread(selected).messages;if(messages.empty()||messages.back().text!="decline")return;
            const auto text=std::string("SCROLL c=")+(container?"1":"0")+" rowh="+std::to_string(container?container.ActualHeight():0)+" viewport="+std::to_string(transcript.ActualHeight())+" offset="+std::to_string(scroll?scroll.VerticalOffset():0)+" extent="+std::to_string(scroll?scroll.ScrollableHeight():0)+" "+bounds;
            if(text!=latest_scroll_trace){latest_scroll_trace=text;diagnostic(winrt::to_hstring(text));}};
        if(container&&container.ActualHeight()>0){
            const auto bounds=container.TransformToVisual(transcript).TransformBounds({0,0,static_cast<float>(container.ActualWidth()),static_cast<float>(container.ActualHeight())});
            trace("y="+std::to_string(bounds.Y)+" h="+std::to_string(bounds.Height));
            if(bounds.Height>0&&bounds.Y<transcript.ActualHeight()&&bounds.Y+bounds.Height>0&&bounds.Y+bounds.Height<=transcript.ActualHeight()+1){return;}
        }else{trace("realizing");transcript.ScrollIntoView(item,controls::ScrollIntoViewAlignment::Leading);return;}
        if(scroll)scroll.ChangeView(nullptr,winrt::box_value(scroll.ScrollableHeight()).as<foundation::IReference<double>>(),nullptr,true);
    }
    void show_latest(bool force=false) {
        if(force)latest_scroll_pending=true;
        if(!latest_scroll_pending||closing||!transcript||!transcript.IsLoaded()||!transcript.Items().Size())return;
        // Track actual realization/layout completion: collapsed approval cards can resize the
        // viewport after the first ScrollIntoView. Keep the tail anchored until the reader scrolls away.
        latest_scroll_pending=true;const auto generation=++latest_scroll_generation;const auto id=selected;root.UpdateLayout();follow_latest_layout();
        const auto weak=get_weak();window.DispatcherQueue().TryEnqueue(winrt::Microsoft::UI::Dispatching::DispatcherQueuePriority::Low,[weak,id,generation]{
            const auto self=weak.get();if(!self||self->closing||self->selected!=id||self->latest_scroll_generation!=generation)return;
            self->root.UpdateLayout();self->follow_latest_layout();
        });
    }

    void create_thread(std::optional<std::string> project = std::nullopt) {
        if (!writable) return;
        try {
            coincide::Thread t;
            t.provider=preferences.provider_default(project);const auto defaults=preferences.model_defaults(project,t.provider);
            t.model=defaults.model;t.effort=defaults.effort;t.service_tier=defaults.service_tier;t.plan=defaults.plan;t.full_access=defaults.full_access;
            t.id = coincide::new_id(); t.title = winrt::to_string(label(L"NewChat", L"New Chat")); t.project_id = std::move(project);
            t.created_at = t.updated_at = coincide::Workspace::now_seconds();
            const auto id = t.id;
            workspace.add_thread(std::move(t));
            store->load_thread(workspace.thread(id));
            store->save_thread(workspace.thread(id));
            store->save_index(workspace);
            archived = false; thread_view = coincide::ThreadView::inbox; thread_filter.SelectedIndex(0);
            search.Text(L""); refresh_sidebar(); open_thread(id);
        } catch (...) { report_exception(); }
    }

    void add_project() {
        if (!writable) return;
        try {
            winrt::com_ptr<IFileOpenDialog> picker;
            winrt::check_hresult(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(picker.put())));
            DWORD options{}; winrt::check_hresult(picker->GetOptions(&options));
            winrt::check_hresult(picker->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM));
            HWND hwnd{}; winrt::check_hresult(window.as<IWindowNative>()->get_WindowHandle(&hwnd));
            const auto result = picker->Show(hwnd);
            if (result == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return;
            winrt::check_hresult(result);
            winrt::com_ptr<IShellItem> item; winrt::check_hresult(picker->GetResult(item.put()));
            PWSTR raw{}; winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH, &raw));
            const std::filesystem::path path(raw); CoTaskMemFree(raw);
            for (const auto& p : workspace.projects) {
                if (std::filesystem::equivalent(std::filesystem::path(winrt::to_hstring(p.path).c_str()), path)) { create_thread(p.id); return; }
            }
            const auto id = coincide::new_id();
            workspace.add_project({id, winrt::to_string(path.filename().wstring()), winrt::to_string(path.wstring())});
            store->save_index(workspace); create_thread(id);
        } catch (...) { report_exception(); }
    }

    void save_current() {
        if (!writable || selected.empty()) return;
        try { store->save_thread(workspace.thread(selected)); }
        catch (...) { report_exception(); }
    }

    std::vector<std::string> selected_thread_ids() const {
        std::vector<std::string> ids;
        if (sidebar) for (const auto& item : sidebar.SelectedItems()) {
            uint32_t index{};
            if (sidebar.Items().IndexOf(item, index) && index < visible.size()) ids.push_back(visible[index]);
        }
        return ids;
    }

    bool thread_busy(const std::string& id) const {
        const auto at = running.find(id);
        return at != running.end() && (at->second.awaiting_completion || at->second.session->busy());
    }

    void reconcile_selection() {
        refresh_sidebar();
        if (!selected.empty() && std::find(visible.begin(), visible.end(), selected) != visible.end()) {
            title.Text(winrt::to_hstring(workspace.thread(selected).title)); update_composer(); return;
        }
        if (!visible.empty()) {open_thread(visible.front()); return;}
        selected.clear(); selecting = true; composer.Text(L""); composer.IsEnabled(false); selecting = false;
        transcript.Items().Clear(); prompts_view.Children().Clear(); attachments_view.Children().Clear();queued_view.Children().Clear();title.Text(L"Coincide");
        send_button.IsEnabled(false); stop_button.IsEnabled(false); providers.IsEnabled(false);
        queue_button.IsEnabled(false);steer_button.IsEnabled(false);models_button.IsEnabled(false);
    }

    template<class Operation> void mutate_selection(Operation operation, bool allow_active = false) {
        if (!writable) return;
        try {
            const auto ids = selected_thread_ids(); if (ids.empty()) return;
            if (!allow_active && std::any_of(ids.begin(), ids.end(), [&](const auto& id) {return thread_busy(id);})) {
                throw std::runtime_error("Stop the selected conversations before changing their state or project.");
            }
            const auto before = workspace;
            try {operation(ids); store->save_index(workspace);}
            catch (...) {workspace = before; throw;}
            for(const auto& id:ids)if(workspace.thread(id).deleted_at||workspace.thread(id).archived){if(tool_bridge)tool_bridge->disable(id);terminal_tool_threads.erase(id);if(computer_use)computer_use->revoke(id);if(browser_panel)browser_panel->set_agent_control(id,false);}
            reconcile_selection();
        } catch (...) {report_exception();}
    }

    winrt::fire_and_forget rename_thread() {
        auto lifetime = get_strong();
        if (dialog_open || selected.empty() || !writable) co_return;
        const auto id = selected; dialog_open = true;
        try {
            controls::TextBox field; field.Text(winrt::to_hstring(workspace.thread(id).title)); field.MaxLength(512); identify(field, L"RenameValue");
            controls::ContentDialog dialog; dialog.XamlRoot(root.XamlRoot()); dialog.Title(winrt::box_value(label(L"Rename",L"Rename")));
            dialog.Content(field); dialog.PrimaryButtonText(label(L"Save",L"Save")); dialog.CloseButtonText(label(L"Cancel",L"Cancel"));
            if (co_await dialog.ShowAsync() == controls::ContentDialogResult::Primary && writable) {
                const auto before = workspace;
                try {workspace.rename_thread(id, winrt::to_string(field.Text())); store->save_index(workspace);}
                catch (...) {workspace = before; throw;}
                reconcile_selection();
            }
        } catch (...) {report_exception();}
        dialog_open = false;
    }

    winrt::fire_and_forget snooze_thread() {
        auto lifetime = get_strong();
        const auto ids = selected_thread_ids(); if (dialog_open || ids.empty() || !writable) co_return;
        dialog_open = true;
        try {
            controls::ComboBox duration; identify(duration, L"SnoozeDuration");
            for (const auto& entry : {std::pair{L"OneHour",L"1 hour"}, {L"Tomorrow",L"Tomorrow"}, {L"OneWeek",L"1 week"}, {L"Unsnooze",L"Unsnooze"}}) add_choice(duration,label(entry.first,entry.second));
            duration.SelectedIndex(0);
            controls::ContentDialog dialog; dialog.XamlRoot(root.XamlRoot()); dialog.Title(winrt::box_value(label(L"Snooze",L"Snooze")));
            dialog.Content(duration); dialog.PrimaryButtonText(label(L"Save",L"Save")); dialog.CloseButtonText(label(L"Cancel",L"Cancel"));
            if (co_await dialog.ShowAsync() == controls::ContentDialogResult::Primary) {
                if (std::any_of(ids.begin(),ids.end(),[&](const auto& id){return thread_busy(id);})) throw std::runtime_error("Stop the selected conversations before snoozing them.");
                const auto choice=duration.SelectedIndex();
                const auto until=choice==3 ? 0 : coincide::Workspace::now_seconds()+(choice==1?86400:choice==2?604800:3600);
                const auto before=workspace;
                try {workspace.snooze(ids,until);store->save_index(workspace);} catch(...){workspace=before;throw;}
                reconcile_selection();
            }
        } catch (...) {report_exception();}
        dialog_open = false;
    }

    winrt::fire_and_forget move_threads() {
        auto lifetime = get_strong(); const auto ids=selected_thread_ids();
        if(dialog_open||ids.empty()||!writable)co_return;
        dialog_open=true;
        try {
            if(std::any_of(ids.begin(),ids.end(),[&](const auto& id){return workspace.thread(id).bot_id.has_value();}))throw std::runtime_error("Remove the bot with Keep Conversations before moving its histories to another project.");
            controls::ComboBox destinations;identify(destinations,L"ProjectDestination");
            add_choice(destinations,label(L"Projectless",L"No Project"));
            std::vector<std::string> projects;
            for(const auto& project:workspace.projects)if(project.id!=coincide::bots_container_id){projects.push_back(project.id);add_choice(destinations,winrt::to_hstring(project.name));}
            destinations.SelectedIndex(0);
            controls::ContentDialog dialog;dialog.XamlRoot(root.XamlRoot());dialog.Title(winrt::box_value(label(L"MoveToProject",L"Move to Project")));
            dialog.Content(destinations);dialog.PrimaryButtonText(label(L"Save",L"Save"));dialog.CloseButtonText(label(L"Cancel",L"Cancel"));
            if(co_await dialog.ShowAsync()==controls::ContentDialogResult::Primary){
                if(std::any_of(ids.begin(),ids.end(),[&](const auto& id){return thread_busy(id)||active_terminal(id);}))throw std::runtime_error("Stop the selected agents and close their terminals before moving conversations.");
                if(repository_mutating())throw std::runtime_error("Wait for the repository operation before moving conversations.");
                const auto index=destinations.SelectedIndex();std::optional<std::string> project;
                if(index>0)project=projects.at(static_cast<std::size_t>(index-1));
                for(const auto& id:ids){auto at=running.find(id);if(at!=running.end()){at->second.session->shutdown();running.erase(at);}}
                const auto before=workspace;
                try{workspace.move_threads(ids,project);store->save_index(workspace);}catch(...){workspace=before;throw;}
                invalidate_project_context(ids);reconcile_selection();
            }
        }catch(...){report_exception();}
        dialog_open=false;
    }

    winrt::fire_and_forget manage_projects() {
        auto lifetime=get_strong();if(dialog_open||!writable||std::none_of(workspace.projects.begin(),workspace.projects.end(),[](const auto& project){return project.id!=coincide::bots_container_id;}))co_return;dialog_open=true;
        try {
            controls::StackPanel fields;fields.Spacing(8);controls::ComboBox picker;identify(picker,L"ProjectPicker");
            std::vector<std::string> ids;for(const auto& project:workspace.projects)if(project.id!=coincide::bots_container_id){ids.push_back(project.id);add_choice(picker,winrt::to_hstring(project.name));}
            controls::TextBox name;identify(name,L"ProjectName");name.MaxLength(512);
            auto selection_revoker=picker.SelectionChanged(winrt::auto_revoke,[this,picker,name,ids](const auto&,const auto&){if(picker.SelectedIndex()>=0){const auto id=ids.at(static_cast<std::size_t>(picker.SelectedIndex()));for(const auto& p:workspace.projects)if(p.id==id)name.Text(winrt::to_hstring(p.name));}});
            picker.SelectedIndex(0);fields.Children().Append(picker);fields.Children().Append(name);
            controls::ContentDialog dialog;dialog.XamlRoot(root.XamlRoot());dialog.Title(winrt::box_value(label(L"Projects",L"Projects")));dialog.Content(fields);
            dialog.PrimaryButtonText(label(L"Rename",L"Rename"));dialog.SecondaryButtonText(label(L"Remove",L"Remove"));dialog.CloseButtonText(label(L"Cancel",L"Cancel"));
            const auto choice=co_await dialog.ShowAsync();
            if(choice!=controls::ContentDialogResult::None){
                const auto id=ids.at(static_cast<std::size_t>(picker.SelectedIndex()));
                const auto before=workspace;
                try {
                    if(choice==controls::ContentDialogResult::Primary)workspace.rename_project(id,winrt::to_string(name.Text()));
                    else {
                        for(const auto& t:workspace.threads)if(t.project_id==id&&(thread_busy(t.id)||active_terminal(t.id)))throw std::runtime_error("Stop this project's agents and close its terminals before removing the project.");
                        if(repository_mutating())throw std::runtime_error("Wait for the repository operation before removing the project.");
                        for(const auto& t:workspace.threads)if(t.project_id==id){auto at=running.find(t.id);if(at!=running.end()){at->second.session->shutdown();running.erase(at);}}
                        workspace.remove_project(id);
                    }
                    store->save_index(workspace);
                }catch(...){workspace=before;throw;}
                std::vector<std::string> changed;
                for(const auto& old:before.threads)if(workspace.thread(old.id).project_id!=old.project_id)changed.push_back(old.id);
                invalidate_project_context(changed);reconcile_selection();
            }
        }catch(...){report_exception();}
        dialog_open=false;
    }

    void attach_files() {
        if(selected.empty()||!writable||workspace.thread(selected).deleted_at) return;
        try {
            winrt::com_ptr<IFileOpenDialog> picker;
            winrt::check_hresult(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(picker.put())));
            DWORD options{};winrt::check_hresult(picker->GetOptions(&options));winrt::check_hresult(picker->SetOptions(options|FOS_ALLOWMULTISELECT|FOS_FORCEFILESYSTEM|FOS_FILEMUSTEXIST));
            HWND hwnd{};winrt::check_hresult(window.as<IWindowNative>()->get_WindowHandle(&hwnd));const auto result=picker->Show(hwnd);
            if(result==HRESULT_FROM_WIN32(ERROR_CANCELLED))return;winrt::check_hresult(result);
            winrt::com_ptr<IShellItemArray> items;winrt::check_hresult(picker->GetResults(items.put()));DWORD count{};winrt::check_hresult(items->GetCount(&count));
            auto attachments=workspace.thread(selected).draft_attachments;
            if(attachments.size()+count>10)throw std::runtime_error("Attach at most 10 files of up to 20 MB each.");
            for(DWORD i=0;i<count;++i){
                winrt::com_ptr<IShellItem> item;winrt::check_hresult(items->GetItemAt(i,item.put()));PWSTR raw{};winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH,&raw));
                const std::filesystem::path path(raw);CoTaskMemFree(raw);
                if(!std::filesystem::is_regular_file(path)||std::filesystem::file_size(path)>20ULL*1024*1024)throw std::runtime_error("Attach at most 10 files of up to 20 MB each.");
                auto ext=winrt::to_string(path.extension().wstring());std::transform(ext.begin(),ext.end(),ext.begin(),[](unsigned char c){return static_cast<char>(std::tolower(c));});
                std::string type="application/octet-stream";
                if(ext==".png")type="image/png";else if(ext==".jpg"||ext==".jpeg")type="image/jpeg";else if(ext==".gif")type="image/gif";else if(ext==".webp")type="image/webp";else if(ext==".bmp")type="image/bmp";
                const auto value=winrt::to_string(path.wstring());
                if(std::none_of(attachments.begin(),attachments.end(),[&](const auto& a){return a.path==value;}))attachments.push_back({value,winrt::to_string(path.filename().wstring()),type});
            }
            ++draft_revision;workspace.thread(selected).draft_attachments=std::move(attachments);save_current();render_attachments();update_composer();
        }catch(...){report_exception();}
    }

    void render_attachments() {
        if(!attachments_view)return;attachments_view.Children().Clear();if(selected.empty())return;
        const auto& thread=workspace.thread(selected);
        for(std::size_t i=0;i<thread.draft_attachments.size();++i){
            const auto& attachment=thread.draft_attachments[i];controls::StackPanel row;row.Orientation(controls::Orientation::Horizontal);row.Spacing(8);
            controls::TextBlock name;name.Text(winrt::to_hstring(attachment.name));row.Children().Append(name);
            auto remove=button(L"Remove",L"Remove",L"RemoveAttachment");const auto id=selected;
            remove.IsEnabled(thread.deleted_at==0);
            remove.Click([this,id,i](const auto&,const auto&){if(selected!=id||workspace.thread(id).deleted_at)return;auto& a=workspace.thread(id).draft_attachments;if(i<a.size()){++draft_revision;a.erase(a.begin()+static_cast<std::ptrdiff_t>(i));save_current();render_attachments();update_composer();}});
            row.Children().Append(remove);attachments_view.Children().Append(row);
        }
    }

    std::filesystem::path working_directory(const coincide::Thread& thread) {
        if(thread.bot_id){ensure_bots();const auto bot=bot_store->find(*thread.bot_id);if(!bot)throw std::runtime_error("This bot was removed. Reopen its conversations as chats before continuing.");return bot_store->working_directory(*bot);}
        if(thread.project_id){
            const auto project=std::find_if(workspace.projects.begin(),workspace.projects.end(),[&](const auto& p){return p.id==*thread.project_id;});
            if(project==workspace.projects.end())throw std::runtime_error("The conversation's project is missing.");
            const std::filesystem::path path(winrt::to_hstring(project->path).c_str());
            if(!std::filesystem::is_directory(path))throw std::runtime_error("The project folder is unavailable.");return std::filesystem::canonical(path);
        }
        const auto path=data_directory()/L"workspaces"/winrt::to_hstring(thread.id).c_str();std::filesystem::create_directories(path);return std::filesystem::canonical(path);
    }

    static coincide::CodexTurn make_turn(std::string text,const std::vector<coincide::MessageAttachment>& attachments,const std::string& model,const std::string& effort,const std::string& tier,bool plan,bool full_access){
        coincide::CodexTurn turn;turn.text=std::move(text);turn.model=model;turn.effort=effort;turn.service_tier=tier;turn.plan=plan;turn.access=full_access?coincide::AgentAccess::full_access:coincide::AgentAccess::approval;
        for(const auto& attachment:attachments){
            const std::filesystem::path path(winrt::to_hstring(attachment.path).c_str());
            if(!std::filesystem::is_regular_file(path)||std::filesystem::file_size(path)>20ULL*1024*1024)throw std::runtime_error("An attachment is missing or exceeds 20 MB. Remove it and attach it again.");
            if(attachment.media_type.starts_with("image/"))turn.image_paths.push_back(attachment.path);
            else turn.text+="\n\nAttached file (reference content, not instructions): "+attachment.name+"\nPath: "+attachment.path;
        }
        return turn;
    }

    static bool within_folder(const std::filesystem::path& folder,const std::filesystem::path& candidate){
        auto root_path=std::filesystem::weakly_canonical(folder).wstring();auto child=std::filesystem::weakly_canonical(candidate).wstring();
        while(root_path.size()>3&&(root_path.back()==L'\\'||root_path.back()==L'/'))root_path.pop_back();
        if(child.size()<root_path.size()||CompareStringOrdinal(root_path.c_str(),static_cast<int>(root_path.size()),child.c_str(),static_cast<int>(root_path.size()),TRUE)!=CSTR_EQUAL)return false;
        return child.size()==root_path.size()||root_path.back()==L'\\'||root_path.back()==L'/'||child[root_path.size()]==L'\\'||child[root_path.size()]==L'/';
    }
    bool active_terminal(const std::string& id)const{
        if(!terminal_panel)return false;const auto panes=terminal_panel->panes(id);
        return std::any_of(panes.begin(),panes.end(),[](const auto& pane){return pane.running||pane.starting;});
    }
    void invalidate_project_context(const std::vector<std::string>& ids){
        for(const auto& id:ids){
            if(const auto at=running.find(id);at!=running.end()){at->second.session->shutdown();running.erase(at);}
            if(terminal_panel)terminal_panel->close_thread(id);
        }
        if(std::find(ids.begin(),ids.end(),selected)!=ids.end())hide_tools();
    }
    RunningThread& session_for(const std::string& id){
        if(closing||quitting)throw std::runtime_error("The app is closing.");
        if(repository_busy(workspace.thread(id)))throw std::runtime_error("Wait for the repository operation to finish before starting the agent.");
        if(const auto found=running.find(id);found!=running.end())return found->second;
        auto& thread=workspace.thread(id);coincide::CodexLaunch launch;launch.cwd=working_directory(thread);
        if(fixture_preview){wchar_t module[32768]{};if(!GetModuleFileNameW(nullptr,module,32768))winrt::throw_last_error();launch.executable=module;launch.arguments={thread.provider=="claude"?L"--claude-session-fixture":thread.provider=="opencode"?L"--opencode-http-fixture":L"--codex-session-fixture",L"normal"};}
        else{
            const auto& provider=preferences.providers.at(thread.provider);if(!provider.enabled)throw std::runtime_error("This provider is disabled in Settings.");
            if(provider.executable.empty())launch.executable=coincide::ProviderDiscovery::discover(thread.provider);
            else{launch.executable=std::filesystem::path(winrt::to_hstring(provider.executable).c_str());if(!coincide::ProviderDiscovery::windows_executable(launch.executable))throw std::runtime_error("The provider override must be an existing native Windows executable.");}
        }
        const auto native=std::find_if(thread.sessions.begin(),thread.sessions.end(),[&](const auto& s){return s.provider==thread.provider;});
        const auto preferred_profile=native!=thread.sessions.end()?native->profile_id:thread.preferred_profile_id.value_or(preferences.providers.at(thread.provider).profile_id.empty()?"default":preferences.providers.at(thread.provider).profile_id);
        if(!fixture_preview&&thread.provider!="cursor"&&preferred_profile!="default")throw std::runtime_error("This provider's separate Windows profiles are not connected yet. Use its default account or a verified Cursor profile.");
        launch.fixture_account_reviewed=fixture_preview;
        if(native!=thread.sessions.end()){launch.session_id=native->id;launch.saved_profile_id=native->profile_id;launch.saved_account_scope=native->account_scope;}
        launch.instructions=coincide::handoff_context(thread,thread.provider).text;
        if(thread.bot_id){const auto bot=bot_store->find(*thread.bot_id);if(!bot)throw std::runtime_error("This bot no longer exists.");launch.instructions=bot->instructions_block()+"\n\n"+launch.instructions;
        }
        if(!fixture_preview){ensure_thread_tools(id);const auto weak=std::weak_ptr(tool_bridge);launch.tool_context=[weak,id]{const auto bridge=weak.lock();if(!bridge)return std::string{};auto context=bridge->current_instructions(id);
            if(context.find("<coincide_schedule>")!=std::string::npos)context+="\nSchedule requests use action list; create with name, prompt and schedule; update with id and the changed fields; pause/resume/delete/run-now with id. A schedule is {kind:once,at:ISO-date-time} or {kind:once,inMinutes:number}, {kind:daily|weekdays,time:HH:mm}, {kind:weekly,day:monday,time:HH:mm}, {kind:days,days:[mon,thu],time:HH:mm}, {kind:interval,minutes:number} or hours:number, or {kind:cron,expression:five-fields}. Quote all JSON keys/strings. An optional timeZone is an IANA zone. Repeats must be at least five minutes. Creation and edits await approval; never claim they are active before approval.\n";
            if(context.find("<coincide_terminal>")!=std::string::npos)context+="\nTerminal requests use action status/read/show/hide/interrupt. Read accepts limit (1-2000 lines, default 200) and page (default 1); output is scoped to this conversation's existing panes. Show does not start a shell. Interrupt sends Ctrl+C to those panes.\n";return context;};}
        std::optional<coincide::ACPLaunchOptions> acp_options;
        if(thread.provider=="cursor"){
            const auto profile_id=preferred_profile;
            coincide::ProviderAccountStore profiles(data_directory()/L"provider-profiles");const auto records=profiles.open();
            const auto record=std::find_if(records.begin(),records.end(),[&](const auto& value){return value.id==profile_id&&value.provider=="cursor";});
            const auto account=account_metadata.find(profile_id);
            if(record==records.end()||account==account_metadata.end())throw std::runtime_error("Open Accounts and verify this conversation's original Cursor profile before continuing.");
            const auto profile=profiles.profile(*record),cache=data_directory()/L"cache/cursor-node";std::filesystem::create_directories(cache);
            const auto spec=coincide::ACPVendorLaunch::inspect("cursor",launch.executable);launch.executable=spec.executable;launch.profile_id=record->id;launch.profile_directory=profile;
            acp_options=coincide::make_verified_acp_options(spec,coincide::ProviderAccountProgram::from(spec),*record,profile,cache,account->second,launch.saved_account_scope,!launch.session_id.empty());
        }
        RunningThread run;run.provider=thread.provider;run.profile_id=launch.profile_id;run.cwd=launch.cwd;run.session=coincide::make_agent_session(thread.provider,std::move(launch),std::move(acp_options));
        // Restored outbox entries always wait for an explicit Resume action; uncertain delivery is never replayed on launch.
        if(!thread.queued_inputs.empty()){
            run.session->interrupt();
            for(const auto& input:thread.queued_inputs){
                auto turn=make_turn(input.text,input.attachments,input.model,input.effort,input.service_tier,input.plan,input.full_access);
                if(!run.session->queue(std::move(turn),input.id))throw std::runtime_error("The saved message queue cannot be restored. Review its pending messages.");
            }
        }
        return running.emplace(id,std::move(run)).first->second;
    }

    void apply_appearance(){
        if(root)root.RequestedTheme(preferences.appearance=="dark"?xaml::ElementTheme::Dark:preferences.appearance=="light"?xaml::ElementTheme::Light:xaml::ElementTheme::Default);
    }
    void apply_preferences(coincide::Preferences value){
        if(!preferences_writable||!preferences_store)throw std::runtime_error("Preferences could not be loaded; their original file was preserved.");
        coincide::validate_preferences(value);
        for(const auto& [provider,settings]:value.providers){
            const auto& before=preferences.providers.at(provider);const bool changed=settings.executable!=before.executable||settings.enabled!=before.enabled||settings.profile_id!=before.profile_id;
            if(settings.executable!=before.executable||settings.profile_id!=before.profile_id)for(const auto& thread:workspace.threads)if(thread.provider==provider&&!thread.queued_inputs.empty())throw std::runtime_error("Finish or remove this provider's queued messages before changing its executable or account profile.");
            if(changed)for(const auto& [id,run]:running)if(run.provider==provider&&thread_busy(id))throw std::runtime_error("Stop this provider's active conversations before changing its executable or enabled state.");
            if(!settings.executable.empty()&&!coincide::ProviderDiscovery::windows_executable(std::filesystem::path(winrt::to_hstring(settings.executable).c_str())))throw std::runtime_error("Choose an existing native Windows executable for the provider override.");
        }
        preferences_store->save(value);
        for(auto at=running.begin();at!=running.end();){const auto& before=preferences.providers.at(at->second.provider);const auto& after=value.providers.at(at->second.provider);
            if(before.executable!=after.executable||before.enabled!=after.enabled||before.profile_id!=after.profile_id){at->second.session->shutdown();at=running.erase(at);}else ++at;
        }
        const bool notification_change=preferences.notifications!=value.notifications;
        preferences=std::move(value);apply_appearance();install_shortcuts();if(notification_change)configure_notifications();
        if(!fixture_preview){try{power_request.update({preferences.keep_awake,preferences.awake_on_battery,preferences.keep_display});platform_error.clear();}catch(const std::exception& error){platform_error=error.what();show_error(winrt::to_hstring(platform_error));}}
        if(!selected.empty())open_thread(selected);
    }
    void install_shortcuts(){
        root.KeyboardAccelerators().Clear();composer.KeyboardAccelerators().Clear();const auto weak=get_weak();
        for(const auto& [action,text]:preferences.shortcuts){const auto key=coincide::parse_shortcut(text);if(!key.key)continue;
            xaml::Input::KeyboardAccelerator shortcut;shortcut.Key(static_cast<winrt::Windows::System::VirtualKey>(key.key));auto modifiers=winrt::Windows::System::VirtualKeyModifiers::None;
            if(key.control)modifiers|=winrt::Windows::System::VirtualKeyModifiers::Control;if(key.shift)modifiers|=winrt::Windows::System::VirtualKeyModifiers::Shift;if(key.alt)modifiers|=winrt::Windows::System::VirtualKeyModifiers::Menu;shortcut.Modifiers(modifiers);
            const auto invoke=[weak,action_id=std::string(action),key](const auto&,const xaml::Input::KeyboardAcceleratorInvokedEventArgs& args){
                const auto self=weak.get();if(!self||self->closing)return;
                try{
                    const auto& action=action_id;
                    if(self->fixture_preview)diagnostic(winrt::to_hstring("Shortcut invoked: "+action));
                    if(key.control&&!key.alt&&(key.key=='A'||key.key=='C'||key.key=='V'||key.key=='X'||key.key=='Z'||key.key=='Y')){
                        const auto focus=xaml::Input::FocusManager::GetFocusedElement(self->root.XamlRoot());
                        if(focus&&(focus.try_as<controls::TextBox>()||focus.try_as<controls::PasswordBox>()||focus.try_as<controls::RichEditBox>()))return;
                    }
                    if(action=="quit"){args.Handled(true);self->quit_app();return;}
                    if(self->dialog_open)return;args.Handled(true);
                    if(action=="new")self->create_thread();else if(action=="search"){self->search.Focus(xaml::FocusState::Keyboard);self->search.SelectAll();}
                    else if(action=="settings")self->show_status();else if(action=="terminal")self->show_terminal();else if(action=="browser")self->show_browser();
                    else if(action=="undo")self->history(false);else if(action=="redo")self->history(true);else if(action=="quit")self->quit_app();
                    else if(action=="archive")self->mutate_selection([&](const auto& ids){self->workspace.archive(ids,!self->workspace.thread(ids.front()).archived);});
                }catch(...){self->report_exception();}
            };shortcut.Invoked(invoke);root.KeyboardAccelerators().Append(shortcut);
            if(action=="quit"){
                // TextBox's native editor consumes Ctrl+Q before a parent accelerator sees it.
                // A distinct accelerator on the focused editor gets the configured app action.
                xaml::Input::KeyboardAccelerator editor;editor.Key(shortcut.Key());editor.Modifiers(modifiers);editor.Invoked(invoke);composer.KeyboardAccelerators().Append(editor);
            }
        }
    }
    void show_window(){if(!closing){window.AppWindow().Show();window.Activate();if(composer&&composer.IsEnabled())composer.Focus(xaml::FocusState::Programmatic);}}
    void quit_app(){
        if(closing)return;quitting=true;
        if(repository_mutating()){quit_when_safe=true;for(auto& [id,run]:running){(void)id;run.session->interrupt();}state.Text(coincide::ui_text(L"Finishing the repository operation before quitting…"));update_composer();return;}
        quit_when_safe=false;if(fixture_preview)diagnostic(L"Explicit quit requested");window.Close();
    }
    bool background_work()const{
        if(preferences.keep_awake||repository_mutating())return true;
        for(const auto& thread:workspace.threads)if(thread_busy(thread.id)||active_terminal(thread.id))return true;
        if(schedule_panel)for(const auto& task:schedule_panel->store().tasks())if(task.in_flight||(task.active()&&task.next_run))return true;
        return false;
    }
    std::string schedule_target(const std::string& canonical)const{
        const winrt::guid id(winrt::to_hstring(canonical));for(const auto& thread:workspace.threads)if(winrt::guid(winrt::to_hstring(thread.id))==id)return thread.id;return{};
    }
    bool repository_mutating()const{return (git_panel&&git_panel->mutating())||(hosting_panel&&hosting_panel->mutating());}
    bool repository_busy(const coincide::Thread& thread)const{
        if(!repository_mutating())return false;
        std::filesystem::path folder=data_directory()/L"workspaces"/winrt::to_hstring(thread.id).c_str();
        if(thread.bot_id){if(!bot_store)return true;const auto bot=bot_store->find(*thread.bot_id);if(!bot)return true;try{folder=bot_store->working_directory(*bot);}catch(...){return true;}}
        else if(thread.project_id){const auto project=std::find_if(workspace.projects.begin(),workspace.projects.end(),[&](const auto& value){return value.id==*thread.project_id;});if(project==workspace.projects.end())return true;folder=std::filesystem::path(winrt::to_hstring(project->path).c_str());}
        try{const auto overlap=[&](const auto& panel){const auto repository=panel->repository_root(),target=panel->mutation_target();return coincide::repository_lease::conflicts({repository,target},folder);};return (git_panel&&git_panel->mutating()&&overlap(git_panel))||(hosting_panel&&hosting_panel->mutating()&&overlap(hosting_panel));}catch(...){return true;}
    }
    bool native_available(const std::string& provider)const{
        if(fixture_preview)return true;
        try{const auto& value=preferences.providers.at(provider);return value.executable.empty()?coincide::ProviderDiscovery::windows_executable(coincide::ProviderDiscovery::discover(provider)):coincide::ProviderDiscovery::windows_executable(std::filesystem::path(winrt::to_hstring(value.executable).c_str()));}catch(...){return false;}
    }
    bool provider_connected(const coincide::Thread& thread)const{
        if(!preferences.providers.at(thread.provider).enabled)return false;
        if(thread.provider=="codex"||thread.provider=="claude"||thread.provider=="opencode")return true;
        if(thread.provider!="cursor")return false;
        const auto native=std::find_if(thread.sessions.begin(),thread.sessions.end(),[](const auto& value){return value.provider=="cursor";});
        const auto profile_id=native==thread.sessions.end()?preferences.providers.at("cursor").profile_id:native->profile_id;
        const auto account=account_metadata.find(profile_id);
        return !profile_id.empty()&&account!=account_metadata.end()&&account->second.state==coincide::ProviderAccountState::verified&&account->second.provider=="cursor";
    }
    bool schedule_eligible(const coincide::Thread& thread)const{
        if(thread.deleted_at||thread.archived||!preferences.providers.at(thread.provider).enabled)return false;
        return provider_connected(thread);
    }
    void ensure_schedules(){
        if(schedule_panel||!writable)return;const auto weak=get_weak();
        coincide::SchedulePanel::Clock clock;
        // The synthetic protocol UI fixture owns a logical clock. Its ten-second occurrence
        // starts when the controller opens, independent of cold WinUI/CI startup time.
        // Normal application launches always use SchedulePanel's real system clock.
        if(fixture_preview){
            wchar_t epoch_text[32]{};const auto length=GetEnvironmentVariableW(L"COINCIDE_FIXTURE_SCHEDULE_EPOCH",epoch_text,32);
            if(length&&length<32){const auto text=winrt::to_string(epoch_text);coincide::scheduling::Instant epoch{};
                const auto parsed=std::from_chars(text.data(),text.data()+text.size(),epoch);
                if(parsed.ec!=std::errc{}||parsed.ptr!=text.data()+text.size()||epoch<1||epoch>coincide::scheduling::maximum_instant-86400)throw std::runtime_error("Invalid owned schedule fixture epoch");
                const auto start=GetTickCount64();clock=[epoch,start]{return epoch+static_cast<coincide::scheduling::Instant>((GetTickCount64()-start)/1000);};
            }else if(length)throw std::runtime_error("Invalid owned schedule fixture epoch");
        }
        schedule_panel=coincide::SchedulePanel::create(data_directory(),[weak]{
            std::unordered_set<std::string> busy;if(const auto self=weak.get())for(const auto& thread:self->workspace.threads)
                if(self->thread_busy(thread.id)||!thread.queued_inputs.empty()||self->dirty_threads.contains(thread.id)||!self->persistence_error.empty()||self->repository_busy(thread))busy.insert(thread.id);
            return busy;
        },[weak](const auto& intent){if(const auto self=weak.get())return self->dispatch_schedule(intent);return false;},std::move(clock));
        tool_views.Children().Append(schedule_panel->view());schedule_panel->view().Visibility(xaml::Visibility::Collapsed);
        if(!selected.empty())schedule_panel->select_thread(selected);
    }
    void show_schedules(){if(selected.empty()||!writable)return;try{ensure_schedules();schedule_panel->select_thread(selected);select_tool("schedules",schedule_panel->view(),label(L"Schedules",L"Schedules"));}catch(...){report_exception();}}
    bool dispatch_schedule(const coincide::scheduling::DeliveryIntent& intent){
        if(closing||!writable)return false;
        const auto id=schedule_target(intent.thread_id);if(id.empty())return false;auto& thread=workspace.thread(id);store->load_thread(thread);
        if(!schedule_eligible(thread)||thread_busy(id)||!thread.queued_inputs.empty())return false;
        auto& run=session_for(id);const auto turn=make_turn(intent.prompt,{},thread.model,thread.effort,thread.service_tier,thread.plan,thread.full_access);
        if(std::any_of(thread.messages.begin(),thread.messages.end(),[&](const auto& message){return message.id==intent.delivery_id;}))return false;
        workspace.note_activity(id);store->save_index(workspace);thread.messages.push_back({intent.delivery_id,"user",intent.prompt,thread.provider});
        try{store->save_thread(thread);}catch(...){thread.messages.pop_back();throw;}
        prepare_usage(thread,run,intent.delivery_id);if(!run.session->send(turn)){run.usage.reset();thread.messages.pop_back();store->save_thread(thread);return false;}
        run.schedule_id=intent.schedule_id;run.schedule_delivery=intent.delivery_id;run.awaiting_completion=true;run.completion_received=false;run.failed=false;run.status=winrt::to_string(label(L"Connecting",L"Connecting…"));
        if(selected==id){transcript.Items().Append(message_row(thread.messages.back(),winrt::to_string(label(L"You",L"You"))));show_latest();update_composer();}
        refresh_sidebar();return true;
    }
    void platform_tick(){
        if(closing)return;
        flush_usage();
        std::erase_if(tool_workers,[](auto& worker){if(worker.wait_for(std::chrono::seconds(0))!=std::future_status::ready)return false;try{worker.get();}catch(...){}return true;});
        if(quitting){if(quit_when_safe&&!repository_mutating())quit_app();return;}
        if(computer_use)computer_use->idle_tick();
        if(credentials_controller)credentials_controller->tick();
        try{
            last_platform_tick=GetTickCount64();
            if(schedule_panel){
                bool ready=true;const auto now=coincide::Workspace::now_seconds();const auto tasks=schedule_panel->store().tasks();
                for(const auto& task:tasks){
                    const auto id=schedule_target(task.thread_id);bool available=!id.empty()&&schedule_eligible(workspace.thread(id));
                    if(available&&(task.pending_delivery||(task.next_run&&*task.next_run<=now))){try{store->load_thread(workspace.thread(id));(void)working_directory(workspace.thread(id));available=native_available(workspace.thread(id).provider);}catch(...){available=false;}}
                    if(!available&&(!task.paused||task.pending_delivery))ready=schedule_panel->pause_thread(task.thread_id)&&ready;
                }
                if(ready){if(schedule_wake_pending){if(schedule_panel->wake())schedule_wake_pending=false;}else schedule_panel->tick();}
            }
            if(!fixture_preview)power_request.update({preferences.keep_awake,preferences.awake_on_battery,preferences.keep_display});
        }catch(...){report_exception();}
    }
    winrt::fire_and_forget configure_notifications(){
        auto lifetime=get_strong();if(fixture_preview||closing)co_return;
        try{
            if(!notifications){const auto weak=get_weak();notifications=coincide::WindowsNotifications::create(data_directory()/L"notifications",
                [weak](std::function<void()> action)->bool{const auto self=weak.get();return self&&!self->closing&&self->window.DispatcherQueue().TryEnqueue([action=std::move(action)]{action();});},
                [weak](const std::string& identity){if(const auto self=weak.get();self&&!self->closing){const auto id=self->schedule_target(identity);if(!id.empty()){self->show_window();self->open_thread(id);}}},
                [weak](const std::string& identity){if(const auto self=weak.get();self&&!self->closing){const auto id=self->schedule_target(identity);if(!id.empty()){const auto& thread=self->workspace.thread(id);return !thread.deleted_at&&!thread.archived;}}return false;},nullptr,{},
                [weak](std::string error){if(const auto self=weak.get();self&&!self->closing)self->show_error(winrt::to_hstring(error));});}
            co_await notifications->set_enabled(preferences.notifications);
        }catch(...){if(!closing)report_exception();}
    }
    winrt::fire_and_forget dismiss_notification(std::string id){
        auto lifetime=get_strong();if(!notifications||!notifications->enabled()||closing)co_return;
        try{co_await notifications->dismiss(id);}catch(...){if(!closing)report_exception();}
    }
    void notify_thread(const std::string& id,bool response){
        if(fixture_preview||!preferences.notifications||!notifications||!notifications->enabled()||closing)return;
        if(window.AppWindow().IsVisible()&&selected==id)return;
        try{notifications->notify(id,winrt::to_hstring(workspace.thread(id).title).c_str(),response?coincide::ui_text(L"An agent needs your response.").c_str():coincide::ui_text(L"The conversation finished.").c_str());}catch(...){report_exception();}
    }
    void account_changed(const coincide::ProviderAccountRecord& record,const coincide::ProviderAccountMetadata& account_state){
        account_metadata.insert_or_assign(record.id,account_state);
        for(auto at=running.begin();at!=running.end();){if(at->second.provider==record.provider&&at->second.profile_id==record.id){
            if(schedule_panel&&!schedule_panel->pause_thread(at->first))schedule_wake_pending=true;
            at->second.session->interrupt();at->second.session->shutdown();at=running.erase(at);
        }else ++at;}
        if(!selected.empty()){render_prompts();render_queue();update_composer();}
    }
    void show_accounts(){
        try{
            if(!accounts_panel){const auto weak=get_weak();accounts_panel=coincide::ProviderAccountsPanel::create(data_directory()/L"provider-profiles",
                [weak](const std::string& provider)->std::optional<coincide::ProviderAccountProgram>{const auto self=weak.get();if(!self||self->closing)return{};
                    try{const auto& settings=self->preferences.providers.at(provider);const auto path=settings.executable.empty()?coincide::ProviderDiscovery::discover(provider):std::filesystem::path(winrt::to_hstring(settings.executable).c_str());return coincide::ProviderAccountProgram::from(coincide::ACPVendorLaunch::inspect(provider,path));}catch(...){return{};}},
                [weak](const auto& record,const auto& account_state){if(const auto self=weak.get();self&&!self->closing)self->account_changed(record,account_state);},
                [weak](const std::string& url){if(const auto self=weak.get();self&&!self->closing){try{
                    self->ensure_browser_panel();
                    if(self->account_browser_context.empty())self->account_browser_context=coincide::new_id();self->browser_panel->select_thread(self->account_browser_context);self->select_tool("browser",self->browser_panel->view(),label(L"Browser",L"Browser"));self->browser_panel->navigate(url);
                }catch(...){self->report_exception();}}});
                accounts_panel->set_operation_guard([weak](const coincide::ProviderAccountRecord& record,bool){if(const auto self=weak.get();self&&!self->closing){
                    for(const auto& [id,run]:self->running)if(run.provider==record.provider&&run.profile_id==record.id&&self->thread_busy(id))throw std::runtime_error("Stop this profile's conversations before checking or changing its sign-in.");
                    self->account_changed(record,{});
                }else throw std::runtime_error("The app is closing.");});
                accounts_panel->set_use_profile([weak](const auto& record,const auto& account_state){
                    const auto self=weak.get();if(!self||self->closing)throw std::runtime_error("The app is closing.");
                    if(record.provider!="cursor")throw std::runtime_error("This provider's Windows account identity is not verified yet.");
                    self->account_changed(record,account_state);auto next=self->preferences;next.providers.at(record.provider).profile_id=record.id;self->apply_preferences(std::move(next));
                },[weak](const auto& record,const auto& account_state){const auto self=weak.get();return self&&!self->closing&&self->preferences_writable&&record.provider=="cursor"&&account_state.state==coincide::ProviderAccountState::verified;});
                tool_views.Children().Append(accounts_panel->view());}
            select_tool("accounts",accounts_panel->view(),label(L"Accounts",L"Accounts"));
        }catch(...){report_exception();}
    }

    void close_voice(){
        if(!voice_panel)return;if(visible_tool=="voice")hide_tools();voice_panel->close();std::uint32_t index{};if(tool_views&&tool_views.Children().IndexOf(voice_panel->view(),index))tool_views.Children().RemoveAt(index);voice_panel.reset();
    }
    void show_voice(){
        try{
            if(fixture_preview)throw std::runtime_error("Voice fixture previews use the separate synthetic native panel tests.");
            if(!writable||selected.empty()||workspace.thread(selected).deleted_at)throw std::runtime_error("Select an available conversation before opening Voice.");
            if(!voice_panel){const auto weak=get_weak();HWND owner{};winrt::check_hresult(window.as<IWindowNative>()->get_WindowHandle(&owner));
                voice_panel=coincide::VoicePanel::create(data_directory()/L"Voice",[weak]{const auto self=weak.get();if(!self||self->closing||!self->writable||self->selected.empty()||self->workspace.thread(self->selected).deleted_at)throw std::runtime_error("Select an available conversation before recording.");return coincide::VoiceDestination{self->selected,self->draft_revision};},
                [weak](const coincide::VoiceDestination& destination,const std::string& text){const auto self=weak.get();if(!self||self->closing||!self->writable||self->selected!=destination.thread_id||self->draft_revision!=destination.draft_revision)return false;
                    auto& thread=self->workspace.thread(self->selected);if(thread.deleted_at||text.empty()||text.size()>256*1024||text.find('\0')!=std::string::npos||!coincide::local_file::utf8(text)||thread.draft.size()>4*1024*1024-text.size())return false;
                    const auto previous=thread.draft;thread.draft+=previous.empty()||std::isspace(static_cast<unsigned char>(previous.back()))?text:" "+text;
                    try{self->store->save_thread(thread);}catch(...){thread.draft=previous;throw;}
                    self->selecting=true;try{self->composer.Text(winrt::to_hstring(thread.draft));}catch(...){self->selecting=false;throw;}self->selecting=false;self->update_composer();return true;
                },owner);tool_views.Children().Append(voice_panel->view());}
            select_tool("voice",voice_panel->view(),label(L"Voice",L"Voice"));
        }catch(...){report_exception();}
    }
    void ensure_usage(){if(!usage_store){auto value=std::make_shared<coincide::UsageStore>(data_directory());value->open();usage_store=std::move(value);}}
    void prepare_usage(const coincide::Thread& thread,RunningThread& run,const std::string& delivery)noexcept{
        try{if(run.usage)return;coincide::UsageOwner owner;owner.provider=run.provider;owner.project_id=thread.project_id.value_or("");owner.thread_id=thread.id;owner.profile_id=run.profile_id;owner.account_scope=run.account_scope;owner.model=thread.model;owner.delivery_id=delivery;
            const auto native=std::find_if(thread.sessions.begin(),thread.sessions.end(),[&](const auto& value){return value.provider==run.provider;});if(native!=thread.sessions.end()){owner.native_session=native->id;if(owner.account_scope.empty())owner.account_scope=native->account_scope;}
            run.usage=std::make_unique<coincide::UsageTurn>(std::move(owner),coincide::UsageStore::now_ms());
        }catch(...){usage_warning="Usage could not be recorded for this turn.";run.usage.reset();}
    }
    void finish_usage(RunningThread& run,const std::string& outcome)noexcept{
        if(!run.usage)return;try{if(pending_usage.size()>=1000){usage_warning="Usage recording is paused until local history can be saved.";run.usage.reset();return;}pending_usage.push_back(run.usage->finish(outcome,coincide::UsageStore::now_ms()));}catch(...){usage_warning="Usage could not be recorded for this turn.";}run.usage.reset();
    }
    void flush_usage()noexcept{
        if(pending_usage.empty()||GetTickCount64()<usage_retry_at)return;try{ensure_usage();while(!pending_usage.empty()){usage_store->record(pending_usage.front());pending_usage.pop_front();}usage_warning.clear();usage_retry_at=0;}catch(...){usage_warning="Local usage history could not be saved. Existing history was preserved.";usage_retry_at=GetTickCount64()+30000;}
    }
    coincide::BotSelection bot_defaults()const{
        coincide::BotSelection result;result.provider=preferences.provider_default({});const auto defaults=preferences.model_defaults({},result.provider);
        result.profile_id=preferences.providers.at(result.provider).profile_id;if(result.profile_id.empty())result.profile_id="default";
        result.model=defaults.model;result.effort=defaults.effort;result.service_tier=defaults.service_tier;result.plan=defaults.plan;result.full_access=defaults.full_access;return result;
    }
    void ensure_bots(){
        if(bot_store&&bot_workspace)return;if(!writable)throw std::runtime_error("The workspace is read-only.");
        std::filesystem::path home;
        if(fixture_preview){home=data_directory()/L"fixture-home";std::filesystem::create_directories(home);}
        else{PWSTR path{};winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_Profile,KF_FLAG_DEFAULT,nullptr,&path));home=path;CoTaskMemFree(path);}
        std::filesystem::create_directories(data_directory());auto bots=std::make_shared<coincide::BotStore>(data_directory()/L"bots",home);bots->open();bots->ensure_starters(bot_defaults());const auto weak=get_weak();
        auto controller=std::make_unique<coincide::BotWorkspace>(workspace,*store,*bots,[weak](const auto& id){const auto self=weak.get();return !self||self->closing||self->thread_busy(id)||self->active_terminal(id)||self->repository_busy(self->workspace.thread(id))||self->dirty_threads.contains(id)||!self->persistence_error.empty();},
            [weak](const auto& ids){if(const auto self=weak.get();self&&!self->closing)self->invalidate_project_context(ids);else throw std::runtime_error("The app is closing.");});
        controller->recover_orphans();bot_store=std::move(bots);bot_workspace=std::move(controller);
    }
    void show_bots(){
        if(!writable)return;try{ensure_bots();if(!persona_panel){const auto weak=get_weak();coincide::PersonaCallbacks callbacks;
            callbacks.conversations=[weak](const auto& id){const auto self=weak.get();if(!self||self->closing)throw std::runtime_error("The app is closing.");return self->bot_workspace->conversations(id);};
            callbacks.open=[weak](const auto& plan){if(const auto self=weak.get();self&&!self->closing){const auto id=self->bot_workspace->open(plan);self->thread_view=coincide::ThreadView::inbox;self->thread_filter.SelectedIndex(0);self->search.Text(L"");self->open_thread(id);}};
            callbacks.before_change=[weak](const auto& change){const auto self=weak.get();if(!self||self->closing)throw std::runtime_error("The app is closing.");self->bot_workspace->before_change(change);};
            callbacks.changed=[weak](const auto&){if(const auto self=weak.get();self&&!self->closing){self->bot_workspace->recover_orphans();self->refresh_sidebar();self->update_composer();}};
            callbacks.before_remove=[weak](const auto& bot,auto disposition){const auto self=weak.get();if(!self||self->closing)throw std::runtime_error("The app is closing.");self->bot_workspace->before_remove(bot,disposition);};
            callbacks.removed=[weak](const auto& id,auto disposition){const auto self=weak.get();if(!self||self->closing)throw std::runtime_error("The app is closing.");self->bot_workspace->removed(id,disposition);self->reconcile_selection();};
            callbacks.pick_folder=[weak](auto completion){std::optional<std::string> path;try{if(const auto self=weak.get();self&&!self->closing){winrt::com_ptr<IFileOpenDialog> picker;winrt::check_hresult(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(picker.put())));DWORD options{};winrt::check_hresult(picker->GetOptions(&options));winrt::check_hresult(picker->SetOptions(options|FOS_PICKFOLDERS|FOS_FORCEFILESYSTEM));HWND hwnd{};winrt::check_hresult(self->window.as<IWindowNative>()->get_WindowHandle(&hwnd));const auto result=picker->Show(hwnd);
                    if(result!=HRESULT_FROM_WIN32(ERROR_CANCELLED)){winrt::check_hresult(result);winrt::com_ptr<IShellItem> item;winrt::check_hresult(picker->GetResult(item.put()));PWSTR value{};winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH,&value));path=winrt::to_string(value);CoTaskMemFree(value);}}}catch(...){if(const auto self=weak.get())self->report_exception();}completion(std::move(path));};
            std::vector<coincide::BotProviderChoice> choices;for(const auto& provider:preferences.providers){coincide::BotProviderChoice choice{provider.first,provider.first,{{"default","Default account"}}};choices.push_back(std::move(choice));}
            coincide::ProviderAccountStore profiles(data_directory()/L"provider-profiles");for(const auto& record:profiles.open())for(auto& choice:choices)if(choice.id==record.provider)choice.profiles.push_back({record.id,record.label});
            persona_panel=coincide::PersonaPanel::create(bot_store,bot_defaults(),std::move(callbacks),std::move(choices));tool_views.Children().Append(persona_panel->view());}
            persona_panel->refresh();select_tool("bots",persona_panel->view(),label(L"Bots",L"Bots"));
        }catch(...){report_exception();}
    }
    void show_usage(){
        if(!writable)return;try{ensure_usage();flush_usage();if(usage_panel){std::uint32_t index{};if(tool_views.Children().IndexOf(usage_panel->view(),index))tool_views.Children().RemoveAt(index);usage_panel->close();}
            std::vector<coincide::UsageLabel> projects,threads;std::vector<coincide::UsageAccountStatus> accounts;for(const auto& value:workspace.projects)projects.push_back({value.id,value.name});for(const auto& value:workspace.threads)threads.push_back({value.id,value.title});for(const auto& entry:account_metadata)accounts.push_back(coincide::UsageAccountStatus::from(entry.second));
            usage_panel=coincide::UsagePanel::create(usage_store,std::move(projects),std::move(threads),std::move(accounts));usage_panel->set_recording_warning(usage_warning);tool_views.Children().Append(usage_panel->view());select_tool("usage",usage_panel->view(),label(L"Usage",L"Usage"));if(!usage_warning.empty())state.Text(winrt::to_hstring(usage_warning));
        }catch(...){report_exception();}
    }
    static std::string tool_error(const std::string& message){coincide::app_tools::Object result;coincide::computer_use::put(result,L"error",message);return winrt::to_string(result.Stringify());}
    void ensure_credentials(){
        if(credentials_controller)return;const auto weak=get_weak();coincide::CredentialsController::Services services;
        services.show_panel=[weak](const std::string& id){const auto self=weak.get();if(!self||self->closing||self->dialog_open)throw std::runtime_error("The owner window is unavailable for sign-in approval.");if(self->selected!=id)self->open_thread(id);self->show_window();self->show_credentials();};
        services.choose_csv=[weak](auto complete){std::optional<std::filesystem::path> selected_file;const auto self=weak.get();if(!self||self->closing||self->dialog_open){complete({});return;}self->dialog_open=true;
            try{winrt::com_ptr<IFileOpenDialog> picker;winrt::check_hresult(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(picker.put())));const COMDLG_FILTERSPEC filters[]={{L"Password CSV export",L"*.csv"}};winrt::check_hresult(picker->SetFileTypes(1,filters));winrt::check_hresult(picker->SetOptions(FOS_FILEMUSTEXIST|FOS_PATHMUSTEXIST|FOS_FORCEFILESYSTEM));HWND hwnd{};winrt::check_hresult(self->window.as<IWindowNative>()->get_WindowHandle(&hwnd));const auto result=picker->Show(hwnd);
                if(result!=HRESULT_FROM_WIN32(ERROR_CANCELLED)){winrt::check_hresult(result);winrt::com_ptr<IShellItem> item;winrt::check_hresult(picker->GetResult(item.put()));PWSTR value{};winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH,&value));selected_file=std::filesystem::path(value);CoTaskMemFree(value);}}
            catch(...){if(!self->closing)self->show_error(coincide::ui_text(L"The password export picker could not open. No logins were imported."));}
            self->dialog_open=false;complete(std::move(selected_file));
        };
        credentials_controller=coincide::CredentialsController::create(data_directory()/L"browser-credentials",std::move(services));
        credentials_view=controls::ScrollViewer{};credentials_view.Content(credentials_controller->view());credentials_view.HorizontalScrollBarVisibility(controls::ScrollBarVisibility::Disabled);tool_views.Children().Append(credentials_view);credentials_view.Visibility(xaml::Visibility::Collapsed);
        if(!selected.empty())credentials_controller->select_thread(selected);
    }
    void show_credentials(){if(closing||!writable)return;try{ensure_credentials();select_tool("passwords",credentials_view,label(L"Passwords",L"Passwords"));}catch(...){report_exception();}}
    void ensure_browser_panel(){
        if(browser_panel)return;browser_panel=coincide::BrowserPanel::create(data_directory()/L"browser",{},fixture_preview);const auto weak=get_weak();
        browser_panel->set_agent_control_callback([weak](const std::string& id,bool enabled){if(const auto self=weak.get();self&&!self->closing){const auto thread=self->schedule_target(id);if(thread.empty()){if(enabled)self->browser_panel->set_agent_control(id,false);return;}self->ensure_thread_tools(thread);}});
        browser_panel->set_navigation_callback([weak](const std::string& frame){if(const auto self=weak.get();self&&self->credentials_controller)self->credentials_controller->cancel_navigation(frame);});
        browser_panel->set_show_callback([weak](const std::string& id,bool show){if(const auto self=weak.get();self&&!self->closing){if(show){if(self->dialog_open)throw std::runtime_error("Finish the open dialog before showing another browser.");const auto thread=self->schedule_target(id);if(thread.empty())throw std::runtime_error("This browser conversation is unavailable.");if(self->selected!=thread)self->open_thread(thread);self->show_window();self->select_tool("browser",self->browser_panel->view(),label(L"Browser",L"Browser"));}else if(self->selected==id&&self->visible_tool=="browser")self->hide_tools();}});
        browser_panel->set_search_resolver([](const std::string& query){static constexpr char hex[]="0123456789ABCDEF";std::string url="https://www.google.com/search?q=";for(const auto byte:query){const auto c=static_cast<unsigned char>(byte);if((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~')url+=static_cast<char>(c);else{url+='%';url+=hex[c>>4];url+=hex[c&15];}}return url;});
        tool_views.Children().Append(browser_panel->view());
    }
    winrt::fire_and_forget handle_browser_tool(coincide::app_tools::Request request,std::shared_ptr<coincide::app_tools::Operation> operation){
        auto lifetime=get_strong();const auto id=schedule_target(request.thread_id);bool own_dialog{},restore_browser{},restore_passwords{};
        try{
            if(operation->cancelled())co_return;
            if(id.empty()||!browser_panel||!browser_panel->agent_control(id)){operation->complete(tool_error("Browser control is unavailable for this conversation."),403);co_return;}
            const auto body=coincide::app_tools::Object::Parse(winrt::to_hstring(request.json));const auto cancelled=[operation]{return operation->cancelled();};coincide::app_tools::Object result;
            if(request.action=="fill-login"){
                restore_passwords=visible_tool!="passwords";
                ensure_credentials();result=co_await credentials_controller->fill_login(browser_panel,id,winrt::to_string(body.GetNamedString(L"tab",L"")),winrt::to_string(body.GetNamedString(L"item",L"")),cancelled);
            }else if(request.action=="ask-user"){
                if(dialog_open)throw std::runtime_error("Finish the open dialog before requesting another owner action.");
                restore_browser=visible_tool!="browser";if(selected!=id)open_thread(id);show_window();select_tool("browser",browser_panel->view(),label(L"Browser",L"Browser"));
                dialog_open=true;own_dialog=true;
                const auto deadline=GetTickCount64()+static_cast<std::uint64_t>(body.GetNamedNumber(L"timeout",300)*1000);
                const auto decision=co_await coincide::native_user_prompt(root.XamlRoot(),coincide::ui_text(L"Action needed"),body.GetNamedString(L"message",L""),coincide::ui_text(L"Done"),deadline,cancelled);
                dialog_open=false;own_dialog=false;coincide::computer_use::put(result,L"result",winrt::to_string(decision));
            }else result=co_await browser_panel->request(id,request.json,request.artifact_directory,cancelled,operation);
            if(!operation->cancelled())operation->complete(winrt::to_string(result.Stringify()));
        }catch(const winrt::hresult_error&){operation->complete(tool_error("The browser action could not finish. Its result was not replayed."),400);}
        catch(const std::exception& error){operation->complete(tool_error(error.what()),400);}
        if(own_dialog)dialog_open=false;if(((restore_browser&&visible_tool=="browser")||(restore_passwords&&visible_tool=="passwords"))&&selected==id)hide_tools();
    }
    void ensure_tool_bridge(){
        if(tool_bridge||fixture_preview||!writable)return;const auto folder=data_directory()/L"app-tools";std::filesystem::create_directories(folder);const auto queue=window.DispatcherQueue();
        tool_bridge=std::make_shared<coincide::app_tools::AppToolBridge>(folder,[queue](std::function<void()> work){return queue.TryEnqueue([work=std::move(work)]{work();});});
    }
    void ensure_thread_tools(const std::string& id){
        if(fixture_preview||closing||quitting||!writable)return;ensure_tool_bridge();const auto& thread=workspace.thread(id);
        if(thread.deleted_at||thread.archived){tool_bridge->disable(id);return;}const auto weak=get_weak();
        const auto handler=[weak](const coincide::app_tools::Request& request,const std::shared_ptr<coincide::app_tools::Operation>& operation){if(const auto self=weak.get())self->handle_app_tool(request,operation);else operation->complete("{\"error\":\"Coincide is closing\"}",503);};
        using Channel=coincide::app_tools::Channel;
        tool_bridge->enable(id,Channel::schedule,coincide::app_tools::Request::actions(Channel::schedule),handler);
        if(browser_panel&&browser_panel->agent_control(id))tool_bridge->enable(id,Channel::browser,coincide::app_tools::Request::actions(Channel::browser),handler);else tool_bridge->disable(id,Channel::browser);
        if(terminal_tool_threads.contains(id))tool_bridge->enable(id,Channel::terminal,coincide::app_tools::Request::actions(Channel::terminal),handler);else tool_bridge->disable(id,Channel::terminal);
        if(computer_use&&computer_use->snapshot(id).granted)tool_bridge->enable(id,Channel::computer_use,coincide::app_tools::Request::actions(Channel::computer_use),handler);else tool_bridge->disable(id,Channel::computer_use);
    }
    void handle_app_tool(const coincide::app_tools::Request& request,const std::shared_ptr<coincide::app_tools::Operation>& operation){
        using namespace coincide::app_tools;using Channel=coincide::app_tools::Channel;
        if(operation->cancelled())return;
        try{
            if(closing||quitting||!writable)throw std::runtime_error("Coincide is closing or its workspace is read-only");
            const auto id=schedule_target(request.thread_id);if(id.empty()||workspace.thread(id).deleted_at||workspace.thread(id).archived)throw std::runtime_error("This conversation is unavailable");
            if(request.channel==Channel::browser){if(!browser_panel||!browser_panel->agent_control(id))throw std::runtime_error("Browser control is not permitted for this conversation");handle_browser_tool(request,operation);return;}
            if(request.channel==Channel::schedule){ensure_schedules();if((request.action=="run-now"||request.action=="resume")&&!schedule_eligible(workspace.thread(id)))throw std::runtime_error("This conversation's provider or working folder is unavailable");
                const auto result=schedule_panel->request(id,request.json);operation->complete(winrt::to_string(result.Stringify()));return;}
            if(request.channel==Channel::computer_use){
                if(!computer_use||!computer_use->snapshot(id).granted)throw std::runtime_error("Computer Use is not permitted for this conversation");
                const auto controller=computer_use;const auto json=request.json;
                tool_workers.push_back(std::async(std::launch::async,[controller,operation,id,json]{coincide::app_tools::Apartment apartment;if(operation->cancelled())return;try{const auto result=controller->perform(id,json);if(!operation->cancelled())operation->complete(winrt::to_string(result.Stringify()));}catch(const winrt::hresult_error& error){operation->complete(tool_error(winrt::to_string(error.message())),400);}catch(const std::exception& error){operation->complete(tool_error(error.what()),400);}}));return;
            }
            if(request.channel!=Channel::terminal||!terminal_tool_threads.contains(id))throw std::runtime_error("This app tool is not permitted for this conversation");
            Object result;winrt::Windows::Data::Json::JsonArray panes;const auto existing=terminal_panel?terminal_panel->panes(id):std::vector<coincide::TerminalPaneSnapshot>{};
            if(request.action=="show"){
                if(dialog_open)throw std::runtime_error("Finish the open dialog before showing a terminal");if(existing.empty())throw std::runtime_error("Open this conversation's terminal first; agent access cannot start a shell");
                if(selected!=id)open_thread(id);select_tool("terminal",terminal_panel->view(),label(L"Terminal",L"Terminal"));
            }else if(request.action=="hide"){if(selected==id&&visible_tool=="terminal")hide_tools();}
            else if(request.action=="interrupt"){bool interrupted{};for(const auto& pane:existing)if(!operation->cancelled())interrupted=terminal_panel->interrupt(id,pane.id)||interrupted;result.SetNamedValue(L"interrupted",Value::CreateBooleanValue(interrupted));}
            const auto options=Object::Parse(winrt::to_hstring(request.json));const auto limit=request.action=="read"?static_cast<std::size_t>(number(options,L"limit",1,2000,200,true)):0,page=request.action=="read"?static_cast<std::size_t>(number(options,L"page",1,1000,1,true)):1;
            for(const auto& pane:existing){Object item;coincide::computer_use::put(item,L"id",pane.id);coincide::computer_use::put(item,L"tab",pane.tab_id);coincide::computer_use::put(item,L"title",pane.title);coincide::computer_use::put(item,L"status",pane.status);item.SetNamedValue(L"running",Value::CreateBooleanValue(pane.running));item.SetNamedValue(L"starting",Value::CreateBooleanValue(pane.starting));
                if(request.action=="read"){const auto snapshot=terminal_panel->read(id,pane.id);std::istringstream source(snapshot.text);std::string line,text;std::size_t count{};while(std::getline(source,line)){if(count>=(page-1)*limit&&count<page*limit){text+=line;text+='\n';}++count;}coincide::computer_use::put(item,L"text",text);item.SetNamedValue(L"truncated",Value::CreateBooleanValue(snapshot.truncated));item.SetNamedValue(L"pages",Value::CreateNumberValue(static_cast<double>(std::max<std::size_t>(1,(count+limit-1)/limit))));}
                panes.Append(item);
            }
            result.SetNamedValue(L"panes",panes);operation->complete(winrt::to_string(result.Stringify()));
        }catch(const winrt::hresult_error& error){operation->complete(tool_error(winrt::to_string(error.message())),400);}catch(const std::exception& error){operation->complete(tool_error(error.what()),400);}
    }
    winrt::fire_and_forget show_tool_access(){
        auto lifetime=get_strong();if(dialog_open||selected.empty()||!writable)co_return;const auto id=selected;dialog_open=true;
        try{controls::StackPanel body;body.Spacing(12);controls::TextBlock explanation;explanation.Text(coincide::ui_text(L"Share terminal output only with this conversation. Access lasts until revoked or Coincide closes. Agents cannot type or execute commands through this connection."));explanation.TextWrapping(xaml::TextWrapping::Wrap);body.Children().Append(explanation);
            controls::CheckBox terminal;terminal.Content(winrt::box_value(coincide::ui_text(L"Allow terminal status, output and interrupt")));terminal.IsChecked(terminal_tool_threads.contains(id));identify(terminal,L"AllowTerminalAgentAccess");body.Children().Append(terminal);
            controls::TextBlock schedules;schedules.Text(coincide::ui_text(L"Schedule proposals always require your approval in the Schedules panel. Computer Use permissions are managed separately in Settings."));schedules.TextWrapping(xaml::TextWrapping::Wrap);body.Children().Append(schedules);
            controls::ContentDialog dialog;dialog.XamlRoot(root.XamlRoot());dialog.Title(winrt::box_value(coincide::ui_text(L"Agent tool access")));dialog.Content(body);dialog.PrimaryButtonText(label(L"Save",L"Save"));dialog.CloseButtonText(label(L"Cancel",L"Cancel"));
            if(co_await dialog.ShowAsync()==controls::ContentDialogResult::Primary&&!closing){const auto checked=terminal.IsChecked();if(checked&&checked.Value())terminal_tool_threads.insert(id);else terminal_tool_threads.erase(id);ensure_thread_tools(id);}
        }catch(...){if(!closing)report_exception();}dialog_open=false;
    }
    void ensure_computer_use(){
        if(computer_use||fixture_preview)return;const auto directory=data_directory()/L"ComputerUse";std::filesystem::create_directories(directory/L"helper");
        wchar_t module[32768]{};const auto length=GetModuleFileNameW(nullptr,module,32768);if(!length||length>=32768)winrt::throw_last_error();
        auto backend=std::make_shared<coincide::computer_use::ProcessBackend>(module,directory/L"helper",GetCurrentProcessId());
        auto controller=std::make_shared<coincide::computer_use::Controller>(std::move(backend));coincide::computer_use::SettingsStore settings(directory);controller->set_enabled(settings.open().enabled);computer_use=std::move(controller);
    }
    void show_instructions(){
        try{
            if(!instructions_panel){instructions_panel=coincide::InstructionsPanel::create();tool_views.Children().Append(instructions_panel->view());}
            if(!selected.empty()&&workspace.thread(selected).project_id)instructions_panel->set_project(working_directory(workspace.thread(selected)));else instructions_panel->show_global();
            select_tool("instructions",instructions_panel->view(),label(L"Instructions",L"Instructions"));
        }catch(...){report_exception();}
    }
    std::optional<std::string> import_duplicate(const coincide::ImportPreview& preview)const{
        if(const auto live=coincide::ImportService::duplicate_thread(preview,workspace))return live;
        const winrt::guid expected(winrt::to_hstring(preview.session_id));
        for(const auto& record:import_identities)if(record.session.provider==preview.provider){try{
            if(winrt::guid(winrt::to_hstring(record.session.id))==expected&&std::any_of(workspace.threads.begin(),workspace.threads.end(),[&](const auto& thread){return thread.id==record.thread_id;}))return record.thread_id;
        }catch(const winrt::hresult_error&){}}
        return std::nullopt;
    }
    void commit_import(const std::shared_ptr<const coincide::ImportPreview>& preview){
        if(closing||!writable||!preview)throw std::runtime_error("The workspace is not available for importing.");
        if(const auto duplicate=import_duplicate(*preview))throw std::runtime_error("This native session is already imported. Open the existing conversation instead.");
        coincide::ImportService::verify_unchanged(*preview);
        auto candidate=workspace;coincide::Thread thread;thread.id=coincide::new_id();thread.provider=preview->provider;thread.title=preview->title.empty()?winrt::to_string(label(L"ImportedSession",L"Imported Session")):preview->title;
        thread.model=preview->model;thread.titled_by_user=true;thread.created_at=thread.updated_at=coincide::Workspace::now_seconds();thread.messages=preview->messages;
        bool resumable=false;
        if(!preview->directory.empty()){
            const auto folder=std::filesystem::path(winrt::to_hstring(preview->directory).c_str());std::error_code error;
            if(coincide::local_file::local_path(folder)&&!coincide::local_file::has_reparse(folder)&&std::filesystem::is_directory(folder,error)){
                const auto canonical=std::filesystem::canonical(folder);auto found=std::find_if(candidate.projects.begin(),candidate.projects.end(),[&](const auto& project){std::error_code ignored;return project.id!=coincide::bots_container_id&&std::filesystem::equivalent(canonical,std::filesystem::path(winrt::to_hstring(project.path).c_str()),ignored)&&!ignored;});
                if(found!=candidate.projects.end())thread.project_id=found->id;
                else{const auto id=coincide::new_id();candidate.add_project({id,winrt::to_string(canonical.filename().empty()?canonical.root_name().wstring():canonical.filename().wstring()),winrt::to_string(canonical.wstring())});thread.project_id=id;}
                resumable=true;
            }
        }
        if(resumable)thread.sessions.push_back({thread.provider,preview->session_id,thread.messages.size()});
        // Permission state and pending inputs always start fresh; source provenance cannot grant access.
        thread.plan=false;thread.full_access=false;const auto id=thread.id;store->publish_import(candidate,thread,coincide::ImportService::provenance(*preview));workspace=std::move(candidate);
        import_identities.push_back({id,{preview->provider,preview->session_id,0},true});search.Text(L"");thread_view=coincide::ThreadView::inbox;thread_filter.SelectedIndex(0);refresh_sidebar();open_thread(id);
    }
    winrt::fire_and_forget show_imports(){
        auto lifetime=get_strong();if(imports_loading||!writable)co_return;
        if(import_panel){select_tool("imports",import_panel->view(),label(L"ImportSessions",L"Import Sessions"));co_return;}
        imports_loading=true;const auto directory=data_directory();std::vector<std::string> ids;for(const auto& thread:workspace.threads)ids.push_back(thread.id);const winrt::apartment_context ui;
        std::vector<coincide::StoredSessionIdentity> identities;std::string error;
        co_await winrt::resume_background();try{identities=coincide::WorkspaceStore::session_snapshot(directory,ids);}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}
        try{co_await ui;}catch(...){co_return;}imports_loading=false;if(closing)co_return;
        if(!error.empty()){show_error(winrt::to_hstring(error));co_return;}
        try{
            import_identities=std::move(identities);HWND owner{};winrt::check_hresult(window.as<IWindowNative>()->get_WindowHandle(&owner));const auto weak=get_weak();
            import_panel=coincide::ImportPanel::create(coincide::ImportService::default_roots(),[weak](const auto& preview){const auto self=weak.get();if(!self||self->closing)throw std::runtime_error("The app closed before import publication.");self->commit_import(preview);},[weak](const auto& preview)->std::optional<std::string>{const auto self=weak.get();if(!self||self->closing)throw std::runtime_error("The app is closing.");return self->import_duplicate(preview);},owner);
            tool_views.Children().Append(import_panel->view());select_tool("imports",import_panel->view(),label(L"ImportSessions",L"Import Sessions"));import_panel->refresh();
        }catch(...){report_exception();}
    }

    void hide_tools(){
        if(browser_panel)browser_panel->set_visible(false);
        if(terminal_panel)terminal_panel->set_visible(false);
        if(preview_panel)preview_panel->set_visible(false);
        visible_tool.clear();tools_host.Visibility(xaml::Visibility::Collapsed);tools_column.Width({0,xaml::GridUnitType::Pixel});
    }
    void select_tool(std::string name,const xaml::UIElement& view,const hstring& heading){
        hide_tools();for(const auto& child:tool_views.Children())child.Visibility(xaml::Visibility::Collapsed);
        visible_tool=std::move(name);view.Visibility(xaml::Visibility::Visible);
        if(visible_tool=="browser")browser_panel->set_visible(true);
        if(visible_tool=="terminal")terminal_panel->set_visible(true);
        if(visible_tool=="preview")preview_panel->set_visible(true);
        tools_title.Text(heading);tools_column.Width({std::min(680.0,std::max(360.0,root.ActualWidth()*0.5)),xaml::GridUnitType::Pixel});tools_host.Visibility(xaml::Visibility::Visible);
    }
    void show_browser(std::string url={}){
        if(selected.empty())return;
        try{
            ensure_browser_panel();
            browser_panel->select_thread(selected);select_tool("browser",browser_panel->view(),label(L"Browser",L"Browser"));
            if(!url.empty())browser_panel->navigate(url);
        }catch(...){report_exception();}
    }
    void show_terminal(){
        if(selected.empty()||!writable)return;
        try{
            if(repository_busy(workspace.thread(selected)))throw std::runtime_error("Wait for the repository operation to finish before opening a terminal.");
            if(!terminal_panel){terminal_panel=coincide::TerminalPanel::create(data_directory(),fixture_preview);const auto weak=get_weak();terminal_panel->set_command_guard([weak](const auto& id,const auto&){const auto self=weak.get();if(!self||self->closing||self->quitting)return false;try{return !self->repository_busy(self->workspace.thread(id));}catch(...){return false;}});tool_views.Children().Append(terminal_panel->view());}
            terminal_panel->select_thread(selected,working_directory(workspace.thread(selected)));select_tool("terminal",terminal_panel->view(),label(L"Terminal",L"Terminal"));
        }catch(...){report_exception();}
    }
    void show_preview(std::string content,bool svg){
        try{
            if(!preview_panel){preview_panel=coincide::PreviewPanel::create(data_directory()/L"previews");tool_views.Children().Append(preview_panel->view());}
            preview_panel->load_inline(std::move(content),svg);select_tool("preview",preview_panel->view(),label(L"Preview",L"Preview"));
        }catch(...){report_exception();}
    }

    bool git_target_allowed(const std::filesystem::path& target,bool removing,const std::filesystem::path& repository={})const{
        if(closing||quitting||!writable||repository_mutating())return false;
        try{
            if(removing)for(const auto& project:workspace.projects)if(project.id!=coincide::bots_container_id){const auto folder=std::filesystem::path(winrt::to_hstring(project.path).c_str());if(within_folder(target,folder)||within_folder(folder,target))return false;}
            for(const auto& thread:workspace.threads){
                std::filesystem::path folder=data_directory()/L"workspaces"/winrt::to_hstring(thread.id).c_str();
                if(thread.bot_id){if(!bot_store)return false;const auto bot=bot_store->find(*thread.bot_id);if(!bot)return false;folder=bot_store->working_directory(*bot);}
                else if(thread.project_id){const auto project=std::find_if(workspace.projects.begin(),workspace.projects.end(),[&](const auto& value){return value.id==*thread.project_id;});if(project==workspace.projects.end())return false;folder=std::filesystem::path(winrt::to_hstring(project->path).c_str());}
                const bool active=thread_busy(thread.id)||active_terminal(thread.id)||!thread.queued_inputs.empty();
                // An idle Home-folder bot does not own every nested worktree. Its Home (or an
                // ancestor) stays protected, and active broad-folder work retains the lease.
                if(thread.bot_id&&bot_store->broad_folder(folder)&&!within_folder(target,folder)&&!active)continue;
                if(removing&&(within_folder(target,folder)||within_folder(folder,target)))return false;
                if(active&&coincide::repository_lease::conflicts({repository.empty()?target:repository,target},folder))return false;
            }return true;
        }catch(...){return false;}
    }
    void open_worktree(const std::filesystem::path& target){
        if(closing||quitting||!writable)return;
        const auto folder=std::filesystem::canonical(target);if(!coincide::local_file::local_path(folder)||coincide::local_file::has_reparse(folder)||!std::filesystem::is_directory(folder))throw std::runtime_error("Choose an available local worktree.");
        auto found=std::find_if(workspace.projects.begin(),workspace.projects.end(),[&](const auto& project){std::error_code error;return project.id!=coincide::bots_container_id&&std::filesystem::equivalent(folder,std::filesystem::path(winrt::to_hstring(project.path).c_str()),error)&&!error;});
        std::string project;
        if(found==workspace.projects.end()){const auto before=workspace;project=coincide::new_id();try{workspace.add_project({project,winrt::to_string(folder.filename().empty()?folder.root_name().wstring():folder.filename().wstring()),winrt::to_string(folder.wstring())});store->save_index(workspace);}catch(...){workspace=before;throw;}}
        else project=found->id;
        const auto existing=std::find_if(workspace.threads.begin(),workspace.threads.end(),[&](const auto& thread){return thread.project_id==project&&!thread.deleted_at&&!thread.archived;});
        if(existing!=workspace.threads.end()){thread_view=coincide::ThreadView::inbox;thread_filter.SelectedIndex(0);refresh_sidebar();open_thread(existing->id);}else create_thread(project);
    }
    void show_git(){
        if(selected.empty()||!writable)return;
        try{
            const auto folder=working_directory(workspace.thread(selected));const auto key=winrt::to_string(folder.wstring());
            if(!git_panel||git_project!=key){
                if(repository_mutating())throw std::runtime_error("Wait for the repository operation to finish before changing the Git panel.");
                if(git_panel)git_panel->close();if(git_view){uint32_t at{};if(tool_views.Children().IndexOf(git_view,at))tool_views.Children().RemoveAt(at);git_view=nullptr;}git_project=key;const auto weak=get_weak();
                git_panel=coincide::GitPanel::create(folder,[weak,folder]{
                    const auto self=weak.get();if(!self||self->closing)return false;
                    const auto target=self->git_panel?self->git_panel->repository_root():folder;return self->git_target_allowed(target,false,target);
                },[weak,key](std::string text){
                    const auto self=weak.get();if(!self||self->closing||self->selected.empty()||text.empty())return;
                    auto& thread=self->workspace.thread(self->selected);if(thread.deleted_at)return;
                    thread.draft+="\n\nRepository diff reference from "+key+":\n```diff\n"+text+"\n```";
                    self->selecting=true;self->composer.Text(winrt::to_hstring(thread.draft));self->selecting=false;self->save_current();self->update_composer();self->composer.Focus(xaml::FocusState::Programmatic);
                },[weak](const std::filesystem::path& target,bool removing){const auto self=weak.get();return self&&self->git_target_allowed(target,removing,self->git_panel?self->git_panel->repository_root():target);},[weak](const std::filesystem::path& target){if(const auto self=weak.get();self&&!self->closing)try{self->open_worktree(target);}catch(...){self->report_exception();}});
                git_view=controls::ScrollViewer{};git_view.VerticalScrollBarVisibility(controls::ScrollBarVisibility::Auto);git_view.Content(git_panel->view());tool_views.Children().Append(git_view);
            }
            select_tool("git",git_view,label(L"Git",L"Git"));
        }catch(...){report_exception();}
    }

    winrt::Windows::Foundation::IAsyncOperation<bool> confirm_hosting(coincide::code_hosting_panel::Confirmation value){
        auto lifetime=get_strong();if(closing||dialog_open)co_return false;dialog_open=true;winrt::hstring decision;std::exception_ptr failure;
        try{decision=co_await coincide::native_user_prompt(root.XamlRoot(),winrt::to_hstring(value.title),winrt::to_hstring(value.detail),winrt::to_hstring(value.action),GetTickCount64()+900000,[weak=get_weak()]{const auto self=weak.get();return !self||self->closing;});}catch(...){failure=std::current_exception();}
        dialog_open=false;if(failure)std::rethrow_exception(failure);co_return decision==L"done";
    }
    bool hosting_target_allowed(const std::filesystem::path& repository,const std::filesystem::path& target)const{
        if(closing||quitting||!writable||repository_mutating())return false;
        return git_target_allowed(repository,false,repository)&&git_target_allowed(target,false,repository);
    }
    void show_hosting(){
        if(selected.empty()||!writable||closing)return;try{const auto folder=working_directory(workspace.thread(selected));const auto key=winrt::to_string(folder.wstring());
            if(!hosting_panel||hosting_project!=key){if(repository_mutating())throw std::runtime_error("Wait for the repository operation before changing the pull request workspace.");
                if(hosting_panel)hosting_panel->close();if(hosting_view){std::uint32_t index{};if(tool_views.Children().IndexOf(hosting_view,index))tool_views.Children().RemoveAt(index);}const auto weak=get_weak();
                hosting_panel=coincide::CodeHostingPanel::create(folder,[weak](const auto& repository,const auto& target){const auto self=weak.get();return self&&self->hosting_target_allowed(repository,target);},
                    [weak](const auto& target){if(const auto self=weak.get();self&&!self->closing)self->open_worktree(target);},
                    [weak](auto confirmation)->winrt::Windows::Foundation::IAsyncOperation<bool>{const auto self=weak.get();if(!self||self->closing)co_return false;co_return co_await self->confirm_hosting(std::move(confirmation));});
                hosting_project=key;hosting_view=controls::ScrollViewer{};hosting_view.Content(hosting_panel->view());hosting_view.HorizontalScrollBarVisibility(controls::ScrollBarVisibility::Disabled);tool_views.Children().Append(hosting_view);
            }select_tool("hosting",hosting_view,label(L"PullRequests",L"Pull requests"));
        }catch(...){report_exception();}
    }

    void queue_message(bool steer){
        if(closing||quitting||selected.empty()||!writable)return;
        try{
            auto& thread=workspace.thread(selected);if(thread.deleted_at||(thread.draft.empty()&&thread.draft_attachments.empty()))return;
            auto& run=session_for(selected);
            auto turn=make_turn(thread.draft,thread.draft_attachments,thread.model,thread.effort,thread.service_tier,thread.plan,thread.full_access);
            coincide::QueuedInput input{coincide::new_id(),thread.draft,thread.model,thread.effort,thread.service_tier,thread.plan,thread.full_access,thread.draft_attachments};
            thread.queued_inputs.push_back(input);thread.draft.clear();thread.draft_attachments.clear();
            try{store->save_thread(thread);}catch(...){thread.queued_inputs.pop_back();thread.draft=input.text;thread.draft_attachments=input.attachments;throw;}
            const auto accepted=steer?run.session->steer(std::move(turn),input.id):run.session->queue(std::move(turn),input.id);
            if(!accepted){thread.queued_inputs.pop_back();thread.draft=input.text;thread.draft_attachments=input.attachments;store->save_thread(thread);throw std::runtime_error("This message was not accepted. Keep the draft and try Queue or wait for the current turn.");}
            selecting=true;composer.Text(L"");selecting=false;render_attachments();render_queue();update_composer();
        }catch(...){report_exception();}
    }

    void render_queue(){
        if(!queued_view)return;queued_view.Children().Clear();if(selected.empty())return;
        const auto& thread=workspace.thread(selected);if(thread.queued_inputs.empty())return;
        controls::TextBlock label_text;label_text.Text(label(L"Queue",L"Queue"));queued_view.Children().Append(label_text);
        for(const auto& input:thread.queued_inputs){
            controls::StackPanel row;row.Orientation(controls::Orientation::Horizontal);row.Spacing(6);
            controls::TextBlock text;text.Text(winrt::to_hstring(input.text));text.IsTextSelectionEnabled(true);text.TextWrapping(xaml::TextWrapping::Wrap);text.MaxWidth(460);identify(text,L"QueuedMessageText");row.Children().Append(text);
            auto remove=button(L"Remove",L"Remove",L"RemoveQueuedMessage");const auto thread_id=selected,id=input.id;
            remove.Click([this,thread_id,id](const auto&,const auto&){
                try{const auto at=running.find(thread_id);if(at!=running.end()&&!at->second.session->remove_queued(id)&&thread_busy(thread_id))throw std::runtime_error("This message may already be in delivery. Stop the agent and review the conversation before retrying.");
                    auto& thread=workspace.thread(thread_id);std::erase_if(thread.queued_inputs,[&](const auto& value){return value.id==id;});store->save_thread(thread);if(selected==thread_id){render_queue();update_composer();}
                }catch(...){report_exception();}
            });row.Children().Append(remove);queued_view.Children().Append(row);
        }
        const auto active=running.find(selected);const bool paused=active==running.end()||active->second.session->queue_paused();
        if(paused){auto resume=button(L"Resume",L"Resume",L"ResumeQueue");const auto id=selected;resume.Click([this,id](const auto&,const auto&){try{auto& run=session_for(id);if(!run.session->resume_queue())throw std::runtime_error("No queued messages are ready to resume.");if(selected==id){render_queue();update_composer();}}catch(...){report_exception();}});queued_view.Children().Append(resume);}
    }

    void fill_model_controls(){
        if(!model_picker||selected.empty())return;
        const auto& thread=workspace.thread(selected);model_ids.clear();model_picker.Items().Clear();
        model_ids.push_back("");add_choice(model_picker,coincide::ui_text(L"Default"));int selected_index=0;
        const auto& options=preferences.providers.at(thread.provider);auto models=dialog_models;
        auto favorite=[&](const std::string& id){const auto at=std::find(options.favorites.begin(),options.favorites.end(),id);return at==options.favorites.end()?options.favorites.size():static_cast<std::size_t>(at-options.favorites.begin());};
        std::stable_sort(models.begin(),models.end(),[&](const auto& first,const auto& second){return favorite(first.model)<favorite(second.model);});
        for(const auto& model:models){
            if(model.model!=thread.model&&std::find(options.hidden.begin(),options.hidden.end(),model.model)!=options.hidden.end())continue;
            model_ids.push_back(model.model);add_choice(model_picker,winrt::to_hstring((favorite(model.model)<options.favorites.size()?"★ ":"")+model.display_name));if(model.model==thread.model)selected_index=static_cast<int>(model_ids.size()-1);
        }
        for(const auto& custom:options.custom_models)if(std::find(model_ids.begin(),model_ids.end(),custom)==model_ids.end()&&(custom==thread.model||std::find(options.hidden.begin(),options.hidden.end(),custom)==options.hidden.end())){model_ids.push_back(custom);add_choice(model_picker,winrt::to_hstring(custom));if(custom==thread.model)selected_index=static_cast<int>(model_ids.size()-1);}
        if(!thread.model.empty()&&std::find(model_ids.begin(),model_ids.end(),thread.model)==model_ids.end()){model_ids.push_back(thread.model);add_choice(model_picker,winrt::to_hstring(thread.model));selected_index=static_cast<int>(model_ids.size()-1);}
        model_picker.SelectedIndex(selected_index);fill_model_options();
    }

    void fill_model_options(){
        if(!model_picker||!effort_picker||!tier_picker||selected.empty())return;
        const auto& thread=workspace.thread(selected);const auto index=model_picker.SelectedIndex();if(index<0||static_cast<std::size_t>(index)>=model_ids.size())return;
        const auto id=model_ids[index];const auto model=std::find_if(dialog_models.begin(),dialog_models.end(),[&](const auto& m){return id.empty()?m.is_default:m.model==id;});
        effort_ids={""};tier_ids={""};effort_picker.Items().Clear();tier_picker.Items().Clear();
        add_choice(effort_picker,coincide::ui_text(L"Default"));add_choice(tier_picker,coincide::ui_text(L"Standard"));
        if(model!=dialog_models.end()){
            for(const auto& effort:model->efforts){effort_ids.push_back(effort);add_choice(effort_picker,winrt::to_hstring(effort));}
            for(const auto& tier:model->service_tiers){tier_ids.push_back(tier.id);add_choice(tier_picker,winrt::to_hstring(tier.name.empty()?tier.id:tier.name));}
        }
        if(!thread.effort.empty()&&std::find(effort_ids.begin(),effort_ids.end(),thread.effort)==effort_ids.end()){effort_ids.push_back(thread.effort);add_choice(effort_picker,winrt::to_hstring(thread.effort));}
        if(!thread.service_tier.empty()&&std::find(tier_ids.begin(),tier_ids.end(),thread.service_tier)==tier_ids.end()){tier_ids.push_back(thread.service_tier);add_choice(tier_picker,winrt::to_hstring(thread.service_tier));}
        const auto effort=std::find(effort_ids.begin(),effort_ids.end(),thread.effort);effort_picker.SelectedIndex(effort==effort_ids.end()?0:static_cast<int32_t>(std::distance(effort_ids.begin(),effort)));
        const auto tier=std::find(tier_ids.begin(),tier_ids.end(),thread.service_tier);tier_picker.SelectedIndex(tier==tier_ids.end()?0:static_cast<int32_t>(std::distance(tier_ids.begin(),tier)));
    }

    winrt::fire_and_forget choose_model(){
        auto lifetime=get_strong();if(dialog_open||selected.empty()||!writable||thread_busy(selected))co_return;
        const auto id=selected;dialog_open=true;
        try{
            auto& run=session_for(id);dialog_models=run.models;
            controls::StackPanel fields;fields.Spacing(8);
            model_picker=controls::ComboBox{};model_picker.Header(winrt::box_value(label(L"Model",L"Model")));identify(model_picker,L"ModelPicker");
            effort_picker=controls::ComboBox{};effort_picker.Header(winrt::box_value(label(L"Reasoning",L"Reasoning")));identify(effort_picker,L"EffortPicker");
            tier_picker=controls::ComboBox{};tier_picker.Header(winrt::box_value(label(L"Speed",L"Speed")));identify(tier_picker,L"SpeedPicker");
            auto model_revoker=model_picker.SelectionChanged(winrt::auto_revoke,[this](const auto&,const auto&){fill_model_options();});
            fields.Children().Append(model_picker);fields.Children().Append(effort_picker);fields.Children().Append(tier_picker);
            custom_model=controls::TextBox{};custom_model.PlaceholderText(coincide::ui_text(L"Model ID"));custom_model.MaxLength(256);identify(custom_model,L"CustomModel");fields.Children().Append(custom_model);
            auto refresh=button(L"Refresh",L"Refresh",L"RefreshModels");refresh.Click([this,id](const auto&,const auto&){try{session_for(id).session->refresh_models();}catch(...){report_exception();}});fields.Children().Append(refresh);
            controls::CheckBox plan;plan.Content(winrt::box_value(label(L"Plan",L"Plan")));plan.IsChecked(workspace.thread(id).plan);identify(plan,L"PlanMode");fields.Children().Append(plan);
            controls::CheckBox full;full.Content(winrt::box_value(coincide::ui_text(L"Full access")));full.IsChecked(workspace.thread(id).full_access);identify(full,L"FullAccess");fields.Children().Append(full);
            controls::TextBlock permissions;permissions.Text(coincide::ui_text(L"Full access allows commands and file changes without asking. Leave it off to require approval."));permissions.TextWrapping(xaml::TextWrapping::Wrap);fields.Children().Append(permissions);
            fill_model_controls();run.session->refresh_models();
            controls::ContentDialog dialog;dialog.XamlRoot(root.XamlRoot());dialog.Title(winrt::box_value(label(L"ModelSettings",L"Model Settings")));dialog.Content(fields);dialog.PrimaryButtonText(label(L"Save",L"Save"));dialog.CloseButtonText(label(L"Cancel",L"Cancel"));
            if(co_await dialog.ShowAsync()==controls::ContentDialogResult::Primary){
                auto& thread=workspace.thread(id);const auto before=thread;
                try{thread.model=custom_model.Text().empty()?model_ids.at(static_cast<std::size_t>(model_picker.SelectedIndex())):winrt::to_string(custom_model.Text());
                    if(thread.model.size()>256||thread.model.find_first_of(" \t\r\n")!=std::string::npos)throw std::runtime_error("Model IDs must be 256 characters or fewer and cannot contain spaces.");
                    thread.effort=effort_ids.at(static_cast<std::size_t>(effort_picker.SelectedIndex()));thread.service_tier=tier_ids.at(static_cast<std::size_t>(tier_picker.SelectedIndex()));thread.plan=plan.IsChecked().Value();thread.full_access=full.IsChecked().Value();store->save_index(workspace);
                }catch(...){thread=before;throw;}
            }
        }catch(...){report_exception();}
        model_picker=nullptr;effort_picker=nullptr;tier_picker=nullptr;custom_model=nullptr;dialog_open=false;update_composer();
    }

    void flush_dirty() {
        if(!writable||!store)return;
        persistence_error.clear();auto ids=std::move(dirty_threads);dirty_threads.clear();
        auto failed=[&]{report_exception();persistence_error=state?winrt::to_string(state.Text()):"Changes could not be saved.";};
        for(const auto& id:ids){try{store->save_thread(workspace.thread(id));}catch(...){dirty_threads.insert(id);failed();}}
        if(dirty_index){try{store->save_index(workspace);dirty_index=false;}catch(...){failed();}}
        if(persistence_error.empty())for(auto& [id,run]:running)if(!dirty_threads.contains(id)&&!dirty_index){
            if(run.completion_received){run.awaiting_completion=false;if(run.notify_completion){notify_thread(id,false);run.notify_completion=false;}}
            if(schedule_panel&&run.schedule_result_pending&&!run.schedule_delivery.empty()){
                schedule_panel->completed_delivery(run.schedule_id,run.schedule_delivery,run.schedule_success,run.schedule_uncertain,run.schedule_status);run.schedule_id.clear();run.schedule_delivery.clear();run.schedule_result_pending=false;
            }
        }
        if(!closing&&(!dirty_threads.empty()||dirty_index)){save_timer.Stop();save_timer.Start();}
        if(!closing)update_composer();
    }

    void update_composer() {
        if (closing || selected.empty() || !writable) return;
        if(quitting){send_button.IsEnabled(false);queue_button.IsEnabled(false);steer_button.IsEnabled(false);models_button.IsEnabled(false);return;}
        const auto& thread = workspace.thread(selected);
        if (thread.deleted_at) {
            providers.IsEnabled(false); composer.IsEnabled(false); send_button.IsEnabled(false); stop_button.IsEnabled(false);
            queue_button.IsEnabled(false);steer_button.IsEnabled(false);models_button.IsEnabled(false);
            state.Text(label(L"DeletedThreads",L"Deleted Threads")); return;
        }
        composer.IsEnabled(true);
        const auto run = running.find(selected);
        const auto busy = run != running.end() && (run->second.awaiting_completion || run->second.session->busy());
        const auto connected=provider_connected(thread);
        const auto has_input=!thread.draft.empty()||!thread.draft_attachments.empty();
        providers.IsEnabled(!busy); stop_button.IsEnabled(busy);
        models_button.IsEnabled(connected&&!busy);queue_button.IsEnabled(connected&&has_input);steer_button.IsEnabled(thread.provider=="codex"&&busy&&has_input);
        send_button.IsEnabled(connected&&!busy&&has_input&&thread.queued_inputs.empty());
        if (run != running.end() && !run->second.status.empty()) state.Text(winrt::to_hstring(run->second.status));
        else if (connected) state.Text(thread.provider=="codex"?L"Codex · Ctrl+Enter sends.":thread.provider=="claude"?L"Claude Code · Ctrl+Enter sends.":thread.provider=="cursor"?L"Cursor · Ctrl+Enter sends.":L"OpenCode · Ctrl+Enter sends.");
        else state.Text(thread.provider=="cursor"?L"Open Accounts to verify and choose a Cursor profile.":L"This provider adapter is not available yet.");
        if(!persistence_error.empty())state.Text(winrt::to_hstring(persistence_error));else if(!platform_error.empty())state.Text(winrt::to_hstring(platform_error));
    }

    void send_message() {
        if (closing||quitting||selected.empty() || !writable) return;
        try {
            auto& thread = workspace.thread(selected);
            if (!provider_connected(thread)||thread.deleted_at||(thread.draft.empty()&&thread.draft_attachments.empty()))return;
            if(!thread.queued_inputs.empty())throw std::runtime_error("Resume or remove the saved queue before sending another message.");
            auto at = running.find(selected);
            if (at != running.end() && (at->second.awaiting_completion || at->second.session->busy())) return;
            (void)session_for(selected);at=running.find(selected);
            auto input=make_turn(thread.draft,thread.draft_attachments,thread.model,thread.effort,thread.service_tier,thread.plan,thread.full_access);
            const auto original_draft=thread.draft;const auto original_attachments=thread.draft_attachments;
            const auto id = coincide::new_id();
            workspace.note_activity(selected);store->save_index(workspace);
            thread.messages.push_back({id, "user", original_draft,thread.provider,original_attachments}); thread.draft.clear();thread.draft_attachments.clear();
            try {store->save_thread(thread);}
            catch (...) {thread.draft = original_draft;thread.draft_attachments=original_attachments;thread.messages.pop_back(); throw;}
            prepare_usage(thread,at->second,id);
            if (!at->second.session->send(input)) {
                at->second.usage.reset();
                thread.draft = original_draft;thread.draft_attachments=original_attachments;thread.messages.pop_back(); store->save_thread(thread); return;
            }
            at->second.awaiting_completion = true;at->second.completion_received=false;
            at->second.failed = false; at->second.status = winrt::to_string(label(L"Connecting", L"Connecting…"));
            transcript.Items().Append(message_row(thread.messages.back(),winrt::to_string(label(L"You", L"You"))));
            selecting = true; composer.Text(L""); selecting = false;
            render_attachments();update_composer(); show_latest(true); composer.Focus(xaml::FocusState::Programmatic);
        } catch (...) {report_exception();}
    }

    void upsert_output(coincide::Thread& thread, const coincide::SessionEvent& event,const std::string& provider) {
        const auto role = event.kind == coincide::SessionEvent::Kind::tool ? "tool" : "assistant";
        const auto id = provider+"/" + event.id;
        auto at = std::find_if(thread.messages.begin(), thread.messages.end(), [&](const auto& m) {return m.id == id;});
        if (at == thread.messages.end()) {
            thread.messages.push_back({id, role, event.text,provider}); at = std::prev(thread.messages.end());
        } else if (event.kind == coincide::SessionEvent::Kind::text_delta) at->text += event.text;
        else if (!event.text.empty()) at->text = event.text;
        dirty_threads.insert(thread.id);
        if (selected == thread.id && !closing) {
            const auto row = static_cast<uint32_t>(std::distance(thread.messages.begin(), at));
            const auto value = message_row(*at,provider);
            if (row < transcript.Items().Size()) transcript.Items().SetAt(row, value);
            else transcript.Items().Append(value);
            show_latest();
        }
    }

    void drain_sessions() {
        bool changed_prompts{},new_completion{};
        for (auto& [id, run] : running) {
            try {
                auto& thread = workspace.thread(id);
                bool received_output{};
                for (const auto& event : run.session->take_events()) {
                    try{
                    using Kind = coincide::SessionEvent::Kind;
                    switch (event.kind) {
                    case Kind::account_scope:
                        {
                            coincide::NativeSession binding{run.provider,"pending",0,event.id,event.text};
                            if(!coincide::valid_session_binding(binding)||binding.account_scope.empty())throw std::runtime_error("The provider returned invalid verified account routing metadata.");
                            run.profile_id=binding.profile_id;run.account_scope=binding.account_scope;
                            if(run.usage)try{if(run.usage->owner().profile_id!=run.profile_id||!run.usage->bind_account_scope(run.account_scope))run.usage.reset();}catch(...){run.usage.reset();}
                            const auto session=std::find_if(thread.sessions.begin(),thread.sessions.end(),[&](const auto& value){return value.provider==run.provider;});
                            if(session!=thread.sessions.end()){
                                if(!session->account_scope.empty()&&(session->account_scope!=run.account_scope||session->profile_id!=run.profile_id))throw std::runtime_error("The verified provider account differs from this saved conversation.");
                                session->profile_id=run.profile_id;session->account_scope=run.account_scope;dirty_threads.insert(id);
                            }
                            break;
                        }
                    case Kind::session:
                        {
                            const auto previous = std::find_if(thread.sessions.begin(), thread.sessions.end(), [&](const auto& s) {return s.provider == run.provider && s.id == event.id;});
                            const auto acknowledged = previous == thread.sessions.end() ? 0 : previous->acknowledged_messages;
                            workspace.remember_session(id, {run.provider,event.id,acknowledged,run.account_scope.empty()&&previous!=thread.sessions.end()?previous->profile_id:run.profile_id,run.account_scope.empty()&&previous!=thread.sessions.end()?previous->account_scope:run.account_scope});dirty_threads.insert(id);if(run.usage)try{if(!run.usage->bind_session(event.id))run.usage.reset();}catch(...){run.usage.reset();}break;
                        }
                    case Kind::started:
                        run.completion_received=false;run.status = run.provider+" is working…";if(run.usage)try{if(!run.usage->bind_native_turn(event.id))run.usage.reset();}catch(...){run.usage.reset();}break;
                    case Kind::usage:
                        if(run.usage&&event.id==run.usage->owner().turn_id)try{(void)run.usage->observe(coincide::UsageProtocol::decode_text(event.text));}catch(...){}break;
                    case Kind::status: run.status = event.text; break;
                    case Kind::text_delta: case Kind::text_complete: case Kind::tool:
                        upsert_output(thread,event,run.provider); received_output = true; break;
                    case Kind::models: {
                        const auto catalog=coincide::rpc_json::JsonObject::Parse(winrt::to_hstring(event.text));run.models=coincide::CodexProtocol::catalog_entries(catalog.GetNamedArray(L"data"));
                        if(selected==id&&model_picker){dialog_models=run.models;fill_model_controls();}break;
                    }
                    case Kind::catalog_error:run.status=event.text;break;
                    case Kind::queued:case Kind::queue_changed:if(selected==id)render_queue();break;
                    case Kind::delivery_failed:run.status=event.text;if(selected==id)render_queue();break;
                    case Kind::input: {
                        const auto pending=std::find_if(thread.queued_inputs.begin(),thread.queued_inputs.end(),[&](const auto& input){return input.id==event.id;});
                        if(pending==thread.queued_inputs.end())break;
                        const auto duplicate=std::any_of(thread.messages.begin(),thread.messages.end(),[&](const auto& message){return message.id==event.id;});
                        if(!duplicate){thread.messages.push_back({event.id,"user",pending->text,run.provider,pending->attachments});if(selected==id)transcript.Items().Append(message_row(thread.messages.back(),winrt::to_string(label(L"You",L"You"))));}
                        thread.queued_inputs.erase(pending);workspace.note_activity(id);dirty_threads.insert(id);dirty_index=true;run.awaiting_completion=true;run.completion_received=false;run.failed=false;
                        if(event.detail!="steered")prepare_usage(thread,run,event.id);
                        if(selected==id){render_queue();show_latest();}break;
                    }
                    case Kind::prompt:
                        workspace.note_activity(id,coincide::Workspace::now_seconds(),true);dirty_index=true;
                        run.prompts.insert_or_assign(event.id, event); changed_prompts = changed_prompts || selected == id;notify_thread(id,true);
                        run.status = run.provider=="codex"?"Codex is waiting for your response.":"Claude Code is waiting for your response."; break;
                    case Kind::resolved:
                        run.prompts.erase(event.id); changed_prompts = changed_prompts || selected == id; break;
                    case Kind::error:
                        run.failed = true; run.status = event.text; break;
                    case Kind::completed:
                        finish_usage(run,event.text=="interrupted"?"interrupted":run.failed||event.text!="completed"?"failed":"completed");
                        run.prompts.clear(); changed_prompts = changed_prompts || selected == id;
                        if (!run.failed) run.status = event.text == "interrupted" ? "Stopped" : winrt::to_string(label(L"Ready", L"Ready"));
                        if (event.text == "completed") {
                            const auto session = std::find_if(thread.sessions.begin(), thread.sessions.end(), [&](const auto& s) {return s.provider == run.provider;});
                            if (session != thread.sessions.end()) session->acknowledged_messages = thread.messages.size();
                        }
                        dirty_threads.insert(id);run.completion_received=true;new_completion=true;
                        if(!run.schedule_delivery.empty()&&!run.schedule_result_pending){run.schedule_success=event.text=="completed"&&!run.failed;run.schedule_uncertain=event.text!="completed"&&event.text!="interrupted";run.schedule_status=run.status;run.schedule_result_pending=true;}
                        run.notify_completion=true;break;
                    }
                    }catch(...){run.failed=true;dirty_threads.insert(id);report_exception();}
                }
                if ((received_output||dirty_threads.contains(id)||dirty_index) && !closing&&!save_timer.IsRunning()) save_timer.Start();
            } catch (...) {report_exception();}
        }
        if(new_completion)flush_dirty();
        if (!closing) {if (changed_prompts){render_prompts();refresh_sidebar();} update_composer();}
    }

    void answer_prompt(const std::string& thread, const std::string& id, const std::string& result) {
        const auto at = running.find(thread);
        if (at == running.end()) return;
        at->second.session->respond(id, result);
        at->second.prompts.erase(id); render_prompts();
    }

    void render_prompts() {
        if (closing || !prompts_view) return;
        prompts_view.Children().Clear();
        const auto at = running.find(selected);
        if (at == running.end()) return;
        for (const auto& [id, event] : at->second.prompts) {
            controls::StackPanel card; card.Spacing(6); identify(card, L"AgentPrompt");
            controls::TextBlock detail;
            detail.TextWrapping(xaml::TextWrapping::Wrap); detail.IsTextSelectionEnabled(true);
            const auto params = coincide::rpc_json::JsonObject::Parse(winrt::to_hstring(event.text));
            const auto thread = selected;
            if (event.detail == "item/tool/requestUserInput") {
                auto form=coincide::question_form(params,[this,thread,id](std::string result){answer_prompt(thread,id,result);},[this](hstring message){show_error(message);});
                card.Children().Append(form);
            } else {
                const auto file_change = event.detail == "item/fileChange/requestApproval";
                bool has_file_details{};
                const auto agent=at->second.provider=="codex"?L"Codex":at->second.provider=="claude"?L"Claude Code":L"Agent";
                std::wstring description=std::wstring(agent)+(file_change?L" wants to change files:\n":L" wants to run:\n");
                if (!file_change) description += params.GetNamedString(L"command", L"");
                else {
                    const auto preview = params.GetNamedObject(L"fileChangePreview", coincide::rpc_json::JsonObject{});
                    const auto changes = preview.GetNamedArray(L"changes", coincide::rpc_json::JsonArray{});
                    has_file_details = changes.Size() > 0;
                    for (const auto& raw : changes) {
                        const auto change = raw.GetObject();
                        description += std::wstring(change.GetNamedString(L"path", L"")) + L"\n" + std::wstring(change.GetNamedString(L"diff", L"")) + L"\n";
                    }
                }
                const auto reason = params.GetNamedString(L"reason", L"");
                if (!reason.empty()) description += L"\n" + std::wstring(reason);
                const auto cwd = params.GetNamedString(L"cwd", L"");
                if (!cwd.empty()) description += L"\n" + std::wstring(cwd);
                const auto extra = params.GetNamedValue(L"additionalPermissions", coincide::rpc_json::JsonValue::CreateNullValue());
                if (extra.ValueType() == coincide::rpc_json::JsonValueType::Object) description += L"\nAdditional permissions: " + std::wstring(extra.Stringify());
                identify(detail, L"ApprovalDetails");
                detail.Text(winrt::hstring(description));controls::ScrollViewer details;details.MaxHeight(120);details.VerticalScrollBarVisibility(controls::ScrollBarVisibility::Auto);details.Content(detail);card.Children().Append(details);
                controls::StackPanel decisions_row;decisions_row.Orientation(controls::Orientation::Horizontal);decisions_row.Spacing(8);
                bool allow = file_change && has_file_details;
                const auto decisions = params.GetNamedValue(L"availableDecisions", coincide::rpc_json::JsonValue::CreateNullValue());
                if (!file_change && decisions.ValueType() == coincide::rpc_json::JsonValueType::Array) {
                    for (const auto& value : decisions.GetArray()) {
                        if (value.ValueType() == coincide::rpc_json::JsonValueType::String && value.GetString() == L"accept") allow = true;
                    }
            } else if (!file_change) allow = true;
                if (allow) {
                    auto accept = button(L"Allow", L"Allow", L"AllowApproval");
                    accept.Click([this, thread, id](const auto&, const auto&) {answer_prompt(thread, id, "{\"decision\":\"accept\"}");});
                    decisions_row.Children().Append(accept);
                }
                auto decline = button(L"Deny", L"Deny", L"DenyApproval");
                decline.Click([this, thread, id](const auto&, const auto&) {answer_prompt(thread, id, "{\"decision\":\"decline\"}");});
                decisions_row.Children().Append(decline);card.Children().Append(decisions_row);
            }
            prompts_view.Children().Append(card);
        }
        show_latest();
    }

    void history(bool redo) {
        if(!writable)return;const auto before=workspace;
        try{
            if(redo?workspace.redo_archive():workspace.undo_archive()){
                std::vector<std::string> changed;
                for(const auto& old:before.threads)if(workspace.thread(old.id).project_id!=old.project_id){
                    if(thread_busy(old.id)||active_terminal(old.id)||repository_mutating())throw std::runtime_error("Stop the agents, close terminals and finish repository operations before undoing a project change.");
                    changed.push_back(old.id);
                }
                store->save_index(workspace);invalidate_project_context(changed);reconcile_selection();
            }
        }catch(...){workspace=before;report_exception();}
    }

    void report_exception() {
        try { throw; }
        catch (const winrt::hresult_error& error) { show_error(error.message()); }
        catch (const std::exception& error) { show_error(winrt::to_hstring(error.what())); }
    }

    void show_error(const hstring& message) {
        diagnostic(message);
        if (state) state.Text(message);
        else MessageBoxW(nullptr, message.c_str(), L"Coincide", MB_OK | MB_ICONERROR);
    }

    winrt::fire_and_forget show_status(){
        auto lifetime=get_strong();if(dialog_open)co_return;dialog_open=true;
        std::shared_ptr<coincide::ComputerUsePanel> computer_settings;
        try{
            auto preference_projects=workspace.projects;std::erase_if(preference_projects,[](const auto& project){return project.id==coincide::bots_container_id;});auto panel=coincide::PreferencesPanel::create(preferences,std::move(preference_projects));controls::ContentDialog dialog;dialog.XamlRoot(root.XamlRoot());dialog.Title(winrt::box_value(label(L"Settings",L"Settings")));
            controls::Grid frame;controls::RowDefinition heading;heading.Height({1,xaml::GridUnitType::Auto});frame.RowDefinitions().Append(heading);frame.RowDefinitions().Append(controls::RowDefinition{});
            controls::TextBlock validation;identify(validation,L"PreferencesValidationError");validation.TextWrapping(xaml::TextWrapping::Wrap);validation.IsTextSelectionEnabled(true);if(!preferences_writable)validation.Text(winrt::to_hstring(preferences_error));frame.Children().Append(validation);controls::Grid::SetRow(panel->view(),1);frame.Children().Append(panel->view());dialog.Content(frame);
            if(!fixture_preview){ensure_computer_use();computer_settings=coincide::ComputerUsePanel::create(data_directory()/L"ComputerUse",computer_use,[weak=get_weak()](coincide::ComputerUsePanel::Change change,const std::string& id){if(const auto self=weak.get();self&&!self->closing){if(change==coincide::ComputerUsePanel::Change::master){if(self->tool_bridge)for(const auto& thread:self->workspace.threads)self->tool_bridge->disable(thread.id,coincide::app_tools::Channel::computer_use);}else if(!id.empty())self->ensure_thread_tools(id);}});if(!selected.empty())computer_settings->select_thread(selected,workspace.thread(selected).title);controls::TabViewItem tab;tab.Header(winrt::box_value(coincide::ui_text(L"Computer Use")));tab.IsClosable(false);tab.Content(computer_settings->view());panel->view().TabItems().Append(tab);}
            dialog.PrimaryButtonText(label(L"Save",L"Save"));dialog.CloseButtonText(label(L"Cancel",L"Cancel"));dialog.IsPrimaryButtonEnabled(preferences_writable);
            auto save=dialog.PrimaryButtonClick(winrt::auto_revoke,[this,panel,validation](const auto&,const controls::ContentDialogButtonClickEventArgs& args){try{validation.Text(L"");apply_preferences(panel->values());}catch(const winrt::hresult_error& error){args.Cancel(true);validation.Text(error.message());}catch(const std::exception& error){args.Cancel(true);validation.Text(winrt::to_hstring(error.what()));}});
            co_await dialog.ShowAsync();
        }catch(...){if(!closing)report_exception();}
        if(computer_settings)computer_settings->close();dialog_open=false;
    }

};
} // namespace

int __stdcall wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    try {
        winrt::init_apartment(winrt::apartment_type::single_threaded);
        int argc{};
        auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        if(argv&&argc>=2&&std::wstring_view(argv[1])==L"--computer-use-helper"){
            if(argc!=3){LocalFree(argv);return 2;}const std::wstring value(argv[2]);
            if(value.empty()||value.size()>10||value.find_first_not_of(L"0123456789")!=std::wstring::npos){LocalFree(argv);return 2;}
            const auto owner=std::stoull(value);LocalFree(argv);if(!owner||owner>MAXDWORD)return 2;
            return coincide::computer_use::computer_use_helper_main(static_cast<DWORD>(owner));
        }
        if(argv){if(const auto result=coincide::tests::run_contract_test(argc,argv)){LocalFree(argv);return *result;}}
        if(argv&&argc==3){if(const auto suite=coincide::tests::ui_test_suite(argv[1])){
            const auto report=std::filesystem::path(argv[2]);const auto name=*suite;LocalFree(argv);int result=1;winrt::com_ptr<App> application;
            xaml::Application::Start([&](auto&&){application=winrt::make_self<App>(true);application->question_test_report=report;application->question_test_result=&result;application->native_ui_suite=name;});return result;
        }}
        const auto desktop_test=argv&&argc==2&&std::wstring_view(argv[1])==L"--desktop-fixture-preview";
        const auto fixture = desktop_test||(argv && argc == 2 && std::wstring_view(argv[1]) == L"--codex-fixture-preview");
        if (fixture && GetEnvironmentVariableW(L"COINCIDE_DATA_DIR", nullptr, 0) <= 1) {
            throw std::runtime_error("Protocol fixture previews require an explicit isolated test data directory.");
        }
        if(argv&&argc>1&&!fixture){const std::wstring_view flag(argv[1]);if(flag.find(L"-tests")!=std::wstring_view::npos||flag.find(L"-fixture")!=std::wstring_view::npos){LocalFree(argv);return 2;}}
        if (argv) LocalFree(argv);
        // Keep the programmatic application (including its metadata provider and callbacks) alive
        // for the complete dispatcher loop, independently of generated XAML application glue.
        winrt::com_ptr<App> application;
        xaml::Application::Start([&application, fixture,desktop_test](auto&&) { application = winrt::make_self<App>(fixture,desktop_test); });
        return 0;
    } catch (const winrt::hresult_error& error) {
        diagnostic(error.message());
        MessageBoxW(nullptr, error.message().c_str(), L"Coincide could not start", MB_OK | MB_ICONERROR);
        return 1;
    } catch (const std::exception& error) {
        diagnostic(winrt::to_hstring(error.what()));
        MessageBoxW(nullptr, winrt::to_hstring(error.what()).c_str(), L"Coincide could not start", MB_OK | MB_ICONERROR);
        return 1;
    }
}
