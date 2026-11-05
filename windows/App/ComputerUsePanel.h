#pragma once
#include "NativeStrings.h"
#include "../Runtime/ComputerUseSettings.h"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <functional>

namespace coincide {
// Native settings only. The shared controller outlives this panel; opening/closing it cannot
// grant access, launch a helper or inspect a window. The host owns its private agent bridge.
class ComputerUsePanel:public std::enable_shared_from_this<ComputerUsePanel> {
public:
    enum class Change{master,granted,revoked,released};
    using Changed=std::function<void(Change,const std::string&)>;
    static std::shared_ptr<ComputerUsePanel> create(std::filesystem::path directory,std::shared_ptr<computer_use::Controller> controller,Changed changed={}){
        auto result=std::shared_ptr<ComputerUsePanel>(new ComputerUsePanel(std::move(directory),std::move(controller),std::move(changed)));
        try{result->settings_=result->store_.open();result->loaded_=true;result->controller_->set_enabled(result->settings_.enabled);}
        catch(const winrt::hresult_error& error){result->load_error_=winrt::to_string(error.message());result->controller_->set_enabled(false);}
        catch(const std::exception& error){result->load_error_=error.what();result->controller_->set_enabled(false);}
        result->build();result->refresh();return result;
    }
    winrt::Microsoft::UI::Xaml::Controls::Grid view()const{return root_;}
    std::string selected_thread()const{return thread_;}
    void select_thread(std::string id,std::string title={}){
        if(closed_)return;if(!id.empty())id=computer_use::identifier(id);if(title.size()>1024||title.find('\0')!=std::string::npos||!local_file::utf8(title))throw std::invalid_argument("Invalid Computer Use conversation title");
        if(id!=thread_)choices_dirty_=false;thread_=std::move(id);title_=std::move(title);error_.Text(L"");refresh();
    }
    void refresh(){
        if(closed_)return;const auto state=controller_->snapshot(thread_);loading_=true;master_.IsOn(state.enabled);if(!choices_dirty_||!state.enabled||thread_.empty()){read_.IsChecked(state.granted&&state.permission.read_windows);capture_.IsChecked(state.granted&&state.permission.capture_windows);input_.IsChecked(state.granted&&state.permission.input);choices_dirty_=false;}loading_=false;
        thread_label_.Text(thread_.empty()?ui_text(L"Select a conversation to grant access."):winrt::hstring(title_.empty()?ui_text(L"Selected conversation"):winrt::to_hstring(title_)));
        status_.Text(!state.enabled?ui_text(L"Computer Use is off."):thread_.empty()?ui_text(L"Computer Use is on. No conversation is selected."):!state.granted?ui_text(L"This conversation has no Computer Use access."):state.permission.input?ui_text(L"This conversation can inspect native windows and send input."):state.permission.capture_windows?ui_text(L"This conversation can inspect and capture native windows."):ui_text(L"This conversation can inspect native windows."));
        desktop_.Text(state.desktop=="this thread"?ui_text(L"This conversation currently controls the desktop."):state.desktop=="another thread"?ui_text(L"Another conversation currently controls the desktop."):ui_text(L"The desktop is available."));
        if(!load_error_.empty())error_.Text(winrt::to_hstring(load_error_));update();
    }
    // Dismissing Settings preserves explicit access until revoke, master-off or app shutdown.
    void close(){closed_=true;changed_={};update();}
private:
    using Grid=winrt::Microsoft::UI::Xaml::Controls::Grid;using TextBlock=winrt::Microsoft::UI::Xaml::Controls::TextBlock;using CheckBox=winrt::Microsoft::UI::Xaml::Controls::CheckBox;using Button=winrt::Microsoft::UI::Xaml::Controls::Button;using Toggle=winrt::Microsoft::UI::Xaml::Controls::ToggleSwitch;
    computer_use::SettingsStore store_;computer_use::Settings settings_;std::shared_ptr<computer_use::Controller> controller_;Changed changed_;std::string thread_,title_,load_error_;bool loaded_{},closed_{},loading_{},pending_disable_{},choices_dirty_{};
    Grid root_{nullptr};Toggle master_{nullptr};CheckBox read_{nullptr},capture_{nullptr},input_{nullptr};Button grant_{nullptr},revoke_{nullptr},release_{nullptr},retry_{nullptr};TextBlock thread_label_{nullptr},status_{nullptr},desktop_{nullptr},error_{nullptr};
    ComputerUsePanel(std::filesystem::path directory,std::shared_ptr<computer_use::Controller> controller,Changed changed):store_(std::move(directory)),controller_(std::move(controller)),changed_(std::move(changed)){if(!controller_)throw std::invalid_argument("Computer Use Settings require the shared controller");}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& value,const wchar_t* id){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
    static TextBlock note(const wchar_t* text,const wchar_t* id=nullptr){TextBlock value;value.Text(ui_text(text));value.TextWrapping(winrt::Microsoft::UI::Xaml::TextWrapping::Wrap);if(id)identify(value,id);return value;}
    static CheckBox option(const wchar_t* text,const wchar_t* id){CheckBox value;value.Content(winrt::box_value(ui_text(text)));value.IsChecked(false);identify(value,id);return value;}
    static Button button(const wchar_t* text,const wchar_t* id){Button value;value.Content(winrt::box_value(ui_text(text)));identify(value,id);return value;}
    static bool checked(const CheckBox& value){const auto selected=value.IsChecked();return selected&&selected.Value();}
    void update(){
        const auto state=controller_->snapshot(thread_);const bool available=!closed_&&loaded_&&state.enabled&&!thread_.empty();master_.IsEnabled(!closed_&&loaded_);read_.IsEnabled(available);capture_.IsEnabled(available&&checked(read_));input_.IsEnabled(available&&checked(read_));grant_.IsEnabled(available&&checked(read_));revoke_.IsEnabled(!closed_&&!thread_.empty()&&state.granted);release_.IsEnabled(!closed_&&!thread_.empty()&&state.granted);retry_.IsEnabled(!closed_&&loaded_&&pending_disable_);retry_.Visibility(pending_disable_?winrt::Microsoft::UI::Xaml::Visibility::Visible:winrt::Microsoft::UI::Xaml::Visibility::Collapsed);
    }
    void notify(Change change,const std::string& id){if(changed_)changed_(change,id);}
    void show_exception(){try{throw;}catch(const winrt::hresult_error& error){error_.Text(error.message());}catch(const std::exception& error){error_.Text(winrt::to_hstring(error.what()));}}
    void master_changed(){
        if(loading_||closed_||!loaded_)return;const bool enable=master_.IsOn();error_.Text(L"");
        if(!enable){controller_->set_enabled(false);settings_.enabled=false;pending_disable_=true;try{notify(Change::master,{});store_.save(settings_);pending_disable_=false;}catch(...){show_exception();}refresh();return;}
        try{store_.save({true});settings_.enabled=true;controller_->set_enabled(true);pending_disable_=false;notify(Change::master,{});}catch(...){show_exception();}refresh();
    }
    void retry_save(){if(closed_||!loaded_||!pending_disable_)return;try{controller_->set_enabled(false);store_.save({false});settings_.enabled=false;pending_disable_=false;error_.Text(L"");notify(Change::master,{});}catch(...){show_exception();}refresh();}
    void grant_access(){
        if(closed_||!loaded_||thread_.empty())return;const auto id=thread_;const computer_use::Permission requested{checked(read_),checked(capture_),checked(input_)};
        try{controller_->grant(id,requested);choices_dirty_=false;error_.Text(L"");notify(Change::granted,id);}catch(...){show_exception();}refresh();
    }
    void revoke_access(){if(closed_||thread_.empty())return;const auto id=thread_;try{controller_->revoke(id);choices_dirty_=false;error_.Text(L"");notify(Change::revoked,id);}catch(...){show_exception();}refresh();}
    void release_access(){if(closed_||thread_.empty())return;const auto id=thread_;try{controller_->release(id);error_.Text(L"");notify(Change::released,id);}catch(...){show_exception();}refresh();}
    void choice_changed(){if(loading_||closed_)return;choices_dirty_=true;if(!checked(read_)){loading_=true;capture_.IsChecked(false);input_.IsChecked(false);loading_=false;}update();}
    void build(){
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;root_=Grid{};identify(root_,L"ComputerUsePanel");ui::ScrollViewer scroll;ui::StackPanel body;body.Spacing(10);body.Padding({12,8,12,12});scroll.Content(body);root_.Children().Append(scroll);const auto weak=weak_from_this();
        body.Children().Append(note(L"Computer Use works with native Windows apps for any provider. Websites use Coincide Browser. Password, script, shell and elevated-app access are unavailable.",L"ComputerUseHelp"));
        master_=Toggle{};master_.Header(winrt::box_value(ui_text(L"Enable Computer Use")));identify(master_,L"ComputerUseEnabled");master_.Toggled([weak](const auto&,const auto&){if(const auto self=weak.lock())self->master_changed();});body.Children().Append(master_);
        body.Children().Append(note(L"The master switch is saved. Conversation permissions last only in this app session and must be granted again after disabling Computer Use or restarting Coincide. Opening these settings never inspects a window or starts the helper."));
        thread_label_=note(L"",L"ComputerUseThread");body.Children().Append(thread_label_);
        read_=option(L"Inspect native windows",L"ComputerUseReadWindows");capture_=option(L"Capture native window images",L"ComputerUseCaptureWindows");input_=option(L"Send clicks, text and scrolling to native apps",L"ComputerUseInput");for(const auto& choice:{read_,capture_,input_}){choice.Checked([weak](const auto&,const auto&){if(const auto self=weak.lock())self->choice_changed();});choice.Unchecked([weak](const auto&,const auto&){if(const auto self=weak.lock())self->choice_changed();});body.Children().Append(choice);}
        body.Children().Append(note(L"Choose permissions, then grant access to the selected conversation. Checkbox changes alone do not grant access. Capture may expose private information, and input can change apps and files."));
        ui::StackPanel actions;actions.Orientation(ui::Orientation::Horizontal);actions.Spacing(8);grant_=button(L"Grant access",L"ComputerUseGrant");revoke_=button(L"Revoke access",L"ComputerUseRevoke");release_=button(L"Release desktop",L"ComputerUseRelease");
        grant_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->grant_access();});revoke_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->revoke_access();});release_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->release_access();});for(const auto& action:{grant_,revoke_,release_})actions.Children().Append(action);body.Children().Append(actions);
        status_=note(L"",L"ComputerUseStatus");desktop_=note(L"",L"ComputerUseDesktop");error_=note(L"",L"ComputerUseError");body.Children().Append(status_);body.Children().Append(desktop_);body.Children().Append(error_);retry_=button(L"Retry saving disabled setting",L"ComputerUseRetrySave");retry_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->retry_save();});body.Children().Append(retry_);
    }
};
} // namespace coincide
