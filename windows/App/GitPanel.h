#pragma once
#include "NativeStrings.h"
#include "../Runtime/GitService.h"
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Windows.UI.Text.h>
#include <functional>

namespace coincide {
namespace git_panel {
namespace xaml=winrt::Microsoft::UI::Xaml;
namespace ui=xaml::Controls;
class Panel:public std::enable_shared_from_this<Panel>{
public:
    static std::shared_ptr<Panel> create(std::filesystem::path folder,std::function<bool()> may_mutate={},std::function<void(std::string)> quote={}){
        auto value=std::shared_ptr<Panel>(new Panel(std::move(folder),std::move(may_mutate),std::move(quote)));value->build();value->refresh();return value;
    }
    xaml::UIElement view()const{return root_;}
    std::filesystem::path repository_root()const{return repository_root_.empty()?folder_:repository_root_;}
    bool mutating()const{return mutating_;}
    void close(){closed_=true;}
private:
    std::filesystem::path folder_,repository_root_;
    std::function<bool()> may_mutate_;
    std::function<void(std::string)> quote_;
    std::shared_ptr<GitService> service_;
    ui::StackPanel root_{nullptr},buttons_{nullptr};
    ui::TextBlock status_{nullptr},output_{nullptr};
    ui::ListView files_{nullptr};
    ui::ComboBox branches_{nullptr};
    ui::TextBox preview_{nullptr},message_{nullptr},remote_{nullptr},new_branch_{nullptr};
    ui::CheckBox staged_{nullptr};
    std::vector<GitFile> file_values_;
    std::vector<GitBranch> branch_values_;
    std::vector<ui::Button> commands_;
    bool busy_{},closed_{},mutating_{};
    explicit Panel(std::filesystem::path folder,std::function<bool()> guard,std::function<void(std::string)> quote):folder_(std::move(folder)),may_mutate_(std::move(guard)),quote_(std::move(quote)){}
    static void identify(const xaml::DependencyObject& object,const wchar_t* id){xaml::Automation::AutomationProperties::SetAutomationId(object,id);}
    std::vector<std::string> selected_paths()const{
        std::vector<std::string> result;for(const auto& item:files_.SelectedItems()){uint32_t at{};if(files_.Items().IndexOf(item,at)&&at<file_values_.size())result.push_back(file_values_[at].path);}return result;
    }
    ui::Button command(const winrt::hstring& label,const wchar_t* id,std::function<void(Panel&)> action){
        ui::Button result;result.Content(winrt::box_value(label));identify(result,id);const auto weak=weak_from_this();
        result.Click([weak,action=std::move(action)](const auto&,const auto&){if(const auto self=weak.lock())action(*self);});commands_.push_back(result);return result;
    }
    void build(){
        root_=ui::StackPanel{};root_.Spacing(8);root_.Padding({12,8,12,12});identify(root_,L"GitPanel");
        status_=ui::TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);status_.IsTextSelectionEnabled(true);root_.Children().Append(status_);
        branches_=ui::ComboBox{};branches_.PlaceholderText(ui_text(L"Branch"));identify(branches_,L"GitBranches");root_.Children().Append(branches_);
        ui::StackPanel branch_actions;branch_actions.Orientation(ui::Orientation::Horizontal);branch_actions.Spacing(6);
        branch_actions.Children().Append(command(ui_text(L"Switch Branch"),L"GitSwitchBranch",[](Panel& self){
            const auto at=self.branches_.SelectedIndex();if(at<0||static_cast<std::size_t>(at)>=self.branch_values_.size())return;
            auto name=self.branch_values_[at].name;self.run([name](GitService& git){git.switch_branch(name);return std::string{};},true);
        }));
        branch_actions.Children().Append(command(ui_text(L"Refresh"),L"GitRefresh",[](Panel& self){self.refresh();}));root_.Children().Append(branch_actions);
        new_branch_=ui::TextBox{};new_branch_.PlaceholderText(ui_text(L"New Branch"));identify(new_branch_,L"GitNewBranchName");root_.Children().Append(new_branch_);
        root_.Children().Append(command(ui_text(L"Create Branch"),L"GitCreateBranch",[](Panel& self){const auto name=winrt::to_string(self.new_branch_.Text());self.run([name](GitService& git){git.switch_branch(name,true);return std::string{};},true);}));
        files_=ui::ListView{};files_.MaxHeight(190);files_.SelectionMode(ui::ListViewSelectionMode::Extended);identify(files_,L"GitFiles");
        const auto weak=weak_from_this();files_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())if(!self->busy_)self->diff();});root_.Children().Append(files_);
        staged_=ui::CheckBox{};staged_.Content(winrt::box_value(ui_text(L"Staged")));identify(staged_,L"GitStagedPreview");
        staged_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->diff();});root_.Children().Append(staged_);
        preview_=ui::TextBox{};preview_.IsReadOnly(true);preview_.AcceptsReturn(true);preview_.TextWrapping(xaml::TextWrapping::NoWrap);preview_.FontFamily(xaml::Media::FontFamily(L"Consolas"));preview_.MinHeight(150);preview_.MaxHeight(280);identify(preview_,L"GitDiff");root_.Children().Append(preview_);
        buttons_=ui::StackPanel{};buttons_.Orientation(ui::Orientation::Horizontal);buttons_.Spacing(6);
        buttons_.Children().Append(command(ui_text(L"Stage"),L"GitStage",[](Panel& self){const auto paths=self.selected_paths();if(!paths.empty())self.run([paths](GitService& git){git.stage(paths);return std::string{};},true);}));
        buttons_.Children().Append(command(ui_text(L"Unstage"),L"GitUnstage",[](Panel& self){const auto paths=self.selected_paths();if(!paths.empty())self.run([paths](GitService& git){git.unstage(paths);return std::string{};},true);}));
        buttons_.Children().Append(command(ui_text(L"Copy to Composer"),L"GitQuoteDiff",[](Panel& self){if(self.quote_)self.quote_(winrt::to_string(self.preview_.Text()));}));root_.Children().Append(buttons_);
        message_=ui::TextBox{};message_.PlaceholderText(ui_text(L"Commit message"));message_.AcceptsReturn(true);message_.MaxHeight(90);identify(message_,L"GitCommitMessage");root_.Children().Append(message_);
        root_.Children().Append(command(ui_text(L"Commit"),L"GitCommit",[](Panel& self){const auto message=winrt::to_string(self.message_.Text());self.run([message](GitService& git){return git.commit(message);},true);}));
        remote_=ui::TextBox{};remote_.PlaceholderText(ui_text(L"Remote"));remote_.Text(L"origin");identify(remote_,L"GitRemote");root_.Children().Append(remote_);
        root_.Children().Append(command(ui_text(L"Push"),L"GitPush",[](Panel& self){const auto remote=winrt::to_string(self.remote_.Text());self.run([remote](GitService& git){return git.push(remote);},true);}));
        root_.Children().Append(command(ui_text(L"Checkpoint"),L"GitCheckpoint",[](Panel& self){self.run([](GitService& git){const auto saved=git.checkpoint();return saved.reference+"\n"+saved.commit;},true);}));
        root_.Children().Append(command(ui_text(L"Worktrees"),L"GitWorktrees",[](Panel& self){self.run([](GitService& git){std::string text;for(const auto& tree:git.worktrees())text+=tree.path+"\n"+tree.branch+"\n\n";return text;},false);}));
        output_=ui::TextBlock{};output_.TextWrapping(xaml::TextWrapping::Wrap);output_.IsTextSelectionEnabled(true);identify(output_,L"GitOutput");root_.Children().Append(output_);
    }
    void refresh(){run([](GitService&){return std::string{};},false);}
    void diff(){
        if(busy_)return;const auto paths=selected_paths();if(paths.empty())return;const auto checked=staged_.IsChecked();const bool staged=checked&&checked.Value();
        run([path=paths.front(),staged](GitService& git){const auto result=git.diff(path,staged);return result.text+(result.truncated?"\n[Preview truncated; the file is unchanged.]":"");},false,true);
    }
    winrt::fire_and_forget run(std::function<std::string(GitService&)> operation,bool mutation,bool diff=false){
        const auto lifetime=shared_from_this();if(busy_||closed_)co_return;
        if(mutation&&may_mutate_&&!may_mutate_()){output_.Text(ui_text(L"Stop the agent before changing the repository."));co_return;}
        busy_=true;mutating_=mutation;
        struct MutationLease{bool& value;~MutationLease(){value=false;}} mutation_lease{mutating_};
        for(const auto& button:commands_)button.IsEnabled(false);files_.IsEnabled(false);branches_.IsEnabled(false);output_.Text(ui_text(L"Working…"));
        const auto selection=selected_paths();const winrt::apartment_context ui_thread;
        std::string text,error;GitStatus state;std::vector<GitBranch> branches;bool status_received{};
        co_await winrt::resume_background();
        try {
            if(!service_)service_=std::make_shared<GitService>(GitService::discover_git(),folder_);
            text=operation(*service_);state=service_->status();status_received=true;if(state.is_repository)branches=service_->branches();
        }catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}catch(const std::exception& failure){error=failure.what();}
        co_await ui_thread;
        if(status_received)repository_root_=state.is_repository?std::filesystem::path(winrt::to_hstring(state.root).c_str()):std::filesystem::path{};
        if(closed_)co_return;
        if(error.empty()){
            status_.Text(winrt::to_hstring(state.is_repository?state.root+"\n"+state.branch+"  ↑"+std::to_string(state.ahead)+" ↓"+std::to_string(state.behind):winrt::to_string(ui_text(L"Not a Git repository."))));
            file_values_=std::move(state.files);files_.Items().Clear();
            for(const auto& file:file_values_){std::string label;label+=file.untracked?'?':file.index_status;label+=file.untracked?'?':file.worktree_status;label+="  "+file.path;files_.Items().Append(winrt::box_value(winrt::to_hstring(label)));}
            for(std::size_t i=0;i<file_values_.size();++i)if(std::find(selection.begin(),selection.end(),file_values_[i].path)!=selection.end())files_.SelectedItems().Append(files_.Items().GetAt(static_cast<uint32_t>(i)));
            branch_values_=std::move(branches);branches_.Items().Clear();for(const auto& branch:branch_values_)branches_.Items().Append(winrt::box_value(winrt::to_hstring(branch.name)));
            if(diff)preview_.Text(winrt::to_hstring(text));else output_.Text(winrt::to_hstring(text));
        }else output_.Text(winrt::to_hstring(error));
        busy_=false;for(const auto& button:commands_)button.IsEnabled(true);files_.IsEnabled(true);branches_.IsEnabled(true);
    }
};
} // namespace git_panel
using GitPanel=git_panel::Panel;
} // namespace coincide
