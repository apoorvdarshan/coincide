#pragma once
#include <algorithm>
#include <array>
#include <charconv>
#include <cstdint>
#include <limits>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace coincide::scheduling {
using Instant=std::int64_t; // UTC Unix seconds, never local time disguised as UTC.
inline constexpr Instant maximum_instant=253402300799LL;
struct CivilDate {int year{1970},month{1},day{1};bool operator==(const CivilDate&)const=default;};
struct LocalTime {CivilDate date;int hour{},minute{},second{};bool operator==(const LocalTime&)const=default;};
inline bool leap_year(int year){return year%4==0&&(year%100!=0||year%400==0);}
inline int month_length(int year,int month){constexpr int lengths[]{31,28,31,30,31,30,31,31,30,31,30,31};return month>=1&&month<=12?lengths[month-1]+(month==2&&leap_year(year)):0;}
inline bool valid_date(CivilDate date){return date.year>=1&&date.year<=9999&&date.month>=1&&date.month<=12&&date.day>=1&&date.day<=month_length(date.year,date.month);}
// Proleptic Gregorian arithmetic (the epoch offset is the number of days before 1970-01-01).
inline Instant civil_days(CivilDate date){
    if(!valid_date(date))throw std::invalid_argument("Invalid Gregorian date");
    int year=date.year-(date.month<=2);const int era=year/400;const unsigned within=static_cast<unsigned>(year-era*400);
    const unsigned month=static_cast<unsigned>(date.month+(date.month>2?-3:9));
    return static_cast<Instant>(era)*146097+within*365+within/4-within/100+(153*month+2)/5+date.day-1-719468;
}
inline CivilDate date_from_days(Instant value){
    value+=719468;const auto era=(value>=0?value:value-146096)/146097;const auto day=static_cast<unsigned>(value-era*146097);
    const auto within=(day-day/1460+day/36524-day/146096)/365;auto year=static_cast<int>(within)+static_cast<int>(era)*400;
    const auto year_day=day-(365*within+within/4-within/100);const auto month=(5*year_day+2)/153;
    const auto day_month=year_day-(153*month+2)/5+1;const auto actual_month=static_cast<int>(month)+(month<10?3:-9);year+=actual_month<=2;
    return {year,actual_month,static_cast<int>(day_month)};
}
inline CivilDate add_days(CivilDate date,int amount){return date_from_days(civil_days(date)+amount);}
inline int weekday(CivilDate date){const auto value=(civil_days(date)+4)%7;return static_cast<int>(value<0?value+7:value)+1;} // Sunday=1.
inline Instant wall_seconds(LocalTime value){
    if(value.hour<0||value.hour>23||value.minute<0||value.minute>59||value.second<0||value.second>59)throw std::invalid_argument("Invalid local clock time");
    return civil_days(value.date)*86400+value.hour*3600+value.minute*60+value.second;
}
inline LocalTime utc_time(Instant value){
    auto days=value/86400,seconds=value%86400;if(seconds<0){seconds+=86400;--days;}
    return {date_from_days(days),static_cast<int>(seconds/3600),static_cast<int>((seconds/60)%60),static_cast<int>(seconds%60)};
}
class Calendar {
public:
    virtual ~Calendar()=default;
    virtual bool valid_zone(std::string_view zone)=0;
    virtual LocalTime local_time(Instant value,std::string_view zone)=0;
    // Resolve only in this civil day. In a fold choose its first occurrence, including when
    // it is already past. A gap advances to the first valid wall time; a skipped day is null.
    virtual std::optional<Instant> resolve(CivilDate day,int hour,int minute,std::string_view zone)=0;
};
class UtcCalendar final:public Calendar {
public:
    bool valid_zone(std::string_view zone)override{return zone=="UTC"||zone=="Etc/UTC"||zone=="GMT";}
    LocalTime local_time(Instant value,std::string_view zone)override{if(!valid_zone(zone))throw std::invalid_argument("Unsupported fixture time zone");return utc_time(value);}
    std::optional<Instant> resolve(CivilDate day,int hour,int minute,std::string_view zone)override{
        if(!valid_zone(zone))throw std::invalid_argument("Unsupported fixture time zone");const auto result=wall_seconds({day,hour,minute,0});
        return result>=0&&result<=maximum_instant?std::optional<Instant>(result):std::nullopt;
    }
};
inline std::string ascii_lower(std::string value){for(auto& c:value)if(c>='A'&&c<='Z')c=static_cast<char>(c-'A'+'a');return value;}
inline bool ascii_space(char value){return value==' '||value=='\t'||value=='\r'||value=='\n'||value=='\f'||value=='\v';}
inline std::string trim(std::string_view value){while(!value.empty()&&ascii_space(value.front()))value.remove_prefix(1);while(!value.empty()&&ascii_space(value.back()))value.remove_suffix(1);return std::string(value);}
inline std::vector<std::string> split(std::string_view value,char delimiter){std::vector<std::string> result;for(;;){const auto at=value.find(delimiter);result.emplace_back(value.substr(0,at));if(at==std::string_view::npos)break;value.remove_prefix(at+1);}return result;}
class CronExpression {
    std::vector<int> minutes_,hours_;
    std::set<int> days_,months_,weekdays_;
    bool restrict_days_{},restrict_weekdays_{};
    static std::set<int> parse(std::string_view text,int low,int high,const std::vector<std::string>& names={},int name_base=0){
        auto number=[&](std::string_view value){
            int result{};const auto converted=std::from_chars(value.data(),value.data()+value.size(),result);
            if(!value.empty()&&converted.ec==std::errc{}&&converted.ptr==value.data()+value.size()&&result>=low&&result<=high)return result;
            const auto found=std::find(names.begin(),names.end(),value);if(found!=names.end())return static_cast<int>(found-names.begin())+name_base;
            throw std::invalid_argument("Invalid cron field");
        };
        std::set<int> values;
        for(const auto& part:split(text,',')){
            const auto pieces=split(part,'/');if(pieces.empty()||pieces.size()>2||pieces.front().empty())throw std::invalid_argument("Invalid cron step");
            int step=1;if(pieces.size()==2){const auto& digits=pieces.back();const auto converted=std::from_chars(digits.data(),digits.data()+digits.size(),step);
                if(digits.empty()||converted.ec!=std::errc{}||converted.ptr!=digits.data()+digits.size()||step<1||step>high+1)throw std::invalid_argument("Invalid cron step");}
            int first=low,last=high;
            if(pieces.front()!="*"){const auto bounds=split(pieces.front(),'-');if(bounds.size()>2)throw std::invalid_argument("Invalid cron range");first=number(bounds.front());
                last=bounds.size()==2?number(bounds.back()):(pieces.size()==2?high:first);if(first>last)throw std::invalid_argument("Descending cron ranges are not supported");}
            for(int value=first;value<=last;value+=step)values.insert(value);
        }
        if(values.empty())throw std::invalid_argument("Empty cron field");return values;
    }
public:
    explicit CronExpression(std::string_view expression){
        if(expression.size()>256)throw std::invalid_argument("Cron expressions have five fields and at most 256 bytes");
        auto text=ascii_lower(trim(expression));
        if(text=="@hourly")text="0 * * * *";else if(text=="@daily"||text=="@midnight")text="0 0 * * *";
        else if(text=="@weekly")text="0 0 * * 0";else if(text=="@monthly")text="0 0 1 * *";
        else if(text=="@yearly"||text=="@annually")text="0 0 1 1 *";
        std::vector<std::string> fields;std::size_t start{};
        while(start<text.size()){while(start<text.size()&&ascii_space(text[start]))++start;if(start==text.size())break;auto end=start;while(end<text.size()&&!ascii_space(text[end]))++end;fields.push_back(text.substr(start,end-start));start=end;}
        if(fields.size()!=5)throw std::invalid_argument("Cron expressions need minute, hour, day, month and weekday");
        const auto minutes=parse(fields[0],0,59),hours=parse(fields[1],0,23);minutes_.assign(minutes.begin(),minutes.end());hours_.assign(hours.begin(),hours.end());
        days_=parse(fields[2],1,31);months_=parse(fields[3],1,12,{"jan","feb","mar","apr","may","jun","jul","aug","sep","oct","nov","dec"},1);
        const auto weekdays=parse(fields[4],0,7,{"sun","mon","tue","wed","thu","fri","sat"});for(const int value:weekdays)weekdays_.insert(value%7);
        restrict_days_=!fields[2].starts_with('*');restrict_weekdays_=!fields[4].starts_with('*');
        std::vector<int> times;for(const int hour:hours_)for(const int minute:minutes_)times.push_back(hour*60+minute);
        int gap=times.front()+1440-times.back();for(std::size_t index=1;index<times.size();++index)gap=std::min(gap,times[index]-times[index-1]);
        if(gap<5)throw std::invalid_argument("Runs must be at least 5 minutes apart");
        bool possible=false;for(const int month:months_)for(const int day:days_)if(day<=month_length(2028,month))possible=true;
        if(!possible&&!restrict_weekdays_)throw std::invalid_argument("This cron expression never matches a date");
    }
    const std::vector<int>& minutes()const{return minutes_;}const std::vector<int>& hours()const{return hours_;}
    bool runs_on(CivilDate day)const{
        if(!months_.contains(day.month))return false;const bool month_day=days_.contains(day.day),week_day=weekdays_.contains(weekday(day)-1);
        return restrict_days_?(restrict_weekdays_?(month_day||week_day):month_day):(restrict_weekdays_?week_day:true);
    }
    std::optional<Instant> next(Instant now,std::string_view zone,Calendar& calendar)const{
        if(now<0||now>=maximum_instant||!calendar.valid_zone(zone))return std::nullopt;
        const auto today=calendar.local_time(now,zone).date;
        for(int offset=0;offset<366*5;++offset){const auto day=add_days(today,offset);if(!valid_date(day))break;if(!runs_on(day))continue;
            for(const int hour:hours_)for(const int minute:minutes_)if(const auto candidate=calendar.resolve(day,hour,minute,zone);candidate&&*candidate>now&&*candidate<=maximum_instant)return candidate;}
        return std::nullopt;
    }
};
enum class RecurrenceKind{once,daily,weekly,weekdays,days,interval,cron};
struct TaskRecurrence {
    RecurrenceKind kind{RecurrenceKind::daily};std::string time_zone{"UTC"};Instant date{};int hour{9},minute{},day_of_week{2};
    std::vector<int> weekdays;int interval_minutes{};std::string cron;
    bool valid(Calendar& calendar)const{
        if(time_zone.empty()||time_zone.size()>256||!calendar.valid_zone(time_zone)||date<0||date>maximum_instant||hour<0||hour>23||minute<0||minute>59||day_of_week<1||day_of_week>7)return false;
        if(kind==RecurrenceKind::days)return !weekdays.empty()&&weekdays.size()<=7&&std::all_of(weekdays.begin(),weekdays.end(),[](int day){return day>=1&&day<=7;});
        if(kind==RecurrenceKind::interval)return interval_minutes>=5&&interval_minutes<=31*24*60;
        if(kind==RecurrenceKind::cron){try{(void)CronExpression(cron);return true;}catch(const std::invalid_argument&){return false;}}
        return kind==RecurrenceKind::once||kind==RecurrenceKind::daily||kind==RecurrenceKind::weekly||kind==RecurrenceKind::weekdays;
    }
    std::optional<Instant> next(Instant now,Calendar& calendar)const{
        if(now<0||now>=maximum_instant||!valid(calendar))return std::nullopt;
        if(kind==RecurrenceKind::once)return date>now?std::optional<Instant>(date):std::nullopt;
        if(kind==RecurrenceKind::interval){if(date>now)return date;const Instant step=static_cast<Instant>(interval_minutes)*60,steps=(now-date)/step+1;
            if(steps>(maximum_instant-date)/step)return std::nullopt;return date+steps*step;}
        if(kind==RecurrenceKind::cron)return CronExpression(cron).next(now,time_zone,calendar);
        const auto today=calendar.local_time(now,time_zone).date;
        for(int offset=0;offset<=7;++offset){const auto day=add_days(today,offset);if(!valid_date(day))break;const int week=weekday(day);
            if(kind==RecurrenceKind::weekly&&week!=day_of_week)continue;if(kind==RecurrenceKind::weekdays&&(week==1||week==7))continue;
            if(kind==RecurrenceKind::days&&std::find(weekdays.begin(),weekdays.end(),week)==weekdays.end())continue;
            if(const auto candidate=calendar.resolve(day,hour,minute,time_zone);candidate&&*candidate>now&&*candidate<=maximum_instant)return candidate;}
        return std::nullopt;
    }
    std::vector<Instant> upcoming(Instant now,std::size_t count,Calendar& calendar)const{
        if(count>1000)throw std::invalid_argument("Schedule previews are limited to 1000 occurrences");std::vector<Instant> result;
        while(result.size()<count){const auto candidate=next(now,calendar);if(!candidate)break;result.push_back(*candidate);now=*candidate;}return result;
    }
};
} // namespace coincide::scheduling
