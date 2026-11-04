#pragma once
#include "../App/ProviderAccountsPanel.h"
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>

namespace coincide {
namespace account_panel_fixture {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline void pump(){MSG message{};for(unsigned i=0;i<512&&PeekMessageW(&message,nullptr,0,0,PM_REMOVE);++i){if(message.message==WM_QUIT){PostQuitMessage(static_cast<int>(message.wParam));break;}TranslateMessage(&message);DispatchMessageW(&message);}}
template<class Predicate>bool until(Predicate predicate){const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(5);while(!predicate()&&std::chrono::steady_clock::now()<end){pump();std::this_thread::sleep_for(std::chrono::milliseconds(1));}pump();return predicate();}
inline xaml::DependencyObject find(const xaml::DependencyObject& root,const wchar_t* id){if(!root)return nullptr;if(xaml::Automation::AutomationProperties::GetAutomationId(root)==id)return root;if(const auto panel=root.try_as<ui::Panel>())for(const auto& child:panel.Children())if(const auto result=find(child,id))return result;return nullptr;}
template<class T>T control(const xaml::DependencyObject& root,const wchar_t* id){const auto value=find(root,id);if(!value)throw std::runtime_error("Missing native account panel control");return value.as<T>();}
inline void invoke(const xaml::DependencyObject& root,const wchar_t* id){const xaml::Automation::Peers::ButtonAutomationPeer peer(control<ui::Button>(root,id));peer.GetPattern(xaml::Automation::Peers::PatternInterface::Invoke).as<xaml::Automation::Provider::IInvokeProvider>().Invoke();pump();}
}

inline int provider_accounts_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace fixture=account_panel_fixture;namespace ui=fixture::ui;
    int checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    const auto folder=std::filesystem::temp_directory_path()/(L"Coincide account panel fixture "+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    ui::Panel host{nullptr};std::shared_ptr<ProviderAccountsPanel> panel;std::vector<ProviderAccountMetadata> updates;std::vector<std::string> urls;std::vector<std::pair<std::string,std::string>> used;std::wstring mode=L"normal";bool installed=true,compatible=true;
    wchar_t executable[32768]{};GetModuleFileNameW(nullptr,executable,32768);
    const auto detach=[&]{if(panel){panel->close();if(host){std::uint32_t index{};if(host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);}panel.reset();}fixture::pump();};
    const auto use_callback=[&](const ProviderAccountRecord& record,const ProviderAccountMetadata& metadata){used.emplace_back(record.id,metadata.scope);};const auto use_compatible=[&](const ProviderAccountRecord&,const ProviderAccountMetadata&){return compatible;};
    const auto mount=[&](bool browser=true){detach();panel=ProviderAccountsPanel::create(folder,[&](const std::string& provider)->std::optional<ProviderAccountProgram>{if(!installed)return{};return ProviderAccountProgram{provider,executable,{L"--provider-account-fixture",mode,ACPFileSystem::wide(provider)}};},[&](const ProviderAccountRecord&,const ProviderAccountMetadata& value){updates.push_back(value);},browser?ProviderAccountsPanel::Browser([&](const std::string& url){urls.push_back(url);}):ProviderAccountsPanel::Browser{});panel->set_use_profile(use_callback,use_compatible);host.Children().Append(panel->view());panel->view().Measure({850,650});panel->view().Arrange({0,0,850,650});panel->view().UpdateLayout();fixture::pump();};
    const auto edit=[&](const wchar_t* id,const wchar_t* text){fixture::control<ui::TextBox>(panel->view(),id).Text(text);};
    const auto enabled=[&](const wchar_t* id){return fixture::control<ui::Button>(panel->view(),id).IsEnabled();};
    try {
        host=xaml_root.Content().as<ui::Panel>();mount();check(panel->records().empty()&&!std::filesystem::exists(folder)&&updates.empty()&&urls.empty(),"Opening account settings must not create a profile, run a CLI or open a browser");
        check(!enabled(L"CheckProviderAccount")&&!enabled(L"SignInProviderAccount")&&!enabled(L"CancelProviderAccount"),"Empty account selection must disable authentication actions");
        check(!enabled(L"UseProviderProfile")&&!panel->selected_record()&&used.empty(),"No current verified account means the native Use profile action must stay disabled");
        fixture::invoke(panel->view(),L"AddProviderProfile");check(panel->records().empty()&&!std::filesystem::exists(folder),"An empty profile label must not create or sign in to an account");
        edit(L"AccountProfileLabel",L"Native Cursor fixture");fixture::invoke(panel->view(),L"AddProviderProfile");check(panel->records().size()==1&&enabled(L"CheckProviderAccount")&&enabled(L"SignInProviderAccount")&&updates.empty()&&urls.empty(),"Adding a local profile must enable explicit actions without starting authentication");
        const auto cursor_id=panel->records()[0].id;fixture::invoke(panel->view(),L"CheckProviderAccount");check(fixture::until([&]{return !panel->busy();})&&updates.size()==1&&updates.back().state==ProviderAccountState::signed_out&&urls.empty(),"Native Check status must run the bounded worker and report signed out without a browser");
        fixture::invoke(panel->view(),L"SignInProviderAccount");check(fixture::until([&]{return !panel->busy();})&&updates.size()==2&&updates.back().state==ProviderAccountState::verified,"Only an explicit native Sign in action may start the synthetic official-flow contract and verify its resulting profile");
        check(urls==std::vector<std::string>{"https://cursor.com/login?state=fixture"},"The panel must dispatch only the sanitized provider verification URL to root's browser callback");
        check(enabled(L"UseProviderProfile")&&panel->selected_record()->id==cursor_id,"Only a freshly verified selected account may enable Use profile");
        fixture::invoke(panel->view(),L"UseProviderProfile");check(used==std::vector<std::pair<std::string,std::string>>{{cursor_id,updates.back().scope}}&&updates.size()==2&&urls.size()==1,"Explicit Use profile must return its exact verified account without starting another CLI or browser flow");
        compatible=false;panel->set_use_profile(use_callback,use_compatible);panel->use_profile();check(!enabled(L"UseProviderProfile")&&used.size()==1,"An incompatible native conversation binding must disable profile adoption even when authentication is verified");compatible=true;panel->set_use_profile(use_callback,use_compatible);
        mode=L"other";panel->use_profile();check(!enabled(L"UseProviderProfile")&&used.size()==1,"Changing the provider launch program must invalidate the old metadata without automatically probing it");mode=L"normal";panel->set_use_profile(use_callback,use_compatible);
        ProviderAccountStore store(folder);const auto records=store.open();check(records.size()==1&&!records[0].last_scope.empty()&&records[0].identity_source=="cursor-status-getMe","The panel must persist nonsecret routing provenance after successful verification");
        const auto credential=store.profile(records[0])/L"Cursor/auth.json";std::ofstream(credential,std::ios::app)<<"synthetic external credential refresh";panel->use_profile();check(!enabled(L"UseProviderProfile")&&used.size()==1,"Credential changes between button enablement and click must refuse stale profile adoption");
        fixture::invoke(panel->view(),L"CheckProviderAccount");check(fixture::until([&]{return !panel->busy();})&&enabled(L"UseProviderProfile"),"A fresh explicit account check may restore Use profile after same-account credential refresh");
        const auto update_count=updates.size(),url_count=urls.size();mount();check(panel->records().size()==1&&updates.size()==update_count&&urls.size()==url_count,"Reopening a profile must not authenticate or reuse historical verification as current");
        check(!enabled(L"UseProviderProfile")&&used.size()==1,"Historical saved account metadata must not enable Use profile when reopening settings");
        fixture::control<ui::ComboBox>(panel->view(),L"AccountProvider").SelectedIndex(2);edit(L"AccountProfileLabel",L"Risk-gated fixture");fixture::invoke(panel->view(),L"AddProviderProfile");check(!enabled(L"CheckProviderAccount")&&!enabled(L"SignInProviderAccount")&&urls.size()==url_count,"An unvalidated Antigravity risk/browser flow must remain disabled in native account settings");
        installed=false;panel->select(cursor_id);check(!enabled(L"CheckProviderAccount")&&!enabled(L"SignInProviderAccount"),"A missing native provider executable must disable account operations");installed=true;mount(false);panel->select(cursor_id);check(enabled(L"CheckProviderAccount")&&!enabled(L"SignInProviderAccount"),"Sign in requires a root browser handoff; metadata checks can remain available");
        mode=L"wait-status";mount();panel->select(cursor_id);fixture::invoke(panel->view(),L"CheckProviderAccount");check(panel->busy()&&enabled(L"CancelProviderAccount")&&!enabled(L"AddProviderProfile"),"An in-flight account worker must leave Cancel available and freeze profile edits");fixture::invoke(panel->view(),L"CancelProviderAccount");check(fixture::until([&]{return !panel->busy();})&&updates.back().state==ProviderAccountState::unknown,"Cancelling verification must invalidate cached current identity and restore native controls");
        fixture::invoke(panel->view(),L"CheckProviderAccount");const auto before_close=updates.size();std::weak_ptr<ProviderAccountsPanel> lifetime=panel;detach();check(fixture::until([&]{return lifetime.expired();})&&updates.size()==before_close&&urls.size()==url_count,"Closing the panel must cancel its owned process and suppress stale UI/browser callbacks");
        mode=L"normal";mount();panel->select(cursor_id);fixture::invoke(panel->view(),L"CheckProviderAccount");check(fixture::until([&]{return !panel->busy();})&&updates.back().state==ProviderAccountState::verified,"A new account panel must remain usable after cancellation and dismissal");
        detach();std::filesystem::remove_all(folder);std::ofstream output(report);output<<"PASS: "<<checks<<" native provider account panel checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<winrt::to_string(error.message())<<'\n';}
     catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}
    std::error_code ignored;std::filesystem::remove_all(folder,ignored);return 1;
}
} // namespace coincide
