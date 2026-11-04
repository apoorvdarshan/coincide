#pragma once
#include "../App/ComputerUsePanel.h"
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#include <fstream>

namespace coincide {
namespace computer_use_panel_fixture {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline void pump(){MSG message{};for(unsigned index=0;index<256&&PeekMessageW(&message,nullptr,0,0,PM_REMOVE);++index){if(message.message==WM_QUIT){PostQuitMessage(static_cast<int>(message.wParam));break;}TranslateMessage(&message);DispatchMessageW(&message);}}
inline xaml::DependencyObject find(const xaml::DependencyObject& value,const wchar_t* id){if(!value)return nullptr;if(xaml::Automation::AutomationProperties::GetAutomationId(value)==id)return value;if(const auto panel=value.try_as<ui::Panel>())for(const auto& child:panel.Children())if(const auto found=find(child,id))return found;if(const auto scroll=value.try_as<ui::ScrollViewer>())if(const auto content=scroll.Content().try_as<xaml::DependencyObject>())return find(content,id);return nullptr;}
template<class T>T control(const xaml::DependencyObject& root,const wchar_t* id){const auto found=find(root,id);if(!found)throw std::runtime_error("A Computer Use fixture control is missing");return found.as<T>();}
inline void invoke(const xaml::DependencyObject& root,const wchar_t* id){const xaml::Automation::Peers::ButtonAutomationPeer peer(control<ui::Button>(root,id));peer.GetPattern(xaml::Automation::Peers::PatternInterface::Invoke).as<xaml::Automation::Provider::IInvokeProvider>().Invoke();pump();}
inline void toggle(const ui::CheckBox& box){const xaml::Automation::Peers::CheckBoxAutomationPeer peer(box);peer.GetPattern(xaml::Automation::Peers::PatternInterface::Toggle).as<xaml::Automation::Provider::IToggleProvider>().Toggle();pump();}
}
// Initialized hidden native controls, a fake backend and unique temporary settings only.
// No real helper is launched and no real desktop, camera/microphone or provider is inspected.
inline int computer_use_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    using namespace computer_use;namespace fixture=computer_use_panel_fixture;namespace ui=fixture::ui;
    struct Fake:Backend{unsigned calls{},stops{};std::uint64_t epoch{1};Object request(const Object&,const std::function<bool()>& cancelled)override{++calls;if(cancelled())throw std::runtime_error("revoked");Object result;return result;}std::uint64_t generation()const override{return epoch;}void stop()noexcept override{++stops;++epoch;}};
    const auto folder=std::filesystem::temp_directory_path()/(L"Coincide CU panel fixture "+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    struct Cleanup{std::filesystem::path value;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(value,ignored);}}cleanup{folder};
    const std::string a="{65e2f1d1-cc61-40b5-95bd-d29c345c444c}",b="{05bd2cb4-5b1b-4dba-9a2c-89d9ea45801c}";const auto file=folder/L"computer-use.json";auto backend=std::make_shared<Fake>();auto controller=std::make_shared<Controller>(backend);
    std::shared_ptr<ComputerUsePanel> panel;ui::Panel host{nullptr};std::vector<std::pair<ComputerUsePanel::Change,std::string>> changes;bool redirect{};int checks{};
    auto check=[&](bool condition,const char* message){++checks;if(!condition)throw std::runtime_error(message);};auto rejects=[&](auto action,const char* message){bool failed{};try{action();}catch(...){failed=true;}check(failed,message);};
    auto read=[&]{std::ifstream input(file,std::ios::binary);return std::string((std::istreambuf_iterator<char>(input)),{});};
    auto detach=[&]{if(panel){panel->close();if(host){std::uint32_t index{};if(host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);}panel.reset();}fixture::pump();};
    auto mount=[&]{detach();panel=ComputerUsePanel::create(folder,controller,[&](auto change,const auto& id){changes.emplace_back(change,id);if(redirect&&change==ComputerUsePanel::Change::granted)panel->select_thread(b,"Fixture B");});host.Children().Append(panel->view());panel->view().Measure({800,600});panel->view().Arrange({0,0,800,600});panel->view().UpdateLayout();fixture::pump();};
    auto control=[&]<class T>(const wchar_t* id){return fixture::control<T>(panel->view(),id);};auto enabled=[&](const wchar_t* id){return control.template operator()<ui::Button>(id).IsEnabled();};
    auto master=[&](bool value){control.template operator()<ui::ToggleSwitch>(L"ComputerUseEnabled").IsOn(value);fixture::pump();};
    try{
        if(!xaml_root||(host=xaml_root.Content().try_as<ui::Panel>())==nullptr)throw std::runtime_error("Computer Use panel tests need an initialized hidden WinUI Panel/XamlRoot");mount();
        check(!controller->snapshot().enabled&&!std::filesystem::exists(folder)&&!backend->calls&&changes.empty(),"Opening the pane must keep the default master off and inspect no desktop");
        check(!enabled(L"ComputerUseGrant")&&!enabled(L"ComputerUseRevoke")&&!enabled(L"ComputerUseRelease"),"No selected permitted thread means all authority actions stay disabled");
        panel->select_thread(a,"Fixture A");check(panel->selected_thread()==a&&!enabled(L"ComputerUseGrant")&&!computer_use::Settings{}.enabled,"Selecting a conversation must not enable Computer Use or grant it access");
        master(true);check(controller->snapshot().enabled&&!controller->snapshot(a).granted&&!backend->calls,"The explicit master toggle must not start a helper or grant a thread access");
        check(Object::Parse(winrt::to_hstring(read())).GetNamedBoolean(L"enabled")&&!enabled(L"ComputerUseGrant"),"Only the master setting persists until read permission is explicitly chosen");
        fixture::toggle(control.template operator()<ui::CheckBox>(L"ComputerUseReadWindows"));fixture::toggle(control.template operator()<ui::CheckBox>(L"ComputerUseCaptureWindows"));fixture::toggle(control.template operator()<ui::CheckBox>(L"ComputerUseInput"));
        check(!controller->snapshot(a).granted&&enabled(L"ComputerUseGrant")&&!backend->calls,"Editing permission checkboxes alone must not confer authority");
        panel->refresh();check(control.template operator()<ui::CheckBox>(L"ComputerUseInput").IsChecked().Value()&&control.template operator()<ui::CheckBox>(L"ComputerUseCaptureWindows").IsChecked().Value()&&!controller->snapshot(a).granted,"A status refresh must preserve pending checkbox edits without granting them");
        redirect=true;fixture::invoke(panel->view(),L"ComputerUseGrant");redirect=false;const auto granted=controller->snapshot(a);
        check(granted.granted&&granted.permission.read_windows&&granted.permission.capture_windows&&granted.permission.input,"Explicit Grant must apply exactly the independently chosen permissions");
        check(changes.back()==std::pair{ComputerUsePanel::Change::granted,a}&&panel->selected_thread()==b&&!controller->snapshot(b).granted,"A callback that switches conversations must not redirect an in-flight grant to a new target");
        check(!backend->calls,"Granting access must not perform an observation or launch a helper");
        panel->select_thread(a,"Fixture A");check(control.template operator()<ui::CheckBox>(L"ComputerUseInput").IsChecked().Value()&&enabled(L"ComputerUseRevoke"),"Returning to a thread must reflect its current ephemeral permission state");
        const auto before=read();check(before.find(a)==std::string::npos&&before.find("token")==std::string::npos&&before.find("grants")==std::string::npos,"Thread IDs, tokens and grants must never enter persisted settings");
        fixture::invoke(panel->view(),L"ComputerUseRelease");check(controller->snapshot(a).granted&&changes.back()==std::pair{ComputerUsePanel::Change::released,a},"Release desktop must preserve explicit permissions and report the exact thread");
        panel->select_thread(b,"Fixture B");fixture::toggle(control.template operator()<ui::CheckBox>(L"ComputerUseReadWindows"));fixture::invoke(panel->view(),L"ComputerUseGrant");panel->select_thread(a,"Fixture A");fixture::invoke(panel->view(),L"ComputerUseRevoke");
        check(!controller->snapshot(a).granted&&controller->snapshot(b).granted&&changes.back()==std::pair{ComputerUsePanel::Change::revoked,a},"Revoking one conversation must leave another explicit grant intact");
        panel->select_thread(b,"Fixture B");fixture::toggle(control.template operator()<ui::CheckBox>(L"ComputerUseReadWindows"));check(!enabled(L"ComputerUseGrant")&&!control.template operator()<ui::CheckBox>(L"ComputerUseCaptureWindows").IsEnabled()&&!control.template operator()<ui::CheckBox>(L"ComputerUseInput").IsEnabled(),"Unchecking read must clear/disable dependent editor choices without implicitly revoking active access");check(controller->snapshot(b).granted,"Checkbox edits must not change a previously active grant until an explicit action");
        master(false);check(!controller->snapshot().enabled&&!controller->snapshot(b).granted&&!Object::Parse(winrt::to_hstring(read())).GetNamedBoolean(L"enabled"),"Master-off must revoke every thread immediately and persist the disabled state");master(true);check(!controller->snapshot(a).granted&&!controller->snapshot(b).granted,"Re-enabling the master must not restore any earlier grants");
        panel->select_thread(a,"Fixture A");fixture::toggle(control.template operator()<ui::CheckBox>(L"ComputerUseReadWindows"));fixture::invoke(panel->view(),L"ComputerUseGrant");const auto previous_changes=changes.size();mount();panel->select_thread(a,"Fixture A");
        check(controller->snapshot(a).granted&&changes.size()==previous_changes&&!backend->calls,"Closing/reopening Settings must preserve existing session grants without performing desktop actions");
        rejects([&]{panel->select_thread("../other","Invalid");},"Invalid conversation IDs must not change the selected permission target");check(panel->selected_thread()==a,"Failed selection validation must leave the exact previous target intact");
        detach();controller=std::make_shared<Controller>(backend);mount();panel->select_thread(a,"Fixture A");check(controller->snapshot().enabled&&!controller->snapshot(a).granted,"A new app controller may restore only the master, never a thread grant");
        master(false);const auto disabled=read();HANDLE lock=CreateFileW((folder/L"computer-use.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);check(lock!=INVALID_HANDLE_VALUE,"The isolated panel settings lock must open");master(true);
        check(!controller->snapshot().enabled&&read()==disabled&&!control.template operator()<ui::TextBlock>(L"ComputerUseError").Text().empty(),"Failed enable persistence must leave authority disabled and show a recoverable error");CloseHandle(lock);master(true);panel->select_thread(a,"Fixture A");fixture::toggle(control.template operator()<ui::CheckBox>(L"ComputerUseReadWindows"));fixture::invoke(panel->view(),L"ComputerUseGrant");const auto enabled_bytes=read();
        lock=CreateFileW((folder/L"computer-use.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,nullptr);check(lock!=INVALID_HANDLE_VALUE,"The second isolated panel writer lock must open");master(false);
        check(!controller->snapshot().enabled&&!controller->snapshot(a).granted&&read()==enabled_bytes&&enabled(L"ComputerUseRetrySave"),"Failed disable persistence must still revoke all current authority and offer an explicit save retry");CloseHandle(lock);fixture::invoke(panel->view(),L"ComputerUseRetrySave");check(!Object::Parse(winrt::to_hstring(read())).GetNamedBoolean(L"enabled")&&!enabled(L"ComputerUseRetrySave"),"Retry saving a disabled setting must preserve revocation without any new grant");
        detach();std::ofstream(file,std::ios::trunc)<<"{\"format\":\"coincide.windows.computer-use\",\"version\":2,\"enabled\":true}";const auto unsupported=read();mount();panel->select_thread(a,"Fixture A");
        check(!controller->snapshot().enabled&&!control.template operator()<ui::ToggleSwitch>(L"ComputerUseEnabled").IsEnabled()&&!enabled(L"ComputerUseGrant")&&read()==unsupported,"Unsupported settings must be preserved and all authority controls remain disabled");
        check(!backend->calls,"The full native settings fixture must never launch a helper or inspect/input any real desktop");detach();std::ofstream output(report);output<<"PASS: "<<checks<<" native Computer Use settings panel checks (synthetic controller backend)\n";return output?0:2;
    }catch(const winrt::hresult_error& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<winrt::to_string(error.message())<<'\n';}catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
