#pragma once
#include "WindowsCalendar.h"
#include "../Core/ScheduleCoordinator.h"
#include "../Core/Workspace.h"
#include <windows.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <unordered_map>

namespace coincide::scheduling {
namespace schedule_json=winrt::Windows::Data::Json;
inline std::string schedule_identity(){winrt::guid value;winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&value)));return winrt::to_string(winrt::to_hstring(value));}
class ScheduleStore {
    using Object=schedule_json::JsonObject;using Array=schedule_json::JsonArray;using Value=schedule_json::JsonValue;using Type=schedule_json::JsonValueType;
    std::filesystem::path directory_;
    Calendar& calendar_;
    std::vector<ScheduledTask> tasks_;
    Object original_{nullptr};std::optional<std::string> snapshot_;
    bool opened_{};
    static constexpr std::size_t file_limit=32*1024*1024,task_limit=1000;
    static std::string identity(std::string_view value){
        if(value.empty()||value.size()>64)throw std::invalid_argument("Invalid schedule identity");
        const winrt::guid parsed(winrt::to_hstring(value));if(parsed==winrt::guid{})throw std::invalid_argument("A schedule identity cannot be empty");
        return winrt::to_string(winrt::to_hstring(parsed));
    }
    static Object clone(const Object& value){return value?Object::Parse(value.Stringify()):Object{};}
    static std::string text(const Object& object,const wchar_t* key,std::string fallback={}){
        const auto value=object.GetNamedValue(key,Value::CreateNullValue());return value.ValueType()==Type::Null?std::move(fallback):winrt::to_string(value.GetString());
    }
    static bool boolean(const Object& object,const wchar_t* key,bool fallback=false){
        const auto value=object.GetNamedValue(key,Value::CreateNullValue());return value.ValueType()==Type::Null?fallback:value.GetBoolean();
    }
    static std::optional<Instant> instant(const Object& object,const wchar_t* key){
        const auto value=object.GetNamedValue(key,Value::CreateNullValue());if(value.ValueType()==Type::Null)return std::nullopt;
        const auto number=value.GetNumber();if(!std::isfinite(number)||number<0||number>static_cast<double>(maximum_instant)||number!=std::floor(number))throw std::invalid_argument("Invalid schedule timestamp");
        return static_cast<Instant>(number);
    }
    static int integer(const Object& object,const wchar_t* key,int fallback){
        const auto value=object.GetNamedValue(key,Value::CreateNullValue());if(value.ValueType()==Type::Null)return fallback;
        const auto number=value.GetNumber();if(!std::isfinite(number)||number<0||number>1000000||number!=std::floor(number))throw std::invalid_argument("Invalid schedule number");return static_cast<int>(number);
    }
    static void put(const Object& object,const wchar_t* key,const std::string& value){object.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(value)));}
    static void put(const Object& object,const wchar_t* key,std::optional<Instant> value){object.SetNamedValue(key,value?Value::CreateNumberValue(static_cast<double>(*value)):Value::CreateNullValue());}
    static std::string kind_name(RecurrenceKind kind){
        switch(kind){case RecurrenceKind::once:return "once";case RecurrenceKind::daily:return "daily";case RecurrenceKind::weekly:return "weekly";case RecurrenceKind::weekdays:return "weekdays";case RecurrenceKind::days:return "days";case RecurrenceKind::interval:return "interval";case RecurrenceKind::cron:return "cron";}
        throw std::invalid_argument("Unknown schedule recurrence");
    }
    static RecurrenceKind kind(std::string_view value){
        if(value=="once")return RecurrenceKind::once;if(value=="daily")return RecurrenceKind::daily;if(value=="weekly")return RecurrenceKind::weekly;
        if(value=="weekdays")return RecurrenceKind::weekdays;if(value=="days")return RecurrenceKind::days;if(value=="interval")return RecurrenceKind::interval;if(value=="cron")return RecurrenceKind::cron;
        throw std::invalid_argument("Unsupported schedule recurrence");
    }
    TaskRecurrence read_recurrence(const Object& value){
        TaskRecurrence result;result.kind=kind(text(value,L"kind"));result.time_zone=text(value,L"timeZone");result.date=instant(value,L"date").value_or(0);
        result.hour=integer(value,L"hour",9);result.minute=integer(value,L"minute",0);result.day_of_week=integer(value,L"weekday",2);
        result.interval_minutes=integer(value,L"intervalMinutes",0);result.cron=text(value,L"cron");
        const auto days=value.GetNamedValue(L"weekdays",Value::CreateNullValue());if(days.ValueType()!=Type::Null){const auto array=days.GetArray();if(array.Size()>7)throw std::invalid_argument("Too many recurrence weekdays");
            for(const auto& day:array){const auto number=day.GetNumber();if(number<1||number>7||number!=std::floor(number))throw std::invalid_argument("Invalid recurrence weekday");result.weekdays.push_back(static_cast<int>(number));}}
        if(!result.valid(calendar_))throw std::invalid_argument("Invalid or unsupported schedule recurrence");return result;
    }
    static Object recurrence_json(const TaskRecurrence& recurrence,const Object& original){
        auto value=clone(original);put(value,L"kind",kind_name(recurrence.kind));put(value,L"timeZone",recurrence.time_zone);put(value,L"date",recurrence.date);
        value.SetNamedValue(L"hour",Value::CreateNumberValue(recurrence.hour));value.SetNamedValue(L"minute",Value::CreateNumberValue(recurrence.minute));value.SetNamedValue(L"weekday",Value::CreateNumberValue(recurrence.day_of_week));
        value.SetNamedValue(L"intervalMinutes",Value::CreateNumberValue(recurrence.interval_minutes));put(value,L"cron",recurrence.cron);Array days;for(const int day:recurrence.weekdays)days.Append(Value::CreateNumberValue(day));value.SetNamedValue(L"weekdays",days);return value;
    }
    static void valid_text(std::string_view value,std::size_t limit,bool nonblank){
        if(value.size()>limit)throw std::invalid_argument("Schedule text exceeds its limit");bool content=false;
        for(std::size_t offset=0;offset<value.size();){const auto code=workspace_text::next(value,offset);if(code==0)throw std::invalid_argument("Schedule text cannot contain NUL");if(!workspace_text::whitespace(code))content=true;}
        if(nonblank&&!content)throw std::invalid_argument("A schedule needs a name and prompt");
    }
    void validate(const std::vector<ScheduledTask>& values){
        if(values.size()>task_limit)throw std::invalid_argument("Too many scheduled tasks");
        std::unordered_set<std::string> identities;std::unordered_map<std::string,std::size_t> threads;
        for(const auto& task:values){const auto id=identity(task.id),thread=identity(task.thread_id);if(!identities.insert(id).second||++threads[thread]>10)throw std::invalid_argument("Duplicate schedule identity or more than ten schedules in one thread");
            (void)workspace_text::label(task.name,200);valid_text(task.prompt,20000,true);valid_text(task.last_message,4096,false);
            if(!task.recurrence.valid(calendar_))throw std::invalid_argument("Invalid schedule recurrence");
            for(const auto timestamp:{task.next_run,task.pending_delivery,task.in_flight,task.last_fired,task.last_run,task.last_finished})if(timestamp&&(*timestamp<0||*timestamp>maximum_instant))throw std::invalid_argument("Invalid schedule state timestamp");
            if(task.in_flight.has_value()!=!task.delivery_id.empty())throw std::invalid_argument("Invalid schedule delivery identity");if(task.in_flight)(void)identity(task.delivery_id);
            if(task.in_flight&&task.pending_delivery)throw std::invalid_argument("A schedule cannot be pending and in flight together");
            if((task.in_flight||task.pending_delivery)&&(!task.last_fired||*task.last_fired<std::max(task.in_flight.value_or(0),task.pending_delivery.value_or(0))))throw std::invalid_argument("Unconsumed schedule delivery state");
            if((task.approval_pending||task.review_required)&&task.in_flight)throw std::invalid_argument("An unapproved or uncertain schedule cannot be in flight");
            if(task.last_outcome!=""&&task.last_outcome!="completed"&&task.last_outcome!="failed"&&task.last_outcome!="interrupted"&&task.last_outcome!="missed")throw std::invalid_argument("Unsupported schedule outcome");
        }
    }
    static std::optional<std::string> read(const std::filesystem::path& path){
        if(!std::filesystem::exists(path))return std::nullopt;if(std::filesystem::file_size(path)>file_limit)throw std::runtime_error("The schedule file exceeds its size limit");
        std::ifstream input(path,std::ios::binary);if(!input)throw std::runtime_error("Could not open the schedule file");std::string result((std::istreambuf_iterator<char>(input)),std::istreambuf_iterator<char>());
        if(input.bad()||result.size()>file_limit)throw std::runtime_error("Could not read the schedule file");return result;
    }
    std::filesystem::path file()const{return directory_/L"scheduled-tasks.json";}
    void require_open()const{if(!opened_)throw std::runtime_error("The schedule store is not open; its original file has been preserved");}
    static std::size_t find(const std::vector<ScheduledTask>& tasks,std::string_view id){const auto canonical=identity(id);for(std::size_t index=0;index<tasks.size();++index)if(identity(tasks[index].id)==canonical)return index;throw std::out_of_range("Schedule not found");}
    Object encode(const std::vector<ScheduledTask>& values){
        auto root=clone(original_);std::unordered_map<std::string,Object> originals;
        if(original_)for(const auto& raw:original_.GetNamedArray(L"tasks")){const auto value=raw.GetObject();originals.emplace(identity(text(value,L"id")),value);}
        root.SetNamedValue(L"version",Value::CreateNumberValue(1));put(root,L"format","coincide.windows.schedules");Array tasks;
        for(const auto& task:values){auto value=clone(originals.contains(identity(task.id))?originals.at(identity(task.id)):Object{nullptr});
            put(value,L"id",task.id);put(value,L"threadID",task.thread_id);put(value,L"name",task.name);put(value,L"prompt",task.prompt);
            value.SetNamedValue(L"recurrence",recurrence_json(task.recurrence,value.GetNamedObject(L"recurrence",Object{})));
            value.SetNamedValue(L"awaitingApproval",Value::CreateBooleanValue(task.approval_pending));value.SetNamedValue(L"paused",Value::CreateBooleanValue(task.paused));value.SetNamedValue(L"reviewRequired",Value::CreateBooleanValue(task.review_required));
            put(value,L"nextRunAt",task.next_run);put(value,L"pendingDelivery",task.pending_delivery);put(value,L"inFlight",task.in_flight);put(value,L"lastFiredOccurrence",task.last_fired);put(value,L"lastRunAt",task.last_run);put(value,L"lastFinishedAt",task.last_finished);
            put(value,L"deliveryID",task.delivery_id);put(value,L"lastOutcome",task.last_outcome);put(value,L"lastMessage",task.last_message);tasks.Append(value);}
        root.SetNamedValue(L"tasks",tasks);return root;
    }
    void commit(std::vector<ScheduledTask> values){
        require_open();validate(values);auto document=encode(values);const auto bytes=winrt::to_string(document.Stringify());if(bytes.size()>file_limit)throw std::runtime_error("The schedule file exceeds its write limit");
        std::optional<std::string> next_snapshot(bytes);auto temporary=file();temporary+=winrt::to_hstring("."+schedule_identity()+".tmp").c_str();
        std::filesystem::create_directories(directory_);
        // Serialize cooperating stores and refuse stale snapshots rather than overwriting edits
        // made by another app/process. A failed write changes neither our state nor originals.
        const auto lock_path=directory_/L"scheduled-tasks.lock";const auto lock=CreateFileW(lock_path.c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(lock==INVALID_HANDLE_VALUE)winrt::throw_last_error();
        try{
            if(read(file())!=snapshot_)throw std::runtime_error("The schedule file changed in another process; reopen it before editing");
            const auto handle=CreateFileW(temporary.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(handle==INVALID_HANDLE_VALUE)winrt::throw_last_error();
            DWORD written{};const bool ok=WriteFile(handle,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)&&written==bytes.size()&&FlushFileBuffers(handle);const auto error=GetLastError();CloseHandle(handle);
            if(!ok)throw winrt::hresult_error(HRESULT_FROM_WIN32(error?error:ERROR_WRITE_FAULT));
            if(!MoveFileExW(temporary.c_str(),file().c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))winrt::throw_last_error();
            tasks_.swap(values);original_=std::move(document);snapshot_.swap(next_snapshot);
        }catch(...){DeleteFileW(temporary.c_str());CloseHandle(lock);throw;}
        CloseHandle(lock);
    }
public:
    explicit ScheduleStore(std::filesystem::path directory,Calendar& calendar):directory_(std::move(directory)),calendar_(calendar){}
    void open(Instant now){
        validate_now(now);opened_=false;tasks_.clear();original_=nullptr;snapshot_.reset();
        const auto bytes=read(file());std::vector<ScheduledTask> decoded;Object original{nullptr};
        if(bytes){original=Object::Parse(winrt::to_hstring(*bytes));if(original.GetNamedNumber(L"version")!=1||text(original,L"format")!="coincide.windows.schedules")throw std::runtime_error("This schedule format is not supported; its file was preserved");
            const auto array=original.GetNamedArray(L"tasks");if(array.Size()>task_limit)throw std::invalid_argument("Too many scheduled tasks");
            for(const auto& raw:array){const auto value=raw.GetObject();ScheduledTask task;task.id=identity(text(value,L"id"));task.thread_id=identity(text(value,L"threadID"));task.name=text(value,L"name");task.prompt=text(value,L"prompt");
                task.recurrence=read_recurrence(value.GetNamedObject(L"recurrence"));task.approval_pending=boolean(value,L"awaitingApproval",true);task.paused=boolean(value,L"paused");task.review_required=boolean(value,L"reviewRequired");
                task.next_run=instant(value,L"nextRunAt");task.pending_delivery=instant(value,L"pendingDelivery");task.in_flight=instant(value,L"inFlight");task.last_fired=instant(value,L"lastFiredOccurrence");task.last_run=instant(value,L"lastRunAt");task.last_finished=instant(value,L"lastFinishedAt");
                task.delivery_id=text(value,L"deliveryID");task.last_outcome=text(value,L"lastOutcome");task.last_message=text(value,L"lastMessage");decoded.push_back(std::move(task));}
            validate(decoded);}
        auto recovered=scheduling::recover(std::move(decoded),now,true,calendar_);original_=original;snapshot_=bytes;opened_=true;
        try{if(recovered.changed)commit(std::move(recovered.tasks));else tasks_=std::move(recovered.tasks);}catch(...){opened_=false;tasks_.clear();throw;}
    }
    const std::vector<ScheduledTask>& tasks()const{require_open();return tasks_;}
    const ScheduledTask& task(std::string_view id)const{require_open();return tasks_.at(find(tasks_,id));}
    std::string create(ScheduledTask task,Instant now){
        require_open();validate_now(now);task.id=task.id.empty()?schedule_identity():identity(task.id);task.thread_id=identity(task.thread_id);task.name=workspace_text::label(task.name,200);
        if(task.recurrence.kind==RecurrenceKind::once&&task.recurrence.date<=now)throw std::invalid_argument("One-time schedules need a future date");
        task.approval_pending=true;task.paused=false;task.review_required=false;task.pending_delivery.reset();task.in_flight.reset();task.delivery_id.clear();task.last_fired.reset();task.last_run.reset();task.last_finished.reset();task.last_outcome.clear();task.last_message.clear();advance(task,now,calendar_);
        auto values=tasks_;values.push_back(task);commit(std::move(values));return task.id;
    }
    void update(std::string_view id,std::string name,std::string prompt,TaskRecurrence recurrence,Instant now){
        require_open();validate_now(now);auto values=tasks_;auto& task=values.at(find(values,id));if(task.in_flight)throw std::runtime_error("Finish the active delivery before editing its schedule");
        if(recurrence.kind==RecurrenceKind::once&&recurrence.date<=now)throw std::invalid_argument("One-time schedules need a future date");
        task.name=workspace_text::label(name,200);task.prompt=std::move(prompt);task.recurrence=std::move(recurrence);task.approval_pending=true;task.pending_delivery.reset();advance(task,now,calendar_);commit(std::move(values));
    }
    void approve(std::string_view id,Instant now){
        require_open();validate_now(now);auto values=tasks_;auto& task=values.at(find(values,id));if(task.in_flight)throw std::runtime_error("This schedule already has an active delivery");
        if(task.recurrence.kind==RecurrenceKind::once&&task.recurrence.date<=now)throw std::invalid_argument("Edit the one-time schedule to a future date before approving it");
        task.approval_pending=false;advance(task,now,calendar_);commit(std::move(values));
    }
    void pause(std::string_view id){require_open();auto values=tasks_;auto& task=values.at(find(values,id));task.paused=true;task.pending_delivery.reset();commit(std::move(values));}
    void resume(std::string_view id,Instant now){
        require_open();validate_now(now);auto values=tasks_;auto& task=values.at(find(values,id));if(task.approval_pending)throw std::runtime_error("Approve the schedule before resuming it");if(task.review_required)throw std::runtime_error("Review the interrupted conversation before resuming this schedule");
        task.paused=false;task.pending_delivery.reset();advance(task,now,calendar_);commit(std::move(values));
    }
    void review_and_resume(std::string_view id,Instant now){
        require_open();validate_now(now);auto values=tasks_;auto& task=values.at(find(values,id));if(task.approval_pending)throw std::runtime_error("Approve the schedule before resuming it");if(task.in_flight)throw std::runtime_error("This schedule still has an active delivery");
        task.review_required=false;task.paused=false;task.pending_delivery.reset();advance(task,now,calendar_);commit(std::move(values));
    }
    void remove(std::string_view id){require_open();auto values=tasks_;const auto index=find(values,id);if(values[index].in_flight)throw std::runtime_error("Finish the active delivery before removing its schedule");values.erase(values.begin()+static_cast<std::ptrdiff_t>(index));commit(std::move(values));}
    std::vector<DeliveryIntent> run_now(std::string_view id,Instant now,const std::unordered_set<std::string>& busy_threads){
        require_open();validate_now(now);auto values=tasks_;auto& task=values.at(find(values,id));
        if(task.approval_pending)throw std::runtime_error("Approve the schedule before running it");
        if(task.paused)throw std::runtime_error("Resume the schedule before running it");
        if(task.review_required)throw std::runtime_error("Review the interrupted delivery before running this schedule");
        if(task.in_flight||task.pending_delivery)throw std::runtime_error("This schedule already has a running or pending delivery");
        bool busy{};for(const auto& thread:busy_threads)if(identity(thread)==task.thread_id)busy=true;
        for(const auto& other:values)if(other.thread_id==task.thread_id&&other.in_flight)busy=true;
        std::vector<DeliveryIntent> result;consumed(task,now);
        if(busy)task.pending_delivery=now;else deliver(task,now,now,schedule_identity,result);
        // A manual run does not alter the configured recurrence or imply approval of a change.
        // The durable in-flight/pending marker is saved before the host receives a delivery.
        commit(std::move(values));return result;
    }
    std::vector<DeliveryIntent> tick(Instant now,const std::unordered_set<std::string>& busy_threads){
        require_open();std::unordered_set<std::string> busy;for(const auto& id:busy_threads)busy.insert(identity(id));auto change=scheduling::tick(tasks_,now,std::move(busy),calendar_,schedule_identity);
        if(change.changed)commit(std::move(change.tasks));return change.deliveries;
    }
    void wake(Instant now){require_open();auto change=scheduling::recover(tasks_,now,false,calendar_);if(change.changed)commit(std::move(change.tasks));}
    void finish(std::string_view id,std::string_view delivery,Instant now,bool success,std::string message={}){
        require_open();validate_now(now);auto values=tasks_;auto& task=values.at(find(values,id));if(!task.in_flight||identity(task.delivery_id)!=identity(delivery))throw std::runtime_error("This schedule delivery is no longer active");
        task.in_flight.reset();task.delivery_id.clear();task.last_finished=now;task.last_outcome=success?"completed":"failed";task.last_message=std::move(message);if(!success)task.paused=true;
        if(task.next_run&&*task.next_run<=now)advance(task,now,calendar_);commit(std::move(values));
    }
    void mark_uncertain(std::string_view id,std::string_view delivery,Instant now,std::string message={}){
        require_open();validate_now(now);auto values=tasks_;auto& task=values.at(find(values,id));if(!task.in_flight||identity(task.delivery_id)!=identity(delivery))throw std::runtime_error("This schedule delivery is no longer active");
        task.in_flight.reset();task.delivery_id.clear();task.pending_delivery.reset();task.review_required=true;task.paused=true;task.last_finished=now;task.last_outcome="interrupted";task.last_message=std::move(message);commit(std::move(values));
    }
};
} // namespace coincide::scheduling
