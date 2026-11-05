#pragma once
#include "BrowserPolicy.h"
#include "BrowserToolEngine.h"
#include "BrowserPrivateText.h"
#include "BrowserToolCapture.h"
#include "BrowserLibraryPanel.h"
#include "../Runtime/AppToolBridgeFiles.h"
#include "NativeStrings.h"
#include <windows.h>
#undef GetCurrentTime
#include <shlobj.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.Web.WebView2.Core.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <array>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <functional>
#include <memory>
#include <stdexcept>
#include <unordered_map>
#include <vector>

namespace coincide {
namespace credentials {struct FrameContext;struct LoginSecret;}
namespace browser_xaml = winrt::Microsoft::UI::Xaml;
namespace browser_controls = winrt::Microsoft::UI::Xaml::Controls;
namespace browser_core = winrt::Microsoft::Web::WebView2::Core;
namespace browser_json = winrt::Windows::Data::Json;
struct BrowserTabSnapshot {
    std::string id, thread_id, url, title, error;
    bool private_mode{}, loading{}, ready{};
};
struct BrowserDownloadSnapshot {
    std::string id, thread_id, name, path, state;
    std::uint64_t received{}, total{};
};

// A reusable pane owned by the app window, with one live controller per tab. Hide with set_visible(false),
// retaining it in the visual tree, so closing the pane does not close pages or their browser processes.
class BrowserPanel : public std::enable_shared_from_this<BrowserPanel> {
public:
    static std::shared_ptr<BrowserPanel> create(std::filesystem::path profile_root,
            std::filesystem::path download_root = {}, bool fixture_mode = false, bool isolate_thread_profiles = false) {
        auto result = std::shared_ptr<BrowserPanel>(new BrowserPanel(std::move(profile_root), std::move(download_root), fixture_mode, isolate_thread_profiles));
        result->load_state(); result->build_view(); return result;
    }
    browser_controls::Grid view() const {return root_;}
    void set_visible(bool value) {visible_ = value; root_.Visibility(value ? browser_xaml::Visibility::Visible : browser_xaml::Visibility::Collapsed);}
    void set_changed_callback(std::function<void()> callback) {changed_ = std::move(callback);}
    void set_navigation_callback(std::function<void(const std::string&)> callback){navigation_changed_=std::move(callback);}
    using AgentControlCallback=std::function<void(const std::string&,bool)>;
    using ShowCallback=std::function<void(const std::string&,bool)>;
    void set_agent_control_callback(AgentControlCallback value){agent_control_changed_=std::move(value);}
    void set_show_callback(ShowCallback value){show_=std::move(value);}
    void set_search_resolver(std::function<std::string(const std::string&)> value){search_=std::move(value);}
    void set_owner(HWND owner){browser_owner_=owner;}
    void set_library_confirmation(BrowserLibraryPanel::Confirm value){library_confirm_=std::move(value);}
    bool library_idle()const{return library_operations_.load()==0&&history_pending_.empty()&&(!library_panel_||!library_panel_->saving());}
    winrt::Windows::Foundation::IAsyncAction flush_library(bool finishing=false){const auto lifetime=shared_from_this();if(finishing)library_finishing_=true;const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(10);const winrt::apartment_context ui_thread;while(!library_idle()){if(std::chrono::steady_clock::now()>deadline)throw std::runtime_error("Browser library is still saving; its previous atomic snapshot remains intact");if(!history_pending_.empty()&&!history_writing_)drain_history();co_await winrt::resume_after(std::chrono::milliseconds(10));try{co_await ui_thread;}catch(...){co_return;}}}
    void show_library(bool show=true){
        if(closed_)return;if(!show){if(library_host_)library_host_.Visibility(browser_xaml::Visibility::Collapsed);return;}
        const auto key=isolate_thread_profiles_?selected_thread_:std::string{"Default"};if(key.empty())throw std::runtime_error("Open a conversation before its browser library");
        if(!library_panel_||library_key_!=key){if(library_panel_)library_panel_->close();library_key_=key;const auto weak=weak_from_this();const auto directory=library_directory(selected_thread_);library_panel_=BrowserLibraryPanel::create(directory,[weak](const std::string& url){if(const auto self=weak.lock();self&&!self->closed_){self->navigate(url);}},library_confirm_,browser_owner_,[weak]{if(const auto self=weak.lock())self->refresh_bookmark();},[weak,directory]{if(const auto self=weak.lock();self&&!self->closed_){for(auto& [thread,state]:self->threads_)if(self->library_directory(thread)==directory)for(const auto& tab:state.tabs)if(!tab->private_mode)tab->omit_restore=true;self->save_state();}});library_host_.Child(library_panel_->view());}else if(!library_panel_->busy())library_panel_->refresh();library_host_.Visibility(browser_xaml::Visibility::Visible);
    }
    std::filesystem::path library_directory(const std::string& thread)const{if(isolate_thread_profiles_&&!browser_thread_id_allowed(thread))throw std::invalid_argument("Choose a browser profile before opening its library");return profiles_/L"library"/winrt::to_hstring(isolate_thread_profiles_?thread:std::string{"Default"}).c_str();}
    bool agent_control(const std::string& thread)const{const auto found=agent_grants_.find(thread);return !closed_&&found!=agent_grants_.end()&&found->second->valid;}
    void set_agent_control(const std::string& thread,bool enabled);
    static std::string tool_schema(){return browser_tool::Request::schema();}
    static std::set<std::string> tool_actions(){return browser_tool::Request::actions();}
    // Caller dispatches on any thread; this coroutine hops to the owning UI dispatcher.
    // Host lifetime is an out-of-band upload approval/pin owner, never a JSON field.
    browser_tool::Reply request(std::string thread,std::string json,std::filesystem::path artifact_directory,
        browser_tool::Cancel cancelled={},std::shared_ptr<void> upload_lifetime={});
    browser_tool::Action credential_context(std::string thread,std::string tab,std::string frame,
        std::shared_ptr<credentials::FrameContext> output,browser_tool::Cancel cancelled={});
    winrt::Windows::Foundation::IAsyncOperation<bool> fill_approved(credentials::FrameContext expected,
        std::shared_ptr<credentials::LoginSecret> secret,browser_tool::Cancel cancelled={});
    void select_thread(std::string id) {
        if (!browser_thread_id_allowed(id)) throw std::invalid_argument("Invalid browser conversation identity");
        selected_thread_ = std::move(id);
        if(isolate_thread_profiles_&&library_panel_&&library_key_!=selected_thread_){library_panel_->close();library_panel_.reset();library_host_.Child(nullptr);library_host_.Visibility(browser_xaml::Visibility::Collapsed);library_key_.clear();}
        auto& state = threads_[selected_thread_];
        if (state.tabs.empty()) {new_tab(); return;}
        for (const auto& tab : state.tabs) create_page(tab);
        if (state.selected.empty() || !find_tab(state.selected)) state.selected = state.tabs.front()->id;
        refresh_tabs();
    }
    std::string new_tab(std::string url = "about:blank", bool private_mode = false) {
        return add_tab(selected_thread_, std::move(url), private_mode, true)->id;
    }
    void close_tab(const std::string& id) {
        const auto tab = find_tab(id); if (!tab) return;
        tab->closed = true; tab->ready = false; tab->loading = false; complete_popup(*tab); complete_agent_dialog(*tab);invalidate_agent_frames(*tab);
        if (tab->page) {
            try {tab->page.Close();tab->upload_lifetimes.clear();} catch (...) { }
            std::uint32_t index{}; if (pages_.Children().IndexOf(tab->page, index)) pages_.Children().RemoveAt(index);
        }
        auto& state = threads_.at(tab->thread_id);
        state.tabs.erase(std::remove(state.tabs.begin(), state.tabs.end(), tab), state.tabs.end());
        if (state.selected == id) state.selected = state.tabs.empty() ? "" : state.tabs.front()->id;
        if (tab->thread_id == selected_thread_) refresh_tabs();
        schedule_save();
    }
    void navigate(const std::string& url) {
        if (!browser_url_allowed(url)) throw std::invalid_argument("Enter an HTTP or HTTPS address without a username or password");
        const auto tab = active_tab(); if (!tab) {new_tab(url); return;}
        tab->url = url; tab->error.clear();
        if (tab->ready) tab->page.CoreWebView2().Navigate(winrt::to_hstring(url));
        else {create_page(tab); if (tab->page.IsLoaded()) initialize(tab);}
        refresh_navigation(); schedule_save();
    }
    std::vector<BrowserTabSnapshot> tabs(const std::string& thread_id) const {
        std::vector<BrowserTabSnapshot> result;
        if (const auto state = threads_.find(thread_id); state != threads_.end()) for (const auto& tab : state->second.tabs) {
            result.push_back({tab->id, tab->thread_id, tab->url, tab->title, tab->error, tab->private_mode, tab->loading, tab->ready});
        }
        return result;
    }
    std::vector<BrowserDownloadSnapshot> downloads(const std::string& thread_id) const {
        std::vector<BrowserDownloadSnapshot> result;
        for (const auto& item : downloads_) if (item->snapshot.thread_id == thread_id) result.push_back(item->snapshot);
        return result;
    }
    // Explicit offline test path; ordinary browser navigation never accepts data/file/javascript URLs.
    void load_fixture_html(const std::string& tab_id, std::string html) {
        if (!fixture_mode_) throw std::logic_error("Browser fixture content is disabled in ordinary launches");
        const auto tab = find_tab(tab_id); if (!tab) throw std::invalid_argument("Unknown browser tab");
        tab->fixture_html = std::move(html);
        if (tab->ready) {tab->fixture_navigation = true; tab->page.NavigateToString(winrt::to_hstring(tab->fixture_html));}
    }
    void fixture_map_host(const std::string& tab_id,const std::string& host,const std::filesystem::path& directory){
        if(!fixture_mode_||!host.ends_with(".invalid")||host.size()>128||host.empty()||host.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789.-")!=std::string::npos)throw std::logic_error("Virtual browser hosts are limited to owned offline fixtures");const auto tab=find_tab(tab_id);if(!tab||!tab->ready)throw std::logic_error("The owned fixture browser is not ready");ACPFileSystem pin(directory);tab->page.CoreWebView2().SetVirtualHostNameToFolderMapping(winrt::to_hstring(host),pin.root().wstring(),browser_core::CoreWebView2HostResourceAccessKind::DenyCors);
    }
    void close() noexcept {
        if (closed_) return;
        closed_ = true;
        if(library_panel_)library_panel_->close();history_pending_.clear();
        for(auto& [thread,grant]:agent_grants_){grant->valid=false;if(agent_control_changed_)try{agent_control_changed_(thread,false);}catch(...){}}
        try {save_timer_.Stop(); save_state();} catch (...) { }
        for (auto& [id, state] : threads_) {
            (void)id;
            for (const auto& tab : state.tabs) {tab->closed = true; tab->ready = false; tab->loading = false; complete_popup(*tab); complete_agent_dialog(*tab);invalidate_agent_frames(*tab); if (tab->page) try {tab->page.Close();tab->upload_lifetimes.clear();} catch (...) { }}
        }
    }

private:
    friend struct BrowserCredentialBridge;
    struct Tab {
        std::string id, thread_id, url{"about:blank"}, title, error, fixture_html;
        bool private_mode{}, loading{}, ready{}, initializing{}, closed{}, fixture_navigation{}, credential_private{},omit_restore{};
        std::uint64_t navigation_id{},document_generation{};
        browser_controls::WebView2 page{nullptr};
        browser_core::CoreWebView2Environment environment{nullptr};
        browser_core::CoreWebView2NewWindowRequestedEventArgs popup{nullptr};
        winrt::Windows::Foundation::Deferral popup_deferral{nullptr};
        browser_json::JsonObject original{nullptr};
        struct ObservedFrame{browser_tool::Frame frame;std::uint64_t navigation{},document{};};
        std::map<std::string,ObservedFrame> observed_frames;
        browser_tool::PrivateText private_text;
        std::vector<browser_json::JsonObject> console;
        std::vector<browser_core::CoreWebView2DevToolsProtocolEventReceiver> protocol_receivers;
        browser_core::CoreWebView2ScriptDialogOpeningEventArgs agent_dialog{nullptr};
        winrt::Windows::Foundation::Deferral agent_dialog_deferral{nullptr};
        std::vector<std::shared_ptr<void>> upload_lifetimes;
        std::uint64_t agent_download_until{};
        std::optional<std::pair<double,double>> viewport_override;
    };
    struct AgentGrant{std::atomic_bool valid{true},busy{};};
    struct ThreadTabs {std::vector<std::shared_ptr<Tab>> tabs; std::string selected;};
    struct Download {BrowserDownloadSnapshot snapshot; browser_core::CoreWebView2DownloadOperation operation{nullptr};};
    struct Deferral {
        winrt::Windows::Foundation::Deferral value{nullptr};
        ~Deferral(){if (value) try {value.Complete();} catch (...) { }}
    };
    std::filesystem::path profiles_, downloads_directory_;
    bool fixture_mode_{}, isolate_thread_profiles_{}, visible_{}, refreshing_{}, closed_{}, dialog_open_{};
    std::string selected_thread_, private_session_;
    std::unordered_map<std::string, ThreadTabs> threads_;
    std::unordered_map<std::wstring, browser_core::CoreWebView2Environment> environments_;
    std::vector<std::shared_ptr<Download>> downloads_;
    std::vector<std::string> displayed_tabs_;
    browser_json::JsonObject original_state_{nullptr};
    browser_controls::Grid root_{nullptr}, pages_{nullptr};
    browser_controls::ComboBox tab_selector_{nullptr};
    browser_controls::TextBox address_{nullptr};
    browser_controls::TextBlock status_{nullptr};
    browser_controls::Button back_{nullptr}, forward_{nullptr},bookmark_{nullptr};
    browser_controls::ListView download_list_{nullptr};
    browser_controls::Border library_host_{nullptr};std::shared_ptr<BrowserLibraryPanel> library_panel_;std::string library_key_;HWND browser_owner_{};BrowserLibraryPanel::Confirm library_confirm_;
    struct HistoryRecord{std::filesystem::path directory;std::string url,title;std::int64_t at{};std::shared_ptr<browser_library::Store> store;};std::vector<HistoryRecord> history_pending_;bool history_writing_{},library_finishing_{};std::atomic_uint library_operations_{};std::uint64_t bookmark_generation_{};std::map<std::filesystem::path,std::shared_ptr<browser_library::Store>> library_stores_;
    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer save_timer_{nullptr};
    std::function<void()> changed_;
    std::function<void(const std::string&)> navigation_changed_;
    std::map<std::string,std::shared_ptr<AgentGrant>> agent_grants_;
    browser_tool::Queue dispatcher_{nullptr};
    AgentControlCallback agent_control_changed_;ShowCallback show_;
    std::function<std::string(const std::string&)> search_;
    browser_controls::ToggleSwitch agent_toggle_{nullptr};
    browser_tool::Reply request_impl(std::string thread,std::string json,std::filesystem::path artifacts,browser_tool::Cancel cancelled,std::shared_ptr<void> upload_lifetime);
    static void complete_agent_dialog(Tab& tab)noexcept{if(tab.agent_dialog_deferral)try{tab.agent_dialog_deferral.Complete();}catch(...){}tab.agent_dialog_deferral=nullptr;tab.agent_dialog=nullptr;}
    void invalidate_agent_frames(Tab& tab){std::vector<std::string> frames;for(const auto& [id,observed]:tab.observed_frames){(void)observed;frames.push_back(id);}tab.observed_frames.clear();if(navigation_changed_)for(const auto& id:frames)try{navigation_changed_(id);}catch(...) {}}
    void wire_agent_events(const std::shared_ptr<Tab>& tab,const browser_core::CoreWebView2& core);
    void start_agent_download(std::shared_ptr<Tab> tab,browser_core::CoreWebView2DownloadStartingEventArgs args);
    browser_json::JsonObject agent_metadata(const std::shared_ptr<Tab>& tab)const;
    std::shared_ptr<browser_library::Store> library_store(const std::filesystem::path& directory){auto& store=library_stores_[directory];if(!store)store=std::make_shared<browser_library::Store>(directory);return store;}
    void record_history(const std::shared_ptr<Tab>& tab){
        if(closed_||library_finishing_||tab->private_mode||tab->credential_private)return;const auto url=browser_library::address(tab->url);if(url.empty()||tab->private_text.text(url)!=url)return;auto title=tab->title;if(tab->ready)try{title=winrt::to_string(tab->page.CoreWebView2().DocumentTitle());}catch(...){}if(tab->private_text.text(title)!=title||url!=tab->url)title.clear();if(history_pending_.size()>=64)history_pending_.erase(history_pending_.begin());const auto directory=library_directory(tab->thread_id);history_pending_.push_back({directory,url,browser_library::bounded(std::move(title),2000),browser_library::now(),library_store(directory)});drain_history();
    }
    winrt::fire_and_forget refresh_bookmark(){const auto lifetime=shared_from_this();if(closed_||library_finishing_||!bookmark_)co_return;const auto generation=++bookmark_generation_;const auto tab=active_tab();const auto url=tab?browser_library::address(tab->url):std::string{};bookmark_.IsEnabled(!url.empty());bookmark_.Content(winrt::box_value(L"☆"));browser_xaml::Automation::AutomationProperties::SetName(bookmark_,ui_text(L"Bookmark This Page"));if(url.empty())co_return;const auto directory=library_directory(tab->thread_id);const auto store=library_store(directory);++library_operations_;struct Pending{std::atomic_uint& count;~Pending(){--count;}} pending{library_operations_};const winrt::apartment_context ui_thread;bool marked{};co_await winrt::resume_background();try{const auto snapshot=store->open();marked=std::any_of(snapshot.contents.bookmarks.begin(),snapshot.contents.bookmarks.end(),[&](const auto& entry){return entry.url==url;});}catch(...){}try{co_await ui_thread;}catch(...){co_return;}if(closed_||generation!=bookmark_generation_)co_return;bookmark_.Content(winrt::box_value(marked?L"★":L"☆"));browser_xaml::Automation::AutomationProperties::SetName(bookmark_,ui_text(marked?L"Remove Bookmark":L"Bookmark This Page"));}
    winrt::fire_and_forget drain_history(){
        const auto lifetime=shared_from_this();if(history_writing_||closed_)co_return;history_writing_=true;++library_operations_;struct Pending{std::atomic_uint& count;~Pending(){--count;}} pending{library_operations_};const winrt::apartment_context ui_thread;
        while(!closed_&&!history_pending_.empty()){auto records=std::exchange(history_pending_,{});std::string error;co_await winrt::resume_background();try{std::map<std::filesystem::path,std::vector<HistoryRecord>> groups;for(auto& record:records)groups[record.directory].push_back(std::move(record));for(const auto& [directory,items]:groups){static_cast<void>(directory);items.front().store->update([&](auto& contents){for(const auto& row:items)browser_library::Store::visit(contents,row.url,row.title,row.at);});}}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error&){error="Could not save browser history safely.";}try{co_await ui_thread;}catch(...){co_return;}if(closed_)break;if(!error.empty())status_.Text(winrt::to_hstring(error));if(library_panel_&&!library_panel_->busy())library_panel_->refresh();}
        history_writing_=false;
    }
    winrt::fire_and_forget toggle_bookmark(){
        const auto lifetime=shared_from_this();const auto tab=active_tab();if(closed_||library_finishing_||!tab)co_return;const auto url=browser_library::address(tab->url);if(url.empty()||tab->private_text.text(url)!=url){status_.Text(ui_text(L"This address cannot be saved as a bookmark."));co_return;}auto title=tab->title;if(tab->private_text.text(title)!=title||url!=tab->url||tab->credential_private)title.clear();const auto directory=library_directory(tab->thread_id);const auto store=library_store(directory);++library_operations_;struct Pending{std::atomic_uint& count;~Pending(){--count;}} pending{library_operations_};const winrt::apartment_context ui_thread;std::string error;bool removed{};co_await winrt::resume_background();try{store->update([&](auto& contents){removed=std::any_of(contents.bookmarks.begin(),contents.bookmarks.end(),[&](const auto& item){return item.url==url;});if(removed)std::erase_if(contents.bookmarks,[&](const auto& item){return item.url==url;});else browser_library::Store::bookmark(contents,url,title);});}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error&){error="Could not save the browser bookmark safely.";}try{co_await ui_thread;}catch(...){co_return;}if(closed_)co_return;status_.Text(error.empty()?ui_text(removed?L"Bookmark removed.":L"Bookmark saved."):winrt::to_hstring(error));if(library_panel_&&!library_panel_->busy())library_panel_->refresh();refresh_bookmark();
    }


    BrowserPanel(std::filesystem::path profiles, std::filesystem::path downloads, bool fixture, bool isolate_threads)
        : profiles_(std::move(profiles)), downloads_directory_(std::move(downloads)), fixture_mode_(fixture), isolate_thread_profiles_(isolate_threads), private_session_(identity()) {
        if (!profiles_.is_absolute()) throw std::invalid_argument("The browser needs an absolute profile directory");
        if (downloads_directory_.empty()) {
            if (fixture) downloads_directory_ = profiles_ / L"fixture-downloads";
            else {
                PWSTR path{}; winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_Downloads, KF_FLAG_DEFAULT, nullptr, &path));
                downloads_directory_ = std::filesystem::path(path) / L"Coincide"; CoTaskMemFree(path);
            }
        }
        if (!downloads_directory_.is_absolute()) throw std::invalid_argument("The browser needs an absolute download directory");
        std::filesystem::create_directories(profiles_);
    }
    static std::string identity() {winrt::guid value; winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&value))); return winrt::to_string(winrt::to_hstring(value));}
    static void identify(const browser_xaml::DependencyObject& view, const wchar_t* id) {browser_xaml::Automation::AutomationProperties::SetAutomationId(view, id);}
    browser_controls::Button make_button(const wchar_t* text, const wchar_t* id, std::function<void(BrowserPanel&)> action) {
        browser_controls::Button value; value.Content(winrt::box_value(ui_text(text))); identify(value, id);
        value.Click([weak = weak_from_this(), action = std::move(action)](const auto&, const auto&) {
            if (const auto self = weak.lock()) try {action(*self);} catch (const std::exception& error) {self->status_.Text(winrt::to_hstring(error.what()));}
            catch (const winrt::hresult_error& error) {self->status_.Text(error.message());}
        });
        return value;
    }
    void build_view() {
        root_ = browser_controls::Grid{}; dispatcher_=root_.DispatcherQueue(); identify(root_, L"BrowserPanel"); root_.RowSpacing(8);
        for (const auto height : {browser_xaml::GridLength{1, browser_xaml::GridUnitType::Auto},
                browser_xaml::GridLength{1, browser_xaml::GridUnitType::Auto}, browser_xaml::GridLength{1, browser_xaml::GridUnitType::Star},
                browser_xaml::GridLength{1, browser_xaml::GridUnitType::Auto}, browser_xaml::GridLength{1, browser_xaml::GridUnitType::Auto}, browser_xaml::GridLength{1, browser_xaml::GridUnitType::Auto}}) {
            browser_controls::RowDefinition row; row.Height(height); root_.RowDefinitions().Append(row);
        }
        browser_controls::StackPanel tabs_bar;tabs_bar.Spacing(6);browser_controls::Grid tab_row;tab_row.ColumnSpacing(6);for(int column=0;column<3;++column){browser_controls::ColumnDefinition value;value.Width({1,column==0?browser_xaml::GridUnitType::Star:browser_xaml::GridUnitType::Auto});tab_row.ColumnDefinitions().Append(value);}
        tab_selector_ = browser_controls::ComboBox{}; tab_selector_.MinWidth(120);tab_selector_.HorizontalAlignment(browser_xaml::HorizontalAlignment::Stretch); tab_selector_.MaxWidth(420); identify(tab_selector_, L"BrowserTabs");
        tab_selector_.SelectionChanged([weak = weak_from_this()](const auto&, const auto&) {
            if (const auto self = weak.lock(); self && !self->refreshing_) {
                const auto index = self->tab_selector_.SelectedIndex();
                if (index >= 0 && static_cast<std::size_t>(index) < self->displayed_tabs_.size()) {
                    self->threads_.at(self->selected_thread_).selected = self->displayed_tabs_[index]; self->show_active(); self->schedule_save();
                }
            }
        });
        tab_row.Children().Append(tab_selector_);auto close_tab_button=make_button(L"Close Tab",L"BrowserCloseTab",[](auto& self){if(const auto tab=self.active_tab())self.close_tab(tab->id);});browser_controls::Grid::SetColumn(close_tab_button,1);tab_row.Children().Append(close_tab_button);
        agent_toggle_=browser_controls::ToggleSwitch{};agent_toggle_.Header(winrt::box_value(ui_text(L"Agent Control")));identify(agent_toggle_,L"BrowserAgentControl");
        agent_toggle_.Toggled([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock();self&&!self->refreshing_&&!self->selected_thread_.empty())try{self->set_agent_control(self->selected_thread_,self->agent_toggle_.IsOn());}catch(...){const bool refreshing=self->refreshing_;self->refreshing_=true;self->agent_toggle_.IsOn(self->agent_control(self->selected_thread_));self->refreshing_=refreshing;self->status_.Text(ui_text(L"Browser agent control could not be changed."));}});browser_controls::Grid::SetColumn(agent_toggle_,2);tab_row.Children().Append(agent_toggle_);tabs_bar.Children().Append(tab_row);
        browser_controls::StackPanel new_tabs;new_tabs.Orientation(browser_controls::Orientation::Horizontal);new_tabs.Spacing(8);new_tabs.Children().Append(make_button(L"New Tab",L"BrowserNewTab",[](auto& self){self.new_tab();}));new_tabs.Children().Append(make_button(L"New Private Tab",L"BrowserNewPrivateTab",[](auto& self){self.new_tab("about:blank",true);}));tabs_bar.Children().Append(new_tabs);browser_controls::StackPanel library_actions;library_actions.Orientation(browser_controls::Orientation::Horizontal);library_actions.Spacing(8);bookmark_=make_button(L"☆",L"BrowserBookmark",[](auto& self){self.toggle_bookmark();});browser_xaml::Automation::AutomationProperties::SetName(bookmark_,ui_text(L"Bookmark This Page"));library_actions.Children().Append(bookmark_);library_actions.Children().Append(make_button(L"Bookmarks and History",L"BrowserLibrary",[](auto& self){self.show_library(!self.library_host_||self.library_host_.Visibility()!=browser_xaml::Visibility::Visible);}));tabs_bar.Children().Append(library_actions);
        root_.Children().Append(tabs_bar);
        browser_controls::Grid navigation; navigation.ColumnSpacing(6);
        for (int i = 0; i < 5; ++i) {browser_controls::ColumnDefinition column; column.Width({1, i == 3 ? browser_xaml::GridUnitType::Star : browser_xaml::GridUnitType::Auto}); navigation.ColumnDefinitions().Append(column);}
        back_ = make_button(L"Back", L"BrowserBack", [](auto& self){if (const auto tab = self.active_tab(); tab && tab->ready && tab->page.CanGoBack()) tab->page.GoBack();});
        forward_ = make_button(L"Forward", L"BrowserForward", [](auto& self){if (const auto tab = self.active_tab(); tab && tab->ready && tab->page.CanGoForward()) tab->page.GoForward();});
        auto reload = make_button(L"Reload", L"BrowserReload", [](auto& self){if (const auto tab = self.active_tab()) {if (tab->ready) tab->page.Reload(); else if (tab->page.IsLoaded()) self.initialize(tab);}});
        address_ = browser_controls::TextBox{}; address_.PlaceholderText(ui_text(L"Enter URL")); identify(address_, L"BrowserAddress");
        address_.KeyDown([weak = weak_from_this()](const auto&, const browser_xaml::Input::KeyRoutedEventArgs& args) {
            if (args.Key() == winrt::Windows::System::VirtualKey::Enter) {
                args.Handled(true); if (const auto self = weak.lock()) try {self->navigate(winrt::to_string(self->address_.Text()));} catch (...) {self->status_.Text(ui_text(L"Enter an HTTP or HTTPS address without a username or password."));}
            }
        });
        auto go = make_button(L"Go", L"BrowserGo", [](auto& self){self.navigate(winrt::to_string(self.address_.Text()));});
        const std::array<browser_xaml::FrameworkElement, 5> controls{back_, forward_, reload, address_, go};
        for (std::size_t i = 0; i < controls.size(); ++i) {browser_controls::Grid::SetColumn(controls[i], static_cast<int>(i)); navigation.Children().Append(controls[i]);}
        browser_controls::Grid::SetRow(navigation, 1); root_.Children().Append(navigation);
        pages_ = browser_controls::Grid{}; pages_.MinHeight(250); browser_controls::Grid::SetRow(pages_, 2); root_.Children().Append(pages_);
        status_ = browser_controls::TextBlock{}; status_.TextWrapping(browser_xaml::TextWrapping::Wrap); identify(status_, L"BrowserStatus"); browser_controls::Grid::SetRow(status_, 3); root_.Children().Append(status_);
        download_list_ = browser_controls::ListView{}; download_list_.MaxHeight(120); identify(download_list_, L"BrowserDownloads"); browser_controls::Grid::SetRow(download_list_, 4); root_.Children().Append(download_list_);
        library_host_=browser_controls::Border{};library_host_.MaxHeight(320);library_host_.Visibility(browser_xaml::Visibility::Collapsed);identify(library_host_,L"BrowserLibraryHost");browser_controls::Grid::SetRow(library_host_,5);root_.Children().Append(library_host_);
        save_timer_ = root_.DispatcherQueue().CreateTimer(); save_timer_.IsRepeating(false); save_timer_.Interval(std::chrono::milliseconds(400));
        save_timer_.Tick([weak = weak_from_this()](const auto&, const auto&) {if (const auto self = weak.lock()) try {self->save_state();} catch (...) {self->status_.Text(ui_text(L"Could not save browser tabs."));}});
        set_visible(false); refresh_navigation();
    }
    std::shared_ptr<Tab> active_tab() const {
        const auto state = threads_.find(selected_thread_); return state == threads_.end() ? nullptr : find_tab(state->second.selected);
    }
    std::shared_ptr<Tab> find_tab(const std::string& id) const {
        for (const auto& [thread, state] : threads_) {(void)thread; for (const auto& tab : state.tabs) if (tab->id == id) return tab;}
        return nullptr;
    }
    std::shared_ptr<Tab> add_tab(const std::string& thread, std::string url, bool private_mode, bool activate,
            browser_core::CoreWebView2Environment environment = nullptr) {
        if (closed_ || !browser_thread_id_allowed(thread) || !browser_url_allowed(url)) throw std::invalid_argument("Choose a browser conversation and an HTTP or HTTPS address");
        auto& state = threads_[thread]; if (state.tabs.size() >= 20) throw std::runtime_error("This conversation already has 20 browser tabs");
        auto tab = std::make_shared<Tab>(); tab->id = identity(); tab->thread_id = thread; tab->url = std::move(url); tab->private_mode = private_mode;
        tab->environment = std::move(environment);
        state.tabs.push_back(tab); if (activate || state.selected.empty()) state.selected = tab->id;
        create_page(tab); if (thread == selected_thread_) refresh_tabs(); schedule_save(); return tab;
    }
    void create_page(const std::shared_ptr<Tab>& tab) {
        if (tab->page || tab->closed) return;
        tab->page = browser_controls::WebView2{}; identify(tab->page, L"BrowserPage"); tab->page.Visibility(browser_xaml::Visibility::Collapsed);
        tab->page.Loaded([weak = weak_from_this(), item = std::weak_ptr<Tab>(tab)](const auto&, const auto&) {if (const auto self = weak.lock()) if (const auto value = item.lock()) self->initialize(value);});
        pages_.Children().Append(tab->page); if (tab->page.IsLoaded()) initialize(tab);
    }
    winrt::fire_and_forget initialize(std::shared_ptr<Tab> tab) {
        auto lifetime = shared_from_this();
        if (closed_ || tab->closed || tab->initializing || tab->ready) co_return;
        tab->initializing = true; tab->loading = true; refresh_navigation();
        try {
            browser_core::CoreWebView2EnvironmentOptions options; options.AllowSingleSignOnUsingOSPrimaryAccount(false);
            if (fixture_mode_) options.AdditionalBrowserArguments(L"--disable-background-networking --disable-component-update --disable-sync --no-first-run");
            // The selected browser profile owns sign-ins; conversations own tabs and access only.
            // Explicit thread isolation is optional. Private tabs still use a verified InPrivate controller.
            const auto directory = profiles_ / L"profiles" / (isolate_thread_profiles_ ? winrt::to_hstring(tab->thread_id) : winrt::hstring(L"Default")).c_str();
            std::filesystem::create_directories(directory);
            if (!tab->environment) {
                if (const auto existing = environments_.find(directory.wstring()); existing != environments_.end()) tab->environment = existing->second;
                else {
                    tab->environment = co_await browser_core::CoreWebView2Environment::CreateWithOptionsAsync(L"", directory.wstring(), options);
                    environments_.try_emplace(directory.wstring(), tab->environment);
                }
            }
            if (closed_ || tab->closed) co_return;
            auto controller = tab->environment.CreateCoreWebView2ControllerOptions();
            if (tab->private_mode) controller.ProfileName(browser_private_profile_name(private_session_)); else controller.ProfileName(L"Default");
            controller.IsInPrivateModeEnabled(tab->private_mode);
            co_await tab->page.EnsureCoreWebView2Async(tab->environment, controller);
            if (closed_ || tab->closed) co_return;
            const auto core = tab->page.CoreWebView2();
            if (core.Profile().IsInPrivateModeEnabled() != tab->private_mode) throw std::runtime_error("The browser did not create the requested private profile");
            const auto settings = core.Settings(); settings.AreDefaultScriptDialogsEnabled(false); settings.IsPasswordAutosaveEnabled(false);
            settings.IsGeneralAutofillEnabled(false); settings.IsWebMessageEnabled(false);
            wire_events(tab, core); wire_agent_events(tab,core); tab->ready = true; tab->loading = false; tab->initializing = false;
            if (tab->popup) {tab->popup.NewWindow(core); complete_popup(*tab);}
            else if (!tab->fixture_html.empty()) {tab->fixture_navigation = true; tab->page.NavigateToString(winrt::to_hstring(tab->fixture_html));}
            else core.Navigate(winrt::to_hstring(tab->url));
        } catch (const winrt::hresult_error& error) {tab->error = winrt::to_string(error.message()); tab->loading = false; tab->initializing = false; complete_popup(*tab);}
          catch (const std::exception& error) {tab->error = error.what(); tab->loading = false; tab->initializing = false; complete_popup(*tab);}
        try{if(!closed_&&dispatcher_.HasThreadAccess()){refresh_tabs();notify();}}catch(...){}
    }
    void wire_events(const std::shared_ptr<Tab>& tab, const browser_core::CoreWebView2& core) {
        const auto weak = weak_from_this(); const auto item = std::weak_ptr<Tab>(tab);
        core.NavigationStarting([weak, item](const auto&, const browser_core::CoreWebView2NavigationStartingEventArgs& args) {
            if (const auto self = weak.lock()) if (const auto value = item.lock()) {
                const auto uri = winrt::to_string(args.Uri());
                const bool inline_fixture = self->fixture_mode_ && value->fixture_navigation
                    && (uri.empty() || uri.starts_with("about:blank") || uri.starts_with("data:text/html"));
                value->fixture_navigation = false;
                if (!browser_url_allowed(uri) && !inline_fixture) {
                    args.Cancel(true); value->error = winrt::to_string(ui_text(L"This navigation is blocked."));
                    if (self->fixture_mode_) {const auto colon = uri.find(':'); value->error += " (scheme=" + (colon != std::string::npos && colon < 16 ? uri.substr(0, colon) : "none") + ", length=" + std::to_string(uri.size()) + ")";}
                } else {self->complete_agent_dialog(*value);self->invalidate_agent_frames(*value);value->navigation_id = args.NavigationId(); value->loading = true;value->omit_restore=false; value->error.clear(); value->url = inline_fixture ? "about:blank" : uri;}
                self->refresh_navigation(); self->notify();
            }
        });
        core.NavigationCompleted([weak, item](const auto&, const browser_core::CoreWebView2NavigationCompletedEventArgs& args) {
            if (const auto self = weak.lock()) if (const auto value = item.lock()) {
                if (args.NavigationId() != value->navigation_id) return;
                value->loading = false; value->upload_lifetimes.clear(); if (!args.IsSuccess() && value->error.empty()) value->error = winrt::to_string(ui_text(L"Navigation failed."));
                if(args.IsSuccess())self->record_history(value);
                self->refresh_bookmark();
                self->refresh_navigation(); self->schedule_save(); self->notify();
            }
        });
        core.SourceChanged([weak, item](const auto& sender, const auto&) {if (const auto self = weak.lock()) if (const auto value = item.lock()) {const auto source = winrt::to_string(sender.Source()); value->url = self->fixture_mode_ && !value->fixture_html.empty() && source.starts_with("data:text/html") ? "about:blank" : source; self->refresh_navigation(); self->schedule_save();}});
        core.DocumentTitleChanged([weak, item](const auto& sender, const auto&) {if (const auto self = weak.lock()) if (const auto value = item.lock()) {value->title = winrt::to_string(sender.DocumentTitle()); if (value->thread_id == self->selected_thread_) self->refresh_tabs(); self->notify();}});
        core.HistoryChanged([weak](const auto&, const auto&) {if (const auto self = weak.lock()) self->refresh_navigation();});
        core.NewWindowRequested([weak, item](const auto&, const browser_core::CoreWebView2NewWindowRequestedEventArgs& args) {
            args.Handled(true);
            if (const auto self = weak.lock()) if (const auto value = item.lock()) {
                if (!args.IsUserInitiated() || !browser_url_allowed(winrt::to_string(args.Uri()))) return;
                try {
                    auto opened = self->add_tab(value->thread_id, "about:blank", value->private_mode, true, value->environment);
                    opened->popup = args; opened->popup_deferral = args.GetDeferral();
                    if (opened->ready) {args.NewWindow(opened->page.CoreWebView2()); complete_popup(*opened);}
                } catch (...) { }
            }
        });
        core.PermissionRequested([weak, item](const auto&, const browser_core::CoreWebView2PermissionRequestedEventArgs& args) {
            args.State(browser_core::CoreWebView2PermissionState::Deny); args.Handled(true); args.SavesInProfile(false);
            if (const auto self = weak.lock()) if (const auto value = item.lock()) if (args.IsUserInitiated() && !permission_name(args.PermissionKind()).empty() && self->can_prompt(value)) self->permission(value, args);
        });
        core.ScriptDialogOpening([weak, item](const auto&, const browser_core::CoreWebView2ScriptDialogOpeningEventArgs& args) {if (const auto self = weak.lock()) if (const auto value = item.lock()) {if(self->agent_control(value->thread_id)){complete_agent_dialog(*value);value->agent_dialog=args;value->agent_dialog_deferral=args.GetDeferral();self->notify();}else if (self->can_prompt(value)) self->script_dialog(value, args);}});
        core.BasicAuthenticationRequested([weak, item](const auto&, const browser_core::CoreWebView2BasicAuthenticationRequestedEventArgs& args) {args.Cancel(true); if (const auto self = weak.lock()) if (const auto value = item.lock()) if (self->can_prompt(value)) self->basic_auth(value, args);});
        core.ServerCertificateErrorDetected([](const auto&, const browser_core::CoreWebView2ServerCertificateErrorDetectedEventArgs& args) {args.Action(browser_core::CoreWebView2ServerCertificateErrorAction::Cancel);});
        core.LaunchingExternalUriScheme([](const auto&, const browser_core::CoreWebView2LaunchingExternalUriSchemeEventArgs& args) {args.Cancel(true);});
        core.DownloadStarting([weak, item](const auto&, const browser_core::CoreWebView2DownloadStartingEventArgs& args) {
            args.Cancel(true); args.Handled(true);
            if (const auto self = weak.lock()) if (const auto value = item.lock()) {if(self->agent_control(value->thread_id)&&GetTickCount64()<value->agent_download_until)self->start_agent_download(value,args);else if (self->can_prompt(value)) self->download(value, args);}
        });
        core.ProcessFailed([weak, item](const auto&, const auto&) {if (const auto self = weak.lock()) if (const auto value = item.lock()) {value->ready = false; value->loading = false; value->error = winrt::to_string(ui_text(L"The browser process stopped.")); self->refresh_navigation(); self->notify();}});
    }
    static void complete_popup(Tab& tab) noexcept {if (tab.popup_deferral) try {tab.popup_deferral.Complete();} catch (...) { } tab.popup_deferral = nullptr; tab.popup = nullptr;}
    bool can_prompt(const std::shared_ptr<Tab>& tab) const {return !fixture_mode_ && !closed_ && !tab->closed && visible_ && root_.IsLoaded() && root_.XamlRoot() && active_tab() == tab && !dialog_open_;}
    browser_controls::ContentDialog consent_dialog(const wchar_t* title, const wchar_t* confirm) {
        browser_controls::ContentDialog dialog; dialog.XamlRoot(root_.XamlRoot()); dialog.Title(winrt::box_value(ui_text(title)));
        dialog.PrimaryButtonText(ui_text(confirm)); dialog.CloseButtonText(ui_text(L"Cancel")); dialog.DefaultButton(browser_controls::ContentDialogButton::Close); return dialog;
    }
    static winrt::hstring permission_name(browser_core::CoreWebView2PermissionKind kind) {
        using Kind = browser_core::CoreWebView2PermissionKind;
        switch (kind) {
        case Kind::Microphone: return ui_text(L"Microphone");
        case Kind::Camera: return ui_text(L"Camera");
        case Kind::Geolocation: return ui_text(L"Location");
        case Kind::Notifications: return ui_text(L"Notifications");
        case Kind::OtherSensors: return ui_text(L"Sensors");
        case Kind::ClipboardRead: return ui_text(L"Read Clipboard");
        case Kind::MultipleAutomaticDownloads: return ui_text(L"Multiple Downloads");
        case Kind::FileReadWrite: return ui_text(L"Read and Write Files");
        case Kind::Autoplay: return ui_text(L"Autoplay");
        case Kind::LocalFonts: return ui_text(L"Local Fonts");
        case Kind::MidiSystemExclusiveMessages: return ui_text(L"MIDI Devices");
        case Kind::WindowManagement: return ui_text(L"Window Management");
        default: return {};
        }
    }
    winrt::fire_and_forget permission(std::shared_ptr<Tab> tab, browser_core::CoreWebView2PermissionRequestedEventArgs args) {
        auto lifetime = shared_from_this(); Deferral done{args.GetDeferral()}; dialog_open_ = true;
        try {
            auto dialog = consent_dialog(L"Website permission", L"Allow");
            browser_controls::TextBlock text; text.TextWrapping(browser_xaml::TextWrapping::Wrap);
            const winrt::Windows::Foundation::Uri uri{args.Uri()}; text.Text(browser_origin(uri) + L"\n" + permission_name(args.PermissionKind()));
            dialog.Content(text);
            if (co_await dialog.ShowAsync() == browser_controls::ContentDialogResult::Primary && !closed_ && !tab->closed) args.State(browser_core::CoreWebView2PermissionState::Allow);
        } catch (...) { }
        dialog_open_ = false;
    }
    winrt::fire_and_forget script_dialog(std::shared_ptr<Tab> tab, browser_core::CoreWebView2ScriptDialogOpeningEventArgs args) {
        auto lifetime = shared_from_this(); Deferral done{args.GetDeferral()}; dialog_open_ = true;
        try {
            auto dialog = consent_dialog(L"Website dialog", L"Confirm"); browser_controls::StackPanel body; body.Spacing(8);
            browser_controls::TextBlock origin; const winrt::Windows::Foundation::Uri uri{args.Uri()}; origin.Text(browser_origin(uri)); body.Children().Append(origin);
            browser_controls::TextBlock message; message.Text(args.Message()); message.TextWrapping(browser_xaml::TextWrapping::Wrap); body.Children().Append(message);
            browser_controls::TextBox answer;
            if (args.Kind() == browser_core::CoreWebView2ScriptDialogKind::Prompt) {answer.Text(args.DefaultText()); body.Children().Append(answer);}
            dialog.Content(body);
            if (co_await dialog.ShowAsync() == browser_controls::ContentDialogResult::Primary && !closed_ && !tab->closed) {
                if (args.Kind() == browser_core::CoreWebView2ScriptDialogKind::Prompt) args.ResultText(answer.Text()); args.Accept();
            }
        } catch (...) { }
        dialog_open_ = false;
    }
    winrt::fire_and_forget basic_auth(std::shared_ptr<Tab> tab, browser_core::CoreWebView2BasicAuthenticationRequestedEventArgs args) {
        auto lifetime = shared_from_this(); Deferral done{args.GetDeferral()}; dialog_open_ = true;
        browser_controls::PasswordBox password;
        try {
            auto dialog = consent_dialog(L"Website sign-in", L"Sign In"); browser_controls::StackPanel body; body.Spacing(8);
            browser_controls::TextBlock origin; origin.Text(winrt::Windows::Foundation::Uri(args.Uri()).Host()); body.Children().Append(origin);
            browser_controls::TextBox username; username.PlaceholderText(ui_text(L"Username")); body.Children().Append(username);
            password.PlaceholderText(ui_text(L"Password")); body.Children().Append(password); dialog.Content(body);
            if (co_await dialog.ShowAsync() == browser_controls::ContentDialogResult::Primary && !closed_ && !tab->closed) {args.Response().UserName(username.Text()); args.Response().Password(password.Password()); args.Cancel(false);}
        } catch (...) { }
        password.Password(L""); dialog_open_ = false;
    }
    winrt::fire_and_forget download(std::shared_ptr<Tab> tab, browser_core::CoreWebView2DownloadStartingEventArgs args) {
        auto lifetime = shared_from_this(); Deferral done{args.GetDeferral()}; dialog_open_ = true;
        try {
            const auto name = browser_download_name(std::wstring(args.ResultFilePath()));
            auto dialog = consent_dialog(L"Download file", L"Download"); dialog.Content(winrt::box_value(winrt::hstring(name)));
            if (co_await dialog.ShowAsync() == browser_controls::ContentDialogResult::Primary && !closed_ && !tab->closed) {
                auto item = std::make_shared<Download>(); item->snapshot.id = identity(); item->snapshot.thread_id = tab->thread_id;
                item->snapshot.name = winrt::to_string(name); item->snapshot.state = winrt::to_string(ui_text(L"Downloading…"));
                const auto directory = downloads_directory_ / winrt::to_hstring(item->snapshot.id).c_str();
                std::filesystem::create_directories(downloads_directory_);
                if (!std::filesystem::create_directory(directory)) throw std::runtime_error("The unique download folder already exists");
                const auto destination = directory / name;
                args.ResultFilePath(destination.wstring()); item->snapshot.path = winrt::to_string(destination.wstring());
                item->operation = args.DownloadOperation(); downloads_.push_back(item); args.Cancel(false);
                const auto weak = weak_from_this(); const auto record = std::weak_ptr<Download>(item);
                const auto update = [weak, record](const auto&, const auto&) {if (const auto self = weak.lock()) if (const auto value = record.lock()) self->update_download(value);};
                item->operation.BytesReceivedChanged(update); item->operation.StateChanged(update); update_download(item);
            }
        } catch (...) { }
        dialog_open_ = false;
    }
    void update_download(const std::shared_ptr<Download>& item) {
        item->snapshot.received = static_cast<std::uint64_t>(std::max<std::int64_t>(0, item->operation.BytesReceived()));
        item->snapshot.total = static_cast<std::uint64_t>(std::max<std::int64_t>(0, item->operation.TotalBytesToReceive()));
        const auto state = item->operation.State();
        item->snapshot.state = winrt::to_string(ui_text(state == browser_core::CoreWebView2DownloadState::Completed ? L"Finished" : state == browser_core::CoreWebView2DownloadState::Interrupted ? L"Interrupted" : L"Downloading…"));
        refresh_downloads(); notify();
    }
    void refresh_tabs() {
        if (!tab_selector_ || refreshing_) return;
        refreshing_ = true; agent_toggle_.IsOn(agent_control(selected_thread_)); tab_selector_.Items().Clear(); displayed_tabs_.clear();
        if (const auto state = threads_.find(selected_thread_); state != threads_.end()) {
            for (const auto& tab : state->second.tabs) {
                browser_controls::ComboBoxItem entry; auto text = tab->title.empty() ? ui_text(L"New Tab") : winrt::to_hstring(tab->title);
                if (tab->private_mode) text = ui_text(L"Private") + L" · " + text;
                entry.Content(winrt::box_value(text)); tab_selector_.Items().Append(entry); displayed_tabs_.push_back(tab->id);
                if (state->second.selected == tab->id) tab_selector_.SelectedIndex(static_cast<int>(displayed_tabs_.size() - 1));
            }
        }
        refreshing_ = false; show_active();
    }
    void show_active() {
        const auto active = active_tab();
        for (const auto& [id, state] : threads_) {(void)id; for (const auto& tab : state.tabs) if (tab->page) tab->page.Visibility(tab == active ? browser_xaml::Visibility::Visible : browser_xaml::Visibility::Collapsed);}
        address_.Text(active ? winrt::to_hstring(active->url) : L"");
        refresh_navigation(); refresh_downloads();refresh_bookmark();
    }
    void refresh_navigation() {
        if (!status_) return;
        const auto tab = active_tab(); back_.IsEnabled(tab && tab->ready && tab->page.CanGoBack()); forward_.IsEnabled(tab && tab->ready && tab->page.CanGoForward());
        if (!tab) {status_.Text(ui_text(L"Open a browser tab to begin.")); return;}
        if (address_.FocusState() == browser_xaml::FocusState::Unfocused) address_.Text(winrt::to_hstring(tab->url));
        status_.Text(!tab->error.empty() ? winrt::to_hstring(tab->error) : tab->loading ? ui_text(L"Loading…") : tab->private_mode ? ui_text(L"Private") : ui_text(L"Ready"));
    }
    void refresh_downloads() {
        if (!download_list_) return;
        download_list_.Items().Clear();
        for (const auto& item : downloads_) if (item->snapshot.thread_id == selected_thread_) {
            browser_controls::ListViewItem entry; const auto& value = item->snapshot;
            entry.Content(winrt::box_value(winrt::to_hstring(value.name + " · " + value.state + " · " + std::to_string(value.received) + "/" + std::to_string(value.total))));
            download_list_.Items().Append(entry);
        }
    }
    void notify() {if (!closed_ && changed_) try {changed_();} catch (...) { }}
    void schedule_save() {if (!closed_ && save_timer_) {save_timer_.Stop(); save_timer_.Start();}}
    void load_state() {
        const auto path = profiles_ / L"tabs.json";
        if (!std::filesystem::exists(path)) return;
        if (std::filesystem::file_size(path) > 1024 * 1024) throw std::runtime_error("Browser tab data exceeds the read limit; it was left unchanged");
        std::ifstream stream(path, std::ios::binary); if (!stream) throw std::runtime_error("Cannot read browser tab data; it was left unchanged");
        const std::string text(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>{}); original_state_ = browser_json::JsonObject::Parse(winrt::to_hstring(text));
        if (original_state_.GetNamedNumber(L"version", 0) != 1) throw std::runtime_error("Unsupported browser tab data; it was left unchanged");
        for (const auto& raw : original_state_.GetNamedArray(L"tabs")) {
            const auto item = raw.GetObject(); const auto thread = winrt::to_string(item.GetNamedString(L"thread"));
            if (item.GetNamedBoolean(L"private", false)) throw std::runtime_error("Private tabs cannot be restored from persistent tab data");
            const auto id = winrt::to_string(item.GetNamedString(L"id"));
            if (!browser_thread_id_allowed(thread) || !browser_thread_id_allowed(id) || threads_[thread].tabs.size() >= 20 || find_tab(id)) throw std::runtime_error("Invalid browser tab identities; existing data was left unchanged");
            auto tab = std::make_shared<Tab>(); tab->id = id; tab->thread_id = thread; tab->url = browser_restore_url(winrt::to_string(item.GetNamedString(L"url", L"about:blank"))); tab->original = item;
            threads_[thread].tabs.push_back(tab); if (item.GetNamedBoolean(L"selected", false)) threads_[thread].selected = id;
        }
    }
    void save_state() {
        auto state = original_state_ ? original_state_ : browser_json::JsonObject{}; state.SetNamedValue(L"version", browser_json::JsonValue::CreateNumberValue(1));
        browser_json::JsonArray tabs;
        for (const auto& [thread, value] : threads_) for (const auto& tab : value.tabs) if (!tab->private_mode && !tab->closed) {
            auto item = tab->original ? tab->original : browser_json::JsonObject{};
            item.SetNamedValue(L"thread", browser_json::JsonValue::CreateStringValue(winrt::to_hstring(thread))); item.SetNamedValue(L"id", browser_json::JsonValue::CreateStringValue(winrt::to_hstring(tab->id)));
            auto restored=browser_restore_url(tab->url);if(tab->omit_restore||tab->private_text.text(restored)!=restored)restored="about:blank";item.SetNamedValue(L"url", browser_json::JsonValue::CreateStringValue(winrt::to_hstring(restored))); item.SetNamedValue(L"selected", browser_json::JsonValue::CreateBooleanValue(value.selected == tab->id)); tabs.Append(item);
        }
        state.SetNamedValue(L"tabs", tabs); const auto bytes = winrt::to_string(state.Stringify());
        if (bytes.size() > 1024 * 1024) throw std::runtime_error("Browser tabs exceed the save limit; existing data was left unchanged");
        const auto temporary = profiles_ / winrt::to_hstring("tabs-" + identity() + ".tmp").c_str();
        HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) winrt::throw_last_error();
        DWORD written{}; const auto ok = bytes.size() <= MAXDWORD && WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) && written == bytes.size() && FlushFileBuffers(file);
        const auto error = GetLastError(); CloseHandle(file);
        if (!ok) {DeleteFileW(temporary.c_str()); throw winrt::hresult_error(HRESULT_FROM_WIN32(error ? error : ERROR_WRITE_FAULT));}
        if (!MoveFileExW(temporary.c_str(), (profiles_ / L"tabs.json").c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {const auto move_error = GetLastError(); DeleteFileW(temporary.c_str()); throw winrt::hresult_error(HRESULT_FROM_WIN32(move_error));}
        original_state_ = state;
    }
};
} // namespace coincide
#include "BrowserToolRequests.h"
#include "BrowserCredentialBridge.h"
