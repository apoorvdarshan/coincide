#pragma once
#include "NativeStrings.h"
#include "../Runtime/InstructionGitSync.h"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <shobjidl.h>
#include <tuple>

namespace coincide {
class InstructionGitPanel:public std::enable_shared_from_this<InstructionGitPanel>{
public:
    static std::shared_ptr<InstructionGitPanel> create(std::filesystem::path data_directory,instruction_git::Runner runner={}){
        auto result=std::shared_ptr<InstructionGitPanel>(new InstructionGitPanel(std::move(data_directory),std::move(runner)));result->build();return result;
    }
    winrt::Microsoft::UI::Xaml::Controls::StackPanel view()const{return root_;}
    std::shared_ptr<instruction_git::Service> service()const{return service_;}
    bool busy()const noexcept{return busy_;}
    bool mutating()const noexcept{return mutating_;}
    std::filesystem::path repository_root()const{return repository_root_;}
    std::filesystem::path mutation_target()const{return mutation_targets_.empty()?repository_root_:mutation_targets_.front();}
    std::vector<std::filesystem::path> mutation_targets()const{return mutation_targets_;}
    void set_mutation_guard(std::function<bool(const std::filesystem::path&)> guard){mutation_guard_=std::move(guard);}
    void owner(HWND value){owner_=value;}
    void select_source(std::optional<InstructionFile> source){source_=std::move(source);binding_id_.clear();repository_root_.clear();++generation_;cancel_->store(true);review_.reset();if(review_box_)review_box_.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);if(!busy_)refresh();}
    void close(){closed_=true;++generation_;cancel_->store(true);review_.reset();abandon(service_);}
    void tick(std::uint64_t now){if(closed_||busy_)return;try{std::set<std::string> permitted;std::vector<std::filesystem::path> targets;
        for(const auto& binding:service_->bindings())if(binding.automatic&&!binding.paused){const auto source=binding.source.resolved.parent_path();if(mutation_guard_&&(!mutation_guard_(binding.repository)||!mutation_guard_(source)))continue;permitted.insert(binding.id);targets.push_back(binding.repository);targets.push_back(source);}
        if(permitted.empty())return;mutation_targets_=std::move(targets);mutating_=true;const auto allowed=std::make_shared<const std::set<std::string>>(std::move(permitted));work([now,allowed](instruction_git::Service& service,const instruction_git::Cancel& cancel){Work result;const std::function<bool(const instruction_git::Binding&)> permit=[allowed](const instruction_git::Binding& binding){return allowed->contains(binding.id);};for(const auto& outcome:service.tick(now,cancel,permit))result.message=outcome.message;return result;});
        }catch(...){status_.Text(ui_text(L"Automatic instruction sync is waiting for valid settings and available workspaces."));}}
    void refresh(){work([](auto& service,const auto&){service.reload();return Work{};});}
private:
    using Stack=winrt::Microsoft::UI::Xaml::Controls::StackPanel;using Button=winrt::Microsoft::UI::Xaml::Controls::Button;
    using TextBox=winrt::Microsoft::UI::Xaml::Controls::TextBox;using Text=winrt::Microsoft::UI::Xaml::Controls::TextBlock;
    using Check=winrt::Microsoft::UI::Xaml::Controls::CheckBox;using Combo=winrt::Microsoft::UI::Xaml::Controls::ComboBox;
    struct Work {std::string message,id;std::shared_ptr<const instruction_git::Review> review;std::optional<instruction_git::Status> status;std::optional<instruction_git::Binding> binding;};
    using Worker=std::function<Work(instruction_git::Service&,const instruction_git::Cancel&)>;
    std::shared_ptr<instruction_git::Service> service_;std::optional<InstructionFile> source_;std::shared_ptr<const instruction_git::Review> review_;
    std::shared_ptr<std::atomic_bool> cancel_{std::make_shared<std::atomic_bool>(false)};bool closed_{};std::atomic_bool busy_{},mutating_{};std::uint64_t generation_{};std::string binding_id_;HWND owner_{};std::filesystem::path repository_root_;std::vector<std::filesystem::path> mutation_targets_;std::function<bool(const std::filesystem::path&)> mutation_guard_;
    Stack root_{nullptr},controls_{nullptr},review_box_{nullptr};Combo setup_kind_{nullptr};TextBox repository_{nullptr},copy_{nullptr},address_{nullptr},preview_{nullptr};Check automatic_push_{nullptr},consent_{nullptr};Text status_{nullptr},title_{nullptr},detail_{nullptr};Button confirm_{nullptr};
    explicit InstructionGitPanel(std::filesystem::path directory,instruction_git::Runner runner):service_(std::make_shared<instruction_git::Service>(std::move(directory),std::move(runner))){}
    static winrt::fire_and_forget abandon(std::shared_ptr<instruction_git::Service> service){co_await winrt::resume_background();try{service->discard_all();}catch(...){}}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& value,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
    static bool checked(const Check& value){const auto state=value.IsChecked();return state&&state.Value();}
    void enable_controls(bool enabled){const std::function<void(const winrt::Microsoft::UI::Xaml::UIElement&)> set=[&](const auto& element){if(const auto control=element.template try_as<winrt::Microsoft::UI::Xaml::Controls::Control>())control.IsEnabled(enabled);if(const auto panel=element.template try_as<winrt::Microsoft::UI::Xaml::Controls::Panel>())for(const auto& child:panel.Children())set(child);};set(controls_);controls_.IsHitTestVisible(enabled);}
    Button button(const wchar_t* text,const wchar_t* id,std::function<void()> action){Button value;value.Content(winrt::box_value(ui_text(text)));identify(value,id);value.Click([action=std::move(action)](const auto&,const auto&){action();});return value;}
    void build(){
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace xaml=winrt::Microsoft::UI::Xaml;
        root_=Stack{};root_.Spacing(8);identify(root_,L"InstructionGitPanel");
        Text explanation;explanation.Text(ui_text(L"Keep a Git copy while the local instructions and their links stay in place. Review each manual change. Automatic sync is off until explicitly approved."));explanation.TextWrapping(xaml::TextWrapping::Wrap);root_.Children().Append(explanation);
        controls_=Stack{};controls_.Spacing(8);root_.Children().Append(controls_);
        setup_kind_=Combo{};identify(setup_kind_,L"InstructionGitSetupKind");setup_kind_.Header(winrt::box_value(ui_text(L"Repository setup")));
        for(const auto* text:{L"Link existing repository",L"Create local repository",L"Clone existing repository",L"Create private GitHub repository"})setup_kind_.Items().Append(winrt::box_value(ui_text(text)));setup_kind_.SelectedIndex(0);controls_.Children().Append(setup_kind_);
        repository_=TextBox{};repository_.Header(winrt::box_value(ui_text(L"Repository folder")));identify(repository_,L"InstructionGitRepository");controls_.Children().Append(repository_);
        controls_.Children().Append(button(L"Choose repository folder…",L"InstructionGitChooseFolder",[weak=weak_from_this()]{if(const auto self=weak.lock())self->choose_folder();}));
        copy_=TextBox{};copy_.Header(winrt::box_value(ui_text(L"Git copy filename")));copy_.Text(L"Global.md");identify(copy_,L"InstructionGitCopy");controls_.Children().Append(copy_);
        address_=TextBox{};address_.Header(winrt::box_value(ui_text(L"Clone address or private GitHub owner/name")));identify(address_,L"InstructionGitAddress");controls_.Children().Append(address_);
        Stack setup;setup.Orientation(ui::Orientation::Horizontal);setup.Spacing(8);setup.Children().Append(button(L"Review setup",L"InstructionGitReviewSetup",[weak=weak_from_this()]{if(const auto self=weak.lock())self->prepare_setup();}));setup.Children().Append(button(L"Refresh status",L"InstructionGitRefresh",[weak=weak_from_this()]{if(const auto self=weak.lock())self->refresh();}));controls_.Children().Append(setup);
        const auto row=[&](std::initializer_list<std::tuple<const wchar_t*,const wchar_t*,instruction_git::Action>> actions){Stack line;line.Orientation(ui::Orientation::Horizontal);line.Spacing(8);for(const auto& [label,id,action]:actions)line.Children().Append(button(label,id,[weak=weak_from_this(),action]{if(const auto self=weak.lock())self->prepare(action);}));controls_.Children().Append(line);};
        row({{L"Use local instructions",L"InstructionGitUseLocal",instruction_git::Action::use_source},{L"Use Git copy",L"InstructionGitUseCopy",instruction_git::Action::use_copy},{L"Commit copy",L"InstructionGitCommit",instruction_git::Action::commit}});
        row({{L"Fetch",L"InstructionGitFetch",instruction_git::Action::fetch},{L"Pull",L"InstructionGitPull",instruction_git::Action::pull},{L"Push",L"InstructionGitPush",instruction_git::Action::push},{L"Unlink",L"InstructionGitUnlink",instruction_git::Action::unlink}});
        automatic_push_=Check{};automatic_push_.Content(winrt::box_value(ui_text(L"Include instruction-only pushes in automatic sync")));automatic_push_.IsChecked(false);identify(automatic_push_,L"InstructionGitAutomaticPush");controls_.Children().Append(automatic_push_);
        row({{L"Review automatic sync",L"InstructionGitEnableAutomatic",instruction_git::Action::enable_automatic},{L"Pause automatic sync",L"InstructionGitPauseAutomatic",instruction_git::Action::disable_automatic}});
        review_box_=Stack{};review_box_.Spacing(8);review_box_.Visibility(xaml::Visibility::Collapsed);identify(review_box_,L"InstructionGitReview");root_.Children().Append(review_box_);
        title_=Text{};title_.FontSize(18);title_.TextWrapping(xaml::TextWrapping::Wrap);identify(title_,L"InstructionGitReviewTitle");review_box_.Children().Append(title_);
        detail_=Text{};detail_.TextWrapping(xaml::TextWrapping::Wrap);detail_.IsTextSelectionEnabled(true);identify(detail_,L"InstructionGitReviewDetail");review_box_.Children().Append(detail_);
        preview_=TextBox{};preview_.IsReadOnly(true);preview_.AcceptsReturn(true);preview_.MaxHeight(240);preview_.TextWrapping(xaml::TextWrapping::Wrap);identify(preview_,L"InstructionGitReviewText");review_box_.Children().Append(preview_);
        consent_=Check{};consent_.Content(winrt::box_value(ui_text(L"I reviewed this destination and these instruction changes")));consent_.IsChecked(false);identify(consent_,L"InstructionGitConsent");
        const auto consent_changed=[weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->confirm_.IsEnabled(!self->busy_&&self->review_&&checked(self->consent_));};consent_.Checked(consent_changed);consent_.Unchecked(consent_changed);review_box_.Children().Append(consent_);
        Stack buttons;buttons.Orientation(ui::Orientation::Horizontal);buttons.Spacing(8);confirm_=button(L"Approve reviewed action",L"InstructionGitConfirm",[weak=weak_from_this()]{if(const auto self=weak.lock())self->approve();});confirm_.IsEnabled(false);buttons.Children().Append(confirm_);
        buttons.Children().Append(button(L"Cancel",L"InstructionGitCancel",[weak=weak_from_this()]{if(const auto self=weak.lock())self->cancel_review();}));review_box_.Children().Append(buttons);
        status_=Text{};status_.TextWrapping(xaml::TextWrapping::Wrap);identify(status_,L"InstructionGitStatus");status_.Text(ui_text(L"Select an instruction file to configure its Git copy."));root_.Children().Append(status_);enable_controls(false);
    }
    winrt::fire_and_forget work(Worker operation){
        const auto lifetime=shared_from_this();if(closed_||busy_)co_return;busy_=true;const auto generation=++generation_;const auto source=source_;const auto service=service_;
        struct Finish{InstructionGitPanel& self;bool active{true};void release(){if(active){self.mutating_=false;self.busy_=false;active=false;}}~Finish(){release();}}finish{*this};
        cancel_=std::make_shared<std::atomic_bool>(false);const auto cancel=cancel_;enable_controls(false);confirm_.IsEnabled(false);status_.Text(ui_text(L"Checking instruction synchronization…"));const winrt::apartment_context ui;
        Work result;std::string error;co_await winrt::resume_background();
        try{result=operation(*service,[cancel]{return cancel->load();});if(source){for(const auto& item:service->bindings())if(local_file::equal_path(item.source.resolved.wstring(),source->resolved.wstring())){result.id=item.id;result.binding=item;try{result.status=service->status(item,[cancel]{return cancel->load();});}catch(const std::exception& failure){if(result.message.empty())result.message=failure.what();}break;}}}
        catch(const std::exception& failure){error=failure.what();}catch(...){error="Instruction synchronization could not be completed. Files were retained; refresh before retrying.";}
        try{co_await ui;}catch(...){co_return;}finish.release();if(closed_)co_return;if(generation!=generation_){refresh();co_return;}
        enable_controls(source_.has_value());if(error.empty()||!result.id.empty())binding_id_=result.id;
        if(!error.empty()){status_.Text(winrt::to_hstring(error));co_return;}
        if(result.binding){repository_root_=result.binding->repository;repository_.Text(winrt::to_hstring(instruction_git::narrow(result.binding->repository)));copy_.Text(winrt::to_hstring(result.binding->copy));automatic_push_.IsChecked(result.binding->push_automatically);}
        if(result.review){review_=std::move(result.review);title_.Text(winrt::to_hstring(review_->title));detail_.Text(winrt::to_hstring(review_->detail));preview_.Text(winrt::to_hstring(review_->preview));consent_.IsChecked(false);review_box_.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Visible);}
        std::string message=result.message;if(message.empty()&&result.status){const auto& status=*result.status;message="Branch: "+status.git.branch+" · ahead "+std::to_string(status.git.ahead)+" · behind "+std::to_string(status.git.behind)+"\n";
            message+=status.step==instruction_git::CopyStep::in_step?"Instruction texts agree.":status.step==instruction_git::CopyStep::update_copy?"Local instructions changed; review the Git copy update.":status.step==instruction_git::CopyStep::update_source?"Incoming instruction text requires approval.":"Both instruction texts changed; choose a side explicitly.";
            if(result.binding->paused)message+="\n"+result.binding->review;else if(result.binding->automatic)message+="\nAutomatic copy sync is enabled; incoming master changes still require approval.";}
        if(message.empty())message=source_?"Choose a repository setup, then review its destination and text.":"Select an instruction file to configure its Git copy.";status_.Text(winrt::to_hstring(message));
    }
    void prepare_setup(){if(!source_||busy_||closed_)return;const auto source=*source_;const auto path=std::filesystem::path(repository_.Text().c_str());const auto name=winrt::to_string(copy_.Text());const auto address=winrt::to_string(address_.Text());const auto kind=setup_kind_.SelectedIndex();
        work([source,path,name,address,kind](auto& service,const auto& cancel){Work result;result.review=kind==0?service.attach(source,path,name,cancel):service.setup(source,path,name,kind==1?instruction_git::SetupKind::local:kind==2?instruction_git::SetupKind::clone:instruction_git::SetupKind::private_github,address);return result;});}
    void prepare(instruction_git::Action action){if(binding_id_.empty()){status_.Text(ui_text(L"Link an instruction Git copy before using synchronization actions."));return;}const auto id=binding_id_;const auto push=checked(automatic_push_);work([id,action,push](auto& service,const auto& cancel){Work result;result.review=service.preview(id,action,push,cancel);return result;});}
    void approve(){if(!review_||!checked(consent_)||busy_)return;const bool mutation=review_->action!=instruction_git::Action::unlink&&review_->action!=instruction_git::Action::disable_automatic&&review_->action!=instruction_git::Action::enable_automatic&&review_->action!=instruction_git::Action::attach;
        if(mutation){const auto& binding=review_->binding;const auto source=binding.source.resolved.parent_path();try{if(mutation_guard_&&(!mutation_guard_(binding.repository)||!mutation_guard_(source))){status_.Text(ui_text(L"Wait for work in the affected repositories to finish before changing instructions or Git references."));return;}}catch(...){status_.Text(ui_text(L"The instruction workspace could not be reserved."));return;}mutation_targets_={binding.repository,source};mutating_=true;}
        const auto review=std::move(review_);review_box_.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);work([review](auto& service,const auto& cancel){Work result;result.message=service.apply(review,cancel).message;return result;});}
    void cancel_review(){if(busy_)return;const auto review=std::move(review_);review_box_.Visibility(winrt::Microsoft::UI::Xaml::Visibility::Collapsed);work([review](auto& service,const auto&){service.discard(review);return Work{};});}
    void choose_folder(){if(busy_||closed_)return;try{winrt::com_ptr<IFileOpenDialog> dialog;winrt::check_hresult(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(dialog.put())));DWORD options{};winrt::check_hresult(dialog->GetOptions(&options));winrt::check_hresult(dialog->SetOptions(options|FOS_PICKFOLDERS|FOS_FORCEFILESYSTEM));const auto result=dialog->Show(owner_);if(result==HRESULT_FROM_WIN32(ERROR_CANCELLED))return;winrt::check_hresult(result);winrt::com_ptr<IShellItem> item;winrt::check_hresult(dialog->GetResult(item.put()));PWSTR raw{};winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH,&raw));const std::filesystem::path path(raw);CoTaskMemFree(raw);repository_.Text(winrt::to_hstring(instruction_git::narrow(path)));}catch(...){status_.Text(ui_text(L"The repository folder could not be selected."));}}
};
} // namespace coincide
