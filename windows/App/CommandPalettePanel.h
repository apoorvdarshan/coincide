#pragma once
#include "../Core/CommandPalette.h"
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
class CommandPalettePanel:public std::enable_shared_from_this<CommandPalettePanel> {
public:
    using Source=std::function<std::vector<PaletteEntry>()>;
    using Activate=std::function<bool(const PaletteEntry&)>;
    static std::shared_ptr<CommandPalettePanel> create(Source source,Activate activate,std::function<void()> dismiss) {
        auto result=std::shared_ptr<CommandPalettePanel>(new CommandPalettePanel(std::move(source),std::move(activate),std::move(dismiss)));result->build();return result;
    }
    ~CommandPalettePanel(){if(cancel_)cancel_->store(true);}
    winrt::Microsoft::UI::Xaml::Controls::Grid view()const{return root_;}
    void show(){active_=true;query_.Text(L"");refresh();query_.Focus(winrt::Microsoft::UI::Xaml::FocusState::Keyboard);}
    void hide(){active_=false;invalidate();}
    bool searching()const{return searching_;}
private:
    Source source_;Activate activate_;std::function<void()> dismiss_;
    winrt::Microsoft::UI::Xaml::Controls::Grid root_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBox query_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::ListView results_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBlock status_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::Button open_{nullptr};
    std::vector<PaletteEntry> entries_;std::shared_ptr<std::atomic_bool> cancel_;
    std::uint64_t generation_{};std::string completed_query_;bool active_{},valid_{},searching_{};
    CommandPalettePanel(Source source,Activate activate,std::function<void()> dismiss):source_(std::move(source)),activate_(std::move(activate)),dismiss_(std::move(dismiss)){}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& value,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
    void invalidate(){if(cancel_)cancel_->store(true);++generation_;valid_=false;searching_=false;entries_.clear();results_.Items().Clear();open_.IsEnabled(false);}
    void activate_selected(){
        if(!active_||!valid_||completed_query_!=winrt::to_string(query_.Text()))return;
        const auto index=results_.SelectedIndex();if(index<0||static_cast<std::size_t>(index)>=entries_.size())return;
        const auto entry=entries_[static_cast<std::size_t>(index)];
        try{if(!activate_||!activate_(entry))throw std::runtime_error("Unavailable palette target");}
        catch(...){valid_=false;open_.IsEnabled(false);status_.Text(ui_text(L"This command or destination changed. Search again."));}
    }
    winrt::fire_and_forget refresh(){
        invalidate();if(!active_)co_return;
        const auto ticket=generation_;const auto weak=weak_from_this();const winrt::apartment_context owner;
        auto cancel=std::make_shared<std::atomic_bool>(false);cancel_=cancel;const auto query=winrt::to_string(query_.Text());
        searching_=true;status_.Text(ui_text(L"Searching commands, projects and conversations…"));
        co_await winrt::resume_after(std::chrono::milliseconds(120));try{co_await owner;}catch(...){co_return;}
        const auto self=weak.lock();if(!self||!self->active_||cancel->load()||ticket!=self->generation_)co_return;
        std::vector<PaletteEntry> snapshot;try{if(!self->source_)throw std::runtime_error("Unavailable palette source");snapshot=self->source_();}catch(...){self->searching_=false;self->status_.Text(ui_text(L"Commands and destinations are unavailable."));co_return;}
        PaletteResults found;bool failed{};co_await winrt::resume_background();
        try{found=CommandPalette::search(snapshot,query,[cancel]{return cancel->load();});}catch(const CommandPalette::Cancelled&){}catch(...){failed=true;}
        try{co_await owner;}catch(...){co_return;}
        if(!self->active_||cancel->load()||ticket!=self->generation_)co_return;
        self->searching_=false;
        if(failed){self->status_.Text(ui_text(L"The search text or destination list is invalid or too large."));co_return;}
        self->entries_=std::move(found.entries);self->completed_query_=query;self->valid_=true;
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace xaml=winrt::Microsoft::UI::Xaml;
        for(const auto& entry:self->entries_){ui::StackPanel row;row.Spacing(2);ui::TextBlock title;title.Text(winrt::to_hstring(entry.title));title.FontWeight(winrt::Windows::UI::Text::FontWeights::SemiBold());title.TextWrapping(xaml::TextWrapping::Wrap);row.Children().Append(title);ui::TextBlock detail;detail.Text(winrt::to_hstring(entry.detail));detail.TextWrapping(xaml::TextWrapping::Wrap);row.Children().Append(detail);xaml::Automation::AutomationProperties::SetName(row,winrt::to_hstring(entry.title+" · "+entry.detail));self->results_.Items().Append(row);}
        if(!self->entries_.empty())self->results_.SelectedIndex(0);
        self->status_.Text(found.limited?ui_text(L"Showing the first 100 matches. Refine your search."):self->entries_.empty()?ui_text(L"No matching commands, projects or conversations."):ui_text(L"Use arrow keys to choose, Enter to open, or Escape to close."));
    }
    void build(){
        namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
        root_=ui::Grid{};root_.RowSpacing(8);identify(root_,L"CommandPalettePanel");
        for(const auto unit:{xaml::GridUnitType::Auto,xaml::GridUnitType::Auto,xaml::GridUnitType::Star,xaml::GridUnitType::Auto}){ui::RowDefinition row;row.Height({1,unit});root_.RowDefinitions().Append(row);}
        query_=ui::TextBox{};query_.PlaceholderText(ui_text(L"Search commands, projects and conversations"));query_.MaxLength(1024);identify(query_,L"CommandPaletteQuery");xaml::Automation::AutomationProperties::SetName(query_,ui_text(L"Command palette search"));root_.Children().Append(query_);
        open_=ui::Button{};open_.Content(winrt::box_value(ui_text(L"Open selected result")));identify(open_,L"CommandPaletteOpen");open_.IsEnabled(false);ui::Grid::SetRow(open_,1);root_.Children().Append(open_);
        results_=ui::ListView{};results_.SelectionMode(ui::ListViewSelectionMode::Single);identify(results_,L"CommandPaletteResults");xaml::Automation::AutomationProperties::SetName(results_,ui_text(L"Commands and destinations"));ui::Grid::SetRow(results_,2);root_.Children().Append(results_);
        status_=ui::TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);identify(status_,L"CommandPaletteStatus");xaml::Automation::AutomationProperties::SetLiveSetting(status_,xaml::Automation::Peers::AutomationLiveSetting::Polite);ui::Grid::SetRow(status_,3);root_.Children().Append(status_);
        const auto weak=weak_from_this();query_.TextChanging([weak](const auto&,const auto&){if(const auto self=weak.lock())self->refresh();});
        const auto key=[weak](const auto&,const xaml::Input::KeyRoutedEventArgs& args){if(const auto self=weak.lock();self&&self->active_){using K=winrt::Windows::System::VirtualKey;if(args.Key()==K::Escape){args.Handled(true);self->hide();if(self->dismiss_)self->dismiss_();}else if(args.Key()==K::Enter){args.Handled(true);self->activate_selected();}else if((args.Key()==K::Up||args.Key()==K::Down)&&self->valid_&&!self->entries_.empty()){args.Handled(true);const auto last=static_cast<std::int32_t>(self->entries_.size()-1),delta=args.Key()==K::Up?-1:1;self->results_.SelectedIndex(std::clamp(self->results_.SelectedIndex()+delta,0,last));self->results_.ScrollIntoView(self->results_.SelectedItem());}}};
        query_.KeyDown(key);results_.KeyDown(key);results_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->open_.IsEnabled(self->active_&&self->valid_&&self->results_.SelectedIndex()>=0);});open_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->activate_selected();});
        root_.KeyDown([weak](const auto&,const xaml::Input::KeyRoutedEventArgs& args){if(args.Key()==winrt::Windows::System::VirtualKey::Escape)if(const auto self=weak.lock();self&&self->active_){args.Handled(true);self->hide();if(self->dismiss_)self->dismiss_();}});
    }
};
} // namespace coincide
