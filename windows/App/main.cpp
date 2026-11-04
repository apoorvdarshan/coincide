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
#include <winrt/Microsoft.UI.Xaml.Data.h>
#include <winrt/Windows.UI.Xaml.Interop.h>
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
#include "../Tests/SessionTests.h"
#include <memory>

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
    return fallback;
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

std::filesystem::path codex_executable() {
    wchar_t path[32768]{};
    const auto explicit_path = GetEnvironmentVariableW(L"COINCIDE_CODEX_EXE", path, 32768);
    if (explicit_path >= 32768) throw std::runtime_error("The Codex executable path is too long");
    if (explicit_path) {
        if (!std::filesystem::is_regular_file(path)) throw std::runtime_error("The configured Codex executable does not exist.");
        return path;
    }
    const auto found = SearchPathW(nullptr, L"codex.exe", nullptr, 32768, path, nullptr);
    if (found && found < 32768) return path;
    const auto count = GetEnvironmentVariableW(L"LOCALAPPDATA", path, 32768);
    if (count && count < 32768) {
        for (const auto& candidate : {std::filesystem::path(path) / L"Programs/Codex/codex.exe",
                std::filesystem::path(path) / L"Microsoft/WinGet/Links/codex.exe"}) {
            if (std::filesystem::is_regular_file(candidate)) return candidate;
        }
    }
    throw std::runtime_error("Install the native Windows Codex CLI and sign in with codex login, then try again.");
}

// ListView needs an identity for each row. Equal boxed strings otherwise identify two different messages
// as the same item, which can make UI Automation sibling traversal cycle indefinitely.
using Inspectable = winrt::Windows::Foundation::IInspectable;
using XamlType = winrt::Windows::UI::Xaml::Interop::TypeName;
using TypeKind = winrt::Windows::UI::Xaml::Interop::TypeKind;
struct DisplayProperty : winrt::implements<DisplayProperty, xaml::Data::ICustomProperty> {
    explicit DisplayProperty(hstring text) : text_(std::move(text)) {}
    XamlType Type() const { return {L"String", TypeKind::Primitive}; }
    hstring Name() const { return L"Text"; }
    Inspectable GetValue(const Inspectable&) const { return winrt::box_value(text_); }
    bool CanRead() const { return true; }
    bool CanWrite() const { return false; }
    void SetValue(const Inspectable&, const Inspectable&) const { throw winrt::hresult_access_denied(); }
    Inspectable GetIndexedValue(const Inspectable&, const Inspectable&) const { throw winrt::hresult_not_implemented(); }
    void SetIndexedValue(const Inspectable&, const Inspectable&, const Inspectable&) const { throw winrt::hresult_not_implemented(); }
private:
    hstring text_;
};
struct DisplayItem : winrt::implements<DisplayItem, xaml::Data::ICustomPropertyProvider> {
    explicit DisplayItem(hstring text) : text_(std::move(text)) {}
    xaml::Data::ICustomProperty GetCustomProperty(const hstring& name) const {
        return name == L"Text" ? winrt::make<DisplayProperty>(text_) : nullptr;
    }
    xaml::Data::ICustomProperty GetIndexedProperty(const hstring&, const XamlType&) const { return nullptr; }
    hstring GetStringRepresentation() const { return text_; }
    XamlType Type() const { return {L"Coincide.DisplayItem", TypeKind::Custom}; }
private:
    hstring text_;
};
winrt::Windows::Foundation::IInspectable display_item(const std::string& text) {
    return winrt::make<DisplayItem>(winrt::to_hstring(text));
}

struct App : xaml::ApplicationT<App, xaml::Markup::IXamlMetadataProvider> {
    xaml::XamlTypeInfo::XamlControlsXamlMetaDataProvider metadata;
    xaml::Window window{nullptr};
    controls::Grid root{nullptr};
    controls::ListView sidebar{nullptr};
    controls::ListView transcript{nullptr};
    controls::TextBox composer{nullptr};
    controls::TextBox search{nullptr};
    controls::TextBlock title{nullptr};
    controls::TextBlock state{nullptr};
    controls::ComboBox providers{nullptr};
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
    bool closing{};
    bool fixture_preview{};
    struct RunningThread {
        std::unique_ptr<coincide::CodexSession> session;
        std::unordered_map<std::string, coincide::SessionEvent> prompts;
        std::string status;
        bool failed{};
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
        window = xaml::Window{};
        window.Title(fixture_preview ? L"Coincide — Protocol Fixture Test" : L"Coincide — Windows Preview");
        window.AppWindow().Resize({1100, 780});
        root = controls::Grid{};
        auto left = controls::ColumnDefinition{}; left.Width({260, xaml::GridUnitType::Pixel});
        root.ColumnDefinitions().Append(left);
        root.ColumnDefinitions().Append(controls::ColumnDefinition{});
        window.Content(root);

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
        sidebar_grid.Children().Append(sidebar_top);

        sidebar = controls::ListView{};
        identify(sidebar, L"Threads");
        sidebar.DisplayMemberPath(L"Text");
        sidebar.SelectionMode(controls::ListViewSelectionMode::Single);
        sidebar.SelectionChanged([this](const auto&, const auto&) {
            const auto index = sidebar.SelectedIndex();
            if (!selecting && index >= 0 && static_cast<std::size_t>(index) < visible.size()) open_thread(visible[index]);
        });
        controls::Grid::SetRow(sidebar, 1);
        sidebar_grid.Children().Append(sidebar);

        controls::StackPanel footer;
        footer.Spacing(8);
        auto archive_toggle = controls::ToggleSwitch{};
        archive_toggle.Header(winrt::box_value(label(L"ShowArchived", L"Show Archived Threads")));
        archive_toggle.Toggled([this, archive_toggle](const auto&, const auto&) {
            archived = archive_toggle.IsOn(); refresh_sidebar();
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

        controls::StackPanel toolbar;
        toolbar.Orientation(controls::Orientation::Horizontal);
        toolbar.Spacing(12);
        title = controls::TextBlock{};
        title.Text(L"Coincide"); title.FontSize(20);
        title.VerticalAlignment(xaml::VerticalAlignment::Center);
        toolbar.Children().Append(title);
        auto archive = button(L"Archive", L"Archive", L"Archive");
        archive.Click([this](const auto&, const auto&) {
            if (selected.empty() || !writable) return;
            try {
                workspace.archive({selected}, !workspace.thread(selected).archived);
                store->save_index(workspace); refresh_sidebar();
            } catch (...) { report_exception(); }
        });
        toolbar.Children().Append(archive);
        auto undo = button(L"Undo", L"Undo", L"Undo");
        undo.Click([this](const auto&, const auto&) { history(false); }); toolbar.Children().Append(undo);
        auto redo = button(L"Redo", L"Redo", L"Redo");
        redo.Click([this](const auto&, const auto&) { history(true); }); toolbar.Children().Append(redo);
        content.Children().Append(toolbar);

        transcript = controls::ListView{};
        identify(transcript, L"Transcript");
        transcript.Loaded([this](const auto&, const auto&) { show_latest(); });
        transcript.SelectionMode(controls::ListViewSelectionMode::None);
        transcript.HorizontalContentAlignment(xaml::HorizontalAlignment::Stretch);
        transcript.ItemTemplate(xaml::Markup::XamlReader::Load(
            LR"(<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock Text="{Binding Text}" TextWrapping="Wrap" IsTextSelectionEnabled="True" Margin="12,8,12,8"/></DataTemplate>)"
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
                    workspace.thread(selected).provider = coincide::provider_ids[index];
                    store->save_index(workspace);
                    update_composer();
                } catch (...) { report_exception(); }
            }
        });
        compose.Children().Append(providers);
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
        controls::Grid::SetRow(compose, 2);
        content.Children().Append(compose);

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
        selecting = true;
        visible = workspace.visible_threads(winrt::to_string(search.Text()), archived);
        sidebar.Items().Clear();
        for (const auto& id : visible) {
            const auto& t = workspace.thread(id);
            std::string display = t.title;
            if (t.project_id) {
                const auto p = std::find_if(workspace.projects.begin(), workspace.projects.end(), [&](const auto& p) {return p.id == *t.project_id;});
                if (p != workspace.projects.end()) display = p->name + " / " + display;
            }
            sidebar.Items().Append(display_item(display));
        }
        const auto at = std::find(visible.begin(), visible.end(), selected);
        if (at != visible.end()) sidebar.SelectedIndex(static_cast<int32_t>(std::distance(visible.begin(), at)));
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
            composer.Text(winrt::to_hstring(t.draft)); composer.IsEnabled(true);
            providers.SelectedIndex(static_cast<int32_t>(std::distance(coincide::provider_ids.begin(),
                std::find(coincide::provider_ids.begin(), coincide::provider_ids.end(), t.provider))));
            transcript.Items().Clear();
            for (const auto& m : t.messages) {
                const auto speaker = m.role == "user" ? winrt::to_string(label(L"You", L"You")) : m.provider;
                transcript.Items().Append(display_item(speaker + "\n" + m.text));
            }
            selecting = false;
            render_prompts(); update_composer();
            // Let WinUI lay out at the final width before requesting the latest virtualized row.
            window.DispatcherQueue().TryEnqueue([this, id] {
                if (selected == id) show_latest();
            });
            refresh_sidebar();
        } catch (...) { selecting = false; report_exception(); }
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
            const auto id = t.id;
            workspace.add_thread(std::move(t));
            store->load_thread(workspace.thread(id));
            store->save_thread(workspace.thread(id));
            store->save_index(workspace);
            archived = false;
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

    void flush_dirty() {
        auto ids = std::move(dirty_threads); dirty_threads.clear();
        for (const auto& id : ids) {
            try {store->save_thread(workspace.thread(id));}
            catch (...) {dirty_threads.insert(id); report_exception();}
        }
    }

    void update_composer() {
        if (closing || selected.empty() || !writable) return;
        const auto& thread = workspace.thread(selected);
        const auto run = running.find(selected);
        const auto busy = run != running.end() && run->second.session->busy();
        providers.IsEnabled(!busy); stop_button.IsEnabled(busy);
        send_button.IsEnabled(thread.provider == "codex" && !busy && !thread.draft.empty());
        if (run != running.end() && !run->second.status.empty()) state.Text(winrt::to_hstring(run->second.status));
        else if (thread.provider == "codex") state.Text(L"Codex · commands and file changes require approval. Ctrl+Enter sends.");
        else state.Text(L"This provider is not connected in the Windows preview yet. Select Codex to begin.");
    }

    void send_message() {
        if (selected.empty() || !writable) return;
        try {
            auto& thread = workspace.thread(selected);
            if (thread.provider != "codex" || thread.draft.empty()) return;
            auto at = running.find(selected);
            if (at != running.end() && at->second.session->busy()) return;
            if (at == running.end()) {
                coincide::CodexLaunch launch;
                if (fixture_preview) {
                    wchar_t module[32768]{};
                    if (!GetModuleFileNameW(nullptr, module, 32768)) winrt::throw_last_error();
                    launch.executable = module; launch.arguments = {L"--codex-session-fixture", L"normal"};
                } else launch.executable = codex_executable();
                const auto native = std::find_if(thread.sessions.begin(), thread.sessions.end(), [](const auto& value) {return value.provider == "codex";});
                if (native != thread.sessions.end()) launch.session_id = native->id;
                else if (std::any_of(thread.messages.begin(), thread.messages.end(), [](const auto& value) {return value.role == "assistant";})) {
                    throw std::runtime_error("Start a new chat for Codex. Importing this conversation's earlier context is not available yet.");
                }
                if (thread.project_id) {
                    const auto project = std::find_if(workspace.projects.begin(), workspace.projects.end(), [&](const auto& p) {return p.id == *thread.project_id;});
                    if (project == workspace.projects.end()) throw std::runtime_error("The conversation's project is missing.");
                    launch.cwd = winrt::to_hstring(project->path).c_str();
                } else {
                    launch.cwd = data_directory() / L"workspaces" / winrt::to_hstring(thread.id).c_str();
                    std::filesystem::create_directories(launch.cwd);
                }
                if (!std::filesystem::is_directory(launch.cwd)) throw std::runtime_error("The project folder is unavailable.");
                RunningThread run;
                run.session = std::make_unique<coincide::CodexSession>(std::move(launch));
                at = running.emplace(selected, std::move(run)).first;
            }
            coincide::CodexTurn input;
            input.text = thread.draft; input.model = thread.model;
            const auto id = coincide::new_id();
            thread.messages.push_back({id, "user", input.text, "codex"}); thread.draft.clear();
            try {store->save_thread(thread);}
            catch (...) {thread.draft = input.text; thread.messages.pop_back(); throw;}
            if (!at->second.session->send(input)) {
                thread.draft = input.text; thread.messages.pop_back(); store->save_thread(thread); return;
            }
            at->second.failed = false; at->second.status = winrt::to_string(label(L"Connecting", L"Connecting…"));
            transcript.Items().Append(display_item(winrt::to_string(label(L"You", L"You")) + "\n" + input.text));
            selecting = true; composer.Text(L""); selecting = false;
            update_composer(); show_latest(); composer.Focus(xaml::FocusState::Programmatic);
        } catch (...) {report_exception();}
    }

    void upsert_output(coincide::Thread& thread, const coincide::SessionEvent& event) {
        const auto role = event.kind == coincide::SessionEvent::Kind::tool ? "tool" : "assistant";
        const auto id = "codex/" + event.id;
        auto at = std::find_if(thread.messages.begin(), thread.messages.end(), [&](const auto& m) {return m.id == id;});
        if (at == thread.messages.end()) {
            thread.messages.push_back({id, role, event.text, "codex"}); at = std::prev(thread.messages.end());
        } else if (event.kind == coincide::SessionEvent::Kind::text_delta) at->text += event.text;
        else if (!event.text.empty()) at->text = event.text;
        dirty_threads.insert(thread.id);
        if (selected == thread.id && !closing) {
            const auto row = static_cast<uint32_t>(std::distance(thread.messages.begin(), at));
            const auto value = display_item("codex\n" + at->text);
            if (row < transcript.Items().Size()) transcript.Items().SetAt(row, value);
            else transcript.Items().Append(value);
            show_latest();
        }
    }

    void drain_sessions() {
        bool changed_prompts{};
        for (auto& [id, run] : running) {
            try {
                auto& thread = workspace.thread(id);
                bool received_output{};
                for (const auto& event : run.session->take_events()) {
                    using Kind = coincide::SessionEvent::Kind;
                    switch (event.kind) {
                    case Kind::session:
                        {
                            const auto previous = std::find_if(thread.sessions.begin(), thread.sessions.end(), [&](const auto& s) {return s.provider == "codex" && s.id == event.id;});
                            const auto acknowledged = previous == thread.sessions.end() ? 0 : previous->acknowledged_messages;
                            workspace.remember_session(id, {"codex", event.id, acknowledged}); store->save_thread(thread); break;
                        }
                    case Kind::started:
                        run.status = "Codex is working…"; break;
                    case Kind::status: run.status = event.text; break;
                    case Kind::text_delta: case Kind::text_complete: case Kind::tool:
                        upsert_output(thread, event); received_output = true; break;
                    case Kind::prompt:
                        run.prompts.insert_or_assign(event.id, event); changed_prompts = changed_prompts || selected == id;
                        run.status = "Codex is waiting for your response."; break;
                    case Kind::resolved:
                        run.prompts.erase(event.id); changed_prompts = changed_prompts || selected == id; break;
                    case Kind::error:
                        run.failed = true; run.status = event.text; break;
                    case Kind::completed:
                        run.prompts.clear(); changed_prompts = changed_prompts || selected == id;
                        if (!run.failed) run.status = event.text == "interrupted" ? "Stopped" : winrt::to_string(label(L"Ready", L"Ready"));
                        if (event.text == "completed") {
                            const auto session = std::find_if(thread.sessions.begin(), thread.sessions.end(), [](const auto& s) {return s.provider == "codex";});
                            if (session != thread.sessions.end()) session->acknowledged_messages = thread.messages.size();
                        }
                        store->save_thread(thread); dirty_threads.erase(id); break;
                    }
                }
                if (received_output && !closing) {save_timer.Stop(); save_timer.Start();}
            } catch (...) {report_exception();}
        }
        if (!closing) {if (changed_prompts) render_prompts(); update_composer();}
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
                detail.Text(L"Codex has a question."); card.Children().Append(detail);
                std::vector<std::pair<std::string, controls::Control>> fields;
                for (const auto& raw : params.GetNamedArray(L"questions")) {
                    const auto question = raw.GetObject();
                    controls::TextBlock question_text;
                    question_text.Text(question.GetNamedString(L"question")); question_text.TextWrapping(xaml::TextWrapping::Wrap);
                    card.Children().Append(question_text);
                    for (const auto& option : question.GetNamedArray(L"options", coincide::rpc_json::JsonArray{})) {
                        controls::TextBlock choice;
                        const auto value = option.GetObject();
                        choice.Text(value.GetNamedString(L"label") + L" — " + value.GetNamedString(L"description", L""));
                        choice.TextWrapping(xaml::TextWrapping::Wrap); card.Children().Append(choice);
                    }
                    controls::Control field{nullptr};
                    if (question.GetNamedBoolean(L"isSecret", false)) field = controls::PasswordBox{};
                    else field = controls::TextBox{};
                    identify(field, L"QuestionAnswer");
                    fields.emplace_back(winrt::to_string(question.GetNamedString(L"id")), field); card.Children().Append(field);
                }
                auto submit = button(L"Submit", L"Submit", L"SubmitAnswer");
                submit.Click([this, thread, id, fields](const auto&, const auto&) {
                    coincide::rpc_json::JsonObject result, answers;
                    for (const auto& [key, field] : fields) {
                        const auto secret = field.try_as<controls::PasswordBox>();
                        const auto answer = secret ? secret.Password() : field.as<controls::TextBox>().Text();
                        coincide::rpc_json::JsonArray values; values.Append(coincide::rpc_json::JsonValue::CreateStringValue(answer));
                        coincide::rpc_json::JsonObject entry; entry.SetNamedValue(L"answers", values);
                        answers.SetNamedValue(winrt::to_hstring(key), entry);
                    }
                    result.SetNamedValue(L"answers", answers); answer_prompt(thread, id, winrt::to_string(result.Stringify()));
                });
                card.Children().Append(submit);
                auto dismiss = button(L"Dismiss", L"Dismiss", L"DismissQuestion");
                dismiss.Click([this, thread, id](const auto&, const auto&) {answer_prompt(thread, id, "{\"answers\":{}}");});
                card.Children().Append(dismiss);
            } else {
                const auto file_change = event.detail == "item/fileChange/requestApproval";
                bool has_file_details{};
                std::wstring description = file_change ? L"Codex wants to change files:\n" : L"Codex wants to run:\n";
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
        if (!writable) return;
        try {
            if (redo ? workspace.redo_archive() : workspace.undo_archive()) {
                store->save_index(workspace); refresh_sidebar();
            }
        } catch (...) { report_exception(); }
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
            dialog.Content(winrt::box_value(L"This Windows preview supports Codex conversations, streamed text, command/file approvals, questions, Stop, saved drafts, and archive undo/redo. Closing the window stops its agent processes. Other providers and feature-parity work are still in development."));
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
        if (argv && argc == 3 && std::wstring_view(argv[1]) == L"--session-tests") {
            const auto report = std::filesystem::path(argv[2]); LocalFree(argv);
            return coincide::session_tests(report);
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
