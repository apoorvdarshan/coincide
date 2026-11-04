#pragma once
#include "NativeStrings.h"
#include "InstructionGitPanel.h"
#include "../Runtime/InstructionService.h"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <functional>
#include <memory>

namespace coincide {
class InstructionsPanel:public std::enable_shared_from_this<InstructionsPanel>{
public:
    static std::shared_ptr<InstructionsPanel> create(InstructionLocations locations=InstructionLocations::standard(),std::filesystem::path sync_data_directory={},instruction_git::Runner runner={}){
        auto result=std::shared_ptr<InstructionsPanel>(new InstructionsPanel(std::move(locations)));
        if(!sync_data_directory.empty())result->git_=InstructionGitPanel::create(std::move(sync_data_directory),std::move(runner));result->build();return result;
    }
    winrt::Microsoft::UI::Xaml::Controls::Grid view()const{return root_;}
    void set_project(std::filesystem::path path){project_=std::move(path);global_=false;if(scope_)scope_.IsOn(false);refresh();}
    void show_global(){global_=true;if(scope_)scope_.IsOn(true);refresh();}
    void close(){closed_=true;++generation_;if(git_)git_->close();}
    std::shared_ptr<InstructionGitPanel> git_sync()const{return git_;}
    void set_owner(HWND owner){if(git_)git_->owner(owner);}
    winrt::fire_and_forget refresh(){
        const auto lifetime=shared_from_this();if(closed_)co_return;const auto generation=++generation_;const auto project=project_;const auto global=global_;const auto locations=locations_;
        if(git_)git_->select_source(std::nullopt);reading_.Text(L"");status_.Text(ui_text(L"Loading instructions…"));refresh_.IsEnabled(false);files_.IsEnabled(false);
        InstructionScan scan;std::string error;const winrt::apartment_context ui;
        co_await winrt::resume_background();try{scan=global?InstructionService::global_files(locations):InstructionService::project_files(project);}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}
        try{co_await ui;}catch(...){co_return;}if(closed_||generation!=generation_)co_return;
        refreshing_=true;entries_=std::move(scan.files);files_.Items().Clear();
        for(const auto& entry:entries_){winrt::Microsoft::UI::Xaml::Controls::ListViewItem item;
            std::string label=entry.display_name;for(const auto& reader:entry.readers)label+=" · "+reader;if(entry.linked)label+=" → "+winrt::to_string(entry.resolved.wstring());if(!entry.exists)label+=" · "+winrt::to_string(ui_text(L"Not found"));
            item.Content(winrt::box_value(winrt::to_hstring(label)));files_.Items().Append(item);
        }
        refreshing_=false;files_.IsEnabled(true);refresh_.IsEnabled(true);
        status_.Text(winrt::to_hstring(error.empty()?scan.incomplete?"Some folders were not searched because discovery reached its limits.":"Select an instruction file to preview it.":error));
    }
private:
    using Grid=winrt::Microsoft::UI::Xaml::Controls::Grid;using Button=winrt::Microsoft::UI::Xaml::Controls::Button;using TextBlock=winrt::Microsoft::UI::Xaml::Controls::TextBlock;
    using TextBox=winrt::Microsoft::UI::Xaml::Controls::TextBox;using ListView=winrt::Microsoft::UI::Xaml::Controls::ListView;using Toggle=winrt::Microsoft::UI::Xaml::Controls::ToggleSwitch;
    InstructionLocations locations_;std::filesystem::path project_;std::vector<InstructionFile> entries_;bool global_{},closed_{},refreshing_{};std::uint64_t generation_{};
    std::shared_ptr<InstructionGitPanel> git_;
    Grid root_{nullptr};Button refresh_{nullptr};TextBlock path_{nullptr},status_{nullptr};TextBox reading_{nullptr};ListView files_{nullptr};Toggle scope_{nullptr};
    explicit InstructionsPanel(InstructionLocations locations):locations_(std::move(locations)){}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& view,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(view,id);}
    void build(){
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace xaml=winrt::Microsoft::UI::Xaml;
        root_=Grid{};identify(root_,L"InstructionsPanel");root_.RowSpacing(8);root_.Padding({12,8,12,12});
        for(int i=0;i<6;++i){ui::RowDefinition row;row.Height({1,i==3?xaml::GridUnitType::Star:xaml::GridUnitType::Auto});root_.RowDefinitions().Append(row);}
        ui::StackPanel toolbar;toolbar.Orientation(ui::Orientation::Horizontal);toolbar.Spacing(12);
        scope_=Toggle{};scope_.Header(winrt::box_value(ui_text(L"Global Instructions")));identify(scope_,L"InstructionsGlobal");
        scope_.Toggled([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock()){self->global_=self->scope_.IsOn();self->refresh();}});toolbar.Children().Append(scope_);
        refresh_=Button{};refresh_.Content(winrt::box_value(ui_text(L"Refresh")));identify(refresh_,L"RefreshInstructions");refresh_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->refresh();});toolbar.Children().Append(refresh_);root_.Children().Append(toolbar);
        files_=ListView{};files_.MaxHeight(200);identify(files_,L"InstructionFiles");files_.SelectionChanged([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock();self&&!self->refreshing_)self->read_selected();});Grid::SetRow(files_,1);root_.Children().Append(files_);
        path_=TextBlock{};path_.IsTextSelectionEnabled(true);path_.TextWrapping(xaml::TextWrapping::Wrap);identify(path_,L"InstructionPath");Grid::SetRow(path_,2);root_.Children().Append(path_);
        reading_=TextBox{};reading_.IsReadOnly(true);reading_.AcceptsReturn(true);reading_.TextWrapping(xaml::TextWrapping::Wrap);identify(reading_,L"InstructionPreview");Grid::SetRow(reading_,3);root_.Children().Append(reading_);
        ui::StackPanel footer;footer.Spacing(6);TextBlock explanation;explanation.Text(ui_text(L"Preview is read only. Git synchronization changes require a separate review and approval."));explanation.TextWrapping(xaml::TextWrapping::Wrap);footer.Children().Append(explanation);
        status_=TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);identify(status_,L"InstructionsStatus");footer.Children().Append(status_);Grid::SetRow(footer,4);root_.Children().Append(footer);
        if(git_){ui::Expander sync;sync.Header(winrt::box_value(ui_text(L"Git synchronization")));identify(sync,L"InstructionGitExpander");ui::ScrollViewer scroll;scroll.MaxHeight(320);scroll.VerticalScrollBarVisibility(ui::ScrollBarVisibility::Auto);scroll.Content(git_->view());sync.Content(scroll);Grid::SetRow(sync,5);root_.Children().Append(sync);}
    }
    winrt::fire_and_forget read_selected(){
        const auto lifetime=shared_from_this();const auto index=files_.SelectedIndex();if(closed_||index<0||static_cast<std::size_t>(index)>=entries_.size())co_return;
        const auto generation=++generation_;const auto entry=entries_[index];path_.Text(winrt::to_hstring(winrt::to_string(entry.path.wstring())+(entry.linked?"\n→ "+winrt::to_string(entry.resolved.wstring()):"")+(entry.protected_master?"\n"+winrt::to_string(ui_text(L"Global master (read only)")):"")));
        reading_.Text(L"");status_.Text(ui_text(L"Loading instructions…"));std::string text,error;const winrt::apartment_context ui;
        co_await winrt::resume_background();try{text=InstructionService::read(entry).text;}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}
        try{co_await ui;}catch(...){co_return;}if(closed_||generation!=generation_)co_return;reading_.Text(winrt::to_hstring(text));status_.Text(error.empty()?ui_text(L"Read only"):winrt::to_hstring(error));if(git_)git_->select_source(entry);
    }
};
} // namespace coincide
