#pragma once
#include "NativeStrings.h"
#include "../Runtime/ImportService.h"
#include <shobjidl.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <functional>
#include <memory>

namespace coincide {
class ImportPanel:public std::enable_shared_from_this<ImportPanel>{
public:
    using Commit=std::function<void(std::shared_ptr<const ImportPreview>)>;
    using Duplicate=std::function<std::optional<std::string>(const ImportPreview&)>;
    static std::shared_ptr<ImportPanel> create(std::vector<ImportRoot> roots,Commit commit,Duplicate duplicate={},HWND owner=nullptr){
        auto value=std::shared_ptr<ImportPanel>(new ImportPanel(std::move(roots),std::move(commit),std::move(duplicate),owner));value->build();return value;
    }
    winrt::Microsoft::UI::Xaml::Controls::Grid view()const{return root_;}
    void close(){closed_=true;++generation_;}
    std::shared_ptr<const ImportPreview> selected_preview()const{return preview_;}
    winrt::fire_and_forget refresh(){
        const auto lifetime=shared_from_this();if(closed_||importing_)co_return;const auto generation=++generation_;reset();set_loading(true);const auto roots=roots_;
        ImportScan scan;std::string error;const winrt::apartment_context ui;co_await winrt::resume_background();
        try{scan=ImportService::scan(roots);}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}
        try{co_await ui;}catch(...){co_return;}if(closed_||generation!=generation_)co_return;candidates_=std::move(scan.candidates);set_loading(false);filter();
        status_.Text(winrt::to_hstring(error.empty()?scan.incomplete?"Some sessions could not be listed. Use Choose File to open a specific JSONL file.":"Select a session to preview it.":error));
    }
    winrt::fire_and_forget select_file(std::filesystem::path path){
        const auto lifetime=shared_from_this();if(closed_||importing_)co_return;const auto generation=++generation_;reset();status_.Text(ui_text(L"Loading session preview…"));
        std::shared_ptr<const ImportPreview> preview;std::string error;bool available{};const winrt::apartment_context ui;co_await winrt::resume_background();
        try{preview=std::make_shared<const ImportPreview>(ImportService::preview(path));const std::filesystem::path directory(winrt::to_hstring(preview->directory).c_str());std::error_code directory_error;available=local_file::local_path(directory)&&!local_file::has_reparse(directory)&&std::filesystem::is_directory(directory,directory_error);}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}
        try{co_await ui;}catch(...){co_return;}if(closed_||generation!=generation_)co_return;preview_=std::move(preview);
        if(!preview_){status_.Text(winrt::to_hstring(error));co_return;}
        details_.Text(winrt::to_hstring(preview_->provider+" · "+preview_->session_id+"\n"+preview_->directory+"\n"+winrt::to_string(preview_->source_path.wstring())));
        std::string transcript;for(const auto& message:preview_->messages){const auto row=message.role+"\n"+message.text+"\n\n";if(row.size()>512*1024-transcript.size()){transcript+="[Preview display truncated.]";break;}transcript+=row;}reading_.Text(winrt::to_hstring(transcript));
        std::optional<std::string> duplicate;try{if(duplicate_)duplicate=duplicate_(*preview_);}catch(const std::exception& failure){status_.Text(winrt::to_hstring(failure.what()));co_return;}
        import_.IsEnabled(!duplicate&&static_cast<bool>(commit_));
        const auto summary=duplicate?"This native session is already imported.":std::to_string(preview_->messages.size())+" messages · "+std::to_string(preview_->omitted_records)+" omitted records · "+std::to_string(preview_->redacted_texts)+" redacted text fields"+(preview_->shortened_text?" · Long text was shortened.":"")+(available?"":"\nThe original working directory is unavailable. History only will be imported; no native session will be resumed.");status_.Text(winrt::to_hstring(summary));
    }
private:
    using Grid=winrt::Microsoft::UI::Xaml::Controls::Grid;using Button=winrt::Microsoft::UI::Xaml::Controls::Button;using TextBlock=winrt::Microsoft::UI::Xaml::Controls::TextBlock;using TextBox=winrt::Microsoft::UI::Xaml::Controls::TextBox;using ListView=winrt::Microsoft::UI::Xaml::Controls::ListView;
    std::vector<ImportRoot> roots_;Commit commit_;Duplicate duplicate_;HWND owner_{};std::vector<ImportCandidate> candidates_,filtered_;std::shared_ptr<const ImportPreview> preview_;
    bool closed_{},importing_{},filtering_{};std::uint64_t generation_{};Grid root_{nullptr};Button refresh_{nullptr},choose_{nullptr},import_{nullptr};TextBox search_{nullptr},reading_{nullptr};TextBlock details_{nullptr},status_{nullptr};ListView files_{nullptr};
    ImportPanel(std::vector<ImportRoot> roots,Commit commit,Duplicate duplicate,HWND owner):roots_(std::move(roots)),commit_(std::move(commit)),duplicate_(std::move(duplicate)),owner_(owner){}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& view,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(view,id);}
    void reset(){preview_.reset();if(import_)import_.IsEnabled(false);if(reading_)reading_.Text(L"");if(details_)details_.Text(L"");}
    void set_loading(bool loading){refresh_.IsEnabled(!loading);choose_.IsEnabled(!loading);files_.IsEnabled(!loading);search_.IsEnabled(!loading);}
    void filter(){
        ++generation_;reset();filtering_=true;filtered_.clear();files_.Items().Clear();const auto query=workspace_text::fold(winrt::to_string(search_.Text()));
        for(const auto& candidate:candidates_)if(query.empty()||workspace_text::fold(candidate.title+" "+candidate.directory+" "+candidate.provider).find(query)!=std::string::npos){filtered_.push_back(candidate);winrt::Microsoft::UI::Xaml::Controls::ListViewItem item;item.Content(winrt::box_value(winrt::to_hstring(candidate.title+"\n"+candidate.provider+" · "+candidate.directory)));files_.Items().Append(item);}
        filtering_=false;
    }
    void build(){
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace xaml=winrt::Microsoft::UI::Xaml;
        root_=Grid{};identify(root_,L"ImportPanel");root_.RowSpacing(8);root_.Padding({12,8,12,12});
        for(int i=0;i<6;++i){ui::RowDefinition row;row.Height({1,i==3?xaml::GridUnitType::Star:xaml::GridUnitType::Auto});root_.RowDefinitions().Append(row);}
        TextBlock explanation;explanation.Text(ui_text(L"Preview a Claude Code or Codex conversation before importing. The original file stays unchanged; imported threads start in approval mode."));explanation.TextWrapping(xaml::TextWrapping::Wrap);root_.Children().Append(explanation);
        ui::StackPanel toolbar;toolbar.Orientation(ui::Orientation::Horizontal);toolbar.Spacing(8);
        refresh_=Button{};refresh_.Content(winrt::box_value(ui_text(L"Refresh")));identify(refresh_,L"RefreshImports");refresh_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->refresh();});toolbar.Children().Append(refresh_);
        choose_=Button{};choose_.Content(winrt::box_value(ui_text(L"Choose File…")));identify(choose_,L"ChooseImportFile");choose_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->choose_file();});toolbar.Children().Append(choose_);
        import_=Button{};import_.Content(winrt::box_value(ui_text(L"Import")));import_.IsEnabled(false);identify(import_,L"ImportSession");import_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->import_selected();});toolbar.Children().Append(import_);Grid::SetRow(toolbar,1);root_.Children().Append(toolbar);
        search_=TextBox{};search_.PlaceholderText(ui_text(L"Search sessions"));identify(search_,L"ImportSearch");search_.TextChanged([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock();self&&!self->importing_)self->filter();});Grid::SetRow(search_,2);root_.Children().Append(search_);
        Grid body;body.ColumnSpacing(8);ui::ColumnDefinition list;list.Width({240,xaml::GridUnitType::Pixel});body.ColumnDefinitions().Append(list);body.ColumnDefinitions().Append(ui::ColumnDefinition{});
        files_=ListView{};identify(files_,L"ImportCandidates");files_.SelectionChanged([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock();self&&!self->filtering_){const auto index=self->files_.SelectedIndex();if(index>=0&&static_cast<std::size_t>(index)<self->filtered_.size())self->select_file(self->filtered_[index].path);}});body.Children().Append(files_);
        reading_=TextBox{};reading_.AcceptsReturn(true);reading_.IsReadOnly(true);reading_.TextWrapping(xaml::TextWrapping::Wrap);identify(reading_,L"ImportTranscriptPreview");Grid::SetColumn(reading_,1);body.Children().Append(reading_);Grid::SetRow(body,3);root_.Children().Append(body);
        details_=TextBlock{};details_.TextWrapping(xaml::TextWrapping::Wrap);details_.IsTextSelectionEnabled(true);identify(details_,L"ImportDetails");Grid::SetRow(details_,4);root_.Children().Append(details_);
        status_=TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);identify(status_,L"ImportStatus");Grid::SetRow(status_,5);root_.Children().Append(status_);
    }
    void choose_file(){
        if(importing_||closed_)return;
        try{winrt::com_ptr<IFileOpenDialog> dialog;winrt::check_hresult(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(dialog.put())));DWORD options{};winrt::check_hresult(dialog->GetOptions(&options));winrt::check_hresult(dialog->SetOptions(options|FOS_FORCEFILESYSTEM|FOS_FILEMUSTEXIST));
            COMDLG_FILTERSPEC type{L"JSONL session",L"*.jsonl"};winrt::check_hresult(dialog->SetFileTypes(1,&type));const auto result=dialog->Show(owner_);if(result==HRESULT_FROM_WIN32(ERROR_CANCELLED))return;winrt::check_hresult(result);winrt::com_ptr<IShellItem> item;winrt::check_hresult(dialog->GetResult(item.put()));PWSTR path{};winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH,&path));std::filesystem::path source(path);CoTaskMemFree(path);select_file(std::move(source));
        }catch(const winrt::hresult_error& failure){status_.Text(failure.message());}catch(const std::exception& failure){status_.Text(winrt::to_hstring(failure.what()));}
    }
    winrt::fire_and_forget import_selected(){
        const auto lifetime=shared_from_this();if(closed_||importing_||!preview_||!commit_)co_return;const auto preview=preview_;const auto generation=++generation_;importing_=true;set_loading(true);import_.IsEnabled(false);
        std::string error;const winrt::apartment_context ui;co_await winrt::resume_background();try{ImportService::verify_unchanged(*preview);}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}
        try{co_await ui;}catch(...){co_return;}if(closed_||generation!=generation_)co_return;
        if(error.empty())try{commit_(preview);}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}
        importing_=false;set_loading(false);status_.Text(error.empty()?ui_text(L"Imported"):winrt::to_hstring(error));if(!error.empty())import_.IsEnabled(true);
    }
};
} // namespace coincide
