#pragma once
#include "../App/UsagePanel.h"
#include "UsageTests.h"
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>

namespace coincide {
namespace usage_panel_fixture {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline void collect(const xaml::DependencyObject& value,const wchar_t* id,std::vector<xaml::DependencyObject>& found){if(!value)return;if(xaml::Automation::AutomationProperties::GetAutomationId(value)==id)found.push_back(value);if(const auto panel=value.try_as<ui::Panel>())for(const auto& child:panel.Children())collect(child,id,found);if(const auto content=value.try_as<ui::ContentControl>())if(const auto child=content.Content().try_as<xaml::DependencyObject>())collect(child,id,found);if(const auto border=value.try_as<ui::Border>())collect(border.Child(),id,found);}
template<class T>T control(const xaml::DependencyObject& value,const wchar_t* id){std::vector<xaml::DependencyObject> found;collect(value,id,found);if(found.size()!=1)throw std::runtime_error("Native usage fixture control is missing or ambiguous");return found.front().as<T>();}
inline void pump(){MSG message{};for(unsigned count=0;count<256&&PeekMessageW(&message,nullptr,0,0,PM_REMOVE);++count){if(message.message==WM_QUIT){PostQuitMessage(static_cast<int>(message.wParam));break;}TranslateMessage(&message);DispatchMessageW(&message);}}
}
inline int usage_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace fixture=usage_panel_fixture;namespace ui=fixture::ui;unsigned checks{};bool owned{};std::shared_ptr<UsagePanel> panel;ui::Panel host{nullptr};
    const auto folder=std::filesystem::temp_directory_path()/(L"Coincide-usage-panel-fixture-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    const auto check=[&](bool value,const char* reason){++checks;if(!value)throw std::runtime_error(reason);};
    const auto detach=[&]{if(panel){panel->close();if(host){std::uint32_t index{};if(host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);}panel.reset();fixture::pump();}};
    try{
        if(!xaml_root||!(host=xaml_root.Content().try_as<ui::Panel>()))throw std::runtime_error("Usage panel fixtures require the initialized native XamlRoot");if(!std::filesystem::create_directory(folder))throw std::runtime_error("Usage panel fixture directory must be unique");owned=true;
        auto store=std::make_shared<UsageStore>(folder);store->open();const auto now=UsageStore::now_ms();UsageTurn measured(usage_fixture_owner(),now-100);UsageObservation usage;usage.scope=UsageObservation::Scope::turn;usage.tokens=UsageTokens{10,3,2,5,0};usage.cost_usd=0.125;measured.observe(usage);store->record(measured.finish("completed",now));
        auto older_owner=usage_fixture_owner("old-turn","codex");older_owner.project_id="{21234567-89ab-cdef-0123-456789abcdef}";older_owner.thread_id="{31234567-89ab-cdef-0123-456789abcdef}";UsageTurn older(older_owner,now-60LL*86400000);UsageObservation snapshot;snapshot.context_tokens=1000;snapshot.context_window=200000;older.observe(snapshot);store->record(older.finish("completed",now-60LL*86400000+1));
        const std::vector<UsageLabel> projects{{"{01234567-89ab-cdef-0123-456789abcdef}","Fixture project A"},{"{21234567-89ab-cdef-0123-456789abcdef}","Fixture project B"}},threads{{"{11234567-89ab-cdef-0123-456789abcdef}","Fixture thread A"},{"{31234567-89ab-cdef-0123-456789abcdef}","Fixture thread B"}};
        const UsageAccountStatus account{"claude","default","Fixture account","1.2.3",std::string(64,'a'),"fixture-metadata",true};panel=UsagePanel::create(store,projects,threads,{account});host.Children().Append(panel->view());panel->view().Measure({850,650});panel->view().Arrange({0,0,850,650});panel->view().UpdateLayout();fixture::pump();
        const auto choose=[&](const wchar_t* id,int index){fixture::control<ui::ComboBox>(panel->view(),id).SelectedIndex(index);fixture::pump();};const auto text=[&](const wchar_t* id){return winrt::to_string(fixture::control<ui::TextBlock>(panel->view(),id).Text());};
        check(panel->displayed_totals().records==1&&panel->displayed_totals().tokens.total()==20,"Opening Usage must show recorded local metrics for its default thirty-day period");
        check(text(L"UsageCostSummary").find("0.1250")!=std::string::npos&&text(L"UsageTokenSummary").find("20")!=std::string::npos,"Native Usage must render provider-reported token and USD figures");
        check(text(L"UsageAccountAvailability").find("Unavailable")!=std::string::npos,"Verified identity metadata must never invent a provider balance or rate limit");
        choose(L"UsageProvider",1);check(panel->displayed_totals().records==0&&text(L"UsageTokenSummary").find("Unavailable")!=std::string::npos&&text(L"UsageCostSummary").find("Unavailable")!=std::string::npos,"An unmeasured provider selection must display unavailable totals rather than fabricated zero cost");
        choose(L"UsagePeriod",2);check(panel->displayed_totals().records==1&&panel->displayed_totals().snapshot_records==1&&panel->displayed_totals().token_records==0,"All recorded time must retain historical context snapshots separately from additive totals");
        choose(L"UsageProvider",0);choose(L"UsageProject",1);check(panel->displayed_totals().records==1&&panel->displayed_totals().tokens.total()==20,"Project filtering must retain only that project's reported usage");choose(L"UsageThread",2);check(panel->displayed_totals().records==0,"Thread and project filters must intersect instead of leaking another thread's metrics");
        choose(L"UsageProject",0);check(panel->displayed_totals().records==1&&panel->displayed_totals().snapshot_records==1,"Thread-only usage selection must restore its own snapshot without another thread's cost");choose(L"UsageThread",0);
        const auto refresh=fixture::control<ui::Button>(panel->view(),L"RefreshUsage");fixture::xaml::Automation::Peers::ButtonAutomationPeer peer(refresh);peer.GetPattern(fixture::xaml::Automation::Peers::PatternInterface::Invoke).as<fixture::xaml::Automation::Provider::IInvokeProvider>().Invoke();fixture::pump();check(panel->displayed_totals().records==2,"Refresh local totals must reread the bounded local store without provider activity");
        panel->set_accounts({});check(text(L"UsageAccountAvailability").find("unavailable")!=std::string::npos,"Clearing verified account metadata must immediately restore truthful availability text");
        {std::ofstream damaged(folder/L"usage-history.json");damaged<<"{\"schema\":77,\"records\":[]}";}panel->refresh();check(panel->displayed_totals().records==0&&text(L"UsageStatus").find("preserved")!=std::string::npos,"Corrupt or future usage history must clear stale displayed totals and preserve the existing file");
        panel->close();panel->set_accounts({account});check(text(L"UsageAccountAvailability").find("unavailable")!=std::string::npos,"Closed Usage panels must ignore subsequent metadata updates");detach();std::filesystem::remove_all(folder);owned=false;std::ofstream output(report);output<<"PASS: "<<checks<<" native passive usage panel checks\n";return output?0:2;
    }catch(const winrt::hresult_error&){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks: native Usage UI contract failure\n";}catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}if(owned){std::error_code error;std::filesystem::remove_all(folder,error);}return 1;
}
} // namespace coincide
