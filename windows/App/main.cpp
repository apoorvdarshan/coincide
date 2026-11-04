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
#include "../Tests/StoreTests.h"
#include "../Tests/ProtocolTests.h"
#include "../Tests/ConnectionTests.h"
#include "../Runtime/CodexSession.h"
#include "../Runtime/AgentFactory.h"
#include "../Core/Handoff.h"
#include "../Tests/SessionTests.h"
#include "DisplayItem.h"
#include "../Tests/DisplayTests.h"
#include "../Tests/GitTests.h"
#include "../Tests/ProviderTests.h"
#include "../Tests/ClaudeTests.h"
#include "../Tests/TerminalTests.h"
#include "GitPanel.h"
#include "QuestionForm.h"
#include "../Tests/QuestionFormTests.h"
#include "../Tests/WindowsCalendarTests.h"
#include "../Tests/ScheduleStoreTests.h"
#include "../Tests/OpenCodeTests.h"
#include "../Tests/BrowserTests.h"
#include "../Tests/PreviewTests.h"
#include "../Tests/CredentialTests.h"
#include "../Tests/ACPTests.h"
#include "BrowserPanel.h"
#include "TerminalPanel.h"
#include "PreviewPanel.h"
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
    std::shared_ptr<coincide::BrowserPanel> browser_panel;
    std::shared_ptr<coincide::TerminalPanel> terminal_panel;
    std::shared_ptr<coincide::PreviewPanel> preview_panel;
    std::string visible_tool;

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
    bool fixture_preview{};
    std::filesystem::path question_test_report;
    int* question_test_result{};
    coincide::ThreadView thread_view{coincide::ThreadView::inbox};
    bool dialog_open{};
    struct RunningThread {
        std::unique_ptr<coincide::AgentSession> session;
        std::unordered_map<std::string, coincide::SessionEvent> prompts;
        std::string status;
        std::string provider;
        std::filesystem::path cwd;
        std::vector<coincide::CodexModel> models;
        bool failed{};
        // The worker can finish before its final output reaches the UI and the store.
        bool awaiting_completion{};
        bool completion_received{};
    };
    std::unordered_map<std::string, RunningThread> running;
    std::unordered_set<std::string> dirty_threads;

    explicit App(bool fixture = false) : fixture_preview(fixture) {
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
                const auto result=coincide::question_form_tests(question_test_report,root.XamlRoot());if(question_test_result)*question_test_result=result;
                window.Close();xaml::Application::Current().Exit();
            });});
            window.Activate();window.AppWindow().Hide();return;
        }
        window = xaml::Window{};
        window.Title(fixture_preview ? L"Coincide — Protocol Fixture Test" : L"Coincide — Windows Preview");
        window.AppWindow().Resize({1100, 780});
        root = controls::Grid{};
        auto left = controls::ColumnDefinition{}; left.Width({260, xaml::GridUnitType::Pixel});
        root.ColumnDefinitions().Append(left);
        root.ColumnDefinitions().Append(controls::ColumnDefinition{});
        tools_column=controls::ColumnDefinition{};tools_column.Width({0,xaml::GridUnitType::Pixel});root.ColumnDefinitions().Append(tools_column);
        window.Content(root);
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
        auto browser=toolbar_button(L"Browser",L"Browser",L"OpenBrowser");browser.Click([this](const auto&,const auto&){show_browser();});toolbar.PrimaryCommands().Append(browser);
        auto terminal=toolbar_button(L"Terminal",L"Terminal",L"OpenTerminal");terminal.Click([this](const auto&,const auto&){show_terminal();});toolbar.PrimaryCommands().Append(terminal);
        content.Children().Append(toolbar);

        transcript = controls::ListView{};
        identify(transcript, L"Transcript");
        transcript.Loaded([this](const auto&, const auto&) { show_latest(); });
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
                    auto at=running.find(selected);if(at!=running.end()){at->second.session->shutdown();running.erase(at);}
                    workspace.select_provider(selected,std::string(coincide::provider_ids[index]));
                    store->save_index(workspace);
                    update_composer();
                } catch (...) { report_exception(); }
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
            if (selecting || selected.empty() || !writable) return;
            workspace.thread(selected).draft = winrt::to_string(composer.Text());
            dirty_threads.insert(selected); save_timer.Stop(); save_timer.Start(); update_composer();
        });
        composer.KeyDown([this](const auto&, const xaml::Input::KeyRoutedEventArgs& args) {
            if (args.Key() == winrt::Windows::System::VirtualKey::Enter && (GetKeyState(VK_CONTROL) & 0x8000)) {
                args.Handled(true); send_message();
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
        prompts_scroll.Content(prompts_view); compose.Children().Append(prompts_scroll);
        state = controls::TextBlock{};
        identify(state, L"AgentStatus");
        state.TextWrapping(xaml::TextWrapping::Wrap);
        state.Text(L"Select a conversation to begin.");
        compose.Children().Append(state);
        controls::ScrollViewer compose_scroll; compose_scroll.MaxHeight(420);
        compose_scroll.VerticalScrollBarVisibility(controls::ScrollBarVisibility::Auto);compose_scroll.Content(compose);
        controls::Grid::SetRow(compose_scroll, 2);
        content.Children().Append(compose_scroll);
        root.SizeChanged([compose_scroll](const auto&,const xaml::SizeChangedEventArgs& args){compose_scroll.MaxHeight(std::max(180.0,std::min(440.0,static_cast<double>(args.NewSize().Height)*0.55)));});

        save_timer = window.DispatcherQueue().CreateTimer();
        save_timer.Interval(std::chrono::milliseconds(400)); save_timer.IsRepeating(false);
        save_timer.Tick([this](const auto&, const auto&) { flush_dirty(); });
        session_timer = window.DispatcherQueue().CreateTimer();
        session_timer.Interval(std::chrono::milliseconds(40));
        session_timer.Tick([this](const auto&, const auto&) { drain_sessions(); });
        session_timer.Start();
        window.Closed([this](const auto&, const auto&) {
            closing = true; save_timer.Stop(); session_timer.Stop();
            for (auto& [id, run] : running) {(void)id; run.session->close();}
            for (auto& [id, run] : running) {(void)id; run.session->shutdown();}
            drain_sessions(); flush_dirty(); save_current();
            if(git_panel)git_panel->close();if(browser_panel)browser_panel->close();if(terminal_panel)terminal_panel->close();if(preview_panel)preview_panel->close();
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
        window.Activate();
        diagnostic(L"Window activated");
        refresh_sidebar();
        if (!visible.empty()) open_thread(visible.front());
    }

    void refresh_sidebar() {
        if (!sidebar || !search) return;
        const auto previous_selection = selected_thread_ids();
        selecting = true;
        visible = workspace.listed_threads(thread_view, winrt::to_string(search.Text()));
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
                if (selected == id) show_latest();
            });
            refresh_sidebar();
            if(browser_panel)browser_panel->select_thread(id);
            if(terminal_panel)terminal_panel->select_thread(id,working_directory(t));
            if(visible_tool=="git")hide_tools();
        } catch (...) { selecting = false; report_exception(); }
    }

    coincide::Inspectable message_row(const coincide::Message& message,const std::string& speaker){
        const auto weak=get_weak();
        return coincide::display_message(message,speaker,[weak](std::string url){
            const auto self=weak.get();if(!self||self->closing)return;
            if(url.starts_with("http://")||url.starts_with("https://"))self->show_browser(std::move(url));
            else if(url.starts_with("mailto:"))(void)winrt::Windows::System::Launcher::LaunchUriAsync(foundation::Uri(winrt::to_hstring(url)));
        },[weak](std::string content,bool svg){const auto self=weak.get();if(self&&!self->closing)self->show_preview(std::move(content),svg);});
    }

    void show_latest() {
        // The first dispatcher callback can run before the window's initial measure/arrange.
        // Loaded handles that case; already-loaded thread switches use the same path after layout.
        if (!transcript || !transcript.IsLoaded() || transcript.Items().Size() == 0) return;
        transcript.UpdateLayout();
        if (transcript.ActualHeight() <= 0 || transcript.ActualWidth() <= 0) return;
        transcript.ScrollIntoView(transcript.Items().GetAt(transcript.Items().Size() - 1));
        diagnostic(hstring{L"Transcript height: " + std::to_wstring(transcript.ActualHeight())});
    }

    void create_thread(std::optional<std::string> project = std::nullopt) {
        if (!writable) return;
        try {
            coincide::Thread t;
            t.provider = "codex";
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
            controls::ComboBox destinations;identify(destinations,L"ProjectDestination");
            add_choice(destinations,label(L"Projectless",L"No Project"));
            std::vector<std::string> projects;
            for(const auto& project:workspace.projects){projects.push_back(project.id);add_choice(destinations,winrt::to_hstring(project.name));}
            destinations.SelectedIndex(0);
            controls::ContentDialog dialog;dialog.XamlRoot(root.XamlRoot());dialog.Title(winrt::box_value(label(L"MoveToProject",L"Move to Project")));
            dialog.Content(destinations);dialog.PrimaryButtonText(label(L"Save",L"Save"));dialog.CloseButtonText(label(L"Cancel",L"Cancel"));
            if(co_await dialog.ShowAsync()==controls::ContentDialogResult::Primary){
                if(std::any_of(ids.begin(),ids.end(),[&](const auto& id){return thread_busy(id)||active_terminal(id);}))throw std::runtime_error("Stop the selected agents and close their terminals before moving conversations.");
                if(git_panel&&git_panel->mutating())throw std::runtime_error("Wait for the repository operation before moving conversations.");
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
        auto lifetime=get_strong();if(dialog_open||!writable||workspace.projects.empty())co_return;dialog_open=true;
        try {
            controls::StackPanel fields;fields.Spacing(8);controls::ComboBox picker;identify(picker,L"ProjectPicker");
            std::vector<std::string> ids;for(const auto& project:workspace.projects){ids.push_back(project.id);add_choice(picker,winrt::to_hstring(project.name));}
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
                        if(git_panel&&git_panel->mutating())throw std::runtime_error("Wait for the repository operation before removing the project.");
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
            workspace.thread(selected).draft_attachments=std::move(attachments);save_current();render_attachments();update_composer();
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
            remove.Click([this,id,i](const auto&,const auto&){if(selected!=id||workspace.thread(id).deleted_at)return;auto& a=workspace.thread(id).draft_attachments;if(i<a.size()){a.erase(a.begin()+static_cast<std::ptrdiff_t>(i));save_current();render_attachments();update_composer();}});
            row.Children().Append(remove);attachments_view.Children().Append(row);
        }
    }

    std::filesystem::path working_directory(const coincide::Thread& thread) {
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
        if(git_panel&&git_panel->mutating()){
            const auto folder=working_directory(workspace.thread(id)),repository=git_panel->repository_root();
            if(within_folder(repository,folder)||within_folder(folder,repository))throw std::runtime_error("Wait for the repository operation to finish before starting the agent.");
        }
        if(const auto found=running.find(id);found!=running.end())return found->second;
        auto& thread=workspace.thread(id);coincide::CodexLaunch launch;launch.cwd=working_directory(thread);
        if(fixture_preview){wchar_t module[32768]{};if(!GetModuleFileNameW(nullptr,module,32768))winrt::throw_last_error();launch.executable=module;launch.arguments={thread.provider=="claude"?L"--claude-session-fixture":thread.provider=="opencode"?L"--opencode-http-fixture":L"--codex-session-fixture",L"normal"};}
        else launch.executable=coincide::ProviderDiscovery::discover(thread.provider);
        const auto native=std::find_if(thread.sessions.begin(),thread.sessions.end(),[&](const auto& s){return s.provider==thread.provider;});
        if(native!=thread.sessions.end())launch.session_id=native->id;
        launch.instructions=coincide::handoff_context(thread,thread.provider).text;
        RunningThread run;run.provider=thread.provider;run.cwd=launch.cwd;run.session=coincide::make_agent_session(thread.provider,std::move(launch));
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
            if(!browser_panel){browser_panel=coincide::BrowserPanel::create(data_directory()/L"browser",{},fixture_preview);tool_views.Children().Append(browser_panel->view());}
            browser_panel->select_thread(selected);select_tool("browser",browser_panel->view(),label(L"Browser",L"Browser"));
            if(!url.empty())browser_panel->navigate(url);
        }catch(...){report_exception();}
    }
    void show_terminal(){
        if(selected.empty()||!writable)return;
        try{
            if(!terminal_panel){terminal_panel=coincide::TerminalPanel::create(data_directory(),fixture_preview);tool_views.Children().Append(terminal_panel->view());}
            terminal_panel->select_thread(selected,working_directory(workspace.thread(selected)));select_tool("terminal",terminal_panel->view(),label(L"Terminal",L"Terminal"));
        }catch(...){report_exception();}
    }
    void show_preview(std::string content,bool svg){
        try{
            if(!preview_panel){preview_panel=coincide::PreviewPanel::create(data_directory()/L"previews");tool_views.Children().Append(preview_panel->view());}
            preview_panel->load_inline(std::move(content),svg);select_tool("preview",preview_panel->view(),label(L"Preview",L"Preview"));
        }catch(...){report_exception();}
    }

    void show_git(){
        if(selected.empty()||!writable)return;
        try{
            const auto folder=working_directory(workspace.thread(selected));const auto key=winrt::to_string(folder.wstring());
            if(!git_panel||git_project!=key){
                if(git_panel&&git_panel->mutating())throw std::runtime_error("Wait for the repository operation to finish before changing the Git panel.");
                if(git_panel)git_panel->close();if(git_view){uint32_t at{};if(tool_views.Children().IndexOf(git_view,at))tool_views.Children().RemoveAt(at);git_view=nullptr;}git_project=key;const auto weak=get_weak();
                git_panel=coincide::GitPanel::create(folder,[weak,folder]{
                    const auto self=weak.get();if(!self||self->closing)return false;
                    const auto target=self->git_panel?self->git_panel->repository_root():folder;for(const auto& [id,run]:self->running){
                        (void)id;if(!run.session->busy()&&!run.awaiting_completion)continue;if(within_folder(target,run.cwd)||within_folder(run.cwd,target))return false;
                    }return true;
                },[weak,key](std::string text){
                    const auto self=weak.get();if(!self||self->closing||self->selected.empty()||text.empty())return;
                    auto& thread=self->workspace.thread(self->selected);if(thread.deleted_at)return;
                    thread.draft+="\n\nRepository diff reference from "+key+":\n```diff\n"+text+"\n```";
                    self->selecting=true;self->composer.Text(winrt::to_hstring(thread.draft));self->selecting=false;self->save_current();self->update_composer();self->composer.Focus(xaml::FocusState::Programmatic);
                });
                git_view=controls::ScrollViewer{};git_view.VerticalScrollBarVisibility(controls::ScrollBarVisibility::Auto);git_view.Content(git_panel->view());tool_views.Children().Append(git_view);
            }
            select_tool("git",git_view,label(L"Git",L"Git"));
        }catch(...){report_exception();}
    }

    void queue_message(bool steer){
        if(selected.empty()||!writable)return;
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
        for(const auto& model:dialog_models){model_ids.push_back(model.model);add_choice(model_picker,winrt::to_hstring(model.display_name));if(model.model==thread.model)selected_index=static_cast<int>(model_ids.size()-1);}
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
        if(persistence_error.empty())for(auto& [id,run]:running)if(run.completion_received&&!dirty_threads.contains(id)&&!dirty_index)run.awaiting_completion=false;
        if(!closing&&(!dirty_threads.empty()||dirty_index)){save_timer.Stop();save_timer.Start();}
        if(!closing)update_composer();
    }

    void update_composer() {
        if (closing || selected.empty() || !writable) return;
        const auto& thread = workspace.thread(selected);
        if (thread.deleted_at) {
            providers.IsEnabled(false); composer.IsEnabled(false); send_button.IsEnabled(false); stop_button.IsEnabled(false);
            queue_button.IsEnabled(false);steer_button.IsEnabled(false);models_button.IsEnabled(false);
            state.Text(label(L"DeletedThreads",L"Deleted Threads")); return;
        }
        composer.IsEnabled(true);
        const auto run = running.find(selected);
        const auto busy = run != running.end() && (run->second.awaiting_completion || run->second.session->busy());
        const auto connected=thread.provider=="codex"||thread.provider=="claude"||thread.provider=="opencode";
        const auto has_input=!thread.draft.empty()||!thread.draft_attachments.empty();
        providers.IsEnabled(!busy); stop_button.IsEnabled(busy);
        models_button.IsEnabled(connected&&!busy);queue_button.IsEnabled(connected&&has_input);steer_button.IsEnabled(thread.provider=="codex"&&busy&&has_input);
        send_button.IsEnabled(connected&&!busy&&has_input&&thread.queued_inputs.empty());
        if (run != running.end() && !run->second.status.empty()) state.Text(winrt::to_hstring(run->second.status));
        else if (connected) state.Text(thread.provider=="codex"?L"Codex · Ctrl+Enter sends.":thread.provider=="claude"?L"Claude Code · Ctrl+Enter sends.":L"OpenCode · Ctrl+Enter sends.");
        else state.Text(L"This provider adapter is not available yet.");
        if(!persistence_error.empty())state.Text(winrt::to_hstring(persistence_error));
    }

    void send_message() {
        if (selected.empty() || !writable) return;
        try {
            auto& thread = workspace.thread(selected);
            if ((thread.provider!="codex"&&thread.provider!="claude"&&thread.provider!="opencode")||thread.deleted_at||(thread.draft.empty()&&thread.draft_attachments.empty()))return;
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
            if (!at->second.session->send(input)) {
                thread.draft = original_draft;thread.draft_attachments=original_attachments;thread.messages.pop_back(); store->save_thread(thread); return;
            }
            at->second.awaiting_completion = true;at->second.completion_received=false;
            at->second.failed = false; at->second.status = winrt::to_string(label(L"Connecting", L"Connecting…"));
            transcript.Items().Append(message_row(thread.messages.back(),winrt::to_string(label(L"You", L"You"))));
            selecting = true; composer.Text(L""); selecting = false;
            render_attachments();update_composer(); show_latest(); composer.Focus(xaml::FocusState::Programmatic);
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
                    case Kind::session:
                        {
                            const auto previous = std::find_if(thread.sessions.begin(), thread.sessions.end(), [&](const auto& s) {return s.provider == run.provider && s.id == event.id;});
                            const auto acknowledged = previous == thread.sessions.end() ? 0 : previous->acknowledged_messages;
                            workspace.remember_session(id, {run.provider,event.id,acknowledged});dirty_threads.insert(id);break;
                        }
                    case Kind::started:
                        run.completion_received=false;run.status = run.provider+" is working…"; break;
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
                        if(selected==id){render_queue();show_latest();}break;
                    }
                    case Kind::prompt:
                        workspace.note_activity(id,coincide::Workspace::now_seconds(),true);dirty_index=true;
                        run.prompts.insert_or_assign(event.id, event); changed_prompts = changed_prompts || selected == id;
                        run.status = run.provider=="codex"?"Codex is waiting for your response.":"Claude Code is waiting for your response."; break;
                    case Kind::resolved:
                        run.prompts.erase(event.id); changed_prompts = changed_prompts || selected == id; break;
                    case Kind::error:
                        run.failed = true; run.status = event.text; break;
                    case Kind::completed:
                        run.prompts.clear(); changed_prompts = changed_prompts || selected == id;
                        if (!run.failed) run.status = event.text == "interrupted" ? "Stopped" : winrt::to_string(label(L"Ready", L"Ready"));
                        if (event.text == "completed") {
                            const auto session = std::find_if(thread.sessions.begin(), thread.sessions.end(), [&](const auto& s) {return s.provider == run.provider;});
                            if (session != thread.sessions.end()) session->acknowledged_messages = thread.messages.size();
                        }
                        dirty_threads.insert(id);run.completion_received=true;new_completion=true;break;
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
                detail.Text(winrt::hstring(description)); card.Children().Append(detail);
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
                    card.Children().Append(accept);
                }
                auto decline = button(L"Deny", L"Deny", L"DenyApproval");
                decline.Click([this, thread, id](const auto&, const auto&) {answer_prompt(thread, id, "{\"decision\":\"decline\"}");});
                card.Children().Append(decline);
            }
            prompts_view.Children().Append(card);
        }
    }

    void history(bool redo) {
        if(!writable)return;const auto before=workspace;
        try{
            if(redo?workspace.redo_archive():workspace.undo_archive()){
                std::vector<std::string> changed;
                for(const auto& old:before.threads)if(workspace.thread(old.id).project_id!=old.project_id){
                    if(thread_busy(old.id)||active_terminal(old.id)||(git_panel&&git_panel->mutating()))throw std::runtime_error("Stop the agents, close terminals and finish repository operations before undoing a project change.");
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

    winrt::fire_and_forget show_status() {
        auto lifetime = get_strong();
        try {
            controls::ContentDialog dialog;
            dialog.XamlRoot(root.XamlRoot());
            dialog.Title(winrt::box_value(label(L"Settings", L"Settings")));
            dialog.Content(winrt::box_value(L"This Windows preview includes Codex, Claude Code and OpenCode adapters, conversation and project controls, model settings, queues, native questions, Markdown, attachments, Git, browser and terminal panels. Closing the window stops its agent and terminal processes. Real signed-in conversations and complete feature parity are still being validated."));
            dialog.CloseButtonText(label(L"Close", L"Close"));
            co_await dialog.ShowAsync();
        } catch (...) { report_exception(); }
    }
};
} // namespace

int __stdcall wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    try {
        winrt::init_apartment(winrt::apartment_type::single_threaded);
        int argc{};
        auto argv = CommandLineToArgvW(GetCommandLineW(), &argc);
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--store-tests") {
            const auto report = std::filesystem::path(argv[2]); LocalFree(argv);
            return coincide::store_tests(report);
        }
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--protocol-tests") {
            const auto report = std::filesystem::path(argv[2]); LocalFree(argv);
            return coincide::protocol_tests(report);
        }
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--connection-tests") {
            const auto report = std::filesystem::path(argv[2]); LocalFree(argv);
            return coincide::connection_tests(report);
        }
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--display-tests") {
            const auto report = std::filesystem::path(argv[2]); LocalFree(argv);
            return coincide::display_tests(report);
        }
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--git-tests") {
            const auto report = std::filesystem::path(argv[2]); LocalFree(argv);
            return coincide::git_tests(report);
        }
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--session-tests") {
            const auto report = std::filesystem::path(argv[2]); LocalFree(argv);
            return coincide::session_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--provider-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::provider_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--claude-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::claude_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--terminal-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::terminal_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--calendar-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::windows_calendar_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--opencode-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::opencode_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--browser-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::browser_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--preview-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::preview_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--schedule-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::schedule_store_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--opencode-http-fixture"){
            const auto mode=std::wstring(argv[2]);LocalFree(argv);return coincide::opencode_http_fixture(mode);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--acp-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::acp_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--acp-session-fixture"){
            const auto mode=std::wstring(argv[2]);LocalFree(argv);return coincide::acp_session_fixture(mode);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--acp-terminal-fixture"){
            const auto mode=std::wstring(argv[2]);LocalFree(argv);return coincide::acp_terminal_fixture(mode);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--credential-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);return coincide::credential_tests(report);
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--question-tests"){
            const auto report=std::filesystem::path(argv[2]);LocalFree(argv);int result=1;winrt::com_ptr<App> application;
            xaml::Application::Start([&](auto&&){application=winrt::make_self<App>(true);application->question_test_report=report;application->question_test_result=&result;});return result;
        }
        if(argv&&argc==3&&std::wstring_view(argv[1])==L"--claude-session-fixture"){
            const auto mode=std::wstring(argv[2]);LocalFree(argv);return coincide::claude_session_fixture(mode);
        }
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--codex-session-fixture") {
            const auto mode = std::wstring(argv[2]); LocalFree(argv);
            return coincide::codex_session_fixture(mode);
        }
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--rpc-fixture") {
            const auto mode = std::wstring(argv[2]); LocalFree(argv);
            return coincide::rpc_fixture(mode);
        }
        const auto fixture = argv && argc == 2 && std::wstring_view(argv[1]) == L"--codex-fixture-preview";
        if (fixture && GetEnvironmentVariableW(L"COINCIDE_DATA_DIR", nullptr, 0) <= 1) {
            throw std::runtime_error("Protocol fixture previews require an explicit isolated test data directory.");
        }
        if (argv) LocalFree(argv);
        // Keep the programmatic application (including its metadata provider and callbacks) alive
        // for the complete dispatcher loop, independently of generated XAML application glue.
        winrt::com_ptr<App> application;
        xaml::Application::Start([&application, fixture](auto&&) { application = winrt::make_self<App>(fixture); });
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
