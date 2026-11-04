#pragma once
#include "ScheduleStore.h"
#include "AppToolBridgeProtocol.h"

namespace coincide::scheduling {
class ScheduleTool {
    using Object=app_tools::Object;using Value=app_tools::Value;using Array=winrt::Windows::Data::Json::JsonArray;
    static int digits(std::string_view text,std::size_t at,std::size_t count){int result{};if(at+count>text.size())app_tools::invalid();for(std::size_t i=at;i<at+count;++i){if(text[i]<'0'||text[i]>'9')app_tools::invalid();result=result*10+text[i]-'0';}return result;}
    static Instant at(const std::string& text,const std::string& zone,Calendar& calendar){
        if(text.size()<16||text[4]!='-'||text[7]!='-'||text[10]!='T'||text[13]!=':')throw std::invalid_argument("Use an ISO date and time for a one-time schedule");
        const CivilDate date{digits(text,0,4),digits(text,5,2),digits(text,8,2)};const auto hour=digits(text,11,2),minute=digits(text,14,2);int second{};std::size_t index=16;
        if(index<text.size()&&text[index]==':'){second=digits(text,index+1,2);index+=3;}
        if(index<text.size()&&text[index]=='.'){const auto start=++index;while(index<text.size()&&text[index]>='0'&&text[index]<='9')++index;if(index==start||index-start>9)app_tools::invalid();}
        const auto wall=wall_seconds({date,hour,minute,second});Instant value{};
        if(index==text.size()){const auto resolved=calendar.resolve(date,hour,minute,zone);if(!resolved)throw std::invalid_argument("This local date does not exist in the selected time zone");value=*resolved+second;}
        else if(text[index]=='Z'&&index+1==text.size())value=wall;
        else if((text[index]=='+'||text[index]=='-')&&index+6==text.size()&&text[index+3]==':'){
            const auto hours=digits(text,index+1,2),minutes=digits(text,index+4,2);if(hours>14||minutes>59||(hours==14&&minutes))app_tools::invalid();const auto offset=(hours*60+minutes)*60;value=wall+(text[index]=='+'?-offset:offset);
        }else app_tools::invalid();
        if(value<0||value>maximum_instant)throw std::invalid_argument("The schedule date is outside the supported range");return value;
    }
    static int day(const std::string& value){if(value=="sun"||value=="sunday")return 1;if(value=="mon"||value=="monday")return 2;if(value=="tue"||value=="tuesday")return 3;if(value=="wed"||value=="wednesday")return 4;if(value=="thu"||value=="thursday")return 5;if(value=="fri"||value=="friday")return 6;if(value=="sat"||value=="saturday")return 7;app_tools::invalid();return 0;}
    static std::string kind(RecurrenceKind value){switch(value){case RecurrenceKind::once:return "once";case RecurrenceKind::daily:return "daily";case RecurrenceKind::weekly:return "weekly";case RecurrenceKind::weekdays:return "weekdays";case RecurrenceKind::days:return "days";case RecurrenceKind::interval:return "interval";case RecurrenceKind::cron:return "cron";}app_tools::invalid();return{};}
    static Object recurrence_json(const TaskRecurrence& task){
        Object value;computer_use::put(value,L"kind",kind(task.kind));computer_use::put(value,L"timeZone",task.time_zone);
        if(task.kind==RecurrenceKind::once){const auto date=utc_time(task.date);const auto pad=[](int number,std::size_t width){auto text=std::to_string(number);return std::string(width>text.size()?width-text.size():0,'0')+text;};computer_use::put(value,L"at",pad(date.date.year,4)+"-"+pad(date.date.month,2)+"-"+pad(date.date.day,2)+"T"+pad(date.hour,2)+":"+pad(date.minute,2)+":"+pad(date.second,2)+"Z");}
        else if(task.kind==RecurrenceKind::interval)value.SetNamedValue(L"minutes",Value::CreateNumberValue(task.interval_minutes));
        else if(task.kind==RecurrenceKind::cron)computer_use::put(value,L"expression",task.cron);
        else {const auto two=[](int n){return std::string(n<10?"0":"")+std::to_string(n);};computer_use::put(value,L"time",two(task.hour)+":"+two(task.minute));
            constexpr const char* names[]{"sun","mon","tue","wed","thu","fri","sat"};if(task.kind==RecurrenceKind::weekly)computer_use::put(value,L"day",names[task.day_of_week-1]);if(task.kind==RecurrenceKind::days){Array days;for(const auto n:task.weekdays)days.Append(Value::CreateStringValue(winrt::to_hstring(names[n-1])));value.SetNamedValue(L"days",days);}}
        return value;
    }
public:
    static TaskRecurrence recurrence(const Object& spec,Instant now,const std::string& default_zone,Calendar& calendar){
        TaskRecurrence result;const auto name=app_tools::text(spec,L"kind",20);result.time_zone=app_tools::text(spec,L"timeZone",128,false);if(result.time_zone.empty())result.time_zone=default_zone;
        if(!calendar.valid_zone(result.time_zone))throw std::invalid_argument("Choose a valid IANA time zone");
        if(name=="once"){result.kind=RecurrenceKind::once;result.date=spec.HasKey(L"at")?at(app_tools::text(spec,L"at",80),result.time_zone,calendar):now+static_cast<Instant>(app_tools::number(spec,L"inMinutes",1,525600,{},true))*60;}
        else if(name=="interval"){result.kind=RecurrenceKind::interval;result.date=now;result.interval_minutes=static_cast<int>(spec.HasKey(L"minutes")?app_tools::number(spec,L"minutes",5,44640,{},true):app_tools::number(spec,L"hours",1,744,{},true)*60);}
        else if(name=="cron"){result.kind=RecurrenceKind::cron;result.cron=app_tools::text(spec,L"expression",256);}
        else {if(name=="daily")result.kind=RecurrenceKind::daily;else if(name=="weekdays")result.kind=RecurrenceKind::weekdays;else if(name=="weekly")result.kind=RecurrenceKind::weekly;else if(name=="days")result.kind=RecurrenceKind::days;else app_tools::invalid();const auto time=app_tools::text(spec,L"time",5);result.hour=digits(time,0,2);result.minute=digits(time,3,2);if(result.kind==RecurrenceKind::weekly)result.day_of_week=day(app_tools::text(spec,L"day",12));if(result.kind==RecurrenceKind::days){for(const auto& raw:spec.GetNamedArray(L"days"))result.weekdays.push_back(day(winrt::to_string(raw.GetString())));std::sort(result.weekdays.begin(),result.weekdays.end());result.weekdays.erase(std::unique(result.weekdays.begin(),result.weekdays.end()),result.weekdays.end());}}
        if(!result.valid(calendar)||(result.kind==RecurrenceKind::once&&result.date<=now))throw std::invalid_argument("Choose a valid future schedule; repeat intervals must be at least five minutes");return result;
    }
    static Object json(const ScheduledTask& task){Object value;computer_use::put(value,L"id",task.id);computer_use::put(value,L"name",task.name);computer_use::put(value,L"prompt",task.prompt);value.SetNamedValue(L"schedule",recurrence_json(task.recurrence));value.SetNamedValue(L"awaitingApproval",Value::CreateBooleanValue(task.approval_pending));value.SetNamedValue(L"paused",Value::CreateBooleanValue(task.paused));value.SetNamedValue(L"reviewRequired",Value::CreateBooleanValue(task.review_required));value.SetNamedValue(L"running",Value::CreateBooleanValue(task.in_flight.has_value()));value.SetNamedValue(L"pending",Value::CreateBooleanValue(task.pending_delivery.has_value()));value.SetNamedValue(L"nextRunAt",task.next_run?Value::CreateNumberValue(static_cast<double>(*task.next_run)):Value::CreateNullValue());computer_use::put(value,L"lastOutcome",task.last_outcome);computer_use::put(value,L"lastMessage",task.last_message);return value;}
    static Object request(ScheduleStore& store,Calendar& calendar,const std::string& thread,const std::string& bytes,Instant now,const std::string& zone,const std::unordered_set<std::string>& busy,std::vector<DeliveryIntent>& deliveries){
        const auto validated=app_tools::Request::parse(app_tools::Channel::schedule,bytes);const auto object=Object::Parse(winrt::to_hstring(validated.json));const auto owner=winrt::to_string(winrt::to_hstring(winrt::guid(winrt::to_hstring(thread))));
        if(validated.action=="list"){Object result;Array tasks;for(const auto& task:store.tasks())if(task.thread_id==owner)tasks.Append(json(task));result.SetNamedValue(L"tasks",tasks);return result;}
        if(validated.action=="create"){ScheduledTask task;task.thread_id=owner;task.name=app_tools::text(object,L"name",200);task.prompt=app_tools::text(object,L"prompt",20000);task.recurrence=recurrence(object.GetNamedObject(L"schedule"),now,zone,calendar);return json(store.task(store.create(std::move(task),now)));}
        const auto id=app_tools::text(object,L"id",38);const auto task=store.task(id);if(task.thread_id!=owner)throw std::invalid_argument("This schedule belongs to another conversation");
        if(validated.action=="update"){store.update(id,object.HasKey(L"name")?app_tools::text(object,L"name",200):task.name,object.HasKey(L"prompt")?app_tools::text(object,L"prompt",20000):task.prompt,object.HasKey(L"schedule")?recurrence(object.GetNamedObject(L"schedule"),now,zone,calendar):task.recurrence,now);}
        else if(validated.action=="pause")store.pause(id);else if(validated.action=="resume")store.resume(id,now);
        else if(validated.action=="delete"){store.remove(id);Object result;computer_use::put(result,L"deleted",id);return result;}
        else if(validated.action=="run-now")deliveries=store.run_now(id,now,busy);else app_tools::invalid();return json(store.task(id));
    }
};
} // namespace coincide::scheduling
