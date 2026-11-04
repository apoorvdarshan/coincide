#pragma once
#include "../Runtime/Preferences.h"
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif
#include <winrt/Windows.Foundation.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include "../App/PreferencesPanel.h"
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#include <chrono>
#include <limits>
#include <thread>

namespace coincide {
namespace preferences_fixture {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline void pump(){MSG message{};for(unsigned count=0;count<512&&PeekMessageW(&message,nullptr,0,0,PM_REMOVE);++count){if(message.message==WM_QUIT){PostQuitMessage(static_cast<int>(message.wParam));break;}TranslateMessage(&message);DispatchMessageW(&message);}}
template<class Predicate>bool until(Predicate predicate){const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(3);while(!predicate()&&std::chrono::steady_clock::now()<end){pump();std::this_thread::sleep_for(std::chrono::milliseconds(1));}pump();return predicate();}
inline void collect(const xaml::DependencyObject& root,const wchar_t* id,std::vector<xaml::DependencyObject>& result){
    if(!root)return;if(xaml::Automation::AutomationProperties::GetAutomationId(root)==id)result.push_back(root);
    if(const auto tabs=root.try_as<ui::TabView>()){for(const auto& tab:tabs.TabItems())collect(tab.as<xaml::DependencyObject>(),id,result);return;}
    if(const auto panel=root.try_as<ui::Panel>())for(const auto& child:panel.Children())collect(child,id,result);
    if(const auto border=root.try_as<ui::Border>())collect(border.Child(),id,result);
    if(const auto content=root.try_as<ui::ContentControl>())if(const auto child=content.Content().try_as<xaml::DependencyObject>())collect(child,id,result);
}
inline std::vector<xaml::DependencyObject> find_all(const xaml::DependencyObject& root,const wchar_t* id){std::vector<xaml::DependencyObject> result;collect(root,id,result);return result;}
template<class T>T control(const xaml::DependencyObject& root,const wchar_t* id){const auto values=find_all(root,id);if(values.size()!=1)throw std::runtime_error("A native preferences fixture control is missing or ambiguous");return values.front().as<T>();}
inline bool visible_descendant(const xaml::DependencyObject& root,const xaml::DependencyObject& target){
    if(!root)return false;if(const auto element=root.try_as<xaml::UIElement>();element&&element.Visibility()==xaml::Visibility::Collapsed)return false;
    if(root==target)return true;for(int index=0;index<xaml::Media::VisualTreeHelper::GetChildrenCount(root);++index)if(visible_descendant(xaml::Media::VisualTreeHelper::GetChild(root,index),target))return true;return false;
}
inline ui::StackPanel page(const std::shared_ptr<PreferencesPanel>& panel,std::uint32_t index){return panel->view().TabItems().GetAt(index).as<ui::TabViewItem>().Content().as<ui::ScrollViewer>().Content().as<ui::StackPanel>();}
inline void tab(const std::shared_ptr<PreferencesPanel>& panel,int index){panel->view().SelectedIndex(index);panel->view().UpdateLayout();pump();}
inline void invoke(const xaml::DependencyObject& root,const wchar_t* id){const xaml::Automation::Peers::ButtonAutomationPeer peer(control<ui::Button>(root,id));peer.GetPattern(xaml::Automation::Peers::PatternInterface::Invoke).as<xaml::Automation::Provider::IInvokeProvider>().Invoke();pump();}
inline void toggle(const ui::CheckBox& checkbox){const xaml::Automation::Peers::CheckBoxAutomationPeer peer(checkbox);peer.GetPattern(xaml::Automation::Peers::PatternInterface::Toggle).as<xaml::Automation::Provider::IToggleProvider>().Toggle();pump();}
inline ui::TextBox shortcut(const xaml::DependencyObject& root,std::string_view action){for(const auto& object:find_all(root,L"KeyboardShortcut")){const auto box=object.as<ui::TextBox>();if(winrt::to_string(winrt::unbox_value<winrt::hstring>(box.Header()))==action)return box;}throw std::runtime_error("A keyboard shortcut fixture field is missing");}
} // namespace preferences_fixture

// Actual initialized controls, pure copied preferences and one unique temporary settings file.
// No provider discovery, executable launch, account, power request, notification or real settings.
inline int preferences_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace fixture=preferences_fixture;namespace ui=fixture::ui;namespace xaml=fixture::xaml;
    const auto folder=std::filesystem::temp_directory_path()/(L"Coincide preferences panel fixture "+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    const std::vector<Project> projects{{"{b26adf8e-5f8f-40a8-b6bf-29b46b03c121}","Fixture A",(folder/L"project-a").string()},{"{1b70d5c7-5baf-4894-a1b4-22454f336b7b}","Fixture B",(folder/L"project-b").string()}};
    std::shared_ptr<PreferencesPanel> panel;ui::Panel host{nullptr};int checks{};std::string phase="initial controls";
    auto check=[&](bool condition,const char* failure){++checks;if(!condition)throw std::runtime_error(failure);};
    auto rejects=[&](auto operation,const char* failure){bool rejected{};try{operation();}catch(...){rejected=true;}check(rejected,failure);};
    auto detach=[&]{if(host&&panel){std::uint32_t index{};if(host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);}panel.reset();fixture::pump();};
    auto mount=[&](Preferences value){detach();panel=PreferencesPanel::create(std::move(value),projects);host.Children().Append(panel->view());panel->view().Measure({850,560});panel->view().Arrange({0,0,850,560});panel->view().UpdateLayout();fixture::pump();};
    auto control=[&]<class T>(const wchar_t* id){return fixture::control<T>(panel->view(),id);};
    auto scope=[&](int index){control.template operator()<ui::ComboBox>(L"ModelDefaultScope").SelectedIndex(index);fixture::pump();};
    auto provider=[&](int index){control.template operator()<ui::ComboBox>(L"ModelDefaultProvider").SelectedIndex(index);fixture::pump();};
    auto read=[&]{std::ifstream stream(folder/L"settings.json",std::ios::binary);return std::string((std::istreambuf_iterator<char>(stream)),std::istreambuf_iterator<char>());};
    try{
        if(!xaml_root||(host=xaml_root.Content().try_as<ui::Panel>())==nullptr)throw std::runtime_error("Preferences panel tests require an initialized hidden WinUI Panel/XamlRoot");
        if(!std::filesystem::create_directory(folder))throw std::runtime_error("The preferences panel fixture directory must be unique");
        Preferences defaults;mount(defaults);
        check(panel->view().TabItems().Size()==5&&!panel->view().IsAddTabButtonVisible(),"Native preferences must expose five fixed settings tabs");
        for(std::uint32_t index=0;index<5;++index){fixture::tab(panel,static_cast<int>(index));const auto item=panel->view().TabItems().GetAt(index).as<ui::TabViewItem>();
            check(!item.IsClosable()&&fixture::until([&]{return fixture::visible_descendant(panel->view(),item.Content().as<xaml::DependencyObject>());}),"Selecting a native settings tab must show its own content without a close action");
            for(std::uint32_t other=0;other<5;++other)if(other!=index)check(!fixture::visible_descendant(panel->view(),panel->view().TabItems().GetAt(other).as<ui::TabViewItem>().Content().as<xaml::DependencyObject>()),"An inactive settings page must not remain visible over the selected tab");}
        fixture::tab(panel,0);const auto initial=panel->values();
        check(initial.appearance=="system"&&initial.default_provider=="codex"&&initial.reply_font=="system"&&initial.font_size==14,"Native settings must retain the declared application defaults");
        check(initial.background&&!initial.notifications&&!initial.keep_awake&&!initial.awake_on_battery&&!initial.keep_display&&!initial.antigravity_ack,"Opening settings must not enable notifications, power changes or risk acknowledgment");
        check(!preferences_ui::checked(control.template operator()<ui::CheckBox>(L"DefaultFullAccess"))&&std::all_of(initial.providers.begin(),initial.providers.end(),[](const auto& entry){return !entry.second.defaults.full_access;}),"Every provider's full-access default must remain off unless explicitly changed");
        check(!preferences_ui::checked(control.template operator()<ui::CheckBox>(L"AntigravityAcknowledgment"))&&!initial.providers.at("antigravity").enabled,"The risk-sensitive provider must start disabled and unacknowledged");
        const auto enabled=fixture::find_all(panel->view(),L"ProviderEnabled"),executables=fixture::find_all(panel->view(),L"ProviderExecutable");check(enabled.size()==provider_ids.size()&&executables.size()==provider_ids.size(),"Each provider must retain its own native enable and executable controls");
        control.template operator()<ui::ComboBox>(L"PreferenceAppearance").SelectedIndex(2);control.template operator()<ui::ComboBox>(L"PreferenceLanguage").SelectedIndex(6);control.template operator()<ui::ComboBox>(L"PreferenceReplyFont").SelectedIndex(1);control.template operator()<ui::NumberBox>(L"PreferenceFontSize").Value(21);
        fixture::toggle(control.template operator()<ui::CheckBox>(L"PreferenceSendOnReturn"));fixture::toggle(control.template operator()<ui::CheckBox>(L"PreferenceNotifications"));auto changed=panel->values();
        check(changed.appearance=="dark"&&changed.language=="hi"&&changed.reply_font=="serif"&&changed.font_size==21&&changed.send_on_return&&changed.notifications,"General native controls must serialize their actual selected values");
        check(defaults.appearance=="system"&&!defaults.notifications&&!defaults.send_on_return,"Editing copied native preferences must not mutate the caller's settings");
        phase="native model-list newline normalization";fixture::tab(panel,2);
        for(const auto* newline:{L"\r",L"\n",L"\r\n"}){const std::wstring separator(newline);control.template operator()<ui::TextBox>(L"FavoriteModels").Text(L" first "+separator+separator+L"second"+separator);
            check(panel->values().providers.at("codex").favorites==std::vector<std::string>{"first","second"},"Native model-list editors must accept CR, LF and CRLF separators without weakening ID validation");}

        phase="project and provider model state";
        Preferences seed;seed.default_provider="claude";seed.providers.at("codex").defaults={"codex","codex/global","high","priority",false,false};seed.providers.at("claude").defaults={"claude","claude/global","medium","",true,false};seed.projects[projects[0].id].provider="codex";seed.projects[projects[0].id].models["codex"]={"codex","project-a/original","medium","",false,false};
        PreferencesStore store(folder);(void)store.open();store.save(seed);const auto original_bytes=read();mount(seed);fixture::tab(panel,2);
        scope(2);check(!preferences_ui::checked(control.template operator()<ui::CheckBox>(L"ProjectModelOverrides"))&&!control.template operator()<ui::TextBox>(L"DefaultModel").IsEnabled(),"A project with inherited model defaults must show disabled override editors");scope(0);auto visited=panel->values();
        check(!visited.projects.contains(projects[1].id)&&visited.provider_default(projects[1].id)=="claude","Merely visiting project model settings must not freeze inheritance or change its provider");
        provider(0);control.template operator()<ui::TextBox>(L"DefaultModel").Text(L"claude/edited");control.template operator()<ui::TextBox>(L"DefaultEffort").Text(L"high");control.template operator()<ui::TextBox>(L"DefaultTier").Text(L"standard");
        provider(1);check(control.template operator()<ui::TextBox>(L"DefaultModel").Text()==L"codex/global","Switching providers must restore that provider's model editor");control.template operator()<ui::TextBox>(L"DefaultModel").Text(L"codex/edited");control.template operator()<ui::TextBox>(L"DefaultEffort").Text(L"xhigh");control.template operator()<ui::TextBox>(L"DefaultTier").Text(L"priority");control.template operator()<ui::CheckBox>(L"DefaultPlan").IsChecked(true);
        scope(1);check(preferences_ui::checked(control.template operator()<ui::CheckBox>(L"ProjectModelOverrides"))&&control.template operator()<ui::TextBox>(L"DefaultModel").Text()==L"project-a/original","A project override must restore its own independent editor");
        control.template operator()<ui::TextBox>(L"DefaultModel").Text(L"project-a/edited");fixture::toggle(control.template operator()<ui::CheckBox>(L"DefaultFullAccess"));control.template operator()<ui::CheckBox>(L"ProjectDefaultProvider").IsChecked(false);auto project_edit=panel->values();
        check(project_edit.provider_default(projects[0].id)=="claude"&&project_edit.model_defaults(projects[0].id,"codex").model=="project-a/edited","Clearing a project provider override must restore inheritance while retaining its model override");
        check(project_edit.providers.at("codex").defaults.model=="codex/edited"&&!project_edit.providers.at("codex").defaults.full_access&&project_edit.model_defaults(projects[0].id,"codex").full_access,"Explicit project access/model changes must not leak into global provider defaults");
        check(project_edit.providers.at("claude").defaults.model=="claude/edited"&&project_edit.providers.at("claude").defaults.service_tier=="standard","Switching away must retain the other provider's unsaved edits");
        scope(2);check(control.template operator()<ui::TextBox>(L"DefaultModel").Text()==L"codex/edited"&&!preferences_ui::checked(control.template operator()<ui::CheckBox>(L"DefaultFullAccess")),"Another project must inherit the current global provider settings safely");
        fixture::toggle(control.template operator()<ui::CheckBox>(L"ProjectModelOverrides"));check(fixture::until([&]{return control.template operator()<ui::TextBox>(L"DefaultModel").IsEnabled();}),"The native override checkbox must enable the project editor through its automation toggle action");
        control.template operator()<ui::TextBox>(L"DefaultModel").Text(L"project-b/codex");control.template operator()<ui::CheckBox>(L"ProjectDefaultProvider").IsChecked(true);provider(0);fixture::toggle(control.template operator()<ui::CheckBox>(L"ProjectModelOverrides"));
        check(fixture::until([&]{return control.template operator()<ui::TextBox>(L"DefaultModel").IsEnabled();}),"Each provider's project override checkbox must operate independently");control.template operator()<ui::TextBox>(L"DefaultModel").Text(L"project-b/claude");scope(0);auto both=panel->values();
        check(both.model_defaults(projects[1].id,"codex").model=="project-b/codex"&&both.model_defaults(projects[1].id,"claude").model=="project-b/claude"&&both.provider_default(projects[1].id)=="codex","Per-project model choices must remain independent across provider switches");
        scope(2);provider(1);fixture::toggle(control.template operator()<ui::CheckBox>(L"ProjectModelOverrides"));check(fixture::until([&]{return !control.template operator()<ui::TextBox>(L"DefaultModel").IsEnabled();}),"Clearing a model override must restore the inherited readonly editor");control.template operator()<ui::CheckBox>(L"ProjectDefaultProvider").IsChecked(false);const auto candidate=panel->values();
        check(candidate.model_defaults(projects[1].id,"codex").model=="codex/edited"&&candidate.model_defaults(projects[1].id,"claude").model=="project-b/claude"&&candidate.provider_default(projects[1].id)=="claude","Clearing one override must preserve another provider and restore the global provider inheritance");
        check(read()==original_bytes&&seed.projects.size()==1&&seed.providers.at("codex").defaults.model=="codex/global","Reading draft values must not persist or mutate the caller before the root Save callback");detach();
        check(read()==original_bytes,"Discarding or cancelling the native panel must leave the settings file untouched");unsigned saves{};auto root_save=[&](const Preferences& value){++saves;store.save(value);};root_save(candidate);PreferencesStore reopened(folder);const auto saved=reopened.open();
        check(saves==1&&read()!=original_bytes&&saved.providers.at("codex").defaults.model=="codex/edited","Only the explicit root Save callback may persist the edited preferences");

        phase="provider safety and model validation";mount(Preferences{});fixture::tab(panel,1);auto providers=fixture::find_all(panel->view(),L"ProviderEnabled");fixture::toggle(providers.back().as<ui::CheckBox>());rejects([&]{panel->values();},"Enabling the risk-sensitive provider without explicit acknowledgment must fail validation");
        fixture::toggle(control.template operator()<ui::CheckBox>(L"AntigravityAcknowledgment"));auto acknowledged=panel->values();check(acknowledged.providers.at("antigravity").enabled&&acknowledged.antigravity_ack&&!acknowledged.providers.at("antigravity").defaults.full_access,"Risk acknowledgment must not silently grant full-access model defaults");fixture::toggle(providers.back().as<ui::CheckBox>());fixture::toggle(control.template operator()<ui::CheckBox>(L"AntigravityAcknowledgment"));
        fixture::toggle(providers[1].as<ui::CheckBox>());rejects([&]{panel->values();},"The current default provider cannot be disabled without choosing an enabled default");control.template operator()<ui::ComboBox>(L"PreferenceDefaultProvider").SelectedIndex(0);check(panel->values().default_provider=="claude","An explicitly selected enabled provider may replace the disabled default");fixture::toggle(providers[1].as<ui::CheckBox>());
        fixture::tab(panel,2);control.template operator()<ui::TextBox>(L"DefaultModel").Text(L"fixture/default");control.template operator()<ui::TextBox>(L"FavoriteModels").Text(L"fixture/default");control.template operator()<ui::TextBox>(L"HiddenModels").Text(L"fixture/default");rejects([&]{panel->values();},"A native model cannot be both hidden and a favorite");control.template operator()<ui::TextBox>(L"FavoriteModels").Text(L"");
        const auto hidden_default=panel->values();check(hidden_default.providers.at("codex").defaults.model=="fixture/default"&&hidden_default.providers.at("codex").hidden==std::vector<std::string>{"fixture/default"},"Hiding a default model must preserve the explicit default selection under the declared visibility policy");
        control.template operator()<ui::TextBox>(L"HiddenModels").Text(L"");control.template operator()<ui::TextBox>(L"FavoriteModels").Text(L" first \n\nfirst\n");rejects([&]{panel->values();},"Whitespace normalization must not silently accept duplicate model IDs");control.template operator()<ui::TextBox>(L"FavoriteModels").Text(L" first \n\nsecond\n");check(panel->values().providers.at("codex").favorites==std::vector<std::string>{"first","second"},"Model list editors must trim blank lines while retaining order");
        std::wstring many;for(int index=0;index<101;++index)many+=L"fixture/model-"+std::to_wstring(index)+L"\n";control.template operator()<ui::TextBox>(L"CustomModels").Text(many);rejects([&]{panel->values();},"Native model lists must reject more than one hundred IDs");control.template operator()<ui::TextBox>(L"CustomModels").Text(L"fixture/custom");
        control.template operator()<ui::TextBox>(L"DefaultModel").Text(std::wstring(100,L'你'));rejects([&]{panel->values();},"Native model ID validation must enforce byte bounds for Unicode input");control.template operator()<ui::TextBox>(L"DefaultModel").Text(L"bad model id");rejects([&]{panel->values();},"Model identifier whitespace must be rejected");control.template operator()<ui::TextBox>(L"DefaultModel").Text(L"fixture/valid");
        phase="keyboard validation";fixture::tab(panel,3);fixture::shortcut(panel->view(),"browser").Text(L"Ctrl+n");rejects([&]{panel->values();},"Shortcut conflicts must normalize case rather than silently stealing another action");fixture::invoke(panel->view(),L"ResetKeyboardShortcuts");check(panel->values().shortcuts==Preferences{}.shortcuts,"The native reset button must restore every default shortcut");
        fixture::shortcut(panel->view(),"quit").Text(L"Alt+F4");rejects([&]{panel->values();},"Windows-reserved shortcuts must be rejected");fixture::shortcut(panel->view(),"quit").Text(L"Ctrl+F9999999999999999999999999999999999999999999999");rejects([&]{panel->values();},"Long function-key values must reject without numeric overflow");fixture::invoke(panel->view(),L"ResetKeyboardShortcuts");fixture::shortcut(panel->view(),"browser").Text(L"");check(panel->values().shortcuts.at("browser").empty(),"Clearing a native shortcut must explicitly disable it");
        phase="font and executable validation";fixture::tab(panel,0);auto font=control.template operator()<ui::NumberBox>(L"PreferenceFontSize");check(font.Minimum()==11&&font.Maximum()==28,"The native font editor must expose the validated size bounds");font.Value(14.5);rejects([&]{panel->values();},"Fractional reply font sizes must be rejected");font.Value(std::numeric_limits<double>::quiet_NaN());rejects([&]{panel->values();},"An empty or nonfinite native font value must be rejected");font.Value(16);
        fixture::tab(panel,1);auto paths=fixture::find_all(panel->view(),L"ProviderExecutable");paths[1].as<ui::TextBox>().Text(L".\\fixture.exe");rejects([&]{panel->values();},"Executable overrides must not depend on the current working directory");paths[1].as<ui::TextBox>().Text(L"");check(panel->values().font_size==16,"Correcting validation errors must leave the same native panel usable");
        detach();std::filesystem::remove_all(folder);std::ofstream output(report);output<<"PASS: "<<checks<<" native preferences panel checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks in "<<phase<<": "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks in "<<phase<<": "<<error.what()<<'\n';}
    std::error_code ignored;std::filesystem::remove_all(folder,ignored);return 1;
}
} // namespace coincide
