#pragma once
#include "../App/SchedulePanel.h"
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#include <thread>

namespace coincide {
namespace schedule_panel_fixture {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline xaml::DependencyObject find(const xaml::DependencyObject& root,const winrt::hstring& id){
    if(!root)return nullptr;if(xaml::Automation::AutomationProperties::GetAutomationId(root)==id)return root;
    if(const auto panel=root.try_as<ui::Panel>()){for(const auto& child:panel.Children())if(const auto value=find(child,id))return value;}
    if(const auto border=root.try_as<ui::Border>())if(const auto value=find(border.Child(),id))return value;
    if(const auto content=root.try_as<ui::ContentControl>())if(const auto child=content.Content().try_as<xaml::DependencyObject>())if(const auto value=find(child,id))return value;
    return nullptr;
}
inline void pump(){MSG message{};for(unsigned count=0;count<512&&PeekMessageW(&message,nullptr,0,0,PM_REMOVE);++count){if(message.message==WM_QUIT){PostQuitMessage(static_cast<int>(message.wParam));break;}TranslateMessage(&message);DispatchMessageW(&message);}}
template<class Predicate>bool until(Predicate predicate){const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(3);while(!predicate()&&std::chrono::steady_clock::now()<end){pump();std::this_thread::sleep_for(std::chrono::milliseconds(1));}pump();return predicate();}
inline void invoke(const xaml::DependencyObject& root,const wchar_t* identity){const auto button=find(root,identity).as<ui::Button>();const xaml::Automation::Peers::ButtonAutomationPeer peer(button);peer.GetPattern(xaml::Automation::Peers::PatternInterface::Invoke).as<xaml::Automation::Provider::IInvokeProvider>().Invoke();pump();}
template<class T>T control(const xaml::DependencyObject& root,const wchar_t* identity){const auto value=find(root,identity);if(!value)throw std::runtime_error("A native schedule fixture control is missing");return value.as<T>();}
} // namespace schedule_panel_fixture

inline int schedule_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    using namespace scheduling;namespace fixture=schedule_panel_fixture;namespace ui=fixture::ui;namespace xaml=fixture::xaml;
    const auto directory=std::filesystem::temp_directory_path()/winrt::to_hstring("coincide-schedule-panel-"+schedule_identity()).c_str();
    const auto thread=schedule_identity(),other_thread=schedule_identity();auto now=wall_seconds({{2026,11,4},8,0,0});
    std::unordered_set<std::string> busy;std::vector<DeliveryIntent> deliveries;bool accept=true,persisted_first=true;std::shared_ptr<SchedulePanel> panel;ui::Panel host{nullptr};int checks{};
    auto check=[&](bool value,const char* failure){++checks;if(!value)throw std::runtime_error(failure);};
    auto detach=[&]{if(panel){panel->close();if(host){std::uint32_t index{};if(host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);}panel.reset();fixture::pump();}};
    auto create=[&]{
        panel=SchedulePanel::create(directory,[&]{return busy;},[&](const DeliveryIntent& intent){
            std::ifstream input(directory/L"scheduled-tasks.json");const std::string bytes((std::istreambuf_iterator<char>(input)),std::istreambuf_iterator<char>());
            auto doc=winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(bytes));bool found{};for(const auto& raw:doc.GetNamedArray(L"tasks")){const auto task=raw.GetObject();if(winrt::to_string(task.GetNamedString(L"id"))==intent.schedule_id)found=task.GetNamedString(L"deliveryID")==winrt::to_hstring(intent.delivery_id)&&task.GetNamedNumber(L"inFlight")==static_cast<double>(intent.occurrence);}
            persisted_first=persisted_first&&found;deliveries.push_back(intent);return accept;},[&]{return now;});
        host.Children().Append(panel->view());panel->view().Measure({800,1600});panel->view().Arrange({0,0,800,1600});panel->view().UpdateLayout();fixture::pump();
    };
    auto card=[&](const std::string& id){return fixture::find(panel->view(),winrt::to_hstring("ScheduleCard_"+id));};
    auto begin=[&](int kind,const wchar_t* name){fixture::invoke(panel->view(),L"ScheduleNew");fixture::control<ui::TextBox>(panel->view(),L"ScheduleName").Text(name);fixture::control<ui::TextBox>(panel->view(),L"SchedulePrompt").Text(L"Isolated scheduled prompt — 你好");fixture::control<ui::ComboBox>(panel->view(),L"ScheduleKind").SelectedIndex(kind);fixture::control<ui::AutoSuggestBox>(panel->view(),L"ScheduleTimeZone").Text(L"UTC");schedule_ui::date(fixture::control<ui::DatePicker>(panel->view(),L"ScheduleDate"),{2026,11,5});schedule_ui::time(fixture::control<ui::TimePicker>(panel->view(),L"ScheduleTime"),9,0);fixture::pump();};
    try{
        if(!xaml_root||(host=xaml_root.Content().try_as<ui::Panel>())==nullptr)throw std::runtime_error("Schedule panel tests require a hidden initialized WinUI Panel/XamlRoot");
        create();check(!fixture::control<ui::Button>(panel->view(),L"ScheduleNew").IsEnabled(),"A schedule needs an explicitly selected conversation");panel->select_thread(thread);
        check(fixture::control<ui::Button>(panel->view(),L"ScheduleNew").IsEnabled(),"Selecting a conversation must enable native schedule creation");
        begin(1,L"Daily fixture");check(fixture::until([&]{return fixture::control<ui::Button>(panel->view(),L"ScheduleSave").IsEnabled();}),"A valid native daily editor must enable Save for approval");
        check(!fixture::control<ui::TextBlock>(panel->view(),L"SchedulePreview").Text().empty(),"A valid editor must display upcoming runs");fixture::invoke(panel->view(),L"ScheduleSave");
        check(fixture::until([&]{return panel->store().tasks().size()==1;}),"Saving a native schedule must persist one task");const auto daily=panel->store().tasks().front().id;
        check(panel->store().task(daily).approval_pending&&fixture::find(card(daily),L"ScheduleApprove"),"Save must expose an approval card before activation");
        now=wall_seconds({{2026,11,4},9,0,0});panel->tick();check(deliveries.empty(),"An unapproved native schedule must never dispatch");now-=3600;fixture::invoke(card(daily),L"ScheduleApprove");
        check(!panel->store().task(daily).approval_pending,"Only explicit approval may activate a saved schedule");now+=3600;panel->tick();
        check(deliveries.size()==1&&persisted_first&&panel->store().task(daily).in_flight,"Native dispatch must observe a persisted consumed/in-flight marker");
        check(!fixture::control<ui::Button>(card(daily),L"ScheduleEdit").IsEnabled()&&!fixture::control<ui::Button>(card(daily),L"ScheduleDelete").IsEnabled(),"An active delivery must retain tracking until completion");
        check(panel->pause_thread(thread)&&panel->store().task(daily).paused&&panel->store().task(daily).in_flight,"Pausing an unavailable thread must preserve its in-flight delivery tracking");fixture::invoke(card(daily),L"ScheduleTogglePause");
        fixture::invoke(card(daily),L"ScheduleTogglePause");check(panel->store().task(daily).paused&&panel->store().task(daily).in_flight,"Pausing future runs must preserve the active delivery");panel->completed_delivery(daily,deliveries.back().delivery_id,true);
        check(!panel->store().task(daily).in_flight&&panel->store().task(daily).last_outcome=="completed","A correlated native completion must finish its schedule");now+=60;fixture::invoke(card(daily),L"ScheduleTogglePause");
        check(!panel->store().task(daily).paused&&panel->store().task(daily).next_run==wall_seconds({{2026,11,5},9,0,0}),"Resume must skip the consumed occurrence and schedule a future run");
        fixture::invoke(card(daily),L"ScheduleEdit");fixture::control<ui::TextBox>(panel->view(),L"ScheduleName").Text(L"Updated native fixture");fixture::pump();fixture::invoke(panel->view(),L"ScheduleSave");
        check(panel->store().task(daily).approval_pending&&panel->store().task(daily).name=="Updated native fixture","Editing an active schedule must require fresh approval");fixture::invoke(card(daily),L"ScheduleDelete");check(panel->store().tasks().empty(),"Explicit native Delete must remove only that schedule metadata");

        now=wall_seconds({{2026,11,4},8,0,0});
        std::vector<std::string> ids;for(int kind=0;kind<7;++kind){begin(kind,(L"Kind "+std::to_wstring(kind)).c_str());
            fixture::control<ui::ComboBox>(panel->view(),L"ScheduleWeekday").SelectedIndex(4);
            for(int day=1;day<=7;++day)fixture::control<ui::CheckBox>(panel->view(),(L"ScheduleDay"+std::to_wstring(day)).c_str()).IsChecked(day==2||day==5);
            fixture::control<ui::TextBox>(panel->view(),L"ScheduleInterval").Text(L"2");fixture::control<ui::ComboBox>(panel->view(),L"ScheduleIntervalUnit").SelectedIndex(1);fixture::control<ui::TextBox>(panel->view(),L"ScheduleCron").Text(L"*/15 9-17 * * mon-fri");
            check(fixture::until([&]{return fixture::control<ui::Button>(panel->view(),L"ScheduleSave").IsEnabled();}),"Every supported recurrence must have a valid native editor/preview");fixture::invoke(panel->view(),L"ScheduleSave");
            check(fixture::until([&]{return panel->store().tasks().size()==static_cast<std::size_t>(kind+1);}),"Every native recurrence must save its own isolated task");const auto& saved=panel->store().tasks().back();ids.push_back(saved.id);
            check(saved.recurrence.kind==schedule_ui::kinds[kind]&&saved.recurrence.time_zone=="UTC"&&saved.approval_pending,"All recurrence types must persist and remain pending approval");}
        check(panel->store().task(ids[3]).recurrence.day_of_week==5&&panel->store().task(ids[4]).recurrence.weekdays==std::vector<int>{2,5},"Weekly and selected-day controls must retain their native day choices");
        check(panel->store().task(ids[5]).recurrence.interval_minutes==120&&panel->store().task(ids[6]).recurrence.cron=="*/15 9-17 * * mon-fri","Interval units and cron text must retain the requested recurrence");
        begin(1,L"Invalid zone fixture");fixture::control<ui::AutoSuggestBox>(panel->view(),L"ScheduleTimeZone").Text(L"bad/zone");
        check(fixture::until([&]{return !fixture::control<ui::Button>(panel->view(),L"ScheduleSave").IsEnabled();})&&panel->store().tasks().size()==7,"An invalid IANA zone must disable Save without creating anything");fixture::invoke(panel->view(),L"ScheduleCancel");

        TaskRecurrence unavailable_recurrence;unavailable_recurrence.hour=9;const auto unavailable=panel->propose(other_thread,"Unavailable target fixture","Isolated unavailable-target fixture",unavailable_recurrence);panel->select_thread(other_thread);fixture::invoke(card(unavailable),L"ScheduleApprove");
        busy.insert(other_thread);now=wall_seconds({{2026,11,4},9,0,0});panel->tick();check(panel->store().task(unavailable).pending_delivery==now,"The unavailable-target fixture must begin with a pending busy run");
        check(panel->pause_thread(other_thread)&&panel->store().task(unavailable).paused&&!panel->store().task(unavailable).pending_delivery,"Unavailable targets must pause and clear pending work before delivery");busy.clear();now+=60;panel->tick();check(deliveries.size()==1&&panel->store().task(unavailable).paused,"Restoring target availability must not automatically resume its schedule");
        fixture::invoke(card(unavailable),L"ScheduleTogglePause");check(panel->store().task(unavailable).active()&&panel->store().task(unavailable).next_run>now,"An unavailable target may resume only through an explicit future-run action");panel->pause_thread(other_thread);panel->select_thread(thread);now=wall_seconds({{2026,11,4},8,0,0});

        fixture::invoke(card(ids[1]),L"ScheduleApprove");busy.insert(thread);now=wall_seconds({{2026,11,4},9,0,0});panel->tick();
        check(deliveries.size()==1&&panel->store().task(ids[1]).pending_delivery==now,"The native controller must keep busy work pending without dispatching");
        now=wall_seconds({{2026,11,5},9,0,0});panel->tick();check(panel->store().task(ids[1]).pending_delivery==now,"A later busy run must replace the pending occurrence");busy.clear();accept=false;panel->tick();
        check(deliveries.size()==2&&panel->store().task(ids[1]).review_required&&panel->store().task(ids[1]).paused,"An unconfirmed dispatch must pause and expose explicit review");
        check(fixture::find(card(ids[1]),L"ScheduleReviewResume")!=nullptr,"An interrupted card must offer an explicit reviewed-resume control");now+=60;fixture::invoke(card(ids[1]),L"ScheduleReviewResume");
        check(!panel->store().task(ids[1]).review_required&&panel->store().task(ids[1]).active()&&panel->store().task(ids[1]).next_run>now,"Reviewed resume must schedule only a future run");

        accept=true;now=*panel->store().task(ids[1]).next_run;panel->tick();check(deliveries.size()==3&&panel->store().task(ids[1]).in_flight,"A reviewed future occurrence must remain deliverable");
        const auto lock_path=directory/L"scheduled-tasks.lock";const auto held=CreateFileW(lock_path.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);if(held==INVALID_HANDLE_VALUE)winrt::throw_last_error();
        panel->completed_delivery(ids[1],deliveries.back().delivery_id,true);const bool retained=panel->store().task(ids[1]).in_flight.has_value();CloseHandle(held);check(retained,"A failed completion write must retain its in-flight marker until retry");panel->tick();
        check(!panel->store().task(ids[1]).in_flight&&panel->store().task(ids[1]).last_outcome=="completed","The next tick must persist a retained completion after a transient write failure");
        now=*panel->store().task(ids[1]).next_run+3600;
        struct WakeLock{HANDLE value;~WakeLock(){if(value!=INVALID_HANDLE_VALUE)CloseHandle(value);}void close(){CloseHandle(value);value=INVALID_HANDLE_VALUE;}}wake_lock{CreateFileW(lock_path.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr)};
        if(wake_lock.value==INVALID_HANDLE_VALUE)winrt::throw_last_error();
        check(!panel->wake()&&panel->store().task(ids[1]).next_run<=now,"A failed wake commit must report failure and retain the unconsumed due state");panel->tick();
        check(deliveries.size()==3&&!panel->store().task(ids[1]).in_flight,"A tick after failed wake recovery must not dispatch an overdue occurrence");wake_lock.close();
        check(panel->wake()&&panel->store().task(ids[1]).next_run>now,"Wake recovery must retry and advance missed occurrences after storage becomes writable");panel->tick();
        check(deliveries.size()==3,"Successful wake recovery must not deliver the skipped overdue occurrence");
        now=*panel->store().task(ids[1]).next_run;panel->tick();check(deliveries.size()==4,"The restart fixture must have a fresh in-flight occurrence");detach();create();panel->select_thread(thread);
        check(panel->store().task(ids[1]).review_required&&!panel->store().task(ids[1]).in_flight&&fixture::find(card(ids[1]),L"ScheduleReviewResume"),"A reopened native panel must show interrupted work for review");panel->tick();check(deliveries.size()==4,"Reopening the native panel must not replay interrupted work");
        panel->select_thread(other_thread);check(!fixture::find(panel->view(),winrt::to_hstring("ScheduleCard_"+ids[1])),"Schedule cards must remain scoped to the selected conversation");panel->close();now+=86400;panel->tick();check(deliveries.size()==4,"Closing the native controller must prevent later timer dispatch");
        detach();std::filesystem::remove_all(directory);std::ofstream output(report);output<<"PASS: "<<checks<<" native schedule panel checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){detach();std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}
    std::error_code ignored;std::filesystem::remove_all(directory,ignored);return 1;
}
} // namespace coincide
