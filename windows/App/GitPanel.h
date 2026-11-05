#pragma once
#include "NativeStrings.h"
#include "../Runtime/GitService.h"
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Windows.UI.Text.h>
#include <functional>

namespace coincide {
namespace git_panel {
namespace xaml=winrt::Microsoft::UI::Xaml;
namespace ui=xaml::Controls;
struct Confirmation{std::string title,detail,action;};
class Panel:public std::enable_shared_from_this<Panel>{
public:
    using TargetGuard=std::function<bool(const std::filesystem::path&,bool removing)>;
    using OpenWorktree=std::function<void(const std::filesystem::path&)>;
    using Confirm=std::function<winrt::Windows::Foundation::IAsyncOperation<bool>(Confirmation)>;
    static std::shared_ptr<Panel> create(std::filesystem::path folder,std::function<bool()> may_mutate={},std::function<void(std::string)> quote={},TargetGuard target_guard={},OpenWorktree open={},Confirm confirm={}){
        auto value=std::shared_ptr<Panel>(new Panel(std::move(folder),std::move(may_mutate),std::move(quote),std::move(target_guard),std::move(open),std::move(confirm)));value->build();value->refresh();return value;
    }
    xaml::UIElement view()const{return root_;}
    std::filesystem::path repository_root()const{return repository_root_.empty()?folder_:repository_root_;}
    bool mutating()const{return mutating_;}
    bool busy()const{return busy_;}
    std::filesystem::path mutation_target()const{return !mutating_||mutation_target_.empty()?repository_root():mutation_target_;}
    void close(){closed_=true;}
private:
    std::filesystem::path folder_,repository_root_,mutation_target_;
    std::function<bool()> may_mutate_;
    std::function<void(std::string)> quote_;
    TargetGuard target_guard_;OpenWorktree open_;Confirm confirm_;
    std::shared_ptr<GitService> service_;
    ui::StackPanel root_{nullptr},buttons_{nullptr};
    ui::TextBlock status_{nullptr},output_{nullptr};
    ui::ListView files_{nullptr},worktrees_{nullptr},checkpoints_{nullptr};
    ui::ComboBox branches_{nullptr},compare_{nullptr};
    ui::TextBox preview_{nullptr},message_{nullptr},remote_{nullptr},new_branch_{nullptr},worktree_path_{nullptr},worktree_branch_{nullptr},checkpoint_message_{nullptr};
    ui::CheckBox staged_{nullptr},worktree_create_{nullptr};ui::Button open_worktree_{nullptr};
    std::vector<GitFile> file_values_;
    std::vector<GitBranch> branch_values_;
    std::vector<GitWorktree> worktree_values_;std::vector<GitCheckpoint> checkpoint_values_;std::string head_,current_branch_;
    std::vector<ui::Button> commands_;
    std::atomic_bool busy_{},closed_{},mutating_{};
    explicit Panel(std::filesystem::path folder,std::function<bool()> guard,std::function<void(std::string)> quote,TargetGuard target_guard,OpenWorktree open,Confirm confirm):folder_(std::move(folder)),may_mutate_(std::move(guard)),quote_(std::move(quote)),target_guard_(std::move(target_guard)),open_(std::move(open)),confirm_(std::move(confirm)){}
    static void identify(const xaml::DependencyObject& object,const wchar_t* id){xaml::Automation::AutomationProperties::SetAutomationId(object,id);}
    std::vector<std::string> selected_paths()const{
        std::vector<std::string> result;for(const auto& item:files_.SelectedItems()){uint32_t at{};if(files_.Items().IndexOf(item,at)&&at<file_values_.size())result.push_back(file_values_[at].path);}return result;
    }
    std::optional<GitBranch> selected_branch()const{const auto index=branches_.SelectedIndex();return index>=0&&static_cast<std::size_t>(index)<branch_values_.size()?std::optional<GitBranch>{branch_values_[index]}:std::nullopt;}
    std::optional<GitWorktree> selected_worktree()const{const auto index=worktrees_.SelectedIndex();return index>=0&&static_cast<std::size_t>(index)<worktree_values_.size()?std::optional<GitWorktree>{worktree_values_[index]}:std::nullopt;}
    std::optional<GitCheckpoint> selected_checkpoint()const{const auto index=checkpoints_.SelectedIndex();return index>=0&&static_cast<std::size_t>(index)<checkpoint_values_.size()?std::optional<GitCheckpoint>{checkpoint_values_[index]}:std::nullopt;}
    Confirmation prompt(std::string title,std::string detail,std::string action)const{return{std::move(title),std::move(detail)+"\n\n"+winrt::to_string(repository_root().wstring()),std::move(action)};}
    void controls(bool enabled){for(const auto& button:commands_)button.IsEnabled(enabled);for(const auto& list:{files_,worktrees_,checkpoints_})list.IsEnabled(enabled);branches_.IsEnabled(enabled);compare_.IsEnabled(enabled);for(const auto& box:{new_branch_,worktree_path_,worktree_branch_,checkpoint_message_,message_,remote_})box.IsEnabled(enabled);staged_.IsEnabled(enabled);worktree_create_.IsEnabled(enabled);if(open_worktree_)open_worktree_.IsEnabled(enabled&&static_cast<bool>(open_));}
    ui::Button command(const winrt::hstring& label,const wchar_t* id,std::function<void(Panel&)> action){
        ui::Button result;result.Content(winrt::box_value(label));identify(result,id);const auto weak=weak_from_this();
        result.Click([weak,action=std::move(action)](const auto&,const auto&){if(const auto self=weak.lock();self&&!self->closed_)action(*self);});commands_.push_back(result);return result;
    }
    void build(){
        root_=ui::StackPanel{};root_.Spacing(8);root_.Padding({12,8,12,12});identify(root_,L"GitPanel");
        status_=ui::TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);status_.IsTextSelectionEnabled(true);root_.Children().Append(status_);
        branches_=ui::ComboBox{};branches_.PlaceholderText(ui_text(L"Branch"));identify(branches_,L"GitBranches");root_.Children().Append(branches_);
        ui::StackPanel branch_actions;branch_actions.Orientation(ui::Orientation::Horizontal);branch_actions.Spacing(6);
        branch_actions.Children().Append(command(ui_text(L"Switch Branch"),L"GitSwitchBranch",[](Panel& self){
            const auto branch=self.selected_branch();if(!branch)return;if(branch->remote){self.output_.Text(ui_text(L"Use Track Remote Branch to create a local checkout."));return;}self.run([name=branch->name](GitService& git){git.switch_branch(name);return std::string{};},true);
        }));
        branch_actions.Children().Append(command(ui_text(L"Refresh"),L"GitRefresh",[](Panel& self){self.refresh();}));root_.Children().Append(branch_actions);
        new_branch_=ui::TextBox{};new_branch_.PlaceholderText(ui_text(L"New Branch"));new_branch_.MaxLength(512);identify(new_branch_,L"GitNewBranchName");root_.Children().Append(new_branch_);
        root_.Children().Append(command(ui_text(L"Create Branch"),L"GitCreateBranch",[](Panel& self){const auto name=winrt::to_string(self.new_branch_.Text());self.run([name](GitService& git){git.switch_branch(name,true);return std::string{};},true);}));
        root_.Children().Append(command(ui_text(L"Track Remote Branch"),L"GitTrackBranch",[](Panel& self){const auto branch=self.selected_branch();if(!branch||!branch->remote){self.output_.Text(ui_text(L"Select a remote branch first."));return;}auto name=winrt::to_string(self.new_branch_.Text());if(name.empty()){const auto slash=branch->name.find('/');name=slash==std::string::npos?branch->name:branch->name.substr(slash+1);}self.run([remote=branch->name,name](GitService& git){git.track_branch(remote,name);return std::string{};},true);}));
        root_.Children().Append(command(ui_text(L"Rename Branch"),L"GitRenameBranch",[](Panel& self){const auto branch=self.selected_branch();if(!branch||branch->remote){self.output_.Text(ui_text(L"Select a local branch first."));return;}const auto name=winrt::to_string(self.new_branch_.Text());self.run([before=branch->name,name](GitService& git){git.rename_branch(before,name);return std::string{};},true);}));
        root_.Children().Append(command(ui_text(L"Delete Branch"),L"GitDeleteBranch",[](Panel& self){const auto branch=self.selected_branch();if(!branch||branch->remote)return;self.run([name=branch->name](GitService& git){git.delete_branch(name);return std::string{};},true,false,self.prompt("Delete Branch","Delete the local branch “"+branch->name+"”? Git will refuse an unmerged branch or a branch used by a worktree.","Delete Branch"));}));
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
        ui::Expander worktree_section;identify(worktree_section,L"GitWorktreeSection");worktree_section.Header(winrt::box_value(ui_text(L"Worktrees")));ui::StackPanel worktree_body;worktree_body.Spacing(6);
        worktrees_=ui::ListView{};worktrees_.MaxHeight(150);identify(worktrees_,L"GitWorktreeList");worktree_body.Children().Append(worktrees_);
        worktree_body.Children().Append(command(ui_text(L"Worktrees"),L"GitWorktrees",[](Panel& self){self.refresh();}));
        worktree_path_=ui::TextBox{};worktree_path_.Header(winrt::box_value(ui_text(L"New worktree folder")));worktree_path_.MaxLength(32760);identify(worktree_path_,L"GitWorktreePath");worktree_body.Children().Append(worktree_path_);
        worktree_branch_=ui::TextBox{};worktree_branch_.Header(winrt::box_value(ui_text(L"Worktree branch")));worktree_branch_.MaxLength(512);identify(worktree_branch_,L"GitWorktreeBranch");worktree_body.Children().Append(worktree_branch_);
        worktree_create_=ui::CheckBox{};worktree_create_.Content(winrt::box_value(ui_text(L"Create a new branch")));worktree_create_.IsChecked(true);identify(worktree_create_,L"GitWorktreeCreateBranch");worktree_body.Children().Append(worktree_create_);
        worktree_body.Children().Append(command(ui_text(L"Create Worktree"),L"GitAddWorktree",[](Panel& self){const std::filesystem::path path(self.worktree_path_.Text().c_str());const auto branch=winrt::to_string(self.worktree_branch_.Text());const auto checked=self.worktree_create_.IsChecked();const bool create=checked&&checked.Value();self.run([path,branch,create](GitService& git){git.add_worktree(path,branch,create);return winrt::to_string(path.wstring());},true);}));
        open_worktree_=command(ui_text(L"Use Worktree"),L"GitOpenWorktree",[](Panel& self){const auto tree=self.selected_worktree();if(!tree||!self.open_)return;try{const std::filesystem::path path(winrt::to_hstring(tree->path).c_str());if(self.target_guard_&&!self.target_guard_(path,false))throw std::runtime_error("Stop work in this workspace before changing its context");self.open_(path);}catch(const std::exception& error){self.output_.Text(winrt::to_hstring(error.what()));}catch(const winrt::hresult_error& error){self.output_.Text(error.message());}});worktree_body.Children().Append(open_worktree_);
        worktree_body.Children().Append(command(ui_text(L"Remove Worktree"),L"GitRemoveWorktree",[](Panel& self){const auto tree=self.selected_worktree();if(!tree)return;if(!self.target_guard_){self.output_.Text(ui_text(L"Worktree removal is unavailable in this window."));return;}const std::filesystem::path path(winrt::to_hstring(tree->path).c_str());self.run([path](GitService& git){git.remove_worktree(path);return std::string{};},true,false,self.prompt("Remove Worktree","Remove the worktree folder “"+tree->path+"” on branch “"+tree->branch+"”? Changed, untracked, ignored, locked, current and main worktrees are refused. The branch is retained.","Remove Worktree"),path,true);}));
        worktree_section.Content(worktree_body);root_.Children().Append(worktree_section);
        ui::Expander checkpoint_section;identify(checkpoint_section,L"GitCheckpointSection");checkpoint_section.Header(winrt::box_value(ui_text(L"Checkpoints")));ui::StackPanel checkpoint_body;checkpoint_body.Spacing(6);
        checkpoint_message_=ui::TextBox{};checkpoint_message_.PlaceholderText(ui_text(L"Checkpoint message"));checkpoint_message_.MaxLength(16000);identify(checkpoint_message_,L"GitCheckpointMessage");checkpoint_body.Children().Append(checkpoint_message_);
        checkpoint_body.Children().Append(command(ui_text(L"Checkpoint"),L"GitCheckpoint",[](Panel& self){auto message=winrt::to_string(self.checkpoint_message_.Text());if(message.empty())message="Coincide working tree checkpoint";self.run([message](GitService& git){const auto saved=git.checkpoint(message);return saved.reference+"\n"+saved.commit;},true);}));
        checkpoints_=ui::ListView{};checkpoints_.MaxHeight(180);identify(checkpoints_,L"GitCheckpointList");checkpoint_body.Children().Append(checkpoints_);
        checkpoint_body.Children().Append(command(ui_text(L"Preview Checkpoint"),L"GitPreviewCheckpoint",[](Panel& self){const auto saved=self.selected_checkpoint();if(saved)self.run([saved=*saved](GitService& git){const auto preview=git.checkpoint_preview(saved.reference,saved.commit);return preview.text+(preview.truncated?"\n[Preview truncated.]":"");},false,true);}));
        compare_=ui::ComboBox{};compare_.Header(winrt::box_value(ui_text(L"Compare checkpoint with")));identify(compare_,L"GitCheckpointCompare");checkpoint_body.Children().Append(compare_);
        checkpoint_body.Children().Append(command(ui_text(L"Compare Checkpoints"),L"GitCompareCheckpoints",[](Panel& self){const auto saved=self.selected_checkpoint();const auto index=self.compare_.SelectedIndex();if(saved&&index>=0&&static_cast<std::size_t>(index)<self.checkpoint_values_.size())self.run([before=self.checkpoint_values_[index].reference,after=saved->reference](GitService& git){return git.checkpoint_diff(before,after).text;},false,true);}));
        checkpoint_body.Children().Append(command(ui_text(L"Restore Checkpoint"),L"GitRestoreCheckpoint",[](Panel& self){const auto saved=self.selected_checkpoint();if(!saved)return;const auto head=self.head_;self.run([saved=*saved,head](GitService& git){git.restore_checkpoint(saved.reference,saved.commit,head);return std::string{"Checkpoint restored to the working tree. HEAD and the index are unchanged."};},true,false,self.prompt("Restore Checkpoint","Restore the working tree to checkpoint “"+saved->message+"”?\n"+saved->reference+"\nObject: "+saved->commit+"\nReviewed HEAD: "+(head.empty()?"unborn":head)+"\nAll staged, changed and untracked work must be preserved first. Ignored collisions, linked paths and sparse checkouts are refused. HEAD, the index, branch and stash are retained.","Restore Checkpoint"));}));
        checkpoint_body.Children().Append(command(ui_text(L"Delete Checkpoint"),L"GitDeleteCheckpoint",[](Panel& self){const auto saved=self.selected_checkpoint();if(saved)self.run([saved=*saved](GitService& git){git.delete_checkpoint(saved.reference,saved.commit);return std::string{};},true,false,self.prompt("Delete Checkpoint","Delete the saved checkpoint reference below? It will no longer protect this snapshot from Git's later garbage collection. Working files are unchanged.\n"+saved->reference+"\nObject: "+saved->commit,"Delete Checkpoint"));}));
        checkpoint_section.Content(checkpoint_body);root_.Children().Append(checkpoint_section);
        output_=ui::TextBlock{};output_.TextWrapping(xaml::TextWrapping::Wrap);output_.IsTextSelectionEnabled(true);identify(output_,L"GitOutput");root_.Children().Append(output_);
    }
    void refresh(){run([](GitService&){return std::string{};},false);}
    void diff(){
        if(busy_)return;const auto paths=selected_paths();if(paths.empty())return;const auto checked=staged_.IsChecked();const bool staged=checked&&checked.Value();
        run([path=paths.front(),staged](GitService& git){const auto result=git.diff(path,staged);return result.text+(result.truncated?"\n[Preview truncated; the file is unchanged.]":"");},false,true);
    }
    winrt::Windows::Foundation::IAsyncOperation<bool> ask(Confirmation confirmation){
        if(confirm_)co_return co_await confirm_(std::move(confirmation));
        ui::ContentDialog dialog;dialog.XamlRoot(root_.XamlRoot());identify(dialog,L"GitConfirmation");dialog.Title(winrt::box_value(ui_text(winrt::to_hstring(confirmation.title))));ui::TextBlock text;text.Text(winrt::to_hstring(confirmation.detail));text.TextWrapping(xaml::TextWrapping::Wrap);text.IsTextSelectionEnabled(true);dialog.Content(text);dialog.PrimaryButtonText(ui_text(winrt::to_hstring(confirmation.action)));dialog.CloseButtonText(ui_text(L"Cancel"));dialog.DefaultButton(ui::ContentDialogButton::Close);co_return co_await dialog.ShowAsync()==ui::ContentDialogResult::Primary;
    }
    bool allowed(const std::filesystem::path& target,bool removing){
        if((may_mutate_&&!may_mutate_())||(target_guard_&&!target_guard_(target,removing))){output_.Text(ui_text(L"Stop the agents and close their terminals before changing this repository or worktree."));return false;}return true;
    }
    winrt::fire_and_forget run(std::function<std::string(GitService&)> operation,bool mutation,bool diff=false,std::optional<Confirmation> confirmation={},std::filesystem::path target={},bool removing=false){
        const auto lifetime=shared_from_this();if(busy_||closed_)co_return;if(target.empty())target=repository_root();
        try{if(mutation&&!allowed(target,removing))co_return;}catch(const std::exception& failure){output_.Text(winrt::to_hstring(failure.what()));co_return;}catch(const winrt::hresult_error& failure){output_.Text(failure.message());co_return;}
        busy_=true;controls(false);output_.Text(ui_text(L"Working…"));const auto dispatcher=root_.DispatcherQueue();
        if(confirmation){bool accepted{};try{accepted=co_await ask(std::move(*confirmation));}catch(...){busy_=false;if(!closed_&&dispatcher.HasThreadAccess()){controls(true);output_.Text(ui_text(L"The confirmation could not be shown. No repository changes were made."));}co_return;}if(closed_){busy_=false;co_return;}if(!accepted){busy_=false;controls(true);output_.Text(ui_text(L"Cancelled"));co_return;}}
        try{if(mutation&&!allowed(target,removing)){busy_=false;controls(true);co_return;}}catch(const std::exception& failure){busy_=false;controls(true);output_.Text(winrt::to_hstring(failure.what()));co_return;}catch(const winrt::hresult_error& failure){busy_=false;controls(true);output_.Text(failure.message());co_return;}
        mutation_target_=target;mutating_=mutation;
        struct MutationLease{Panel& panel;~MutationLease(){panel.mutating_=false;panel.busy_=false;}} mutation_lease{*this};
        const auto selection=selected_paths();const auto old_branch=selected_branch()?selected_branch()->name:std::string{},old_tree=selected_worktree()?selected_worktree()->path:std::string{},old_checkpoint=selected_checkpoint()?selected_checkpoint()->reference:std::string{};
        const auto compared=compare_.SelectedIndex();const auto old_compare=compared>=0&&static_cast<std::size_t>(compared)<checkpoint_values_.size()?checkpoint_values_[compared].reference:std::string{};
        const winrt::apartment_context ui_thread;std::string text,error;GitStatus state;std::vector<GitBranch> branches;std::vector<GitWorktree> trees;std::vector<GitCheckpoint> checkpoints;bool status_received{};
        co_await winrt::resume_background();try{
            if(!service_)service_=std::make_shared<GitService>(GitService::discover_git(),folder_);text=operation(*service_);
        }catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}catch(const std::exception& failure){error=failure.what();}
        try{if(service_){state=service_->status();status_received=true;if(state.is_repository){branches=service_->branches();trees=service_->worktrees();checkpoints=service_->checkpoints();}}}catch(const winrt::hresult_error& failure){if(error.empty())error=winrt::to_string(failure.message());}catch(const std::exception& failure){if(error.empty())error=failure.what();}
        try{co_await ui_thread;}catch(...){co_return;}if(status_received)repository_root_=state.is_repository?std::filesystem::path(winrt::to_hstring(state.root).c_str()):std::filesystem::path{};if(closed_)co_return;
        if(status_received){
            const bool branch_changed=current_branch_!=state.branch;current_branch_=state.branch;head_=state.head;if(branch_changed)preview_.Text(L"");status_.Text(winrt::to_hstring(state.is_repository?state.root+"\n"+(state.branch.empty()?std::string{"Detached HEAD"}:state.branch)+"  ↑"+std::to_string(state.ahead)+" ↓"+std::to_string(state.behind):winrt::to_string(ui_text(L"Not a Git repository."))));
            file_values_=std::move(state.files);files_.Items().Clear();for(const auto& file:file_values_){std::string label;label+=file.untracked?'?':file.index_status;label+=file.untracked?'?':file.worktree_status;label+="  "+file.path;files_.Items().Append(winrt::box_value(winrt::to_hstring(label)));}for(std::size_t i=0;i<file_values_.size();++i)if(std::find(selection.begin(),selection.end(),file_values_[i].path)!=selection.end())files_.SelectedItems().Append(files_.Items().GetAt(static_cast<uint32_t>(i)));
            branch_values_=std::move(branches);branches_.Items().Clear();int selected_branch=-1,current_branch=-1;for(std::size_t i=0;i<branch_values_.size();++i){const auto& branch=branch_values_[i];branches_.Items().Append(winrt::box_value(winrt::to_hstring((branch.remote?"remote · ":"")+branch.name+(branch.current?" ✓":""))));if(branch.name==old_branch)selected_branch=static_cast<int>(i);if(branch.current)current_branch=static_cast<int>(i);}branches_.SelectedIndex(branch_changed?current_branch:selected_branch>=0?selected_branch:current_branch);
            worktree_values_=std::move(trees);worktrees_.Items().Clear();int selected_tree=-1;for(std::size_t i=0;i<worktree_values_.size();++i){const auto& tree=worktree_values_[i];worktrees_.Items().Append(winrt::box_value(winrt::to_hstring(tree.path+"\n"+tree.branch+(tree.main?" · main":"")+(tree.locked?" · locked":"")+(tree.prunable?" · prunable":""))));if(tree.path==old_tree)selected_tree=static_cast<int>(i);}worktrees_.SelectedIndex(selected_tree>=0?selected_tree:worktree_values_.empty()?-1:0);
            checkpoint_values_=std::move(checkpoints);checkpoints_.Items().Clear();compare_.Items().Clear();int selected_checkpoint=-1,selected_compare=-1;for(std::size_t i=0;i<checkpoint_values_.size();++i){const auto& checkpoint=checkpoint_values_[i];const auto label=checkpoint.created_at+" · "+checkpoint.message+"\n"+checkpoint.reference+"\n"+checkpoint.commit;checkpoints_.Items().Append(winrt::box_value(winrt::to_hstring(label)));compare_.Items().Append(winrt::box_value(winrt::to_hstring(checkpoint.created_at+" · "+checkpoint.message)));if(checkpoint.reference==old_checkpoint)selected_checkpoint=static_cast<int>(i);if(checkpoint.reference==old_compare)selected_compare=static_cast<int>(i);}checkpoints_.SelectedIndex(selected_checkpoint>=0?selected_checkpoint:checkpoint_values_.empty()?-1:0);compare_.SelectedIndex(selected_compare>=0?selected_compare:checkpoint_values_.empty()?-1:0);
            if(!error.empty())output_.Text(winrt::to_hstring(error));else if(diff){preview_.Text(winrt::to_hstring(text));output_.Text(L"");}else output_.Text(winrt::to_hstring(text));
        }else output_.Text(winrt::to_hstring(error));busy_=false;controls(true);
    }
};
} // namespace git_panel
using GitPanel=git_panel::Panel;
} // namespace coincide
