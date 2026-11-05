#pragma once
#include "../App/CommandPalettePanel.h"
#include "ThreadFindBarTests.h"

namespace coincide {
inline int command_palette_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace f=thread_find_fixture;unsigned checks{};std::shared_ptr<CommandPalettePanel> panel;f::ui::Panel host{nullptr};
    const auto check=[&](bool value,const char* why){++checks;if(!value)throw std::runtime_error(why);};
    const auto until=[&](auto condition){const auto end=GetTickCount64()+5000;while(!condition()&&GetTickCount64()<end){f::pump();Sleep(1);}f::pump();return condition();};
    const auto settle=[&]{const auto end=GetTickCount64()+5000;while(panel->searching()&&GetTickCount64()<end){f::pump();Sleep(1);}f::pump();if(panel->searching())throw std::runtime_error("Owned palette search did not settle");};
    const auto cleanup=[&]{if(panel){panel->hide();if(host){std::uint32_t index{};if(host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);}panel.reset();}f::pump();};
    try{
        if(!xaml_root||!(host=xaml_root.Content().try_as<f::ui::Panel>()))throw std::runtime_error("Palette fixture requires an initialized native Panel");
        using K=PaletteKind;bool fail_source{},stale{},hide_on_open{};unsigned reads{},dismissed{};std::vector<PaletteEntry> opened;
        panel=CommandPalettePanel::create([&]{++reads;if(fail_source)throw std::runtime_error("Owned unavailable metadata");return std::vector<PaletteEntry>{{K::command,"new","New Chat","Create a conversation"},{K::project,"project","Straße","Project"},{K::thread,"one","Same title","codex · Straße"},{K::thread,"two","Same title","claude"}};},[&](const auto& entry){if(stale)return false;if(hide_on_open)panel->hide();opened.push_back(entry);return true;},[&]{++dismissed;});
        host.Children().Append(panel->view());panel->view().Measure({700,500});panel->view().Arrange({0,0,700,500});panel->view().UpdateLayout();f::pump();
        const auto query=f::control<f::ui::TextBox>(panel->view(),L"CommandPaletteQuery");const auto status=f::control<f::ui::TextBlock>(panel->view(),L"CommandPaletteStatus");
        const auto list=f::control<f::ui::ListView>(panel->view(),L"CommandPaletteResults");const auto open=f::control<f::ui::Button>(panel->view(),L"CommandPaletteOpen");
        const auto invoke=[&]{f::xaml::Automation::Peers::ButtonAutomationPeer peer(open);peer.GetPattern(f::xaml::Automation::Peers::PatternInterface::Invoke).as<f::xaml::Automation::Provider::IInvokeProvider>().Invoke();f::pump();};
        check(reads==0&&opened.empty()&&!open.IsEnabled(),"Constructing the palette must not load destinations or execute commands");
        panel->show();settle();check(reads==1&&list.Items().Size()==4&&opened.empty()&&open.IsEnabled(),"Opening must show metadata while leaving activation explicit");
        query.Text(L"same");check(list.Items().Size()==0&&!open.IsEnabled(),"Editing a query must immediately revoke old result actions");settle();check(list.Items().Size()==2,"Both identical titles must remain selectable");list.SelectedIndex(1);invoke();check(until([&]{return opened.size()==1;})&&opened.back().id=="two"&&opened.back().kind==K::thread,"An identical title must activate its exact selected conversation ID");
        stale=true;invoke();check(until([&]{return !open.IsEnabled();})&&opened.size()==1&&status.Text()==ui_text(L"This command or destination changed. Search again."),"A destination rejected during revalidation must fail without another action");stale=false;
        query.Text(L"STRASSE");settle();check(list.Items().Size()==2,"Native controls must search Unicode project metadata");list.SelectedIndex(0);invoke();check(until([&]{return opened.size()==2;})&&opened.back().kind==K::project&&opened.back().id=="project","A project result must retain its distinct target kind");
        query.Text(L"New Chat");settle();hide_on_open=true;invoke();check(until([&]{return opened.size()==3;})&&opened.back().id=="new"&&list.Items().Size()==0&&!open.IsEnabled(),"Closing during activation must preserve a copied command while revoking old results");hide_on_open=false;
        panel->show();query.Text(L"same");query.Text(L"STRASSE");settle();check(list.Items().Size()==2&&std::wstring(f::xaml::Automation::AutomationProperties::GetName(list.Items().GetAt(0).as<f::xaml::DependencyObject>())).find(L"Straße")!=std::wstring::npos,"A superseded query must not publish its earlier native rows");
        query.Text(L"absent");settle();check(list.Items().Size()==0&&!open.IsEnabled(),"An unmatched query must not keep an earlier action enabled");
        fail_source=true;query.Text(L"changed");settle();check(list.Items().Size()==0&&status.Text()==ui_text(L"Commands and destinations are unavailable."),"An unavailable workspace must report a native error without partial actions");fail_source=false;
        query.Text(L"same");panel->hide();settle();check(list.Items().Size()==0&&!open.IsEnabled(),"Hiding the palette must revoke a pending search");panel->show();settle();check(list.Items().Size()==4&&dismissed==0,"Reopening must obtain a fresh snapshot without invoking dismissal");
        cleanup();std::ofstream output(report);output<<"PASS: "<<checks<<" native command palette checks\n";return output?0:2;
    }catch(const winrt::hresult_error&){cleanup();std::ofstream(report)<<"FAIL after "<<checks<<" checks: native palette UI API failure\n";}catch(const std::exception& error){cleanup();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
