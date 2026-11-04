#pragma once
#include "../Core/SchedulerCore.h"
#include <windows.h>
#include <icu.h>
#include <winrt/base.h>
#include <memory>
#include <mutex>
#include <unordered_map>

#pragma comment(lib,"icu.lib")

namespace coincide::scheduling {
// The Windows 10 system ICU C API uses IANA data directly. Windows.Globalization.Calendar
// accepts IANA names but its Windows-rule mapping loses historical date-line transitions.
// ICU is part of our existing minimum Windows 10 2004 target, not a bundled dependency.
class WindowsCalendar final:public Calendar {
    using NativeCalendar=std::unique_ptr<UCalendar,decltype(&ucal_close)>;
    std::mutex mutex_;
    std::unordered_map<std::string,NativeCalendar> calendars_;
    static void checked(UErrorCode status){if(U_FAILURE(status))throw std::runtime_error("Windows could not resolve this IANA calendar time");}
    UCalendar* calendar(std::string_view zone){
        if(zone.empty()||zone.size()>256||zone.find('\0')!=std::string_view::npos)throw std::invalid_argument("Invalid IANA time zone");
        const std::string identity(zone);if(const auto found=calendars_.find(identity);found!=calendars_.end())return found->second.get();
        const auto name=winrt::to_hstring(zone);const auto* chars=reinterpret_cast<const UChar*>(name.c_str());
        UErrorCode status=U_ZERO_ERROR;UBool system{};UChar canonical[512]{};
        (void)ucal_getCanonicalTimeZoneID(chars,static_cast<std::int32_t>(name.size()),canonical,512,&system,&status);
        checked(status);if(!system)throw std::invalid_argument("Unsupported IANA time zone");
        NativeCalendar value(ucal_open(chars,static_cast<std::int32_t>(name.size()),"en_US_POSIX",UCAL_GREGORIAN,&status),ucal_close);checked(status);
        if(!value)throw std::runtime_error("Windows could not create an IANA calendar");
        ucal_setGregorianChange(value.get(),-8.64e15,&status);checked(status);
        ucal_setAttribute(value.get(),UCAL_REPEATED_WALL_TIME,UCAL_WALLTIME_FIRST);
        ucal_setAttribute(value.get(),UCAL_SKIPPED_WALL_TIME,UCAL_WALLTIME_NEXT_VALID);
        if(calendars_.size()>=64)calendars_.clear();return calendars_.emplace(identity,std::move(value)).first->second.get();
    }
    static LocalTime fields(UCalendar* value,UErrorCode& status){
        const auto year=ucal_get(value,UCAL_YEAR,&status),month=ucal_get(value,UCAL_MONTH,&status)+1,day=ucal_get(value,UCAL_DATE,&status);
        const auto hour=ucal_get(value,UCAL_HOUR_OF_DAY,&status),minute=ucal_get(value,UCAL_MINUTE,&status),second=ucal_get(value,UCAL_SECOND,&status);
        checked(status);return {{year,month,day},hour,minute,second};
    }
public:
    bool valid_zone(std::string_view zone)override{
        const std::lock_guard lock(mutex_);try{(void)calendar(zone);return true;}catch(const winrt::hresult_error&){return false;}catch(const std::invalid_argument&){return false;}catch(const std::runtime_error&){return false;}
    }
    LocalTime local_time(Instant instant,std::string_view zone)override{
        if(instant<0||instant>maximum_instant)throw std::invalid_argument("The schedule instant exceeds the supported range");
        const std::lock_guard lock(mutex_);auto* value=calendar(zone);UErrorCode status=U_ZERO_ERROR;
        ucal_setMillis(value,static_cast<double>(instant)*1000,&status);checked(status);return fields(value,status);
    }
    std::optional<Instant> resolve(CivilDate date,int hour,int minute,std::string_view zone)override{
        (void)wall_seconds({date,hour,minute,0});const std::lock_guard lock(mutex_);auto* value=calendar(zone);UErrorCode status=U_ZERO_ERROR;
        ucal_clear(value);ucal_setDateTime(value,date.year,date.month-1,date.day,hour,minute,0,&status);checked(status);
        const auto milliseconds=ucal_getMillis(value,&status);checked(status);
        // UCAL_WALLTIME_NEXT_VALID may move an entirely skipped civil day to tomorrow;
        // recurrence searches the next day itself instead of returning a mismatched date.
        if(fields(value,status).date!=date)return std::nullopt;
        const auto seconds=milliseconds/1000;if(seconds<0||seconds>static_cast<double>(maximum_instant))return std::nullopt;
        return static_cast<Instant>(seconds);
    }
};
} // namespace coincide::scheduling
