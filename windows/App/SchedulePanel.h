#pragma once
#include "NativeStrings.h"
#include "../Runtime/ScheduleStore.h"
#include "../Runtime/ScheduleTool.h"
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Globalization.h>
#include <chrono>
#include <functional>
#include <iomanip>
#include <sstream>

namespace coincide {
namespace schedule_ui {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline void identify(const xaml::DependencyObject& value,const wchar_t* id){xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
inline ui::TextBlock text(const winrt::hstring& value){ui::TextBlock result;result.Text(value);result.TextWrapping(xaml::TextWrapping::Wrap);return result;}
inline ui::TextBox input(const winrt::hstring& label,const wchar_t* id,int limit){ui::TextBox result;result.Header(winrt::box_value(label));result.MaxLength(limit);identify(result,id);return result;}
inline ui::Button button(const winrt::hstring& label,const wchar_t* id){ui::Button result;result.Content(winrt::box_value(label));identify(result,id);return result;}
inline bool checked(const ui::CheckBox& value){const auto state=value.IsChecked();return state&&state.Value();}
inline constexpr scheduling::RecurrenceKind kinds[]{scheduling::RecurrenceKind::once,scheduling::RecurrenceKind::daily,scheduling::RecurrenceKind::weekdays,scheduling::RecurrenceKind::weekly,scheduling::RecurrenceKind::days,scheduling::RecurrenceKind::interval,scheduling::RecurrenceKind::cron};
inline winrt::hstring kind_label(scheduling::RecurrenceKind kind){
    using K=scheduling::RecurrenceKind;switch(kind){case K::once:return ui_text(L"Once");case K::daily:return ui_text(L"Daily");case K::weekly:return ui_text(L"Weekly");case K::weekdays:return ui_text(L"Weekdays");case K::days:return ui_text(L"Selected days");case K::interval:return ui_text(L"Interval");case K::cron:return ui_text(L"Cron");}return{};
}
inline winrt::hstring day_label(int day){switch(day){case 1:return ui_text(L"Sunday");case 2:return ui_text(L"Monday");case 3:return ui_text(L"Tuesday");case 4:return ui_text(L"Wednesday");case 5:return ui_text(L"Thursday");case 6:return ui_text(L"Friday");case 7:return ui_text(L"Saturday");default:throw std::invalid_argument("Invalid schedule weekday");}}
inline winrt::Windows::Globalization::Calendar picker_calendar(){return {{L"en-US"},winrt::Windows::Globalization::CalendarIdentifiers::Gregorian(),winrt::Windows::Globalization::ClockIdentifiers::TwentyFourHour()};}
inline scheduling::CivilDate date(const ui::DatePicker& picker){auto calendar=picker_calendar();calendar.SetDateTime(picker.Date());return {calendar.Year(),calendar.Month(),calendar.Day()};}
inline void date(const ui::DatePicker& picker,scheduling::CivilDate value){auto calendar=picker_calendar();calendar.Day(1);calendar.Year(value.year);calendar.Month(value.month);calendar.Day(value.day);calendar.Hour(12);calendar.Minute(0);calendar.Second(0);calendar.Nanosecond(0);picker.Date(calendar.GetDateTime());}
inline void time(const ui::TimePicker& picker,int hour,int minute){picker.Time(std::chrono::duration_cast<winrt::Windows::Foundation::TimeSpan>(std::chrono::minutes(hour*60+minute)));}
inline std::pair<int,int> time(const ui::TimePicker& picker){const auto minutes=std::chrono::duration_cast<std::chrono::minutes>(picker.Time()).count();if(minutes<0||minutes>=1440)throw std::invalid_argument("Choose a valid schedule time");return {static_cast<int>(minutes/60),static_cast<int>(minutes%60)};}
inline winrt::hstring formatted(scheduling::Instant instant,std::string_view zone){
    const auto name=winrt::to_hstring(zone);wchar_t locale[LOCALE_NAME_MAX_LENGTH]{};GetUserDefaultLocaleName(locale,LOCALE_NAME_MAX_LENGTH);const auto locale_name=winrt::to_string(locale);
    UErrorCode status=U_ZERO_ERROR;std::unique_ptr<UDateFormat,decltype(&udat_close)> format(udat_open(UDAT_SHORT,UDAT_MEDIUM,locale_name.c_str(),reinterpret_cast<const UChar*>(name.c_str()),static_cast<int32_t>(name.size()),nullptr,0,&status),udat_close);
    if(U_FAILURE(status)||!format)throw std::runtime_error("Windows could not format this schedule time");
    std::vector<UChar> output(256);auto length=udat_format(format.get(),static_cast<double>(instant)*1000,output.data(),static_cast<int32_t>(output.size()),nullptr,&status);
    if(status==U_BUFFER_OVERFLOW_ERROR){status=U_ZERO_ERROR;output.resize(static_cast<std::size_t>(length)+1);length=udat_format(format.get(),static_cast<double>(instant)*1000,output.data(),static_cast<int32_t>(output.size()),nullptr,&status);}
    if(U_FAILURE(status)||length<0)throw std::runtime_error("Windows could not format this schedule time");return winrt::hstring(reinterpret_cast<const wchar_t*>(output.data()),static_cast<std::uint32_t>(length));
}
inline int positive_integer(const winrt::hstring& value,int maximum){const auto text=scheduling::trim(winrt::to_string(value));int result{};const auto converted=std::from_chars(text.data(),text.data()+text.size(),result);if(text.empty()||converted.ec!=std::errc{}||converted.ptr!=text.data()+text.size()||result<1||result>maximum)throw std::invalid_argument("Choose a valid repeat interval");return result;}
inline bool has_content(std::string_view value){bool content{};for(std::size_t at=0;at<value.size();){const auto code=workspace_text::next(value,at);if(!code)throw std::invalid_argument("The prompt cannot contain NUL");if(!workspace_text::whitespace(code))content=true;}return content;}
} // namespace schedule_ui

// UI-thread controller. The host owns its timer and provider conversations. This panel never
// starts a timer, model, notification, shell or network request on its own.
class SchedulePanel:public std::enable_shared_from_this<SchedulePanel>{
public:
    using Busy=std::function<std::unordered_set<std::string>()>;
    using Dispatch=std::function<bool(const scheduling::DeliveryIntent&)>;
    using Clock=std::function<scheduling::Instant()>;
    static std::shared_ptr<SchedulePanel> create(std::filesystem::path data,Busy busy,Dispatch dispatch,Clock clock={}){
        auto result=std::shared_ptr<SchedulePanel>(new SchedulePanel(std::move(data),std::move(busy),std::move(dispatch),std::move(clock)));result->build();return result;
    }
    schedule_ui::ui::Grid view()const{return root_;}
    const scheduling::ScheduleStore& store()const{return store_;}
    void select_thread(std::string id){
        if(closed_)return;if(!id.empty())id=canonical(id);if(id==selected_thread_)return;selected_thread_=std::move(id);editing_.clear();editor_.Visibility(schedule_ui::xaml::Visibility::Collapsed);refresh();
    }
    std::string propose(std::string thread,std::string name,std::string prompt,scheduling::TaskRecurrence recurrence){
        if(closed_)throw std::runtime_error("The schedules panel is closed");scheduling::ScheduledTask task;task.thread_id=canonical(thread);task.name=std::move(name);task.prompt=std::move(prompt);task.recurrence=std::move(recurrence);
        const auto id=store_.create(std::move(task),now_());refresh();return id;
    }
    winrt::Windows::Data::Json::JsonObject request(const std::string& thread,const std::string& json){
        if(closed_)throw std::runtime_error("The schedules panel is closed");std::vector<scheduling::DeliveryIntent> deliveries;
        const auto result=scheduling::ScheduleTool::request(store_,calendar_,thread,json,now_(),default_zone(),busy_?busy_():std::unordered_set<std::string>{},deliveries);
        refresh();for(const auto& intent:deliveries){bool accepted{};try{accepted=dispatch_(intent);}catch(...){}if(!accepted)queue_completion(intent.schedule_id,intent.delivery_id,false,true,winrt::to_string(ui_text(L"Delivery was not confirmed. Review the conversation before resuming.")));}retry_completions();refresh();return result.HasKey(L"id")?scheduling::ScheduleTool::json(store_.task(winrt::to_string(result.GetNamedString(L"id")))):result;
    }
    void tick(){
        if(closed_||ticking_)return;ticking_=true;struct Reset{bool& value;~Reset(){value=false;}}reset{ticking_};
        try{
            if(wake_pending_){(void)wake();return;}
            const auto before=state_key();if(!retry_completions())return;const auto intents=store_.tick(now_(),busy_?busy_():std::unordered_set<std::string>{});
            for(const auto& intent:intents){bool accepted{};try{accepted=dispatch_(intent);}catch(...){}
                if(!accepted)queue_completion(intent.schedule_id,intent.delivery_id,false,true,winrt::to_string(ui_text(L"Delivery was not confirmed. Review the conversation before resuming.")));}
            retry_completions();if(before!=state_key())refresh();
        }catch(...){show_exception();}
    }
    bool wake(){if(closed_)return false;wake_pending_=true;try{if(!retry_completions())return false;store_.wake(now_());wake_pending_=false;error_.Text(L"");refresh();return true;}catch(...){show_exception();return false;}}
    bool pause_thread(std::string_view thread){
        if(closed_)return true;try{const auto id=canonical(thread);std::vector<std::string> pause;
            for(const auto& task:store_.tasks())if(task.thread_id==id&&(!task.paused||task.pending_delivery))pause.push_back(task.id);
            for(const auto& task:pause)store_.pause(task);if(!pause.empty())refresh();return true;
        }catch(...){show_exception();return false;}
    }
    void completed(std::string_view thread,bool success,bool uncertain=false,std::string message={}){
        if(closed_)return;const auto identity=canonical(thread);for(const auto& task:store_.tasks())if(task.thread_id==identity&&task.in_flight){completed_delivery(task.id,task.delivery_id,success,uncertain,std::move(message));return;}
    }
    void completed_delivery(std::string schedule,std::string delivery,bool success,bool uncertain=false,std::string message={}){
        if(closed_)return;try{queue_completion(std::move(schedule),std::move(delivery),success,uncertain,std::move(message));retry_completions();refresh();}catch(...){show_exception();}
    }
    void close(){closed_=true;busy_={};dispatch_={};pending_.clear();}
private:
    using Grid=schedule_ui::ui::Grid;using StackPanel=schedule_ui::ui::StackPanel;using TextBox=schedule_ui::ui::TextBox;using TextBlock=schedule_ui::ui::TextBlock;
    using ComboBox=schedule_ui::ui::ComboBox;using Button=schedule_ui::ui::Button;using CheckBox=schedule_ui::ui::CheckBox;using DatePicker=schedule_ui::ui::DatePicker;using TimePicker=schedule_ui::ui::TimePicker;
    using AutoSuggestBox=schedule_ui::ui::AutoSuggestBox;using Border=schedule_ui::ui::Border;
    struct Completion{std::string schedule,delivery,message;scheduling::Instant at;bool success,uncertain;};
    scheduling::WindowsCalendar calendar_;
    scheduling::ScheduleStore store_;
    Busy busy_;Dispatch dispatch_;Clock now_;
    Grid root_{nullptr};StackPanel rows_{nullptr},editor_stack_{nullptr},days_{nullptr},interval_row_{nullptr};Border editor_{nullptr};
    Button new_{nullptr},save_{nullptr};TextBox name_{nullptr},prompt_{nullptr},interval_{nullptr},cron_{nullptr};TextBlock preview_{nullptr},error_{nullptr},editor_title_{nullptr};
    ComboBox kind_{nullptr},weekday_{nullptr},unit_{nullptr};DatePicker date_{nullptr};TimePicker time_{nullptr};AutoSuggestBox zone_{nullptr};
    std::array<CheckBox,7> day_buttons_{};
    std::vector<std::string> zones_;std::vector<Completion> pending_;
    std::string selected_thread_,editing_;bool closed_{},loading_{},ticking_{},wake_pending_{};
    SchedulePanel(std::filesystem::path data,Busy busy,Dispatch dispatch,Clock clock):store_(std::move(data),calendar_),busy_(std::move(busy)),dispatch_(std::move(dispatch)),now_(std::move(clock)){
        if(!dispatch_)throw std::invalid_argument("A schedules panel needs a delivery handler");if(!now_)now_=[] {return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();};store_.open(now_());
    }
    static std::string canonical(std::string_view value){const winrt::guid id(winrt::to_hstring(value));if(id==winrt::guid{})throw std::invalid_argument("Choose a conversation for this schedule");return winrt::to_string(winrt::to_hstring(id));}
    std::string state_key()const{std::string key;for(const auto& task:store_.tasks()){key+=task.id+task.delivery_id+task.last_outcome+std::to_string(task.next_run.value_or(-1))+":"+std::to_string(task.pending_delivery.value_or(-1))+":"+std::to_string(task.last_finished.value_or(-1));key+=task.paused?'p':'a';key+=task.review_required?'r':'n';}return key;}
    static std::string bounded_message(std::string message){
        try{std::size_t last{};for(std::size_t at=0;at<message.size();){const auto code=workspace_text::next(message,at);if(!code)throw std::invalid_argument("NUL");if(at<=4096)last=at;}if(message.size()>4096)message.resize(last);return message;}
        catch(...){return winrt::to_string(ui_text(L"The scheduled turn finished. Review its conversation for details."));}
    }
    void queue_completion(std::string schedule,std::string delivery,bool success,bool uncertain,std::string message){
        const scheduling::ScheduledTask* task{};try{task=&store_.task(schedule);}catch(const std::out_of_range&){return;}
        if(!task->in_flight||task->delivery_id!=delivery)return;
        for(auto& pending:pending_)if(pending.schedule==schedule&&pending.delivery==delivery){if(uncertain)pending.uncertain=true;return;}
        pending_.push_back({std::move(schedule),std::move(delivery),bounded_message(std::move(message)),now_(),success,uncertain});
    }
    bool retry_completions(){
        try{const bool recovering=!pending_.empty();while(!pending_.empty()){const auto& value=pending_.front();
                if(value.uncertain)store_.mark_uncertain(value.schedule,value.delivery,value.at,value.message);else store_.finish(value.schedule,value.delivery,value.at,value.success,value.message);
                pending_.erase(pending_.begin());}if(recovering)error_.Text(L"");return true;}
        catch(...){show_exception();return false;}
    }
    void show_exception(){try{throw;}catch(const winrt::hresult_error& value){error_.Text(value.message());}catch(const std::exception& value){error_.Text(winrt::to_hstring(value.what()));}}
    template<class Operation>void action(Operation operation){if(closed_)return;try{error_.Text(L"");operation();refresh();}catch(...){show_exception();}}
    void build(){
        namespace ui=schedule_ui::ui;namespace xaml=schedule_ui::xaml;
        root_=Grid{};root_.Padding({12,12,12,12});schedule_ui::identify(root_,L"SchedulePanel");
        ui::ScrollViewer scroll;scroll.VerticalScrollBarVisibility(ui::ScrollBarVisibility::Auto);root_.Children().Append(scroll);
        StackPanel content;content.Spacing(12);scroll.Content(content);
        auto title=schedule_ui::text(ui_text(L"Schedules in this conversation"));title.FontSize(18);content.Children().Append(title);
        auto notice=schedule_ui::text(ui_text(L"Each run sends the prompt into this conversation with its current agent, model and access. Busy conversations receive only the latest pending run. Coincide must be open; missed runs are skipped."));notice.Opacity(0.75);content.Children().Append(notice);
        new_=schedule_ui::button(ui_text(L"New schedule"),L"ScheduleNew");content.Children().Append(new_);
        error_=schedule_ui::text(L"");schedule_ui::identify(error_,L"ScheduleError");content.Children().Append(error_);
        editor_=Border{};editor_.Visibility(xaml::Visibility::Collapsed);schedule_ui::identify(editor_,L"ScheduleEditor");content.Children().Append(editor_);editor_stack_=StackPanel{};editor_stack_.Spacing(8);editor_.Child(editor_stack_);
        editor_title_=schedule_ui::text(ui_text(L"New schedule"));editor_stack_.Children().Append(editor_title_);
        name_=schedule_ui::input(ui_text(L"Task name"),L"ScheduleName",200);editor_stack_.Children().Append(name_);
        prompt_=schedule_ui::input(ui_text(L"Task prompt"),L"SchedulePrompt",20000);prompt_.AcceptsReturn(true);prompt_.TextWrapping(xaml::TextWrapping::Wrap);prompt_.MinHeight(90);editor_stack_.Children().Append(prompt_);
        kind_=ComboBox{};kind_.Header(winrt::box_value(ui_text(L"Repeat")));schedule_ui::identify(kind_,L"ScheduleKind");for(const auto value:schedule_ui::kinds)kind_.Items().Append(winrt::box_value(schedule_ui::kind_label(value)));editor_stack_.Children().Append(kind_);
        zone_=AutoSuggestBox{};zone_.Header(winrt::box_value(ui_text(L"Time zone")));zone_.PlaceholderText(L"Asia/Kolkata");schedule_ui::identify(zone_,L"ScheduleTimeZone");editor_stack_.Children().Append(zone_);
        date_=DatePicker{};date_.CalendarIdentifier(winrt::Windows::Globalization::CalendarIdentifiers::Gregorian());date_.Header(winrt::box_value(ui_text(L"First run date")));schedule_ui::identify(date_,L"ScheduleDate");
        auto bounds=schedule_ui::picker_calendar();bounds.Day(1);bounds.Year(1970);bounds.Month(1);date_.MinYear(bounds.GetDateTime());bounds.Year(9999);bounds.Month(12);date_.MaxYear(bounds.GetDateTime());editor_stack_.Children().Append(date_);
        time_=TimePicker{};time_.ClockIdentifier(winrt::Windows::Globalization::ClockIdentifiers::TwentyFourHour());time_.MinuteIncrement(1);time_.Header(winrt::box_value(ui_text(L"Run at")));schedule_ui::identify(time_,L"ScheduleTime");editor_stack_.Children().Append(time_);
        weekday_=ComboBox{};weekday_.Header(winrt::box_value(ui_text(L"Day")));schedule_ui::identify(weekday_,L"ScheduleWeekday");for(int day=1;day<=7;++day)weekday_.Items().Append(winrt::box_value(schedule_ui::day_label(day)));editor_stack_.Children().Append(weekday_);
        days_=StackPanel{};days_.Spacing(4);schedule_ui::identify(days_,L"ScheduleDays");for(int day=1;day<=7;++day){auto& value=day_buttons_[static_cast<std::size_t>(day-1)];value=CheckBox{};value.Content(winrt::box_value(schedule_ui::day_label(day)));schedule_ui::identify(value,(L"ScheduleDay"+std::to_wstring(day)).c_str());days_.Children().Append(value);}editor_stack_.Children().Append(days_);
        interval_row_=StackPanel{};interval_row_.Orientation(ui::Orientation::Horizontal);interval_row_.Spacing(8);interval_=schedule_ui::input(ui_text(L"Repeat every"),L"ScheduleInterval",8);interval_.Width(140);interval_row_.Children().Append(interval_);
        unit_=ComboBox{};unit_.Header(winrt::box_value(ui_text(L"Unit")));schedule_ui::identify(unit_,L"ScheduleIntervalUnit");for(const auto& value:{ui_text(L"Minutes"),ui_text(L"Hours"),ui_text(L"Days")})unit_.Items().Append(winrt::box_value(value));interval_row_.Children().Append(unit_);editor_stack_.Children().Append(interval_row_);
        cron_=schedule_ui::input(ui_text(L"Cron expression"),L"ScheduleCron",256);cron_.PlaceholderText(L"0 9 * * 1-5");editor_stack_.Children().Append(cron_);
        preview_=schedule_ui::text(L"");schedule_ui::identify(preview_,L"SchedulePreview");editor_stack_.Children().Append(preview_);
        editor_stack_.Children().Append(schedule_ui::text(ui_text(L"Saving creates an approval card. The schedule runs only after you explicitly approve the saved prompt and timing.")));
        StackPanel buttons;buttons.Orientation(ui::Orientation::Horizontal);buttons.Spacing(8);save_=schedule_ui::button(ui_text(L"Save for approval"),L"ScheduleSave");buttons.Children().Append(save_);auto cancel=schedule_ui::button(ui_text(L"Cancel"),L"ScheduleCancel");buttons.Children().Append(cancel);editor_stack_.Children().Append(buttons);
        rows_=StackPanel{};rows_.Spacing(12);schedule_ui::identify(rows_,L"ScheduleList");content.Children().Append(rows_);
        const auto weak=weak_from_this();new_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->action([&]{self->edit({});});});
        cancel.Click([weak](const auto&,const auto&){if(const auto self=weak.lock()){self->editing_.clear();self->editor_.Visibility(xaml::Visibility::Collapsed);}});
        save_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->action([&]{self->save();});});
        auto changed=[weak](const auto&,const auto&){if(const auto self=weak.lock())self->changed();};
        name_.TextChanged(changed);prompt_.TextChanged(changed);interval_.TextChanged(changed);cron_.TextChanged(changed);kind_.SelectionChanged(changed);weekday_.SelectionChanged(changed);unit_.SelectionChanged(changed);date_.DateChanged(changed);time_.TimeChanged(changed);
        for(const auto& day:day_buttons_){day.Checked(changed);day.Unchecked(changed);}
        zone_.TextChanged([weak](const auto&,const auto&){if(const auto self=weak.lock()){self->suggest_zones();self->changed();}});
        load_zones();refresh();
    }
    void load_zones(){
        UErrorCode status=U_ZERO_ERROR;std::unique_ptr<UEnumeration,decltype(&uenum_close)> values(ucal_openTimeZones(&status),uenum_close);if(U_FAILURE(status)||!values)return;
        int32_t length{};while(const auto* value=uenum_next(values.get(),&length,&status)){if(U_FAILURE(status)||zones_.size()>=2048)break;if(length>0&&length<=256)zones_.emplace_back(value,static_cast<std::size_t>(length));}std::sort(zones_.begin(),zones_.end());
    }
    void suggest_zones(){
        if(loading_||closed_)return;const auto needle=scheduling::ascii_lower(winrt::to_string(zone_.Text()));std::vector<winrt::Windows::Foundation::IInspectable> matches;
        if(!needle.empty())for(const auto& zone:zones_)if(scheduling::ascii_lower(zone).find(needle)!=std::string::npos){matches.push_back(winrt::box_value(winrt::to_hstring(zone)));if(matches.size()==20)break;}
        zone_.ItemsSource(winrt::single_threaded_observable_vector<winrt::Windows::Foundation::IInspectable>(std::move(matches)));
    }
    std::string default_zone(){auto calendar=schedule_ui::picker_calendar();const auto zone=winrt::to_string(calendar.GetTimeZone());return calendar_.valid_zone(zone)?zone:"UTC";}
    void edit(std::string id){
        if(selected_thread_.empty())return;loading_=true;struct Reset{bool& value;~Reset(){value=false;}}reset{loading_};editing_=std::move(id);scheduling::TaskRecurrence recurrence;
        if(editing_.empty()){recurrence.time_zone=default_zone();recurrence.date=std::min(now_()+3600,scheduling::maximum_instant);recurrence.interval_minutes=30;recurrence.cron="0 9 * * 1-5";recurrence.weekdays={2,3,4,5,6};name_.Text(L"");prompt_.Text(L"");editor_title_.Text(ui_text(L"New schedule"));}
        else{const auto& task=store_.task(editing_);if(task.thread_id!=selected_thread_||task.in_flight)throw std::runtime_error("Finish the active delivery before editing its schedule");recurrence=task.recurrence;name_.Text(winrt::to_hstring(task.name));prompt_.Text(winrt::to_hstring(task.prompt));editor_title_.Text(ui_text(L"Edit schedule"));}
        for(std::size_t index=0;index<std::size(schedule_ui::kinds);++index)if(schedule_ui::kinds[index]==recurrence.kind)kind_.SelectedIndex(static_cast<int32_t>(index));zone_.Text(winrt::to_hstring(recurrence.time_zone));
        const auto date=scheduling::RecurrenceKind::once==recurrence.kind||scheduling::RecurrenceKind::interval==recurrence.kind?calendar_.local_time(recurrence.date,recurrence.time_zone):calendar_.local_time(std::min(now_()+3600,scheduling::maximum_instant),recurrence.time_zone);
        schedule_ui::date(date_,date.date);schedule_ui::time(time_,recurrence.kind==scheduling::RecurrenceKind::once||recurrence.kind==scheduling::RecurrenceKind::interval?date.hour:recurrence.hour,recurrence.kind==scheduling::RecurrenceKind::once||recurrence.kind==scheduling::RecurrenceKind::interval?date.minute:recurrence.minute);
        weekday_.SelectedIndex(recurrence.day_of_week-1);for(int day=1;day<=7;++day)day_buttons_[static_cast<std::size_t>(day-1)].IsChecked(std::find(recurrence.weekdays.begin(),recurrence.weekdays.end(),day)!=recurrence.weekdays.end());
        const int minutes=recurrence.interval_minutes?recurrence.interval_minutes:30;const int unit=minutes%1440==0?2:minutes%60==0?1:0;unit_.SelectedIndex(unit);interval_.Text(winrt::to_hstring(minutes/(unit==2?1440:unit==1?60:1)));cron_.Text(winrt::to_hstring(recurrence.cron.empty()?"0 9 * * 1-5":recurrence.cron));editor_.Visibility(schedule_ui::xaml::Visibility::Visible);
        loading_=false;changed();
    }
    scheduling::TaskRecurrence current(){
        const auto index=kind_.SelectedIndex();if(index<0||static_cast<std::size_t>(index)>=std::size(schedule_ui::kinds))throw std::invalid_argument("Choose a schedule recurrence");
        scheduling::TaskRecurrence result;result.kind=schedule_ui::kinds[index];result.time_zone=scheduling::trim(winrt::to_string(zone_.Text()));if(!calendar_.valid_zone(result.time_zone))throw std::invalid_argument("Choose a valid IANA time zone");
        const auto [hour,minute]=schedule_ui::time(time_);result.hour=hour;result.minute=minute;result.day_of_week=weekday_.SelectedIndex()+1;
        if(result.kind==scheduling::RecurrenceKind::once||result.kind==scheduling::RecurrenceKind::interval){const auto value=calendar_.resolve(schedule_ui::date(date_),hour,minute,result.time_zone);if(!value)throw std::invalid_argument("Choose a date that exists in this time zone");result.date=*value;}
        if(result.kind==scheduling::RecurrenceKind::days)for(int day=1;day<=7;++day)if(schedule_ui::checked(day_buttons_[static_cast<std::size_t>(day-1)]))result.weekdays.push_back(day);
        if(result.kind==scheduling::RecurrenceKind::interval){const auto unit=unit_.SelectedIndex();if(unit<0||unit>2)throw std::invalid_argument("Choose an interval unit");const int factor=unit==2?1440:unit==1?60:1;result.interval_minutes=schedule_ui::positive_integer(interval_.Text(),44640/factor)*factor;}
        if(result.kind==scheduling::RecurrenceKind::cron)result.cron=scheduling::trim(winrt::to_string(cron_.Text()));
        if(!result.valid(calendar_))throw std::invalid_argument("Choose a valid schedule; repeats must be at least five minutes apart");if(result.kind==scheduling::RecurrenceKind::once&&result.date<=now_())throw std::invalid_argument("Choose a future date for a one-time schedule");return result;
    }
    void changed(){
        if(loading_||closed_||!editor_)return;namespace xaml=schedule_ui::xaml;const auto index=kind_.SelectedIndex();if(index<0||static_cast<std::size_t>(index)>=std::size(schedule_ui::kinds))return;const auto kind=schedule_ui::kinds[index];using K=scheduling::RecurrenceKind;
        date_.Visibility(kind==K::once||kind==K::interval?xaml::Visibility::Visible:xaml::Visibility::Collapsed);time_.Visibility(kind==K::cron?xaml::Visibility::Collapsed:xaml::Visibility::Visible);weekday_.Visibility(kind==K::weekly?xaml::Visibility::Visible:xaml::Visibility::Collapsed);days_.Visibility(kind==K::days?xaml::Visibility::Visible:xaml::Visibility::Collapsed);interval_row_.Visibility(kind==K::interval?xaml::Visibility::Visible:xaml::Visibility::Collapsed);cron_.Visibility(kind==K::cron?xaml::Visibility::Visible:xaml::Visibility::Collapsed);
        try{const auto recurrence=current();const auto runs=recurrence.upcoming(now_(),3,calendar_);winrt::hstring next=ui_text(L"Next runs");for(const auto run:runs)next=next+L"\n"+schedule_ui::formatted(run,recurrence.time_zone);if(runs.empty())next=ui_text(L"No future runs. Choose a later time.");preview_.Text(next+L"\n"+winrt::to_hstring(recurrence.time_zone));
            (void)workspace_text::label(winrt::to_string(name_.Text()),200);const auto prompt=winrt::to_string(prompt_.Text());if(prompt.size()>20000||!schedule_ui::has_content(prompt))throw std::invalid_argument("Enter a task name and prompt");save_.IsEnabled(!selected_thread_.empty()&&!runs.empty());}
        catch(const winrt::hresult_error& value){preview_.Text(value.message());save_.IsEnabled(false);}catch(const std::exception& value){preview_.Text(winrt::to_hstring(value.what()));save_.IsEnabled(false);}
    }
    void save(){
        const auto recurrence=current();const auto name=winrt::to_string(name_.Text()),prompt=winrt::to_string(prompt_.Text());
        if(editing_.empty()){scheduling::ScheduledTask task;task.thread_id=selected_thread_;task.name=name;task.prompt=prompt;task.recurrence=recurrence;store_.create(std::move(task),now_());}
        else store_.update(editing_,name,prompt,recurrence,now_());editing_.clear();editor_.Visibility(schedule_ui::xaml::Visibility::Collapsed);
    }
    winrt::hstring summary(const scheduling::TaskRecurrence& recurrence){
        using K=scheduling::RecurrenceKind;auto result=schedule_ui::kind_label(recurrence.kind);
        if(recurrence.kind==K::once)result=result+L" · "+schedule_ui::formatted(recurrence.date,recurrence.time_zone);
        else if(recurrence.kind==K::interval)result=result+L" · "+winrt::to_hstring(recurrence.interval_minutes)+L" "+ui_text(L"Minutes");
        else if(recurrence.kind==K::cron)result=result+L" · "+winrt::to_hstring(recurrence.cron);
        else{std::wostringstream clock;clock<<std::setfill(L'0')<<std::setw(2)<<recurrence.hour<<L":"<<std::setw(2)<<recurrence.minute;result=result+L" · "+winrt::hstring(clock.str());if(recurrence.kind==K::weekly)result=result+L" · "+schedule_ui::day_label(recurrence.day_of_week);
            if(recurrence.kind==K::days)for(const int day:recurrence.weekdays)result=result+L" · "+schedule_ui::day_label(day);}
        return result+L" · "+winrt::to_hstring(recurrence.time_zone);
    }
    void refresh(){
        if(closed_||!rows_)return;namespace ui=schedule_ui::ui;namespace xaml=schedule_ui::xaml;rows_.Children().Clear();std::size_t count{};
        const auto weak=weak_from_this();for(const auto& task:store_.tasks())if(task.thread_id==selected_thread_){++count;StackPanel card;card.Spacing(6);schedule_ui::identify(card,winrt::to_hstring("ScheduleCard_"+task.id).c_str());auto title=schedule_ui::text(winrt::to_hstring(task.name));title.FontSize(15);card.Children().Append(title);
            auto status=schedule_ui::text(task.approval_pending?ui_text(L"Awaiting approval"):task.review_required?ui_text(L"Review interrupted delivery"):task.in_flight?ui_text(L"Running"):task.paused?ui_text(L"Paused"):task.pending_delivery?ui_text(L"Waiting for this conversation"):ui_text(L"Active"));schedule_ui::identify(status,L"ScheduleStatus");card.Children().Append(status);card.Children().Append(schedule_ui::text(summary(task.recurrence)));
            auto next=schedule_ui::text(task.next_run?ui_text(L"Next run")+L" · "+schedule_ui::formatted(*task.next_run,task.recurrence.time_zone):ui_text(L"No future runs"));schedule_ui::identify(next,L"ScheduleNextRun");card.Children().Append(next);
            ui::ScrollViewer prompt;prompt.MaxHeight(140);prompt.VerticalScrollBarVisibility(ui::ScrollBarVisibility::Auto);prompt.Content(schedule_ui::text(winrt::to_hstring(task.prompt)));card.Children().Append(prompt);
            if(!task.last_message.empty())card.Children().Append(schedule_ui::text(winrt::to_hstring(task.last_message)));
            StackPanel actions;actions.Orientation(ui::Orientation::Horizontal);actions.Spacing(6);const auto id=task.id;
            if(task.approval_pending){auto approve=schedule_ui::button(ui_text(L"Approve schedule"),L"ScheduleApprove");approve.IsEnabled(!task.in_flight);approve.Click([weak,id](const auto&,const auto&){if(const auto self=weak.lock())self->action([&]{self->store_.approve(id,self->now_());});});actions.Children().Append(approve);}
            else if(task.review_required){card.Children().Append(schedule_ui::text(ui_text(L"Review the conversation to check what already ran. Resuming schedules only future occurrences.")));auto review=schedule_ui::button(ui_text(L"Reviewed — resume future runs"),L"ScheduleReviewResume");review.Click([weak,id](const auto&,const auto&){if(const auto self=weak.lock())self->action([&]{self->store_.review_and_resume(id,self->now_());});});actions.Children().Append(review);}
            else{auto pause=schedule_ui::button(task.paused?ui_text(L"Resume"):ui_text(L"Pause"),L"ScheduleTogglePause");const bool paused=task.paused;pause.Click([weak,id,paused](const auto&,const auto&){if(const auto self=weak.lock())self->action([&]{if(paused)self->store_.resume(id,self->now_());else self->store_.pause(id);});});actions.Children().Append(pause);}
            auto edit=schedule_ui::button(ui_text(L"Edit"),L"ScheduleEdit");edit.IsEnabled(!task.in_flight);edit.Click([weak,id](const auto&,const auto&){if(const auto self=weak.lock())self->action([&]{self->edit(id);});});actions.Children().Append(edit);
            auto remove=schedule_ui::button(ui_text(L"Delete schedule"),L"ScheduleDelete");remove.IsEnabled(!task.in_flight);remove.Click([weak,id](const auto&,const auto&){if(const auto self=weak.lock())self->action([&]{self->store_.remove(id);if(self->editing_==id){self->editing_.clear();self->editor_.Visibility(xaml::Visibility::Collapsed);}});});actions.Children().Append(remove);card.Children().Append(actions);rows_.Children().Append(card);}
        new_.IsEnabled(!selected_thread_.empty()&&count<10);if(!count)rows_.Children().Append(schedule_ui::text(selected_thread_.empty()?ui_text(L"Select a conversation to manage its schedules."):ui_text(L"No schedules in this conversation.")));
    }
};
} // namespace coincide
