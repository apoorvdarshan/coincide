#pragma once
#include "../App/InstructionGitPanel.h"
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>

namespace coincide {
namespace instruction_git_panel_fixture {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline xaml::DependencyObject find(const xaml::DependencyObject& root,const wchar_t* id,unsigned depth=0){if(!root||depth>32)return nullptr;if(xaml::Automation::AutomationProperties::GetAutomationId(root)==id)return root;if(const auto panel=root.try_as<ui::Panel>())for(const auto& child:panel.Children())if(const auto match=find(child,id,depth+1))return match;if(const auto content=root.try_as<ui::ContentControl>())return find(content.Content().try_as<xaml::DependencyObject>(),id,depth+1);return nullptr;}
template<class T>T control(const xaml::DependencyObject& root,const wchar_t* id){const auto value=find(root,id);if(!value)throw std::runtime_error("An instruction Git fixture control is missing");return value.as<T>();}
inline void pump(){MSG message{};for(unsigned i=0;i<512&&PeekMessageW(&message,nullptr,0,0,PM_REMOVE);++i){if(message.message==WM_QUIT){PostQuitMessage(static_cast<int>(message.wParam));break;}TranslateMessage(&message);DispatchMessageW(&message);}}
template<class Predicate>bool until(Predicate done){const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(15);while(!done()&&std::chrono::steady_clock::now()<end){pump();std::this_thread::sleep_for(std::chrono::milliseconds(1));}pump();return done();}
inline void invoke(const xaml::DependencyObject& root,const wchar_t* id){const xaml::Automation::Peers::ButtonAutomationPeer peer(control<ui::Button>(root,id));peer.GetPattern(xaml::Automation::Peers::PatternInterface::Invoke).as<xaml::Automation::Provider::IInvokeProvider>().Invoke();pump();}
inline bool checked(const ui::CheckBox& control){const auto value=control.IsChecked();return value&&value.Value();}
}
inline int instruction_git_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace fixture=instruction_git_panel_fixture;namespace git=instruction_git;namespace ui=fixture::ui;
    unsigned checks{};bool owned{};std::shared_ptr<InstructionGitPanel> panel;ui::Panel host{nullptr};
    const auto root=std::filesystem::temp_directory_path()/(L"Coincide-Instruction-Git-Panel-"+git::wide(background_host::new_guid()));
    struct Cleanup{std::filesystem::path path;bool& owned;~Cleanup(){if(owned){std::error_code error;std::filesystem::remove_all(path,error);}}}cleanup{root,owned};
    const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    const auto detach=[&]{if(panel){panel->close();fixture::until([&]{return!panel->busy();});panel->service()->discard_all();std::uint32_t index{};if(host&&host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);panel.reset();}fixture::pump();};
    try{
        if(!xaml_root||!(host=xaml_root.Content().try_as<ui::Panel>()))throw std::runtime_error("Instruction Git UI fixtures require an initialized hidden WinUI panel");
        if(!std::filesystem::create_directory(root))throw std::runtime_error("Owned instruction Git UI fixture setup failed");owned=true;const auto source_dir=root/L"project";std::filesystem::create_directory(source_dir);
        const auto source=source_dir/L"AGENTS.md",repo=root/L"repository",data=root/L"data";const std::string original="Owned synthetic instructions — 你好\n";std::ofstream(source,std::ios::binary)<<original;
        const auto file=InstructionService::project_files(source_dir).files.front();struct State{std::atomic_uint calls{},writes{},pushes{},github{};std::atomic_bool hold{},entered{},release{true};};const auto state=std::make_shared<State>();auto& calls=state->calls;auto& writes=state->writes;auto& pushes=state->pushes;auto& github=state->github;auto& hold=state->hold;auto& entered=state->entered;auto& release=state->release;const auto native=git::native_runner();
        git::Runner runner=[state,native](git::Command command,const auto& cancel){++state->calls;if(command.mutation){++state->writes;if(state->hold){state->entered=true;const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(10);while(!state->release&&!(cancel&&cancel())&&std::chrono::steady_clock::now()<end)std::this_thread::sleep_for(std::chrono::milliseconds(1));if(!state->release)throw std::runtime_error("Owned instruction fixture mutation gate expired or cancelled");}}if(command.tool==code_hosting::Tool::gh){++state->github;throw std::runtime_error("No GitHub operations are authorized in the native panel fixture");}if(std::find(command.arguments.begin(),command.arguments.end(),L"push")!=command.arguments.end())++state->pushes;command.isolated_fixture=true;command.arguments.insert(command.arguments.begin(),{L"-c",L"user.name=Coincide Synthetic UI",L"-c",L"user.email=fixture@example.invalid"});return native(command,cancel);};
        panel=InstructionGitPanel::create(data,runner);host.Children().Append(panel->view());check(calls==0&&!std::filesystem::exists(data),"Panel construction must not run Git, access accounts or save settings");
        panel->select_source(file);const auto view=panel->view();const auto setup=fixture::control<ui::ComboBox>(view,L"InstructionGitSetupKind");
        check(fixture::until([&]{return setup.IsEnabled();})&&calls==0,"Selecting an unlinked source should enable local setup without a CLI or mutation");
        fixture::control<ui::TextBox>(view,L"InstructionGitRepository").Text(winrt::to_hstring(git::narrow(repo)));setup.SelectedIndex(1);
        fixture::invoke(view,L"InstructionGitReviewSetup");const auto review=fixture::control<ui::StackPanel>(view,L"InstructionGitReview");const auto confirm=fixture::control<ui::Button>(view,L"InstructionGitConfirm");const auto consent=fixture::control<ui::CheckBox>(view,L"InstructionGitConsent");
        check(fixture::until([&]{return review.Visibility()==fixture::xaml::Visibility::Visible;})&&!confirm.IsEnabled()&&!fixture::checked(consent),"A concrete setup review must require a fresh explicit confirmation");
        check(!std::filesystem::exists(repo)&&calls==0&&local_file::read(source,1024).bytes==original,"Setup review must not create a repository or edit the original instruction file");
        check(fixture::control<ui::TextBox>(view,L"InstructionGitReviewText").IsReadOnly(),"Instruction text review must remain read only");
        fixture::invoke(view,L"InstructionGitCancel");check(fixture::until([&]{return review.Visibility()==fixture::xaml::Visibility::Collapsed&&setup.IsEnabled();})&&!std::filesystem::exists(repo)&&calls==0,"Cancel must leave source, destination and settings untouched");
        fixture::invoke(view,L"InstructionGitReviewSetup");check(fixture::until([&]{return review.Visibility()==fixture::xaml::Visibility::Visible;}),"A new setup attempt must produce a separate review");
        std::ofstream(source,std::ios::binary)<<"Changed after native review\n";consent.IsChecked(true);check(confirm.IsEnabled(),"Explicit review consent should enable only the current action");fixture::invoke(view,L"InstructionGitConfirm");
        const auto status=fixture::control<ui::TextBlock>(view,L"InstructionGitStatus");check(fixture::until([&]{return std::wstring_view(status.Text()).find(L"changed after setup review")!=std::wstring_view::npos;})&&!std::filesystem::exists(repo)&&calls==0,"Stale native approval must fail before any CLI, repository or settings change");
        std::ofstream(source,std::ios::binary)<<original;fixture::invoke(view,L"InstructionGitReviewSetup");check(fixture::until([&]{return review.Visibility()==fixture::xaml::Visibility::Visible;})&&!fixture::checked(consent)&&!confirm.IsEnabled(),"A failed/stale confirmation must not carry consent into a new review");
        panel->set_mutation_guard([](const auto&){return false;});consent.IsChecked(true);fixture::invoke(view,L"InstructionGitConfirm");check(!std::filesystem::exists(repo)&&calls==0&&!panel->mutating()&&review.Visibility()==fixture::xaml::Visibility::Visible,"A busy-workspace guard must refuse before any filesystem, Git or lease mutation");
        panel->set_mutation_guard([](const auto&){return true;});hold=true;release=false;fixture::invoke(view,L"InstructionGitConfirm");check(fixture::until([&]{return entered.load();})&&panel->mutating()&&panel->mutation_targets().size()==2&&panel->mutation_target()==repo,"The entire approved worker action must expose repository and resolved-source mutation leases while UI events remain responsive");release=true;
        check(fixture::until([&]{return setup.IsEnabled()&&std::filesystem::is_directory(repo/L".git");})&&!panel->mutating(),"An explicit approved local setup should complete on a worker and release its mutation lease");
        check(local_file::read(source,1024).bytes==original&&local_file::read(repo/L"Global.md",1024).bytes==original&&writes>0,"Approved native setup must retain original instructions and create the reviewed Git copy only");
        check(panel->service()->bindings().size()==1&&!panel->service()->bindings().front().automatic,"Native setup must not silently enable automatic synchronization");
        fixture::invoke(view,L"InstructionGitEnableAutomatic");check(fixture::until([&]{return review.Visibility()==fixture::xaml::Visibility::Visible;})&&!panel->service()->bindings().front().automatic,"Automatic synchronization must have its own explicit native review");
        check(!fixture::checked(fixture::control<ui::CheckBox>(view,L"InstructionGitAutomaticPush")),"Automatic pushing must default to off independently of copy synchronization");fixture::invoke(view,L"InstructionGitCancel");
        check(pushes==0&&github==0,"Native fixtures must never contact a remote, query GitHub auth or create a real repository");detach();std::ofstream(report)<<"PASS: "<<checks<<" instruction Git native UI checks (owned synthetic project/local Git only)\n";return 0;
    }catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<": "<<error.what()<<'\n';}catch(const winrt::hresult_error&){detach();std::ofstream(report)<<"FAIL after "<<checks<<": Windows instruction Git UI API error\n";}return 1;
}
} // namespace coincide
