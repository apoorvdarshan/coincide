#pragma once
#include "../Runtime/WindowsCalendar.h"
#include <filesystem>
#include <fstream>

namespace coincide {
inline int windows_calendar_tests(const std::filesystem::path& report){
    using namespace scheduling;
    int checks{};
    auto check=[&](bool value,const char* failure){++checks;if(!value)throw std::runtime_error(failure);};
    auto at=[](int year,int month,int day,int hour=0,int minute=0,int second=0){return wall_seconds({{year,month,day},hour,minute,second});};
    try{
        WindowsCalendar calendar;
        check(calendar.valid_zone("UTC")&&calendar.valid_zone("Asia/Kolkata")&&calendar.valid_zone("America/New_York"),"Windows must accept documented IANA identifiers");
        check(!calendar.valid_zone("not/a/timezone")&&!calendar.valid_zone(std::string("UTC\0other",9)),"Invalid or NUL-bearing IANA identifiers must fail closed");
        check(calendar.local_time(at(2026,11,4,12,34,56),"UTC")==LocalTime{{2026,11,4},12,34,56},"Windows UTC conversion must retain every calendar field");
        check(calendar.local_time(at(2026,11,4,23,45),"Asia/Kolkata")==LocalTime{{2026,11,5},5,15,0},"IANA conversion must apply fractional offsets and date rollover");
        check(calendar.resolve({2026,11,5},9,15,"Asia/Kolkata")==at(2026,11,5,3,45),"Resolving a local IANA time must return UTC Unix seconds");
        check(calendar.resolve({2028,2,29},0,0,"UTC")==at(2028,2,29),"Windows calendar conversion must retain leap days");
        check(calendar.resolve({2026,3,8},2,30,"America/New_York")==at(2026,3,8,7),"A nonexistent New York 02:30 must resolve to the gap's first valid 03:00");
        check(calendar.resolve({2026,11,1},1,30,"America/New_York")==at(2026,11,1,5,30),"An ambiguous New York 01:30 must resolve to its first occurrence");
        TaskRecurrence recurrence;recurrence.time_zone="America/New_York";recurrence.hour=1;recurrence.minute=30;
        check(recurrence.next(at(2026,11,1,5,30),calendar)==at(2026,11,2,6,30),"Native recurrence must never replay the second folded wall time");
        recurrence.hour=2;
        check(recurrence.next(at(2026,3,8,5),calendar)==at(2026,3,8,7),"Native daily recurrence must follow the shared DST gap policy");
        check(CronExpression("30 2 * * *").next(at(2026,3,8,5),"America/New_York",calendar)==at(2026,3,8,7),"Native cron must follow the same gap policy");
        check(CronExpression("30 1 * * *").next(at(2026,11,1,5,45),"America/New_York",calendar)==at(2026,11,2,6,30),"Native cron after the first fold must advance to the next day");
        check(calendar.valid_zone("Australia/Lord_Howe"),"Windows must accept the Lord Howe IANA zone");
        check(calendar.resolve({2026,10,4},2,15,"Australia/Lord_Howe")==at(2026,10,3,15,30),"A thirty-minute DST gap must advance to 02:30, not assume an hour");
        check(calendar.resolve({2026,4,5},1,45,"Australia/Lord_Howe")==at(2026,4,4,14,45),"A thirty-minute DST fold must choose its first occurrence");
        check(calendar.valid_zone("Pacific/Apia")&&!calendar.resolve({2011,12,30},9,0,"Pacific/Apia"),"A date-line-skipped civil day must not resolve to another day");
        recurrence={};recurrence.time_zone="Pacific/Apia";recurrence.hour=9;
        check(recurrence.next(at(2011,12,29,20),calendar)==at(2011,12,30,19),"Daily recurrence must skip a missing civil day and keep the intended wall time");
        const auto before=calendar.local_time(at(2026,11,4,12),"UTC");
        (void)calendar.resolve({2026,3,8},2,30,"America/New_York");
        check(calendar.local_time(at(2026,11,4,12),"UTC")==before,"Zone/calendar caches must not leak one schedule's zone into another");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows IANA calendar checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}
    return 1;
}
} // namespace coincide
