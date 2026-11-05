#pragma once
#include "../Core/TranscriptFind.h"
#include "NativeStrings.h"
#include <atomic>
#include <chrono>
#include <memory>
#include <winrt/Microsoft.UI.Input.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Documents.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Core.h>

namespace coincide {
class ThreadFindBar:public std::enable_shared_from_this<ThreadFindBar>{
public:
    using Source=std::function<const Thread*()>;
    using Navigate=std::function<void(const TranscriptFindMatch&)>;
    static std::shared_ptr<ThreadFindBar> create(Source source,Navigate navigate,std::function<void()> closed={}){
        auto self=std::shared_ptr<ThreadFindBar>(new ThreadFindBar(std::move(source),std::move(navigate),std::move(closed)));self->build();return self;
    }
    winrt::Microsoft::UI::Xaml::Controls::StackPanel view()const{return root_;}
    bool visible()const{return root_&&root_.Visibility()==winrt::Microsoft::UI::Xaml::Visibility::Visible;}
    void open(){pending_message_.clear();try{if(!source_||!source_()){close(false);return;}root_.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);source_changed();query_.Focus(winrt::Microsoft::UI::Xaml::FocusState::Keyboard);query_.SelectAll();}catch(...){failure();}}
    void open_match(const std::string& query,const std::string& message_id){
        open();if(!visible())return;try{setting_=true;query_.Text(winrt::to_hstring(query));setting_=false;pending_message_=message_id;navigate_ready_=true;source_changed();}catch(...){setting_=false;failure();}
    }
    void close(bool restore_focus=true){cancel();valid_=false;model_={};thread_.clear();navigate_ready_=false;try{timer_.Stop();root_.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);setting_=true;query_.Text(L"");setting_=false;preview_.Inlines().Clear();status_.Text(L"");update_buttons(false);if(restore_focus&&closed_)closed_();}catch(...){setting_=false;failure();}}
    // Only the current rendered transcript calls this. Coalesce bursts of vector changes;
    // background work owns a text-only snapshot and never touches live Thread objects.
    void source_changed(){if(!visible())return;cancel();valid_=false;update_buttons(false);status_.Text(ui_text(L"Searching message text…"));if(!timer_.IsRunning())timer_.Start();}
    bool searching()const{return timer_.IsRunning()||working_;}
    void next(bool backwards=false){try{if(searching()||!visible()||!valid_)return;const auto current=source_?source_():nullptr;if(!current||current->id!=thread_||model_.query()!=winrt::to_string(query_.Text())){source_changed();return;}if(const auto hit=model_.move(backwards)){render();if(navigate_)navigate_(*hit);}}catch(...){failure();}}
private:
    using Xaml=winrt::Microsoft::UI::Xaml::DependencyObject;
    using Panel=winrt::Microsoft::UI::Xaml::Controls::StackPanel;
    Source source_;Navigate navigate_;std::function<void()> closed_;Panel root_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBox query_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBlock status_{nullptr},preview_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::Button previous_{nullptr},next_{nullptr};
    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer timer_{nullptr};
    std::shared_ptr<std::atomic_bool> cancelled_;TranscriptFind model_;std::string thread_,pending_message_;std::uint64_t generation_{};bool setting_{},working_{},navigate_ready_{},valid_{};
    ThreadFindBar(Source source,Navigate navigate,std::function<void()> closed):source_(std::move(source)),navigate_(std::move(navigate)),closed_(std::move(closed)){}
    static void identify(const Xaml& value,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
    void cancel(){if(cancelled_)cancelled_->store(true);working_=false;++generation_;}
    void failure()noexcept{cancel();valid_=false;try{timer_.Stop();update_buttons(false);preview_.Inlines().Clear();status_.Text(ui_text(L"Message text could not be searched."));}catch(...){} }
    void update_buttons(bool available){previous_.IsEnabled(available);next_.IsEnabled(available);}
    void render(){
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace doc=winrt::Microsoft::UI::Xaml::Documents;
        preview_.Inlines().Clear();const auto hit=model_.current();update_buttons(hit!=nullptr);if(!hit){status_.Text(model_.query().empty()?ui_text(L"Enter text to search this conversation."):ui_text(L"No matching messages"));return;}
        auto text=std::to_wstring(model_.position()+1)+L" / "+std::to_wstring(model_.matches().size())+L" · "+std::wstring(ui_text(L"matching messages"));if(model_.limited())text+=L" · "+std::wstring(ui_text(L"Showing first 10,000 matches"));status_.Text(text);
        doc::Run before;before.Text(winrt::to_hstring((hit->leading?"…":"")+hit->before));preview_.Inlines().Append(before);doc::Bold selected;doc::Run match;match.Text(winrt::to_hstring(hit->matched));selected.Inlines().Append(match);preview_.Inlines().Append(selected);doc::Run after;after.Text(winrt::to_hstring(hit->after+(hit->trailing?"…":"")));preview_.Inlines().Append(after);
    }
    winrt::fire_and_forget execute(){
        const auto weak=weak_from_this();const winrt::apartment_context owner;
        std::vector<TranscriptFindDocument> documents;std::string id,query;const auto ticket=++generation_;auto cancellation=std::make_shared<std::atomic_bool>(false);cancelled_=cancellation;
        try{const auto source=source_?source_():nullptr;if(!visible()||!source){close(false);co_return;}id=source->id;query=winrt::to_string(query_.Text());if(query.empty()){model_={};thread_=id;working_=false;render();co_return;}if(query.size()>TranscriptFind::maximum_query_bytes)throw std::invalid_argument("Find query exceeds its bound");documents=TranscriptFind::snapshot(source->messages);working_=true;}
        catch(...){failure();try{status_.Text(ui_text(L"Search text is too long or unavailable."));}catch(...){}co_return;}
        TranscriptFind result;bool failed{},stopped{};co_await winrt::resume_background();
        try{result=TranscriptFind::search(documents,std::move(query),[cancellation]{return cancellation->load();});}catch(const TranscriptFind::Cancelled&){stopped=true;}catch(...){failed=true;}
        try{co_await owner;}catch(...){co_return;}
        const auto self=weak.lock();if(!self||ticket!=self->generation_||cancellation->load()||!self->visible())co_return;self->working_=false;
        try{
            const auto current=self->source_?self->source_():nullptr;if(stopped||!current||current->id!=id||(!failed&&result.query()!=winrt::to_string(self->query_.Text()))){self->source_changed();co_return;}if(failed){self->failure();co_return;}
            if(!self->pending_message_.empty()){const auto target=std::exchange(self->pending_message_,{});if(!result.select(target)){self->failure();self->status_.Text(ui_text(L"This search result changed or is unavailable. Search again."));co_return;}}
            else if(self->thread_==id)result.preserve_selection(self->model_);self->thread_=id;self->model_=std::move(result);self->valid_=true;self->render();
            const auto navigate=std::exchange(self->navigate_ready_,false);if(navigate&&self->model_.current()&&self->navigate_)self->navigate_(*self->model_.current());
        }catch(...){self->failure();}
    }
    void build(){
        namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;const auto weak=weak_from_this();root_=Panel{};root_.Spacing(4);root_.Margin({0,6,0,8});root_.Visibility(xaml::Visibility::Collapsed);identify(root_,L"ThreadFindBar");
        ui::Grid row;ui::ColumnDefinition query_column;query_column.Width({1,xaml::GridUnitType::Star});row.ColumnDefinitions().Append(query_column);for(unsigned i=0;i<3;++i){ui::ColumnDefinition column;column.Width({1,xaml::GridUnitType::Auto});row.ColumnDefinitions().Append(column);}
        query_=ui::TextBox{};query_.PlaceholderText(ui_text(L"Find in message text"));query_.MaxLength(1024);identify(query_,L"ThreadFindQuery");xaml::Automation::AutomationProperties::SetName(query_,ui_text(L"Find in message text"));row.Children().Append(query_);
        const auto button=[&](const wchar_t* title,const wchar_t* id,unsigned column){ui::Button value;value.Content(winrt::box_value(ui_text(title)));identify(value,id);value.Margin({4,0,0,0});ui::Grid::SetColumn(value,static_cast<int>(column));row.Children().Append(value);return value;};
        previous_=button(L"Previous",L"ThreadFindPrevious",1);next_=button(L"Next",L"ThreadFindNext",2);auto dismiss=button(L"Close",L"ThreadFindClose",3);previous_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->next(true);});next_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->next();});dismiss.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->close();});root_.Children().Append(row);
        status_=ui::TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);identify(status_,L"ThreadFindStatus");xaml::Automation::AutomationProperties::SetLiveSetting(status_,xaml::Automation::Peers::AutomationLiveSetting::Polite);root_.Children().Append(status_);
        ui::TextBlock explanation;explanation.Text(ui_text(L"Matches message text literally, including code and markup. One result per message."));explanation.TextWrapping(xaml::TextWrapping::Wrap);root_.Children().Append(explanation);
        preview_=ui::TextBlock{};preview_.TextWrapping(xaml::TextWrapping::Wrap);preview_.IsTextSelectionEnabled(true);identify(preview_,L"ThreadFindExcerpt");ui::ScrollViewer excerpt;excerpt.MaxHeight(100);excerpt.VerticalScrollBarVisibility(ui::ScrollBarVisibility::Auto);excerpt.Content(preview_);root_.Children().Append(excerpt);
        timer_=winrt::Microsoft::UI::Dispatching::DispatcherQueue::GetForCurrentThread().CreateTimer();timer_.Interval(std::chrono::milliseconds(200));timer_.IsRepeating(false);timer_.Tick([weak](const auto&,const auto&){if(const auto self=weak.lock())self->execute();});
        query_.TextChanging([weak](const auto&,const auto&){if(const auto self=weak.lock();self&&!self->setting_){self->pending_message_.clear();self->cancel();self->timer_.Stop();self->navigate_ready_=true;self->source_changed();}});
        query_.KeyDown([weak](const auto&,const xaml::Input::KeyRoutedEventArgs& args){if(const auto self=weak.lock()){if(args.Key()==winrt::Windows::System::VirtualKey::Escape){args.Handled(true);self->close();}else if(args.Key()==winrt::Windows::System::VirtualKey::Enter){args.Handled(true);const auto shift=winrt::Microsoft::UI::Input::InputKeyboardSource::GetKeyStateForCurrentThread(winrt::Windows::System::VirtualKey::Shift);self->next((shift&winrt::Windows::UI::Core::CoreVirtualKeyStates::Down)==winrt::Windows::UI::Core::CoreVirtualKeyStates::Down);}}});update_buttons(false);
    }
};
} // namespace coincide
