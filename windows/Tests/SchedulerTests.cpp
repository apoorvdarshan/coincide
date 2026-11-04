#include "../Core/SchedulerCore.h"
#include "../Core/ScheduleCoordinator.h"
#include <iostream>
#include <functional>

namespace {
using namespace coincide::scheduling;
int checks{};
void check(bool value,const char* failure){++checks;if(!value)throw std::runtime_error(failure);}
template<class Operation>void rejects(Operation operation,const char* failure){bool rejected{};try{operation();}catch(const std::invalid_argument&){rejected=true;}check(rejected,failure);}
Instant at(int year,int month,int day,int hour=0,int minute=0,int second=0){return wall_seconds({{year,month,day},hour,minute,second});}
// An independently specified 2026 fixture calendar. Real OS/IANA behavior is checked in
// WindowsCalendarTests.h, while recurrence policies remain portable and wall-clock-free.
class FixtureCalendar final:public Calendar {
public:
    bool valid_zone(std::string_view zone)override{return zone=="UTC"||zone=="Asia/Kolkata"||zone=="America/New_York";}
    LocalTime local_time(Instant value,std::string_view zone)override{
        if(!valid_zone(zone))throw std::invalid_argument("Invalid fixture zone");
        const int offset=zone=="Asia/Kolkata"?19800:zone=="America/New_York"?(value>=at(2026,3,8,7)&&value<at(2026,11,1,6)?-14400:-18000):0;
        return utc_time(value+offset);
    }
    std::optional<Instant> resolve(CivilDate day,int hour,int minute,std::string_view zone)override{
        if(!valid_zone(zone))throw std::invalid_argument("Invalid fixture zone");const auto wall=wall_seconds({day,hour,minute,0});
        if(zone=="UTC")return wall;if(zone=="Asia/Kolkata")return wall-19800;
        const LocalTime wanted{day,hour,minute,0};std::optional<Instant> first;
        for(const int offset:{-14400,-18000})if(local_time(wall-offset,zone)==wanted&&(!first||wall-offset<*first))first=wall-offset;
        if(!first&&day==CivilDate{2026,3,8}&&hour==2)return at(2026,3,8,7);return first;
    }
};
}

int main(){
    try{
        UtcCalendar utc;FixtureCalendar zones;
        check(civil_days({1970,1,1})==0&&weekday({1970,1,1})==5,"The Gregorian epoch and Sunday-based weekday must agree");
        for(const CivilDate value:std::vector<CivilDate>{{1,1,1},{1601,1,1},{1969,12,31},{2000,2,29},{2026,11,4},{9999,12,31}})
            check(date_from_days(civil_days(value))==value,"Civil date arithmetic must round trip without local time or time_t limits");
        check(month_length(2000,2)==29&&month_length(1900,2)==28&&month_length(2028,2)==29,"Gregorian leap-century rules must be accurate");
        rejects([]{(void)civil_days({2026,2,29});},"Invalid dates must be rejected");
        check(utc_time(-1)==LocalTime{{1969,12,31},23,59,59},"Negative civil arithmetic must use floor rather than truncate days");

        TaskRecurrence recurrence;recurrence.hour=9;recurrence.minute=15;
        check(recurrence.next(at(2026,11,4,9,14,59),utc)==at(2026,11,4,9,15),"A daily occurrence strictly in the future must remain today");
        check(recurrence.next(at(2026,11,4,9,15),utc)==at(2026,11,5,9,15),"An exact occurrence must never be returned twice");
        recurrence.kind=RecurrenceKind::weekly;recurrence.day_of_week=2;recurrence.time_zone="Asia/Kolkata";
        check(recurrence.next(at(2026,10,28,12),zones)==at(2026,11,2,3,45),"Weekly recurrence must use its IANA-zone weekday and time");
        recurrence.kind=RecurrenceKind::weekdays;recurrence.time_zone="UTC";
        check(recurrence.next(at(2026,11,6,10),utc)==at(2026,11,9,9,15),"Weekdays must skip Saturday and Sunday");
        recurrence.kind=RecurrenceKind::days;recurrence.weekdays={2,5,2};
        check(recurrence.next(at(2026,11,4),utc)==at(2026,11,5,9,15),"Selected-day recurrence must tolerate duplicate days without duplicate runs");
        recurrence.weekdays.clear();check(!recurrence.valid(utc)&&!recurrence.next(at(2026,11,4),utc),"A selected-day recurrence needs at least one valid day");
        recurrence.weekdays={8};check(!recurrence.valid(utc),"Out-of-range weekdays must be invalid");

        recurrence={};recurrence.kind=RecurrenceKind::once;recurrence.date=at(2026,11,5,12);
        check(recurrence.next(at(2026,11,5,11),utc)==recurrence.date&&!recurrence.next(recurrence.date,utc),"One-time recurrences must be strictly future and finite");
        recurrence.kind=RecurrenceKind::interval;recurrence.interval_minutes=15;const auto anchor=recurrence.date;
        check(recurrence.next(anchor-1,utc)==anchor,"An interval's first run must retain its anchor");
        check(recurrence.next(anchor,utc)==anchor+900&&recurrence.next(anchor+9999,utc)==anchor+10800,"Late or resumed intervals must keep phase rather than drifting from now");
        recurrence.interval_minutes=4;check(!recurrence.valid(utc),"Intervals must not run more often than every five minutes");
        recurrence.interval_minutes=31*1440+1;check(!recurrence.valid(utc),"Interval units must be bounded to thirty-one days");
        recurrence.interval_minutes=5;recurrence.date=maximum_instant-10;
        check(!recurrence.next(maximum_instant-5,utc),"Interval arithmetic must stop at its timestamp range instead of overflow");
        recurrence={};recurrence.time_zone="invalid/zone";check(!recurrence.next(at(2026,11,4),zones),"Unsupported IANA identifiers must fail closed");
        recurrence.time_zone="UTC";recurrence.hour=24;check(!recurrence.valid(utc),"Hours must be within a 24-hour clock");

        for(const auto bad:{"","* * * *","0 9 * * * *","60 * * * *","0 24 * * *","0 9 0 * *","0 9 * 13 *","0 9 * * 8","5-1 * * * *","*/0 * * * *","0 9 * * funday","0,,5 * * * *","0 9 * * 1/","* * * * *","*/4 * * * *","58,1 * * * *","0 9 30 2 *"})
            rejects([&]{(void)CronExpression(bad);},"Malformed, impossible, or too-frequent cron expressions must be rejected");
        const CronExpression steps("*/15 9-17/4 1,15 JAN,jul *");
        check(steps.minutes()==std::vector<int>{0,15,30,45}&&steps.hours()==std::vector<int>{9,13,17},"Cron lists, steps, names and ranges must compose");
        check(steps.runs_on({2026,1,15})&&!steps.runs_on({2026,2,15})&&!steps.runs_on({2026,1,16}),"Cron month and day restrictions must match their fields");
        check(CronExpression("10/20 * * * *").minutes()==std::vector<int>{10,30,50},"A numeric cron step must extend from that value through the field's end");
        check(CronExpression("30 6 * * 7").runs_on({2026,11,1})&&!CronExpression("30 6 * * 7").runs_on({2026,11,2}),"Cron Sunday must accept seven as well as zero");
        check(CronExpression("0 9 * * MON-FRI").runs_on({2026,11,2}),"Cron English weekday names must be case-insensitive");
        for(const auto text:{"@hourly","@daily","@midnight","@weekly","@monthly","@yearly","@annually"})check(CronExpression(text).next(at(2026,11,4),"UTC",utc).has_value(),"Documented cron shorthands must run");
        const CronExpression either("0 12 13 * 5");auto cursor=at(2026,11,1);std::vector<Instant> runs;
        for(int index=0;index<3;++index){cursor=*either.next(cursor,"UTC",utc);runs.push_back(cursor);}
        check(runs==std::vector<Instant>{at(2026,11,6,12),at(2026,11,13,12),at(2026,11,20,12)},"Restricted day-of-month and weekday fields must use cron OR semantics");
        check(CronExpression("0 0 29 2 *").next(at(2026,3,1),"UTC",utc)==at(2028,2,29),"Cron must find leap-day runs years ahead");
        rejects([]{(void)CronExpression(std::string(257,' '));},"Cron expressions must stay bounded even when whitespace-only");

        recurrence={};recurrence.time_zone="America/New_York";recurrence.hour=2;recurrence.minute=30;
        check(recurrence.next(at(2026,3,8,5),zones)==at(2026,3,8,7),"A spring-forward gap must run at its first valid wall time");
        recurrence.hour=1;check(recurrence.next(at(2026,11,1,4),zones)==at(2026,11,1,5,30),"A repeated fall-back wall time must use its first occurrence");
        check(recurrence.next(at(2026,11,1,5,30),zones)==at(2026,11,2,6,30)&&recurrence.next(at(2026,11,1,5,45),zones)==at(2026,11,2,6,30),"The second fold occurrence must not replay after the first has passed");
        check(CronExpression("30 2 * * *").next(at(2026,3,8,5),"America/New_York",zones)==at(2026,3,8,7),"Cron must share the gap policy with daily schedules");
        check(CronExpression("30 1 * * *").next(at(2026,11,1,5,30),"America/New_York",zones)==at(2026,11,2,6,30),"Cron must not replay the second fold occurrence");
        recurrence={};recurrence.kind=RecurrenceKind::cron;recurrence.time_zone="Asia/Kolkata";recurrence.cron="15 9 * * 1";
        const auto preview=recurrence.upcoming(at(2026,10,28,12),3,zones);
        check(preview==std::vector<Instant>{at(2026,11,2,3,45),at(2026,11,9,3,45),at(2026,11,16,3,45)},"Previews must return bounded ordered future runs in the selected zone");
        rejects([&]{(void)recurrence.upcoming(at(2026,11,4),1001,zones);},"Unbounded schedule previews must be rejected");
        ScheduledTask task;task.id="fixture-task";task.thread_id="fixture-thread";task.name="Fixture";task.prompt="No actual dispatch";task.recurrence.hour=9;task.next_run=at(2026,11,4,9);
        unsigned identities{};auto make_id=[&]{return "intent-"+std::to_string(++identities);};
        check(tick({task},at(2026,11,4,9),{},utc,make_id).deliveries.empty()&&identities==0,"Pending approval must never produce a delivery intent");
        task.approval_pending=false;
        auto transition=tick({task},at(2026,11,4,9),{"fixture-thread"},utc,make_id);
        check(transition.changed&&transition.deliveries.empty()&&transition.tasks.front().pending_delivery==at(2026,11,4,9),"A busy scheduled thread must retain one consumed pending occurrence");
        transition=tick(transition.tasks,at(2026,11,5,9),{"fixture-thread"},utc,make_id);
        check(transition.tasks.front().pending_delivery==at(2026,11,5,9)&&transition.tasks.front().last_fired==at(2026,11,5,9),"A newer busy occurrence must replace the pending one rather than build a backlog");
        transition=tick(transition.tasks,at(2026,11,5,9,1),{},utc,make_id);
        check(transition.deliveries.size()==1&&transition.deliveries.front().occurrence==at(2026,11,5,9)&&transition.tasks.front().in_flight==at(2026,11,5,9),"An idle thread must receive only its latest consumed pending occurrence");
        check(transition.tasks.front().delivery_id==transition.deliveries.front().delivery_id&&!transition.tasks.front().pending_delivery,"An intent must correlate with an in-flight marker and clear pending work");
        transition=tick(transition.tasks,at(2026,11,6,9),{},utc,make_id);
        check(transition.deliveries.empty()&&transition.tasks.front().next_run==at(2026,11,7,9),"A stale caller busy snapshot must not overlap an in-flight schedule");
        auto restart=recover(transition.tasks,at(2026,11,6,10),true,utc);
        check(restart.tasks.front().review_required&&restart.tasks.front().paused&&!restart.tasks.front().in_flight&&restart.tasks.front().last_outcome=="interrupted","Restart recovery must require review for uncertain in-flight deliveries");
        check(tick(restart.tasks,at(2026,11,7,9),{},utc,make_id).deliveries.empty(),"Uncertain restarted delivery must never automatically replay");
        auto second=task;second.id="other-task";auto paired=tick({task,second},at(2026,11,4,9),{},utc,make_id);
        check(paired.deliveries.size()==1&&paired.tasks.back().pending_delivery.has_value(),"Two simultaneous schedules for the same thread must share one dispatch slot");
        auto awake=recover({task},at(2026,11,6,12),false,utc);
        check(awake.tasks.front().next_run==at(2026,11,7,9)&&awake.tasks.front().last_outcome=="missed"&&tick(awake.tasks,at(2026,11,6,12),{},utc,make_id).deliveries.empty(),"Wake recovery must skip overdue occurrences without launching a backlog");
        task.paused=true;check(tick({task},at(2026,11,4,9),{},utc,make_id).deliveries.empty(),"Paused schedules must never dispatch");
        task.paused=false;task.last_fired=at(2026,11,4,9);
        check(tick({task},at(2026,11,4,9),{},utc,make_id).deliveries.empty(),"A persisted consumed occurrence must not replay after a backward clock change");
        std::cout<<"PASS: "<<checks<<" scheduler recurrence checks\n";return 0;
    }catch(const std::exception& error){std::cerr<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';return 1;}
}
