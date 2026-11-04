#pragma once
#include "SchedulerCore.h"
#include <functional>
#include <unordered_set>

namespace coincide::scheduling {
struct ScheduledTask {
    std::string id,thread_id,name,prompt;
    TaskRecurrence recurrence;
    bool approval_pending{true},paused{},review_required{};
    std::optional<Instant> next_run,pending_delivery,in_flight,last_fired,last_run,last_finished;
    std::string delivery_id,last_outcome,last_message;
    bool active()const{return !approval_pending&&!paused&&!review_required;}
};
struct DeliveryIntent {std::string schedule_id,delivery_id,thread_id,prompt;Instant occurrence{};};
struct ScheduleTransition {std::vector<ScheduledTask> tasks;std::vector<DeliveryIntent> deliveries;bool changed{};};
inline void validate_now(Instant now){if(now<0||now>maximum_instant)throw std::invalid_argument("Invalid schedule clock");}
inline void advance(ScheduledTask& task,Instant now,Calendar& calendar){task.next_run=task.recurrence.next(now,calendar);}
inline void consumed(ScheduledTask& task,Instant occurrence){task.last_fired=std::max(task.last_fired.value_or(0),occurrence);}
inline void deliver(ScheduledTask& task,Instant occurrence,Instant now,const std::function<std::string()>& identity,std::vector<DeliveryIntent>& intents){
    task.in_flight=occurrence;task.delivery_id=identity();task.pending_delivery.reset();task.last_run=now;task.last_finished.reset();task.last_outcome.clear();task.last_message.clear();
    intents.push_back({task.id,task.delivery_id,task.thread_id,task.prompt,occurrence});
}
// These helpers produce state + intents only. The store MUST commit the entire transition
// before exposing intents. There are no model, message, timer, notification or OS actions here.
inline ScheduleTransition tick(std::vector<ScheduledTask> tasks,Instant now,std::unordered_set<std::string> busy,Calendar& calendar,const std::function<std::string()>& identity){
    validate_now(now);ScheduleTransition result{std::move(tasks),{},false};
    // Include in-flight schedules even if the caller's busy snapshot has not caught up yet.
    for(const auto& task:result.tasks)if(task.in_flight)busy.insert(task.thread_id);
    for(auto& task:result.tasks){
        if(!task.active())continue;
        const bool due=task.next_run&&*task.next_run<=now;if(!due&&!task.pending_delivery)continue;
        if(task.in_flight){if(due){consumed(task,*task.next_run);advance(task,now,calendar);result.changed=true;}continue;}
        std::optional<Instant> occurrence=task.pending_delivery;
        if(due){const auto candidate=*task.next_run;advance(task,now,calendar);result.changed=true;
            if(!task.last_fired||candidate>*task.last_fired){consumed(task,candidate);occurrence=candidate;}}
        if(!occurrence)continue;
        if(busy.contains(task.thread_id)){if(task.pending_delivery!=occurrence){task.pending_delivery=occurrence;result.changed=true;}continue;}
        consumed(task,*occurrence);deliver(task,*occurrence,now,identity,result.deliveries);busy.insert(task.thread_id);result.changed=true;
    }
    return result;
}
inline ScheduleTransition recover(std::vector<ScheduledTask> tasks,Instant now,bool relaunch,Calendar& calendar){
    validate_now(now);ScheduleTransition result{std::move(tasks),{},false};
    for(auto& task:result.tasks){
        if(relaunch&&task.in_flight){task.in_flight.reset();task.delivery_id.clear();task.review_required=true;task.paused=true;
            task.last_outcome="interrupted";task.last_message="The app closed before delivery finished. Review the conversation before resuming.";task.last_finished=now;result.changed=true;}
        if(task.pending_delivery){task.pending_delivery.reset();if(!task.review_required){task.last_outcome="missed";task.last_message="A pending run was skipped while the app was closed or asleep.";}result.changed=true;}
        if(task.next_run&&*task.next_run<=now){consumed(task,*task.next_run);advance(task,now,calendar);
            if(!task.in_flight&&!task.review_required&&!task.approval_pending){task.last_outcome="missed";task.last_message="An occurrence was skipped while the app was closed or asleep.";}result.changed=true;}
    }
    return result;
}
} // namespace coincide::scheduling
