#pragma once
#include "../App/ConversationSearchPanel.h"
#include "ThreadFindBarTests.h"

namespace coincide {
inline int conversation_search_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace f=thread_find_fixture;unsigned checks{};std::shared_ptr<ConversationSearchPanel> panel;f::ui::Panel host{nullptr};
    const auto check=[&](bool condition,const char* why){++checks;if(!condition)throw std::runtime_error(why);};
    struct Worker {std::atomic<unsigned> reads{},finished{};std::atomic_bool block{},skip{},on_ui{};DWORD owner{GetCurrentThreadId()};};auto worker=std::make_shared<Worker>();
    const auto pump_until=[&](auto condition){const auto end=GetTickCount64()+10000;while(!condition()&&GetTickCount64()<end){f::pump();Sleep(2);}f::pump();if(!condition())throw std::runtime_error("Owned search worker did not settle");};
    const auto cleanup=[&]{worker->block=false;if(panel){panel->hide();if(host){std::uint32_t index{};if(host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);}panel.reset();f::pump();}};
    try{
        if(!xaml_root||!(host=xaml_root.Content().try_as<f::ui::Panel>()))throw std::runtime_error("Search requires an initialized native XamlRoot");
        bool source_failure{},stale{};std::vector<std::pair<std::string,std::string>> opened;
        panel=ConversationSearchPanel::create([&]{if(source_failure)throw std::runtime_error("Owned unavailable store");ConversationSearchPanel::Snapshot source;source.threads={{"one","Same title",""},{"two","Same title",""}};
            source.read=[worker](const auto& id,std::size_t& bytes,const auto& cancel){++worker->reads;struct Done{std::shared_ptr<Worker> worker;~Done(){++worker->finished;}} done{worker};if(GetCurrentThreadId()==worker->owner)worker->on_ui=true;const auto end=GetTickCount64()+5000;while(worker->block&&!cancel()&&GetTickCount64()<end)Sleep(1);if(cancel())throw TranscriptFind::Cancelled{};if(worker->skip&&id=="one")throw std::runtime_error("Owned unavailable transcript");bytes+=20;return std::vector<TranscriptFindDocument>{{id+"-message","Straße **needle**"}};};return source;
        },[&](const auto& hit,const auto& query){if(stale)return false;opened.emplace_back(hit.thread_id,query);return true;});
        host.Children().Append(panel->view());panel->view().Measure({700,500});panel->view().Arrange({0,0,700,500});panel->view().UpdateLayout();f::pump();
        const auto query=f::control<f::ui::TextBox>(panel->view(),L"ConversationSearchQuery");
        const auto status=f::control<f::ui::TextBlock>(panel->view(),L"ConversationSearchStatus");const auto results=f::control<f::ui::ListView>(panel->view(),L"ConversationSearchResults");const auto search=f::control<f::ui::Button>(panel->view(),L"ConversationSearchStart"),open=f::control<f::ui::Button>(panel->view(),L"ConversationSearchOpen");
        const auto invoke=[&](const f::ui::Button& button){f::xaml::Automation::Peers::ButtonAutomationPeer peer(button);peer.GetPattern(f::xaml::Automation::Peers::PatternInterface::Invoke).as<f::xaml::Automation::Provider::IInvokeProvider>().Invoke();f::pump();};
        check(worker->reads==0&&!search.IsEnabled()&&!open.IsEnabled(),"Constructing search must be inert");panel->show();query.Text(L"needle");check(search.IsEnabled()&&worker->reads==0,"Typing must not rescan saved history before explicit Search");invoke(search);pump_until([&]{return !panel->searching();});
        check(results.Items().Size()==2&&!worker->on_ui&&worker->reads==2,"Saved transcripts must be searched on a worker with native result rows");check(std::wstring(status.Text()).find(L"2")!=std::wstring::npos,"Native results must report their snapshot count");
        results.SelectedIndex(1);check(open.IsEnabled(),"Selecting a result must enable explicit message navigation");invoke(open);check(opened.size()==1&&opened.back()==std::pair<std::string,std::string>{"two","needle"},"Identical titles must open the selected conversation identity and exact query");
        stale=true;invoke(open);check(opened.size()==1&&!open.IsEnabled()&&status.Text()==ui_text(L"This search result changed or is unavailable. Search again."),"An unavailable result must fail closed without invoking a different target");stale=false;
        query.Text(L"STRASSE");check(results.Items().Size()==0&&!open.IsEnabled(),"Query edits must immediately revoke stale result navigation");invoke(search);pump_until([&]{return !panel->searching();});check(results.Items().Size()==2,"Unicode folded queries must work through native controls");
        worker->skip=true;invoke(search);pump_until([&]{return !panel->searching();});check(results.Items().Size()==1&&std::wstring(status.Text()).find(std::wstring(ui_text(L"unavailable conversations skipped")))!=std::wstring::npos,"Partial saved-file failures must remain visible alongside available results");worker->skip=false;
        worker->block=true;const auto before=worker->finished.load();invoke(search);pump_until([&]{return worker->reads>before;});query.Text(L"changed query");check(!panel->searching()&&results.Items().Size()==0&&search.IsEnabled(),"Editing a query must cancel the old snapshot immediately");pump_until([&]{return worker->finished>before;});check(results.Items().Size()==0,"A canceled worker must not republish results for an old query");worker->block=false;
        source_failure=true;invoke(search);check(!panel->searching()&&results.Items().Size()==0&&status.Text()==ui_text(L"Search text or saved conversations are unavailable."),"An unavailable source must give an explicit native error");source_failure=false;
        query.Text(std::wstring(600,L'猫'));invoke(search);check(!panel->searching()&&results.Items().Size()==0&&status.Text()==ui_text(L"Search text or saved conversations are unavailable."),"UTF-8 query bounds must fail without truncated matches");
        query.Text(L"needle");worker->block=true;const auto hide_before=worker->finished.load();invoke(search);pump_until([&]{return worker->reads>hide_before;});panel->hide();pump_until([&]{return worker->finished>hide_before;});check(results.Items().Size()==0&&!open.IsEnabled(),"Hiding search must cancel workers and revoke every result action");worker->block=false;panel->show();check(search.IsEnabled()&&results.Items().Size()==0,"Reopening search must allow an explicit fresh snapshot");
        cleanup();std::ofstream output(report);output<<"PASS: "<<checks<<" native conversation search controls checks\n";return output?0:2;
    }catch(const winrt::hresult_error&){cleanup();std::ofstream(report)<<"FAIL after "<<checks<<" checks: native conversation search UI contract failure\n";}catch(const std::exception& error){cleanup();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
