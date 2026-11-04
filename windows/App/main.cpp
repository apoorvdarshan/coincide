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
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.Windows.ApplicationModel.Resources.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.System.h>
#include "WorkspaceStore.h"
#include "../Tests/StoreTests.h"
#include <memory>

namespace xaml = winrt::Microsoft::UI::Xaml;
namespace controls = winrt::Microsoft::UI::Xaml::Controls;
namespace foundation = winrt::Windows::Foundation;
using winrt::hstring;

namespace {
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

struct App : xaml::ApplicationT<App> {
    xaml::Window window{nullptr};
    controls::Grid root{nullptr};
    controls::ListView sidebar{nullptr};
    controls::ListView transcript{nullptr};
    controls::TextBox composer{nullptr};
    controls::TextBox search{nullptr};
    controls::TextBlock title{nullptr};
    controls::TextBlock state{nullptr};
    controls::ComboBox providers{nullptr};
    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer save_timer{nullptr};
    std::unique_ptr<coincide::WorkspaceStore> store;
    coincide::Workspace workspace;
    std::vector<std::string> visible;
    std::string selected;
    bool selecting{};
    bool archived{};
    bool writable{};

    App() {
        Resources().MergedDictionaries().Append(controls::XamlControlsResources{});
        UnhandledException([this](const auto&, const xaml::UnhandledExceptionEventArgs& args) {
            args.Handled(true);
            show_error(args.Message());
        });
    }

    void OnLaunched(const xaml::LaunchActivatedEventArgs&) {
        window = xaml::Window{};
        window.Title(L"Coincide — Windows Preview");
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
        transcript.SelectionMode(controls::ListViewSelectionMode::None);
        transcript.HorizontalContentAlignment(xaml::HorizontalAlignment::Stretch);
        transcript.ItemTemplate(xaml::Markup::XamlReader::Load(
            LR"(<DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"><TextBlock Text="{Binding}" TextWrapping="Wrap" IsTextSelectionEnabled="True" Margin="12,8,12,8"/></DataTemplate>)"
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
            save_timer.Stop(); save_timer.Start();
        });
        compose.Children().Append(composer);
        state = controls::TextBlock{};
        state.TextWrapping(xaml::TextWrapping::Wrap);
        // Explicit preview capability notice: no fake Send button or fabricated agent responses.
        state.Text(L"Windows development preview: agent connections are not available in this build.");
        compose.Children().Append(state);
        controls::Grid::SetRow(compose, 2);
        content.Children().Append(compose);

        save_timer = window.DispatcherQueue().CreateTimer();
        save_timer.Interval(std::chrono::milliseconds(400)); save_timer.IsRepeating(false);
        save_timer.Tick([this](const auto&, const auto&) { save_current(); });
        window.Closed([this](const auto&, const auto&) { save_timer.Stop(); save_current(); });

        try {
            store = std::make_unique<coincide::WorkspaceStore>(data_directory());
            workspace = store->open();
            writable = true;
        } catch (...) {
            writable = false;
            report_exception();
        }
        window.Activate();
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
            sidebar.Items().Append(winrt::box_value(winrt::to_hstring(display)));
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
            selecting = true;
            selected = id;
            title.Text(winrt::to_hstring(t.title));
            composer.Text(winrt::to_hstring(t.draft)); composer.IsEnabled(true);
            providers.SelectedIndex(static_cast<int32_t>(std::distance(coincide::provider_ids.begin(),
                std::find(coincide::provider_ids.begin(), coincide::provider_ids.end(), t.provider))));
            transcript.Items().Clear();
            for (const auto& m : t.messages) {
                const auto speaker = m.role == "user" ? winrt::to_string(label(L"You", L"You")) : m.provider;
                transcript.Items().Append(winrt::box_value(winrt::to_hstring(speaker + "\n" + m.text)));
            }
            selecting = false;
            // Let WinUI lay out at the final width before requesting the latest virtualized row.
            window.DispatcherQueue().TryEnqueue([this, id] {
                if (selected != id || transcript.Items().Size() == 0) return;
                transcript.UpdateLayout();
                transcript.ScrollIntoView(transcript.Items().GetAt(transcript.Items().Size() - 1));
            });
            refresh_sidebar();
        } catch (...) { selecting = false; report_exception(); }
    }

    void create_thread(std::optional<std::string> project = std::nullopt) {
        if (!writable) return;
        try {
            coincide::Thread t;
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
        if (state) state.Text(message);
        else MessageBoxW(nullptr, message.c_str(), L"Coincide", MB_OK | MB_ICONERROR);
    }

    winrt::fire_and_forget show_status() {
        auto lifetime = get_strong();
        try {
            controls::ContentDialog dialog;
            dialog.XamlRoot(root.XamlRoot());
            dialog.Title(winrt::box_value(label(L"Settings", L"Settings")));
            dialog.Content(winrt::box_value(L"This Windows preview supports local projects, conversations, saved drafts, and archive undo/redo. Agent connections and other feature-parity work are still in development."));
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
        if (argv) LocalFree(argv);
        xaml::Application::Start([](auto&&) { winrt::make<App>(); });
        return 0;
    } catch (const winrt::hresult_error& error) {
        MessageBoxW(nullptr, error.message().c_str(), L"Coincide could not start", MB_OK | MB_ICONERROR);
        return 1;
    } catch (const std::exception& error) {
        MessageBoxW(nullptr, winrt::to_hstring(error.what()).c_str(), L"Coincide could not start", MB_OK | MB_ICONERROR);
        return 1;
    }
}
