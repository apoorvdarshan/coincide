#pragma once
#include "../Runtime/ScheduleTool.h"
#include "InstructionImportTests.h"

namespace coincide {
inline int schedule_tool_tests(const std::filesystem::path& report){
    using namespace scheduling;using Object=app_tools::Object;using Value=app_tools::Value;
    std::size_t checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    try{
        instruction_import_fixture::Directory owned;UtcCalendar calendar;const Instant now=wall_seconds({{2026,11,4},12,0,0});ScheduleStore store(owned.path,calendar);store.open(now);
        const std::string first="{11111111-1111-1111-1111-111111111111}",second="{22222222-2222-2222-2222-222222222222}";std::vector<DeliveryIntent> deliveries;
        const auto request=[&](const std::string& thread,const std::string& json,Instant time=0,std::unordered_set<std::string> busy=std::unordered_set<std::string>{}){deliveries.clear();return ScheduleTool::request(store,calendar,thread,json,time?time:now,"UTC",busy,deliveries);};
        const auto rejects=[&](auto action,const char* message){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,message);};
        check(request(first,R"({"action":"list"})").GetNamedArray(L"tasks").Size()==0,"New threads must see only their own empty schedule list");
        const auto created=request(first,R"({"action":"create","name":"Owned reminder 你好","prompt":"Owned synthetic prompt","schedule":{"kind":"once","inMinutes":30}})");const auto id=winrt::to_string(created.GetNamedString(L"id"));
        check(created.GetNamedBoolean(L"awaitingApproval")&&deliveries.empty(),"Agent-created schedules must require approval without dispatch");
        check(store.task(id).recurrence.date==now+1800,"Relative schedules must use the actual UTC clock");
        check(request(second,R"({"action":"list"})").GetNamedArray(L"tasks").Size()==0,"Other threads must not learn schedule prompts or identities");
        const auto encoded=[&](const char* action,const std::string& extra=std::string{}){Object value;computer_use::put(value,L"action",action);computer_use::put(value,L"id",id);if(!extra.empty())computer_use::put(value,L"name",extra);return winrt::to_string(value.Stringify());};
        rejects([&]{request(first,encoded("run-now"));},"Run Now must not approve a pending schedule");
        for(const auto action:{"update","pause","resume","delete","run-now"})rejects([&]{request(second,encoded(action,std::string(action)=="update"?"Other name":""));},"Every mutation must enforce the originating thread");
        store.approve(id,now);const auto original_next=store.task(id).next_run;auto manual=request(first,encoded("run-now"));
        check(manual.GetNamedBoolean(L"running")&&deliveries.size()==1&&store.task(id).in_flight,"Manual deliveries must be saved before exposing an intent");
        check(store.task(id).next_run==original_next&&deliveries[0].thread_id==first,"Manual runs must preserve recurrence and thread ownership");
        rejects([&]{request(first,encoded("run-now"));},"A running manual delivery must never be duplicated");
        store.finish(id,deliveries.empty()?store.task(id).delivery_id:deliveries[0].delivery_id,now+1,true); // A rejected retry clears only the caller's output vector.
        request(first,encoded("pause"));rejects([&]{request(first,encoded("run-now"));},"Paused schedules require explicit resume before manual dispatch");request(first,encoded("resume"));
        manual=request(first,encoded("run-now"),now+2,{first});check(manual.GetNamedBoolean(L"pending")&&deliveries.empty(),"A busy thread must persist a single pending manual delivery");
        rejects([&]{request(first,encoded("run-now"),now+3);},"Pending manual deliveries must reject duplicate requests");
        deliveries=store.tick(now+4,{});check(deliveries.size()==1&&deliveries[0].occurrence==now+2,"A pending manual run must dispatch once after its thread becomes idle");store.finish(id,deliveries[0].delivery_id,now+5,true);
        const auto changed=request(first,encoded("update","Updated owned name"),now+6);check(changed.GetNamedBoolean(L"awaitingApproval")&&store.task(id).name=="Updated owned name","Every schedule change must restore the approval gate");
        rejects([&]{request(first,R"({"action":"approve","id":"11111111-1111-1111-1111-111111111111"})");},"No app-tool request may approve its own proposal");
        for(const auto& specification:{R"({"kind":"once","at":"2026-11-04T13:15:09Z"})",R"({"kind":"once","at":"2026-11-04T18:45:09+05:30"})",R"({"kind":"once","at":"2026-11-04T13:15:09","timeZone":"UTC"})"}){const auto value=ScheduleTool::recurrence(Object::Parse(winrt::to_hstring(specification)),now,"UTC",calendar);check(value.date==now+4509,"Absolute/local schedule forms must refer to the intended instant");}
        for(const auto* name:{"daily","weekdays","weekly","days","interval","cron"}){
            Object spec;computer_use::put(spec,L"kind",name);const std::string kind=name;
            if(kind=="interval")spec.SetNamedValue(L"minutes",Value::CreateNumberValue(30));else if(kind=="cron")computer_use::put(spec,L"expression","0 9 * * 1-5");else{computer_use::put(spec,L"time","09:30");if(kind=="weekly")computer_use::put(spec,L"day","monday");if(kind=="days"){winrt::Windows::Data::Json::JsonArray days;days.Append(Value::CreateStringValue(L"mon"));days.Append(Value::CreateStringValue(L"fri"));spec.SetNamedValue(L"days",days);}}
            check(ScheduleTool::recurrence(spec,now,"UTC",calendar).next(now,calendar).has_value(),"Every supported recurrence must produce a future run");
        }
        for(const auto* specification:{R"({"kind":"once","at":"2026-02-30T09:00Z"})",R"({"kind":"once","at":"2026-11-04T13:00+14:01"})",R"({"kind":"once","inMinutes":1,"timeZone":"Unknown/Zone"})",R"({"kind":"interval","minutes":1})"})rejects([&]{ScheduleTool::recurrence(Object::Parse(winrt::to_hstring(specification)),now,"UTC",calendar);},"Malformed times, zones and short intervals must fail closed");
        request(first,encoded("delete"));check(store.tasks().empty(),"Explicit deletion must remove only the owned schedule");
        std::ofstream output(report);output<<"PASS: "<<checks<<" thread-scoped schedule app-tool checks; no timers or model execution\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}catch(const winrt::hresult_error&){std::ofstream(report)<<"FAIL after "<<checks<<" checks: native schedule app-tool failure\n";}return 1;
}
} // namespace coincide
