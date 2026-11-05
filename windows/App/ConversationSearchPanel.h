#pragma once
#include "../Core/ConversationSearch.h"
#include "NativeStrings.h"
#include <atomic>
#include <memory>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Text.h>

namespace coincide {
class ConversationSearchPanel:public std::enable_shared_from_this<ConversationSearchPanel>{
public:
    struct Snapshot {std::vector<ConversationSearchThread> threads;ConversationSearch::Reader read;};
    using Source=std::function<Snapshot()>;
    using Navigate=std::function<bool(const ConversationSearchHit&,const std::string&)>;
    static std::shared_ptr<ConversationSearchPanel> create(Source source,Navigate navigate){
        auto panel=std::shared_ptr<ConversationSearchPanel>(new ConversationSearchPanel(std::move(source),std::move(navigate)));panel->build();return panel;
    }
    ~ConversationSearchPanel(){if(cancelled_)cancelled_->store(true);}
    winrt::Microsoft::UI::Xaml::Controls::Grid view()const{return root_;}
    void show(){active_=true;invalidate();query_.Focus(winrt::Microsoft::UI::Xaml::FocusState::Keyboard);}
    void hide()noexcept{active_=false;try{invalidate();}catch(...){if(cancelled_)cancelled_->store(true);working_=false;valid_=false;}}
    bool searching()const{return working_;}
private:
    using UI=winrt::Microsoft::UI::Xaml::Controls::Grid;
    Source source_;Navigate navigate_;UI root_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBox query_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::ListView results_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBlock status_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::Button search_{nullptr},open_{nullptr};
    std::shared_ptr<std::atomic_bool> cancelled_;std::vector<ConversationSearchHit> hits_;
    std::uint64_t generation_{};std::string completed_query_;bool active_{},working_{},valid_{};
    ConversationSearchPanel(Source source,Navigate navigate):source_(std::move(source)),navigate_(std::move(navigate)){}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& value,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
    void invalidate(){
        if(cancelled_)cancelled_->store(true);++generation_;working_=false;valid_=false;hits_.clear();completed_query_.clear();results_.Items().Clear();open_.IsEnabled(false);
        search_.IsEnabled(active_&&!query_.Text().empty());status_.Text(ui_text(L"Enter text, then search saved conversations. Drafts and queued input are excluded."));
    }
    void open_selected(){
        if(!active_||working_||!valid_||completed_query_!=winrt::to_string(query_.Text()))return;
        const auto index=results_.SelectedIndex();if(index<0||static_cast<std::size_t>(index)>=hits_.size())return;
        try{const auto hit=hits_[static_cast<std::size_t>(index)];if(!navigate_||!navigate_(hit,completed_query_))throw std::runtime_error("Search result changed");}
        catch(...){valid_=false;open_.IsEnabled(false);status_.Text(ui_text(L"This search result changed or is unavailable. Search again."));}
    }
    winrt::fire_and_forget execute(){
        if(!active_||working_||query_.Text().empty())co_return;
        invalidate();const auto ticket=generation_;const auto weak=weak_from_this();const winrt::apartment_context owner;
        auto cancel=std::make_shared<std::atomic_bool>(false);cancelled_=cancel;std::string query;Snapshot snapshot;
        try{query=winrt::to_string(query_.Text());(void)TranscriptFind::search({},query);if(!source_)throw std::runtime_error("Search scope unavailable");snapshot=source_();}
        catch(...){status_.Text(ui_text(L"Search text or saved conversations are unavailable."));co_return;}
        working_=true;search_.IsEnabled(false);status_.Text(ui_text(L"Searching saved messages…"));
        ConversationSearch result;bool failed{},stopped{};co_await winrt::resume_background();
        try{result=ConversationSearch::search(snapshot.threads,query,snapshot.read,[cancel]{return cancel->load();});}
        catch(const TranscriptFind::Cancelled&){stopped=true;}catch(...){failed=true;}
        try{co_await owner;}catch(...){co_return;}
        const auto self=weak.lock();if(!self||!self->active_||ticket!=self->generation_||cancel->load())co_return;
        self->working_=false;self->search_.IsEnabled(true);
        try{
            if(stopped||failed){self->status_.Text(ui_text(L"Saved messages could not be searched."));co_return;}
            self->hits_=std::move(result.hits);self->completed_query_=query;self->valid_=true;
            for(const auto& hit:self->hits_){
                namespace ui=winrt::Microsoft::UI::Xaml::Controls;ui::StackPanel row;row.Spacing(3);ui::TextBlock title;title.Text(winrt::to_hstring(hit.title));title.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());title.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);row.Children().Append(title);
                const auto& text=hit.message;const auto excerpt=(text.leading?"…":"")+text.before+text.matched+text.after+(text.trailing?"…":"");ui::TextBlock body;body.Text(winrt::to_hstring(excerpt));body.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);row.Children().Append(body);
                winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetName(row,winrt::to_hstring(hit.title+": "+excerpt));self->results_.Items().Append(row);
            }
            auto summary=std::to_wstring(self->hits_.size())+L" "+std::wstring(ui_text(L"matching messages"))+L" · "+std::to_wstring(result.searched)+L" "+std::wstring(ui_text(L"saved conversations searched"));
            if(result.unavailable)summary+=L" · "+std::to_wstring(result.unavailable)+L" "+std::wstring(ui_text(L"unavailable conversations skipped"));
            if(result.limited)summary+=L" · "+std::wstring(ui_text(L"Search limit reached; results are partial"));
            self->status_.Text(summary);
        }catch(...){self->invalidate();self->status_.Text(ui_text(L"Search results could not be displayed."));}
    }
    void build(){
        namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;root_=UI{};root_.RowSpacing(8);identify(root_,L"ConversationSearchPanel");
        for(unsigned n=0;n<4;++n){ui::RowDefinition row;row.Height({n==2?1.0:0.0,n==2?xaml::GridUnitType::Star:xaml::GridUnitType::Auto});root_.RowDefinitions().Append(row);}
        query_=ui::TextBox{};query_.PlaceholderText(ui_text(L"Search all saved conversations"));query_.MaxLength(1024);identify(query_,L"ConversationSearchQuery");xaml::Automation::AutomationProperties::SetName(query_,ui_text(L"Search all saved conversations"));root_.Children().Append(query_);
        ui::StackPanel actions;actions.Orientation(ui::Orientation::Horizontal);actions.Spacing(8);search_=ui::Button{};search_.Content(winrt::box_value(ui_text(L"Search messages")));search_.IsEnabled(false);identify(search_,L"ConversationSearchStart");actions.Children().Append(search_);open_=ui::Button{};open_.Content(winrt::box_value(ui_text(L"Open message")));open_.IsEnabled(false);identify(open_,L"ConversationSearchOpen");actions.Children().Append(open_);ui::Grid::SetRow(actions,1);root_.Children().Append(actions);
        results_=ui::ListView{};results_.SelectionMode(ui::ListViewSelectionMode::Single);identify(results_,L"ConversationSearchResults");xaml::Automation::AutomationProperties::SetName(results_,ui_text(L"Matching saved messages"));ui::Grid::SetRow(results_,2);root_.Children().Append(results_);
        status_=ui::TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);identify(status_,L"ConversationSearchStatus");xaml::Automation::AutomationProperties::SetLiveSetting(status_,xaml::Automation::Peers::AutomationLiveSetting::Polite);ui::Grid::SetRow(status_,3);root_.Children().Append(status_);
        const auto weak=weak_from_this();query_.TextChanging([weak](const auto&,const auto&){if(const auto self=weak.lock())self->invalidate();});query_.KeyDown([weak](const auto&,const xaml::Input::KeyRoutedEventArgs& args){if(args.Key()==winrt::Windows::System::VirtualKey::Enter)if(const auto self=weak.lock()){args.Handled(true);self->execute();}});search_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->execute();});open_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->open_selected();});
        results_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->open_.IsEnabled(self->active_&&self->valid_&&self->results_.SelectedIndex()>=0);});results_.KeyDown([weak](const auto&,const xaml::Input::KeyRoutedEventArgs& args){if(args.Key()==winrt::Windows::System::VirtualKey::Enter)if(const auto self=weak.lock()){args.Handled(true);self->open_selected();}});invalidate();
    }
};
} // namespace coincide
