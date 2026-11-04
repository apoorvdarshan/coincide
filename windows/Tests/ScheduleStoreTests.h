#pragma once
#include "../Runtime/ScheduleStore.h"

namespace coincide {
inline int schedule_store_tests(const std::filesystem::path& report){
    using namespace scheduling;namespace json=winrt::Windows::Data::Json;
    const auto root=std::filesystem::temp_directory_path()/winrt::to_hstring("coincide-schedule-tests-"+schedule_identity()).c_str();
    int checks{};
    auto check=[&](bool value,const char* failure){++checks;if(!value)throw std::runtime_error(failure);};
    auto rejects=[&](auto operation,const char* failure){bool rejected{};try{operation();}catch(...){rejected=true;}check(rejected,failure);};
    auto at=[](int year,int month,int day,int hour=0,int minute=0){return wall_seconds({{year,month,day},hour,minute,0});};
    auto read=[](const std::filesystem::path& path){std::ifstream input(path,std::ios::binary);return std::string((std::istreambuf_iterator<char>(input)),std::istreambuf_iterator<char>());};
    auto write=[](const std::filesystem::path& path,const json::JsonObject& document){std::ofstream output(path,std::ios::binary);output<<winrt::to_string(document.Stringify());if(!output)throw std::runtime_error("Could not write the isolated schedule fixture");};
    UtcCalendar calendar;const auto now=at(2026,11,4,8),due=at(2026,11,4,9);const auto thread=schedule_identity();
    auto value=[&](std::string thread_id={}){ScheduledTask task;task.thread_id=thread_id.empty()?thread:std::move(thread_id);task.name="Morning review — 你好";task.prompt="Review fixture only\nNo model calls";task.recurrence.hour=9;return task;};
    try{
        ScheduleStore store(root/L"basic",calendar);store.open(now);auto proposed=value();proposed.approval_pending=false;
        const auto id=store.create(proposed,now);
        check(store.tasks().size()==1&&store.task(id).approval_pending&&store.task(id).next_run==due,"Every creation must require approval even when the caller supplies an approved flag");
        check(store.tick(due,{}).empty(),"Pending approval must prevent any delivery intents");
        rejects([&]{store.resume(id,now);},"Resume must not bypass pending approval");
        store.approve(id,now);check(store.task(id).active(),"Explicit approval must enable an unpaused valid schedule");
        auto deliveries=store.tick(due,{});check(deliveries.size()==1&&deliveries.front().thread_id==thread&&deliveries.front().prompt==proposed.prompt,"A due approved schedule must return its thread and exact prompt in an intent");
        const auto first=deliveries.front();const auto file=root/L"basic"/L"scheduled-tasks.json";
        const auto persisted=json::JsonObject::Parse(winrt::to_hstring(read(file))).GetNamedArray(L"tasks").GetAt(0).GetObject();
        check(persisted.GetNamedNumber(L"lastFiredOccurrence")==static_cast<double>(due)&&persisted.GetNamedNumber(L"inFlight")==static_cast<double>(due)&&persisted.GetNamedString(L"deliveryID")==winrt::to_hstring(first.delivery_id),"Consumed occurrence and matching delivery token must be on disk before an intent is returned");
        check(store.tick(due,{}).empty()&&store.tick(at(2026,11,5,9),{}).empty(),"Repeated ticks and a stale empty busy set must never overlap an in-flight delivery");
        check(store.task(id).next_run==at(2026,11,6,9),"An active delivery must consume overlapping slots without a backlog");
        rejects([&]{store.finish(id,schedule_identity(),due,true);},"A stale or unrelated delivery token must never finish the current run");
        rejects([&]{store.remove(id);},"Removing a schedule must not lose an active delivery's tracking");
        store.finish(id,first.delivery_id,at(2026,11,5,10),true);
        check(!store.task(id).in_flight&&store.task(id).last_outcome=="completed"&&store.task(id).next_run==at(2026,11,6,9),"Completing a delivery must preserve its consumed future phase");
        store.update(id,"Renamed schedule","Updated fixture",proposed.recurrence,at(2026,11,5,11));
        check(store.task(id).approval_pending&&store.task(id).prompt=="Updated fixture"&&store.tick(at(2026,11,6,9),{}).empty(),"Editing must repropose the schedule and never implicitly approve the new prompt");

        ScheduleStore busy(root/L"busy",calendar);busy.open(now);const auto busy_id=busy.create(value(),now);busy.approve(busy_id,now);
        check(busy.tick(due,{thread}).empty()&&busy.task(busy_id).pending_delivery==due,"Busy threads must retain one pending consumed occurrence");
        check(busy.tick(at(2026,11,5,9),{thread}).empty()&&busy.task(busy_id).pending_delivery==at(2026,11,5,9),"A newer busy occurrence must replace the older one");
        deliveries=busy.tick(at(2026,11,5,9,1),{});
        check(deliveries.size()==1&&deliveries.front().occurrence==at(2026,11,5,9)&&!busy.task(busy_id).pending_delivery,"Becoming idle must send only the latest pending run");
        busy.mark_uncertain(busy_id,deliveries.front().delivery_id,at(2026,11,5,9,2),"Fixture ambiguous handoff");
        check(busy.task(busy_id).review_required&&busy.task(busy_id).paused&&busy.tick(at(2026,11,6,9),{}).empty(),"An uncertain dispatch must stop automatic retries and require review");
        rejects([&]{busy.resume(busy_id,at(2026,11,5,10));},"Ordinary Resume must not clear an uncertain delivery review requirement");
        busy.review_and_resume(busy_id,at(2026,11,5,10));check(busy.task(busy_id).active()&&busy.task(busy_id).next_run==at(2026,11,6,9),"Explicit reviewed resume must skip the uncertain slot and schedule a future one");
        busy.pause(busy_id);check(busy.tick(at(2026,11,6,9),{}).empty(),"An explicit pause must stop delivery");
        busy.resume(busy_id,at(2026,11,6,10));check(busy.task(busy_id).next_run==at(2026,11,7,9),"Resuming a paused schedule must skip missed slots");

        ScheduleStore shared(root/L"shared-thread",calendar);shared.open(now);const auto first_id=shared.create(value(),now),second_id=shared.create(value(),now);shared.approve(first_id,now);shared.approve(second_id,now);
        deliveries=shared.tick(due,{});check(deliveries.size()==1&&shared.task(second_id).pending_delivery==due,"Two schedules for one thread must share one dispatch slot even with a stale busy snapshot");
        shared.finish(first_id,deliveries.front().delivery_id,due+60,true);check(shared.tick(due+61,{}).size()==1,"The second pending schedule must remain deliverable after the first finishes");

        ScheduleStore wake(root/L"wake",calendar);wake.open(now);const auto wake_id=wake.create(value(),now);wake.approve(wake_id,now);wake.wake(at(2026,11,6,12));
        check(wake.task(wake_id).last_outcome=="missed"&&wake.task(wake_id).next_run==at(2026,11,7,9)&&wake.tick(at(2026,11,6,12),{}).empty(),"Wake must skip missed occurrences without dispatching a backlog");
        ScheduleStore original(root/L"restart",calendar);original.open(now);const auto restart_id=original.create(value(),now);original.approve(restart_id,now);check(original.tick(due,{}).size()==1,"The restart fixture must have a persisted in-flight run");
        ScheduleStore restarted(root/L"restart",calendar);restarted.open(due+1);
        check(restarted.task(restart_id).review_required&&restarted.task(restart_id).paused&&!restarted.task(restart_id).in_flight&&restarted.task(restart_id).last_outcome=="interrupted","Relaunch must recover an in-flight run as interrupted and review-required");
        check(restarted.tick(at(2026,11,5,9),{}).empty(),"A restarted uncertain delivery must never be replayed automatically");
        rejects([&]{restarted.resume(restart_id,due+2);},"Relaunch review cannot be bypassed by ordinary Resume");
        const auto restart_bytes=read(root/L"restart"/L"scheduled-tasks.json");
        rejects([&]{original.pause(restart_id);},"An older store snapshot must refuse to overwrite another process's recovery");
        check(read(root/L"restart"/L"scheduled-tasks.json")==restart_bytes&&original.task(restart_id).in_flight.has_value(),"A stale write rejection must preserve disk and the original in-memory state");
        restarted.review_and_resume(restart_id,at(2026,11,5,10));check(restarted.task(restart_id).next_run==at(2026,11,6,9),"Reviewed recovery must advance to a future occurrence");

        ScheduleStore waiting(root/L"pending-restart",calendar);waiting.open(now);const auto waiting_id=waiting.create(value(),now);waiting.approve(waiting_id,now);(void)waiting.tick(due,{thread});
        ScheduleStore waiting_reopened(root/L"pending-restart",calendar);waiting_reopened.open(due+1);
        check(!waiting_reopened.task(waiting_id).pending_delivery&&waiting_reopened.task(waiting_id).last_outcome=="missed"&&waiting_reopened.tick(due+1,{}).empty(),"Undelivered busy work must be skipped at restart rather than blindly replayed");
        ScheduleStore once(root/L"once",calendar);once.open(now);auto once_value=value();once_value.recurrence.kind=RecurrenceKind::once;once_value.recurrence.date=due;const auto once_id=once.create(once_value,now);once.approve(once_id,now);once.wake(due+1);
        check(!once.task(once_id).next_run&&once.tick(due+1,{}).empty(),"A missed one-time schedule must be consumed at wake");
        rejects([&]{once.create(once_value,due+1);},"Past one-time creation must be rejected");

        ScheduleStore future(root/L"unknown",calendar);future.open(now);const auto future_id=future.create(value(),now);const auto future_file=root/L"unknown"/L"scheduled-tasks.json";
        auto document=json::JsonObject::Parse(winrt::to_hstring(read(future_file)));document.SetNamedValue(L"futureRoot",json::JsonValue::CreateBooleanValue(true));auto future_task=document.GetNamedArray(L"tasks").GetAt(0).GetObject();
        future_task.SetNamedValue(L"futureTask",json::JsonValue::CreateStringValue(L"retain me"));future_task.GetNamedObject(L"recurrence").SetNamedValue(L"futureRecurrence",json::JsonValue::CreateNumberValue(42));write(future_file,document);
        ScheduleStore future_reopened(root/L"unknown",calendar);future_reopened.open(now);future_reopened.approve(future_id,now);
        document=json::JsonObject::Parse(winrt::to_hstring(read(future_file)));future_task=document.GetNamedArray(L"tasks").GetAt(0).GetObject();
        check(document.GetNamedBoolean(L"futureRoot")&&future_task.GetNamedString(L"futureTask")==L"retain me"&&future_task.GetNamedObject(L"recurrence").GetNamedNumber(L"futureRecurrence")==42,"Unknown root, task, and recurrence fields must survive edits");
        check(future_reopened.task(future_id).name=="Morning review — 你好"&&future_reopened.task(future_id).prompt==value().prompt,"Names and multiline prompts must survive UTF-8 persistence");
        const auto lock_path=root/L"unknown"/L"scheduled-tasks.lock";const auto held=CreateFileW(lock_path.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(held==INVALID_HANDLE_VALUE)winrt::throw_last_error();const auto before_locked=read(future_file);
        bool rejected=false;try{future_reopened.pause(future_id);}catch(...){rejected=true;}CloseHandle(held);
        check(rejected&&read(future_file)==before_locked&&!future_reopened.task(future_id).paused,"An atomic-write lock failure must preserve both disk and in-memory state");

        const auto baseline=document.Stringify();
        auto malformed=[&](auto mutate,const char* failure){auto corrupt=json::JsonObject::Parse(baseline);mutate(corrupt);write(future_file,corrupt);const auto untouched=read(future_file);ScheduleStore invalid(root/L"unknown",calendar);rejects([&]{invalid.open(now);},failure);rejects([&]{invalid.pause(future_id);},"Failed schedule opens must revoke all write APIs");check(read(future_file)==untouched,"Malformed schedule files must be preserved exactly");};
        malformed([](auto doc){doc.GetNamedArray(L"tasks").GetAt(0).GetObject().SetNamedValue(L"paused",json::JsonValue::CreateStringValue(L"false"));},"Wrong-typed approval/runtime flags must fail closed");
        malformed([](auto doc){doc.GetNamedArray(L"tasks").GetAt(0).GetObject().SetNamedValue(L"nextRunAt",json::JsonValue::CreateNumberValue(0.5));},"Fractional schedule timestamps must be rejected");
        malformed([](auto doc){doc.GetNamedArray(L"tasks").GetAt(0).GetObject().SetNamedValue(L"nextRunAt",json::JsonValue::CreateNumberValue(-1));},"Negative schedule timestamps must be rejected");
        malformed([](auto doc){doc.GetNamedArray(L"tasks").GetAt(0).GetObject().GetNamedObject(L"recurrence").SetNamedValue(L"timeZone",json::JsonValue::CreateStringValue(L"bad/zone"));},"Unsupported persisted time zones must fail closed");
        malformed([](auto doc){doc.SetNamedValue(L"version",json::JsonValue::CreateNumberValue(2));},"Future schedule versions must be preserved and rejected");
        malformed([](auto doc){doc.SetNamedValue(L"format",json::JsonValue::CreateStringValue(L"different-platform"));},"A different platform's schedule format must not be silently reinterpreted");
        malformed([](auto doc){auto tasks=doc.GetNamedArray(L"tasks");auto alias=json::JsonObject::Parse(tasks.GetAt(0).GetObject().Stringify());auto id=winrt::to_string(alias.GetNamedString(L"id"));for(auto& c:id)if(c>='a'&&c<='f')c=static_cast<char>(c-'a'+'A');alias.SetNamedValue(L"id",json::JsonValue::CreateStringValue(winrt::to_hstring(id)));tasks.Append(alias);},"Canonical GUID aliases must not bypass duplicate identity checks");
        malformed([](auto doc){doc.GetNamedArray(L"tasks").GetAt(0).GetObject().SetNamedValue(L"prompt",json::JsonValue::CreateStringValue(L" \n\t "));},"Blank prompts must be rejected");
        malformed([](auto doc){doc.GetNamedArray(L"tasks").GetAt(0).GetObject().SetNamedValue(L"deliveryID",json::JsonValue::CreateStringValue(L"orphan-token"));},"An orphan delivery marker must fail validation");
        auto legacy=json::JsonObject::Parse(baseline);auto legacy_task=legacy.GetNamedArray(L"tasks").GetAt(0).GetObject();
        for(const auto key:{L"awaitingApproval",L"paused",L"reviewRequired",L"nextRunAt",L"pendingDelivery",L"inFlight",L"lastFiredOccurrence",L"lastRunAt",L"lastFinishedAt",L"deliveryID",L"lastOutcome",L"lastMessage"})legacy_task.Remove(key);
        write(future_file,legacy);ScheduleStore legacy_store(root/L"unknown",calendar);legacy_store.open(now);
        check(legacy_store.task(future_id).approval_pending&&legacy_store.tick(due,{}).empty(),"Missing old approval/runtime fields must default to pending with no invented delivery");
        {std::ofstream output(future_file,std::ios::binary);output<<"{ malformed";}
        rejects([&]{legacy_store.open(now);},"A malformed reopen must revoke a previously successful store");
        rejects([&]{legacy_store.approve(future_id,now);},"A failed reopen must not retain write authority from its earlier snapshot");
        check(read(future_file)=="{ malformed","A failed reopen must preserve malformed bytes");

        ScheduleStore limits(root/L"limits",calendar);limits.open(now);for(int index=0;index<10;++index)(void)limits.create(value(),now);
        rejects([&]{limits.create(value(),now);},"One thread must not exceed ten schedules");check(limits.tasks().size()==10,"A rejected schedule creation must not partially mutate memory");
        auto oversized=value(schedule_identity());oversized.prompt=std::string(20001,'x');rejects([&]{limits.create(oversized,now);},"Oversized prompts must be rejected before writing");
        std::filesystem::remove_all(root);std::ofstream output(report);output<<"PASS: "<<checks<<" native schedule store and policy checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}
    std::error_code ignored;std::filesystem::remove_all(root,ignored);return 1;
}
} // namespace coincide
