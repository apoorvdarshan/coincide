#pragma once
#include "../Runtime/ProjectFileIndex.h"
#include "NativeStrings.h"
#include <atomic>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Windows.System.h>

namespace coincide {
struct FileMentionRequest {
    std::string thread,project;std::filesystem::path root;std::u16string text;
    std::size_t caret{},selection{};std::uint64_t revision{};
    bool operator==(const FileMentionRequest&)const=default;
};
class ComposerFileMentions:public std::enable_shared_from_this<ComposerFileMentions> {
public:
    using Source=std::function<std::optional<FileMentionRequest>()>;
    using Apply=std::function<bool(const FileMentionRequest&,const FileMentionTrigger&,const std::string&)>;
    using Reader=std::function<ProjectFileIndex::Result(const std::filesystem::path&,ProjectFileIndex::Cancel)>;
    using Verify=std::function<std::shared_ptr<ProjectFileIndex::Verified>(const std::shared_ptr<ProjectFileIndex::Scope>&,const ProjectFileIndex::Entry&)>;
    static std::shared_ptr<ComposerFileMentions> create(const winrt::Microsoft::UI::Xaml::Controls::TextBox& editor,Source source,Apply apply,Reader read=ProjectFileIndex::scan,Verify verify=ProjectFileIndex::verify){
        auto result=std::shared_ptr<ComposerFileMentions>(new ComposerFileMentions(editor,std::move(source),std::move(apply),std::move(read),std::move(verify)));result->build();return result;
    }
    ~ComposerFileMentions(){if(cancel_)cancel_->store(true);}
    winrt::Microsoft::UI::Xaml::Controls::StackPanel view()const{return root_;}
    bool searching()const{return working_;}
    void invalidate(){if(cancel_)cancel_->store(true);++generation_;working_=false;ready_=false;matches_.clear();snapshot_={};request_.reset();results_.Items().Clear();insert_.IsEnabled(false);root_.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);}
    void close(){closed_=true;invalidate();}
    bool key(winrt::Windows::System::VirtualKey key,bool control,bool shift,bool alt){
        using K=winrt::Windows::System::VirtualKey;if(closed_||root_.Visibility()!=winrt::Microsoft::UI::Xaml::Visibility::Visible||control||alt)return false;
        if(key==K::Enter&&shift)return false;
        if(key==K::Escape){dismiss();return true;}
        if(key==K::Enter||(!shift&&key==K::Tab)){if(ready_)insert_selected();return true;}
        if((key==K::Up||key==K::Down)&&ready_&&!matches_.empty()){const auto last=static_cast<std::int32_t>(matches_.size()-1),delta=key==K::Up?-1:1;results_.SelectedIndex(std::clamp(results_.SelectedIndex()+delta,0,last));results_.ScrollIntoView(results_.SelectedItem());return true;}return false;
    }
    static std::u16string utf16(const winrt::hstring& text){return {text.begin(),text.end()};}
    static winrt::hstring wide(std::u16string_view text){return winrt::hstring(std::wstring(text.begin(),text.end()));}
private:
    winrt::Microsoft::UI::Xaml::Controls::TextBox editor_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::StackPanel root_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::ListView results_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBlock status_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::Button insert_{nullptr};
    Source source_;Apply apply_;Reader read_;Verify verify_;
    ProjectFileIndex::Result snapshot_;std::vector<ProjectFileIndex::Entry> matches_;
    std::optional<FileMentionRequest> request_,dismissed_;FileMentionTrigger trigger_;
    std::shared_ptr<std::atomic_bool> cancel_;std::uint64_t generation_{};bool closed_{},working_{},ready_{};
    ComposerFileMentions(const winrt::Microsoft::UI::Xaml::Controls::TextBox& editor,Source source,Apply apply,Reader read,Verify verify):editor_(editor),source_(std::move(source)),apply_(std::move(apply)),read_(std::move(read)),verify_(std::move(verify)){}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& value,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
    void dismiss(){try{dismissed_=source_?source_():std::nullopt;}catch(...){dismissed_.reset();}invalidate();editor_.Focus(winrt::Microsoft::UI::Xaml::FocusState::Programmatic);}
    winrt::fire_and_forget refresh(){
        invalidate();if(closed_)co_return;const auto ticket=generation_;const auto weak=weak_from_this();const winrt::apartment_context owner;
        auto cancel=std::make_shared<std::atomic_bool>(false);cancel_=cancel;working_=true;
        co_await winrt::resume_after(std::chrono::milliseconds(100));try{co_await owner;}catch(...){co_return;}
        const auto self=weak.lock();if(!self||self->closed_||ticket!=self->generation_||cancel->load())co_return;
        std::optional<FileMentionRequest> request;std::optional<FileMentionTrigger> trigger;std::string query;
        try{request=self->source_?self->source_():std::nullopt;if(!request||request==self->dismissed_){self->working_=false;co_return;}trigger=ComposerFileMention::detect(request->text,request->caret,request->selection);if(!trigger){self->working_=false;co_return;}query=winrt::to_string(wide(trigger->query));}catch(...){self->working_=false;co_return;}
        self->working_=true;self->root_.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);self->status_.Text(ui_text(L"Looking for project files…"));
        const auto read=self->read_;ProjectFileIndex::Result found;std::vector<std::string> paths;bool failed{};co_await winrt::resume_background();
        try{found=read(request->root,[cancel]{return cancel->load();});for(const auto& file:found.files)paths.push_back(file.path);paths=ComposerFileMention::match(std::move(paths),query);}catch(const ProjectFileIndex::Cancelled&){}catch(...){failed=true;}
        try{co_await owner;}catch(...){co_return;}
        if(self->closed_||ticket!=self->generation_||cancel->load())co_return;
        self->working_=false;
        try{
            if(!self->source_||self->source_()!=request){self->invalidate();co_return;}
            if(failed){self->status_.Text(ui_text(L"Project files are unavailable. Your message is unchanged."));co_return;}
            self->snapshot_=std::move(found);self->request_=std::move(request);self->trigger_=*trigger;
            for(const auto& path:paths){const auto hit=std::find_if(self->snapshot_.files.begin(),self->snapshot_.files.end(),[&](const auto& value){return value.path==path;});if(hit==self->snapshot_.files.end())continue;self->matches_.push_back(*hit);self->results_.Items().Append(winrt::box_value(winrt::to_hstring(path)));}
            self->ready_=!self->matches_.empty();if(self->ready_)self->results_.SelectedIndex(0);self->insert_.IsEnabled(self->ready_);
            self->status_.Text(self->snapshot_.limited?ui_text(L"File scan limit reached. These results are partial."):self->ready_?ui_text(L"Choose a file, then press Tab or Enter to insert its path."):ui_text(L"No matching project files."));
        }catch(...){self->invalidate();}
    }
    winrt::fire_and_forget insert_selected(){
        if(closed_||!ready_||working_||!request_)co_return;const auto index=results_.SelectedIndex();if(index<0||static_cast<std::size_t>(index)>=matches_.size())co_return;
        const auto request=*request_;const auto trigger=trigger_;const auto entry=matches_[static_cast<std::size_t>(index)];const auto scope=snapshot_.scope;
        const auto ticket=generation_;const auto weak=weak_from_this();const auto verify=verify_;const winrt::apartment_context owner;
        ready_=false;working_=true;insert_.IsEnabled(false);status_.Text(ui_text(L"Checking selected project file…"));
        std::shared_ptr<ProjectFileIndex::Verified> pin;co_await winrt::resume_background();try{pin=verify(scope,entry);}catch(...){}
        try{co_await owner;}catch(...){co_return;}
        const auto self=weak.lock();if(!self||self->closed_||ticket!=self->generation_)co_return;self->working_=false;
        try{if(!pin||!self->source_||self->source_()!=std::optional(request)||!self->apply_||!self->apply_(request,trigger,entry.path))throw std::runtime_error("Stale project file mention");self->invalidate();self->editor_.Focus(winrt::Microsoft::UI::Xaml::FocusState::Programmatic);}
        catch(...){self->status_.Text(ui_text(L"The file or message changed. Type the mention again to refresh."));}
    }
    void build(){
        namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;root_=ui::StackPanel{};root_.Spacing(4);root_.Visibility(xaml::Visibility::Collapsed);identify(root_,L"FileMentionSuggestions");
        status_=ui::TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);identify(status_,L"FileMentionStatus");xaml::Automation::AutomationProperties::SetLiveSetting(status_,xaml::Automation::Peers::AutomationLiveSetting::Polite);root_.Children().Append(status_);
        results_=ui::ListView{};results_.MaxHeight(90);results_.SelectionMode(ui::ListViewSelectionMode::Single);identify(results_,L"FileMentionResults");xaml::Automation::AutomationProperties::SetName(results_,ui_text(L"Matching project files"));root_.Children().Append(results_);
        ui::StackPanel actions;actions.Orientation(ui::Orientation::Horizontal);actions.Spacing(8);insert_=ui::Button{};insert_.Content(winrt::box_value(ui_text(L"Insert file mention")));insert_.IsEnabled(false);identify(insert_,L"InsertFileMention");actions.Children().Append(insert_);ui::Button close;close.Content(winrt::box_value(ui_text(L"Close file suggestions")));identify(close,L"CloseFileMentions");actions.Children().Append(close);root_.Children().Append(actions);
        const auto weak=weak_from_this();editor_.TextChanging([weak](const auto&,const auto&){if(const auto self=weak.lock())self->invalidate();});editor_.TextChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->refresh();});editor_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->refresh();});
        insert_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->insert_selected();});close.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->dismiss();});
        results_.KeyDown([weak](const auto&,const xaml::Input::KeyRoutedEventArgs& args){if(const auto self=weak.lock())if(self->key(args.Key(),(GetKeyState(VK_CONTROL)&0x8000)!=0,(GetKeyState(VK_SHIFT)&0x8000)!=0,(GetKeyState(VK_MENU)&0x8000)!=0))args.Handled(true);});
    }
};
} // namespace coincide
