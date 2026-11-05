#pragma once
#include "../Runtime/Preferences.h"
#include "NativeStrings.h"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Windows.System.h>
#include <sstream>
#include <memory>
namespace coincide {
namespace preferences_ui {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline void identify(const xaml::DependencyObject& object,const wchar_t* id){xaml::Automation::AutomationProperties::SetAutomationId(object,id);}
inline ui::TextBlock note(const winrt::hstring& value){ui::TextBlock text;text.Text(value);text.TextWrapping(xaml::TextWrapping::Wrap);text.IsTextSelectionEnabled(true);return text;}
inline void choice(const ui::ComboBox& box,const winrt::hstring& name){ui::ComboBoxItem item;item.Content(winrt::box_value(name));box.Items().Append(item);}
inline ui::TextBox edit(const wchar_t* header,const wchar_t* id){ui::TextBox value;value.Header(winrt::box_value(ui_text(header)));identify(value,id);return value;}
inline ui::CheckBox toggle(const wchar_t* title,bool checked,const wchar_t* id){ui::CheckBox value;value.Content(winrt::box_value(ui_text(title)));value.IsChecked(checked);identify(value,id);return value;}
inline bool checked(const ui::CheckBox& box){const auto value=box.IsChecked();return value&&value.Value();}
inline ui::StackPanel page(){ui::StackPanel value;value.Spacing(10);value.Padding({12,12,12,12});return value;}
inline void link(const ui::StackPanel& parent,const wchar_t* title,const wchar_t* url){ui::HyperlinkButton value;value.Content(winrt::box_value(ui_text(title)));value.NavigateUri(winrt::Windows::Foundation::Uri(url));parent.Children().Append(value);}
inline std::string lines(const std::vector<std::string>& values){std::string result;for(const auto& value:values){if(!result.empty())result+='\n';result+=value;}return result;}
inline std::vector<std::string> lines(const winrt::hstring& text){
    // WinUI's multiline TextBox may expose CR separators even when input used LF.
    // Normalize all three newline spellings before trimming individual model IDs.
    const auto bytes=winrt::to_string(text);std::string normalized;normalized.reserve(bytes.size());
    for(std::size_t index=0;index<bytes.size();++index){if(bytes[index]=='\r'){normalized+='\n';if(index+1<bytes.size()&&bytes[index+1]=='\n')++index;}else normalized+=bytes[index];}
    std::vector<std::string> result;std::istringstream input(normalized);std::string value;
    while(std::getline(input,value)){while(!value.empty()&&std::isspace(static_cast<unsigned char>(value.back())))value.pop_back();const auto begin=value.find_first_not_of(" \t");if(begin!=std::string::npos)result.push_back(value.substr(begin));}return result;
}
}
class PreferencesPanel:public std::enable_shared_from_this<PreferencesPanel>{
public:
    static std::shared_ptr<PreferencesPanel> create(Preferences value,std::vector<Project> projects={}){auto self=std::shared_ptr<PreferencesPanel>(new PreferencesPanel(std::move(value),std::move(projects)));self->build();return self;}
    preferences_ui::ui::TabView view()const{return root_;}
    Preferences values(){
        using namespace preferences_ui;save_model();auto value=draft_;value.appearance=std::vector<std::string>{"system","light","dark"}.at(static_cast<std::size_t>(appearance_.SelectedIndex()));
        value.language=languages_.at(static_cast<std::size_t>(language_.SelectedIndex()));value.reply_font=std::vector<std::string>{"system","serif","mono"}.at(static_cast<std::size_t>(font_.SelectedIndex()));
        const auto size=font_size_.Value();if(!std::isfinite(size)||size!=std::floor(size))throw std::invalid_argument("Enter a whole reply font size");value.font_size=static_cast<int>(size);
        value.default_provider=provider_ids.at(static_cast<std::size_t>(default_provider_.SelectedIndex()));value.send_on_return=checked(send_);value.background=checked(background_);value.notifications=checked(notifications_);value.keep_awake=checked(awake_);value.awake_on_battery=checked(battery_);value.keep_display=checked(display_);value.antigravity_ack=checked(risk_);
        for(std::size_t i=0;i<provider_ids.size();++i){auto& provider=value.providers.at(std::string(provider_ids[i]));provider.enabled=checked(enabled_[i]);provider.executable=winrt::to_string(executables_[i].Text());}
        for(const auto& [id,box]:shortcuts_)value.shortcuts[id]=winrt::to_string(box.Text());validate_preferences(value);return value;
    }
private:
    Preferences draft_;std::vector<Project> projects_;preferences_ui::ui::TabView root_{nullptr};
    preferences_ui::ui::ComboBox appearance_{nullptr},language_{nullptr},font_{nullptr},default_provider_{nullptr},model_provider_{nullptr},model_scope_{nullptr};
    preferences_ui::ui::NumberBox font_size_{nullptr};
    preferences_ui::ui::CheckBox send_{nullptr},background_{nullptr},notifications_{nullptr},awake_{nullptr},battery_{nullptr},display_{nullptr},risk_{nullptr},plan_{nullptr},access_{nullptr},project_default_{nullptr},project_models_{nullptr};
    std::vector<preferences_ui::ui::CheckBox> enabled_;std::vector<preferences_ui::ui::TextBox> executables_;
    std::map<std::string,preferences_ui::ui::TextBox> shortcuts_;
    preferences_ui::ui::TextBox model_{nullptr},effort_{nullptr},tier_{nullptr},favorites_{nullptr},hidden_{nullptr},custom_{nullptr};
    std::vector<std::string> languages_{"","en-US","de","es","es-419","fr","hi","id","it","ja","ko","nl","pl","pt-BR","ru","tr","uk","vi","zh-Hans","zh-Hant"};
    std::size_t edited_provider_{},edited_scope_{};bool selecting_{};
    PreferencesPanel(Preferences value,std::vector<Project> projects):draft_(std::move(value)),projects_(std::move(projects)){}
    void add_page(const wchar_t* title,const preferences_ui::ui::StackPanel& content){using namespace preferences_ui;ui::TabViewItem tab;tab.Header(winrt::box_value(ui_text(title)));tab.IsClosable(false);ui::ScrollViewer scroll;scroll.Content(content);scroll.MaxHeight(470);scroll.VerticalScrollBarVisibility(ui::ScrollBarVisibility::Auto);tab.Content(scroll);root_.TabItems().Append(tab);}
    void save_model(){
        if(selecting_||!model_)return;using namespace preferences_ui;const auto provider=std::string(provider_ids.at(edited_provider_));auto& value=draft_.providers.at(provider);value.favorites=lines(favorites_.Text());value.hidden=lines(hidden_.Text());value.custom_models=lines(custom_.Text());
        ProviderModelPreference selection{provider,winrt::to_string(model_.Text()),winrt::to_string(effort_.Text()),winrt::to_string(tier_.Text()),checked(plan_),checked(access_)};
        if(!edited_scope_)value.defaults=selection;else{
            const auto id=projects_.at(edited_scope_-1).id;auto found=draft_.projects.find(id);
            if(found==draft_.projects.end()&&!checked(project_models_)&&!checked(project_default_))return;
            auto& project=draft_.projects[id];if(checked(project_models_))project.models[provider]=selection;else project.models.erase(provider);
            if(checked(project_default_))project.provider=provider;else if(project.provider==provider)project.provider.clear();
        }
    }
    void load_model(){
        using namespace preferences_ui;selecting_=true;edited_provider_=static_cast<std::size_t>(std::max(0,model_provider_.SelectedIndex()));edited_scope_=static_cast<std::size_t>(std::max(0,model_scope_.SelectedIndex()));
        const auto provider=std::string(provider_ids.at(edited_provider_));const auto& value=draft_.providers.at(provider);const auto selection=draft_.model_defaults(edited_scope_?std::optional<std::string>(projects_.at(edited_scope_-1).id):std::nullopt,provider);
        model_.Text(winrt::to_hstring(selection.model));effort_.Text(winrt::to_hstring(selection.effort));tier_.Text(winrt::to_hstring(selection.service_tier));plan_.IsChecked(selection.plan);access_.IsChecked(selection.full_access);
        favorites_.Text(winrt::to_hstring(lines(value.favorites)));hidden_.Text(winrt::to_hstring(lines(value.hidden)));custom_.Text(winrt::to_hstring(lines(value.custom_models)));
        project_default_.Visibility(edited_scope_?xaml::Visibility::Visible:xaml::Visibility::Collapsed);project_models_.Visibility(edited_scope_?xaml::Visibility::Visible:xaml::Visibility::Collapsed);
        bool overrides{},preferred{};if(edited_scope_)if(const auto found=draft_.projects.find(projects_.at(edited_scope_-1).id);found!=draft_.projects.end()){overrides=found->second.models.contains(provider);preferred=found->second.provider==provider;}
        project_default_.IsChecked(preferred);project_models_.IsChecked(overrides);for(const auto& box:{model_,effort_,tier_})box.IsEnabled(!edited_scope_||overrides);plan_.IsEnabled(!edited_scope_||overrides);access_.IsEnabled(!edited_scope_||overrides);selecting_=false;
    }
    void build(){
        using namespace preferences_ui;root_=ui::TabView{};root_.IsAddTabButtonVisible(false);identify(root_,L"PreferencesTabs");const auto weak=weak_from_this();
        auto general=page();appearance_=ui::ComboBox{};appearance_.Header(winrt::box_value(ui_text(L"Appearance")));identify(appearance_,L"PreferenceAppearance");for(const auto title:{L"System",L"Light",L"Dark"})choice(appearance_,ui_text(title));appearance_.SelectedIndex(draft_.appearance=="light"?1:draft_.appearance=="dark"?2:0);general.Children().Append(appearance_);
        language_=ui::ComboBox{};language_.Header(winrt::box_value(ui_text(L"Language")));identify(language_,L"PreferenceLanguage");for(const auto& language:languages_)choice(language_,language.empty()?ui_text(L"System language"):winrt::to_hstring(language));const auto found=std::find(languages_.begin(),languages_.end(),draft_.language);language_.SelectedIndex(found==languages_.end()?0:static_cast<int>(found-languages_.begin()));general.Children().Append(language_);general.Children().Append(note(ui_text(L"Language changes apply when you reopen Coincide.")));
        font_=ui::ComboBox{};font_.Header(winrt::box_value(ui_text(L"Reply font")));identify(font_,L"PreferenceReplyFont");for(const auto title:{L"System",L"Serif",L"Monospace"})choice(font_,ui_text(title));font_.SelectedIndex(draft_.reply_font=="serif"?1:draft_.reply_font=="mono"?2:0);general.Children().Append(font_);
        font_size_=ui::NumberBox{};font_size_.Header(winrt::box_value(ui_text(L"Reply font size")));font_size_.Minimum(11);font_size_.Maximum(28);font_size_.Value(draft_.font_size);font_size_.SmallChange(1);identify(font_size_,L"PreferenceFontSize");general.Children().Append(font_size_);
        default_provider_=ui::ComboBox{};default_provider_.Header(winrt::box_value(ui_text(L"Default provider for new chats")));identify(default_provider_,L"PreferenceDefaultProvider");for(const auto id:provider_ids)choice(default_provider_,winrt::to_hstring(id));default_provider_.SelectedIndex(static_cast<int>(std::find(provider_ids.begin(),provider_ids.end(),draft_.default_provider)-provider_ids.begin()));general.Children().Append(default_provider_);
        send_=toggle(L"Enter sends; Shift+Enter inserts a line break",draft_.send_on_return,L"PreferenceSendOnReturn");general.Children().Append(send_);general.Children().Append(note(ui_text(L"Ctrl+Enter always sends. During an active turn it queues your message.")));
        background_=toggle(L"Keep active work running when the window closes",draft_.background,L"PreferenceBackground");general.Children().Append(background_);general.Children().Append(note(ui_text(L"Open Coincide from its tray icon. Quit stops its agents and terminals; interrupted schedules require review after relaunch.")));
        notifications_=toggle(L"Notify when work finishes or needs a response",draft_.notifications,L"PreferenceNotifications");general.Children().Append(notifications_);
        awake_=toggle(L"Keep Awake while Coincide is running",draft_.keep_awake,L"PreferenceKeepAwake");battery_=toggle(L"Keep Awake on battery too",draft_.awake_on_battery,L"PreferenceAwakeBattery");display_=toggle(L"Keep the display on too",draft_.keep_display,L"PreferenceKeepDisplay");general.Children().Append(awake_);general.Children().Append(battery_);general.Children().Append(display_);general.Children().Append(note(ui_text(L"Keep Awake uses an app-owned sleep request. Windows, the lid policy or ASUS software can still request hibernation. Quit releases the request.")));add_page(L"General",general);
        auto providers=page();providers.Children().Append(note(ui_text(L"Native executable overrides apply to this Windows app. Leave a path empty for discovery. Enabling a provider does not sign you in.")));
        for(const auto id:provider_ids){const auto& value=draft_.providers.at(std::string(id));auto enabled=toggle(L"Enabled",value.enabled,L"ProviderEnabled");enabled.Content(winrt::box_value(winrt::to_hstring(id)));enabled_.push_back(enabled);providers.Children().Append(enabled);auto path=edit(L"Native executable path",L"ProviderExecutable");path.Text(winrt::to_hstring(value.executable));path.MaxLength(32760);executables_.push_back(path);providers.Children().Append(path);}
        risk_=toggle(L"I understand the documented Antigravity account risk",draft_.antigravity_ack,L"AntigravityAcknowledgment");providers.Children().Append(risk_);link(providers,L"Antigravity account-risk notice",L"https://github.com/apoorvdarshan/coincide#agents");add_page(L"Providers",providers);
        auto models=page();model_scope_=ui::ComboBox{};model_scope_.Header(winrt::box_value(ui_text(L"Defaults apply to")));identify(model_scope_,L"ModelDefaultScope");choice(model_scope_,ui_text(L"All projects"));for(const auto& project:projects_)choice(model_scope_,winrt::to_hstring(project.name));model_scope_.SelectedIndex(0);models.Children().Append(model_scope_);
        model_provider_=ui::ComboBox{};model_provider_.Header(winrt::box_value(ui_text(L"Provider")));identify(model_provider_,L"ModelDefaultProvider");for(const auto id:provider_ids)choice(model_provider_,winrt::to_hstring(id));model_provider_.SelectedIndex(1);models.Children().Append(model_provider_);
        model_=edit(L"Default model ID",L"DefaultModel");effort_=edit(L"Default reasoning effort",L"DefaultEffort");tier_=edit(L"Default speed tier",L"DefaultTier");for(const auto& box:{model_,effort_,tier_}){box.MaxLength(256);models.Children().Append(box);}
        plan_=toggle(L"Plan by default in new chats",false,L"DefaultPlan");access_=toggle(L"Allow full access by default in new chats",false,L"DefaultFullAccess");models.Children().Append(plan_);models.Children().Append(access_);models.Children().Append(note(ui_text(L"Full access allows commands and file changes without asking. Defaults never change an existing conversation.")));
        project_models_=toggle(L"Override model defaults in this project",false,L"ProjectModelOverrides");models.Children().Append(project_models_);project_models_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())if(!self->selecting_){self->save_model();self->load_model();}});
        project_default_=toggle(L"Use this provider by default in this project",false,L"ProjectDefaultProvider");models.Children().Append(project_default_);
        favorites_=edit(L"Favorite model IDs, one per line",L"FavoriteModels");hidden_=edit(L"Hidden model IDs, one per line",L"HiddenModels");custom_=edit(L"Custom model IDs, one per line",L"CustomModels");for(const auto& box:{favorites_,hidden_,custom_}){box.AcceptsReturn(true);box.MinHeight(70);box.MaxHeight(140);models.Children().Append(box);}
        model_provider_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())if(!self->selecting_){self->save_model();self->load_model();}});model_scope_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())if(!self->selecting_){self->save_model();self->load_model();}});load_model();add_page(L"Models",models);
        auto keyboard=page();keyboard.Children().Append(note(ui_text(L"Use Ctrl, Shift or Alt with a letter, number or F1–F12. Clear a field to disable it. Editor shortcuts retain their text-editing behavior.")));for(const auto& [id,value]:draft_.shortcuts){auto box=edit(L"Shortcut",L"KeyboardShortcut");box.Header(winrt::box_value(winrt::to_hstring(id)));box.Text(winrt::to_hstring(value));box.MaxLength(64);keyboard.Children().Append(box);shortcuts_.emplace(id,box);}ui::Button reset;reset.Content(winrt::box_value(ui_text(L"Reset keyboard shortcuts")));identify(reset,L"ResetKeyboardShortcuts");reset.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())for(const auto& [id,value]:Preferences{}.shortcuts)self->shortcuts_.at(id).Text(winrt::to_hstring(value));});keyboard.Children().Append(reset);add_page(L"Keyboard",keyboard);
        auto about=page();about.Children().Append(note(L"Coincide for Windows · Development preview\nC++/WinRT + WinUI 3"));about.Children().Append(note(ui_text(L"One window for the coding agents you already use.")));link(about,L"Website and documentation",L"https://coincide.dev");link(about,L"Source code and issue tracker",L"https://github.com/apoorvdarshan/coincide");link(about,L"Releases and updates",L"https://github.com/apoorvdarshan/coincide/releases");link(about,L"OpenSSF assessment",L"https://www.bestpractices.dev/projects/15854");about.Children().Append(note(ui_text(L"MIT License · Copyright 2026 Apoorv Darshan. Native Windows development builds are not signed public releases.")));add_page(L"About",about);
    }
};
}
