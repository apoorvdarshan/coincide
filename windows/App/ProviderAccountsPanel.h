#pragma once
#include "NativeStrings.h"
#include "../Runtime/ProviderAccounts.h"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Dispatching.h>

namespace coincide {
// Root owns presentation, persistence notifications and the browser. No operation starts when
// merely opening this panel. Status/sign-in run only from explicit actions and never block XAML.
class ProviderAccountsPanel:public std::enable_shared_from_this<ProviderAccountsPanel> {
public:
    using ProgramResolver=std::function<std::optional<ProviderAccountProgram>(const std::string&)>;
    using Changed=std::function<void(const ProviderAccountRecord&,const ProviderAccountMetadata&)>;
    using Browser=std::function<void(const std::string&)>;
    static std::shared_ptr<ProviderAccountsPanel> create(std::filesystem::path root,ProgramResolver resolve,Changed changed={},Browser browser={}) {
        auto result=std::shared_ptr<ProviderAccountsPanel>(new ProviderAccountsPanel(std::move(root),std::move(resolve),std::move(changed),std::move(browser)));
        result->build();result->reload();return result;
    }
    winrt::Microsoft::UI::Xaml::Controls::Grid view()const{return view_;}
    void close(){closed_=true;++generation_;if(cancel_)cancel_->store(true);}
    void select(const std::string& profile_id) {
        for(std::size_t index=0;index<records_.size();++index) if(records_[index].id==profile_id){profiles_.SelectedIndex(static_cast<int>(index));return;}
    }
    const std::vector<ProviderAccountRecord>& records()const{return records_;}
    bool busy()const{return busy_;}
    void set_operation_guard(std::function<void(const ProviderAccountRecord&,bool)> guard){operation_guard_=std::move(guard);}
    void set_use_profile(Changed callback,std::function<bool(const ProviderAccountRecord&,const ProviderAccountMetadata&)> compatible={}){use_profile_=std::move(callback);compatible_=std::move(compatible);update_buttons();}
    std::optional<ProviderAccountRecord> selected_record()const {const auto index=profiles_.SelectedIndex();return index>=0&&static_cast<std::size_t>(index)<records_.size()?std::optional(records_[static_cast<std::size_t>(index)]):std::nullopt;}
    void use_profile(){
        if(busy_||closed_)return;const auto record=selected_record();if(!record)return;
        try{const auto found=verified_.find(record->id);if(!use_profile_||found==verified_.end()||!can_use(*record,found->second)){update_buttons();status_.Text(ui_text(L"Check this profile's current compatible account before using it."));return;}use_profile_(*record,found->second);status_.Text(ui_text(L"The verified profile was selected."));}
        catch(const winrt::hresult_error& error){status_.Text(error.message());}catch(const std::exception& error){status_.Text(winrt::to_hstring(error.what()));}
    }
    void reload() {
        if(busy_||closed_)return;
        try {records_=store_.open();verified_.clear();verified_programs_.clear();populate();status_.Text(ui_text(L"Choose a profile, then check its status. Existing CLI logins are preserved."));}
        catch(const winrt::hresult_error& error){status_.Text(error.message());}
        catch(const std::exception& error){status_.Text(winrt::to_hstring(error.what()));}
    }
    void add_profile() {
        if(busy_||closed_)return;
        try {
            const auto index=provider_.SelectedIndex(); if(index<0||index>=3)throw std::invalid_argument("Choose a provider");
            const std::string provider=std::array<std::string,3>{"cursor","grok","antigravity"}[index];
            const auto record=store_.create(provider,winrt::to_string(label_.Text())); auto next=records_;next.push_back(record);store_.save(next);records_=std::move(next);
            populate();select(record.id);label_.Text(L"");status_.Text(ui_text(L"Local profile created. Sign in only when you are ready to approve the provider's browser page."));
        }catch(const winrt::hresult_error& error){status_.Text(error.message());}
         catch(const std::exception& error){status_.Text(winrt::to_hstring(error.what()));}
    }
    winrt::fire_and_forget check_status(){co_await operate(false);}
    winrt::fire_and_forget sign_in(){co_await operate(true);}
    void cancel(){if(cancel_)cancel_->store(true);}
private:
    using Grid=winrt::Microsoft::UI::Xaml::Controls::Grid;using Button=winrt::Microsoft::UI::Xaml::Controls::Button;
    using TextBlock=winrt::Microsoft::UI::Xaml::Controls::TextBlock;using ComboBox=winrt::Microsoft::UI::Xaml::Controls::ComboBox;using TextBox=winrt::Microsoft::UI::Xaml::Controls::TextBox;
    ProviderAccountStore store_;ProgramResolver resolve_;Changed changed_;Browser browser_;std::vector<ProviderAccountRecord> records_;
    std::function<void(const ProviderAccountRecord&,bool)> operation_guard_;
    Changed use_profile_;std::function<bool(const ProviderAccountRecord&,const ProviderAccountMetadata&)> compatible_;
    std::map<std::string,ProviderAccountMetadata> verified_;std::map<std::string,ProviderAccountProgram> verified_programs_;
    Grid view_{nullptr};ComboBox provider_{nullptr},profiles_{nullptr};TextBox label_{nullptr};TextBlock status_{nullptr},detail_{nullptr};Button add_{nullptr},check_{nullptr},sign_in_{nullptr},cancel_button_{nullptr},use_button_{nullptr};
    ProviderAccounts::Cancel cancel_;bool busy_{},closed_{};std::uint64_t generation_{};
    ProviderAccountsPanel(std::filesystem::path root,ProgramResolver resolve,Changed changed,Browser browser):store_(std::move(root)),resolve_(std::move(resolve)),changed_(std::move(changed)),browser_(std::move(browser)){}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& value,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
    static TextBlock note(const wchar_t* text){TextBlock value;value.Text(ui_text(text));value.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);return value;}
    static Button action(const wchar_t* title,const wchar_t* id){Button value;value.Content(winrt::box_value(ui_text(title)));identify(value,id);return value;}
    void build(){
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace xaml=winrt::Microsoft::UI::Xaml;
        view_=Grid{};identify(view_,L"ProviderAccountsPanel");view_.Padding({12,8,12,12});ui::StackPanel stack;stack.Spacing(10);
        stack.Children().Append(note(L"Provider profiles"));stack.Children().Append(note(L"Each added profile has its own native CLI login. Coincide stores profile labels and verified account routing metadata; passwords and tokens stay with the CLI."));
        provider_=ComboBox{};provider_.Header(winrt::box_value(ui_text(L"Provider")));identify(provider_,L"AccountProvider");for(const auto* name:{L"Cursor",L"Grok",L"Antigravity"}){ui::ComboBoxItem item;item.Content(winrt::box_value(ui_text(name)));provider_.Items().Append(item);}provider_.SelectedIndex(0);stack.Children().Append(provider_);
        label_=TextBox{};label_.Header(winrt::box_value(ui_text(L"Profile label")));label_.MaxLength(80);identify(label_,L"AccountProfileLabel");stack.Children().Append(label_);
        add_=action(L"Add local profile",L"AddProviderProfile");add_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->add_profile();});stack.Children().Append(add_);
        profiles_=ComboBox{};profiles_.Header(winrt::box_value(ui_text(L"Selected profile")));identify(profiles_,L"AccountProfiles");profiles_.SelectionChanged([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->update_buttons();});stack.Children().Append(profiles_);
        detail_=note(L"");identify(detail_,L"AccountProfileDetails");stack.Children().Append(detail_);
        ui::StackPanel actions;actions.Orientation(ui::Orientation::Horizontal);actions.Spacing(8);
        check_=action(L"Check status",L"CheckProviderAccount");check_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->check_status();});actions.Children().Append(check_);
        sign_in_=action(L"Sign in",L"SignInProviderAccount");sign_in_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->sign_in();});actions.Children().Append(sign_in_);
        use_button_=action(L"Use profile",L"UseProviderProfile");use_button_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->use_profile();});actions.Children().Append(use_button_);
        cancel_button_=action(L"Cancel",L"CancelProviderAccount");cancel_button_.Click([weak=weak_from_this()](const auto&,const auto&){if(const auto self=weak.lock())self->cancel();});actions.Children().Append(cancel_button_);stack.Children().Append(actions);
        stack.Children().Append(note(L"Sign in opens only the provider's verification page when requested. Finish using an existing account; this panel never creates an external account or changes a global CLI login."));
        status_=note(L"");status_.IsTextSelectionEnabled(true);identify(status_,L"ProviderAccountStatus");stack.Children().Append(status_);view_.Children().Append(stack);
    }
    void populate(){profiles_.Items().Clear();for(const auto& record:records_){winrt::Microsoft::UI::Xaml::Controls::ComboBoxItem item;item.Content(winrt::box_value(winrt::to_hstring(record.label+" · "+record.provider)));profiles_.Items().Append(item);}if(!records_.empty())profiles_.SelectedIndex(0);update_buttons();}
    void update_buttons(){
        add_.IsEnabled(!busy_);provider_.IsEnabled(!busy_);label_.IsEnabled(!busy_);profiles_.IsEnabled(!busy_);cancel_button_.IsEnabled(busy_);
        const auto index=profiles_.SelectedIndex();const bool selected=index>=0&&static_cast<std::size_t>(index)<records_.size();ProviderAccountCapabilities caps;bool installed{};
        if(selected){caps=ProviderAccounts::capabilities(records_[index].provider);try{installed=resolve_&&resolve_(records_[index].provider).has_value();}catch(...){installed=false;}detail_.Text(winrt::to_hstring(caps.explanation+(installed?"":" Select a native provider executable in Preferences first.")));}else detail_.Text(ui_text(L"Add or select a local provider profile."));
        check_.IsEnabled(!busy_&&selected&&installed&&caps.metadata);sign_in_.IsEnabled(!busy_&&selected&&installed&&caps.sign_in&&static_cast<bool>(browser_));
        bool usable{};if(!busy_&&!closed_&&selected&&installed&&use_profile_){const auto found=verified_.find(records_[index].id);usable=found!=verified_.end()&&can_use(records_[index],found->second);}use_button_.IsEnabled(usable);
    }
    bool can_use(const ProviderAccountRecord& record,const ProviderAccountMetadata& metadata)const {
        try{
            if(record.provider!="cursor"||!ProviderAccounts::current(metadata,record,store_.profile(record)))return false;
            const auto before=verified_programs_.find(record.id);const auto current=resolve_?resolve_(record.provider):std::nullopt;if(before==verified_programs_.end()||!current||current->provider!=before->second.provider||current->command_prefix!=before->second.command_prefix)return false;
            std::error_code error;if(!std::filesystem::equivalent(current->executable,before->second.executable,error)||error)return false;
            return !compatible_||compatible_(record,metadata);
        }catch(...){return false;}
    }
    winrt::Windows::Foundation::IAsyncAction operate(bool sign_in){
        const auto lifetime=shared_from_this();if(busy_||closed_)co_return;
        const auto index=profiles_.SelectedIndex();if(index<0||static_cast<std::size_t>(index)>=records_.size())co_return;
        const auto record=records_[index];std::optional<ProviderAccountProgram> program;std::filesystem::path profile;
        try{program=resolve_?resolve_(record.provider):std::nullopt;if(!program)throw std::runtime_error("Select a native provider executable in Preferences first");if(sign_in&&!browser_)throw std::runtime_error("The provider browser handoff is unavailable");profile=store_.profile(record);if(operation_guard_)operation_guard_(record,sign_in);}
        catch(const winrt::hresult_error& error){status_.Text(error.message());co_return;}
        catch(const std::exception& error){status_.Text(winrt::to_hstring(error.what()));co_return;}
        verified_.erase(record.id);verified_programs_.erase(record.id);
        busy_=true;const auto generation=++generation_;cancel_=std::make_shared<std::atomic_bool>(false);const auto cancellation=cancel_;update_buttons();status_.Text(ui_text(sign_in?L"Waiting for provider sign-in…":L"Checking provider account…"));
        const auto dispatcher=view_.DispatcherQueue();const auto weak=weak_from_this();const winrt::apartment_context ui;ProviderAccountMetadata metadata;std::string error;
        co_await winrt::resume_background();
        try{
            const auto browser=[weak,dispatcher,generation](const std::string& url){dispatcher.TryEnqueue([weak,generation,url]{if(const auto self=weak.lock();self&&!self->closed_&&self->generation_==generation&&self->cancel_&&!self->cancel_->load()&&self->browser_)self->browser_(url);});};
            metadata=sign_in?ProviderAccounts::sign_in(*program,record,profile,cancellation,browser):ProviderAccounts::check(*program,record,profile,cancellation);
        }catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}catch(const std::exception& failure){error=failure.what();}catch(...){error="The provider account operation failed";}
        try{co_await ui;}catch(...){co_return;}if(closed_||generation!=generation_)co_return;busy_=false;cancel_.reset();update_buttons();
        if(!error.empty()){status_.Text(winrt::to_hstring(error));update_buttons();if(changed_){metadata.profile_id=record.id;metadata.provider=record.provider;try{changed_(record,metadata);}catch(...){}}co_return;}
        try{
            auto next=records_;auto& saved=next[static_cast<std::size_t>(index)];
            // Last verification is historical metadata, never automatically trusted on reopening.
            if(metadata.state==ProviderAccountState::verified){saved.last_scope=metadata.scope;saved.identity_source=metadata.identity_source;saved.verified_at=metadata.verified_at;}
            store_.save(next);records_=std::move(next);status_.Text(winrt::to_hstring(metadata.status+(metadata.version.empty()?"":"\n"+metadata.version)));
            if(metadata.state==ProviderAccountState::verified){verified_[record.id]=metadata;verified_programs_[record.id]=*program;}update_buttons();
            if(changed_)changed_(records_[static_cast<std::size_t>(index)],metadata);
            update_buttons();
        }catch(const winrt::hresult_error& failure){status_.Text(failure.message());}catch(const std::exception& failure){status_.Text(winrt::to_hstring(failure.what()));}
    }
};
} // namespace coincide
