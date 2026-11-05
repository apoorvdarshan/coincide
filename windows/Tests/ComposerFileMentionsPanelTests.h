#pragma once
#include "../App/ComposerFileMentions.h"
#include "ThreadFindBarTests.h"

namespace coincide {
inline int composer_file_mentions_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace f=thread_find_fixture;unsigned checks{};std::shared_ptr<ComposerFileMentions> controller;f::ui::Panel host{nullptr};f::ui::StackPanel fixture{nullptr};
    struct Worker {std::atomic<unsigned> started{},finished{},verified{};std::atomic_bool block{},on_ui{},fail_verify{};DWORD owner=GetCurrentThreadId();};auto worker=std::make_shared<Worker>();
    const auto until=[&](auto condition){const auto end=GetTickCount64()+5000;while(!condition()&&GetTickCount64()<end){f::pump();Sleep(1);}f::pump();return condition();};
    const auto check=[&](bool value,const char* why){++checks;if(!value)throw std::runtime_error(why);};
    const auto settle=[&]{if(!until([&]{return !controller->searching();}))throw std::runtime_error("Owned mention worker did not settle");};
    const auto cleanup=[&]{worker->block=false;if(controller)controller->close();until([&]{return worker->started==worker->finished;});if(host&&fixture){std::uint32_t at{};if(host.Children().IndexOf(fixture,at))host.Children().RemoveAt(at);}controller.reset();f::pump();};
    try{
        if(!xaml_root||!(host=xaml_root.Content().try_as<f::ui::Panel>()))throw std::runtime_error("File mention fixture needs an initialized Panel");
        fixture=f::ui::StackPanel{};f::ui::TextBox editor;fixture.Children().Append(editor);host.Children().Append(fixture);std::uint64_t revision{};editor.TextChanging([&](const auto&,const auto&){++revision;});
        bool project=true,reject_apply{};std::string thread="one";unsigned applied{};
        const auto source=[&]()->std::optional<FileMentionRequest>{if(!project)return{};return FileMentionRequest{thread,"project",L"C:\\owned-project",ComposerFileMentions::utf16(editor.Text()),static_cast<std::size_t>(editor.SelectionStart()),static_cast<std::size_t>(editor.SelectionLength()),revision};};
        controller=ComposerFileMentions::create(editor,source,[&](const auto& request,const auto& trigger,const auto& path){if(reject_apply||source()!=std::optional(request))return false;const auto edit=ComposerFileMention::insert(request.text,trigger,ComposerFileMentions::utf16(winrt::to_hstring(path)));++applied;editor.Text(ComposerFileMentions::wide(edit.text));editor.SelectionStart(static_cast<std::int32_t>(edit.caret));editor.SelectionLength(0);return true;},
            [worker](const auto& path,const auto& cancel){++worker->started;struct Done{std::shared_ptr<Worker> worker;~Done(){++worker->finished;}} done{worker};if(GetCurrentThreadId()==worker->owner)worker->on_ui=true;const auto end=GetTickCount64()+3000;while(worker->block&&!cancel()&&GetTickCount64()<end)Sleep(1);if(cancel())throw ProjectFileIndex::Cancelled{};if(worker->block)throw std::runtime_error("Owned file barrier did not release");ProjectFileIndex::Result result;result.scope=std::make_shared<ProjectFileIndex::Scope>();result.scope->root=path;result.files={{"src/main.cpp",{}},{"App File.swift",{}},{"README.md",{}}};return result;},
            [worker](const auto& scope,const auto& entry){++worker->verified;if(GetCurrentThreadId()==worker->owner)worker->on_ui=true;if(worker->fail_verify||!scope||entry.path.empty())throw std::runtime_error("Owned file identity changed");return std::make_shared<ProjectFileIndex::Verified>();});
        fixture.Children().Append(controller->view());fixture.Measure({700,600});fixture.Arrange({0,0,700,600});fixture.UpdateLayout();f::pump();
        const auto list=f::control<f::ui::ListView>(fixture,L"FileMentionResults");const auto insert=f::control<f::ui::Button>(fixture,L"InsertFileMention");const auto status=f::control<f::ui::TextBlock>(fixture,L"FileMentionStatus");
        const auto set=[&](const wchar_t* text){editor.Text(text);editor.SelectionStart(static_cast<std::int32_t>(editor.Text().size()));editor.SelectionLength(0);f::pump();};
        const auto invoke=[&]{f::xaml::Automation::Peers::ButtonAutomationPeer peer(insert);peer.GetPattern(f::xaml::Automation::Peers::PatternInterface::Invoke).as<f::xaml::Automation::Provider::IInvokeProvider>().Invoke();f::pump();};
        check(worker->started==0&&applied==0&&controller->view().Visibility()==f::xaml::Visibility::Collapsed,"Creating inline suggestions must not enumerate project files or edit the message");
        set(L"ordinary text");settle();check(worker->started==0&&controller->view().Visibility()==f::xaml::Visibility::Collapsed,"Ordinary prose must remain outside file discovery");
        set(L"Look @src");settle();check(list.Items().Size()==1&&insert.IsEnabled()&&editor.Text()==L"Look @src"&&!worker->on_ui,"Typing a file trigger must search metadata on a worker without changing the draft");
        check(!controller->key(winrt::Windows::System::VirtualKey::Enter,true,false,false)&&!controller->key(winrt::Windows::System::VirtualKey::Enter,false,true,false),"Explicit send and newline modifiers must keep their normal editor behavior");
        invoke();settle();check(until([&]{return applied==1;})&&editor.Text()==L"Look @src/main.cpp "&&worker->verified==1&&!worker->on_ui,"Explicit insertion must recheck the selected file on a worker and replace only its original token");
        set(L"Look @App");settle();check(controller->key(winrt::Windows::System::VirtualKey::Tab,false,false,false),"Tab must explicitly accept a ready file suggestion");settle();check(applied==2&&editor.Text()==L"Look @\"App File.swift\" ","File names with spaces must be quoted in the actual editor");
        set(L"Keep @src");settle();worker->fail_verify=true;invoke();settle();check(applied==2&&editor.Text()==L"Keep @src"&&!insert.IsEnabled()&&status.Text()==ui_text(L"The file or message changed. Type the mention again to refresh."),"A replaced or inaccessible file must preserve the exact current draft");worker->fail_verify=false;
        set(L"Again @src");settle();reject_apply=true;invoke();settle();check(applied==2&&editor.Text()==L"Again @src","A changed conversation or source revision must reject insertion");reject_apply=false;
        set(L"Escape @src");settle();check(controller->key(winrt::Windows::System::VirtualKey::Escape,false,false,false)&&editor.Text()==L"Escape @src"&&controller->view().Visibility()==f::xaml::Visibility::Collapsed,"Escape must dismiss suggestions without editing the message");
        const auto before=worker->started.load();worker->block=true;set(L"Wait @src");check(until([&]{return worker->started>before;}),"The owned stale-query fixture must reach its worker barrier");thread="two";controller->invalidate();worker->block=false;check(until([&]{return worker->started==worker->finished;})&&list.Items().Size()==0&&applied==2,"Switching conversations must cancel and revoke results from the old project context");
        project=false;set(L"No project @src");settle();check(worker->started==before+1&&controller->view().Visibility()==f::xaml::Visibility::Collapsed,"Projectless conversations must never enumerate an invented working folder");
        controller->close();set(L"Closed @src");f::pump();check(list.Items().Size()==0&&!insert.IsEnabled()&&applied==2,"A closed composer helper must stay inert");
        cleanup();std::ofstream output(report);output<<"PASS: "<<checks<<" native composer file mention checks; injected metadata backend only\n";return output?0:2;
    }catch(const winrt::hresult_error&){cleanup();std::ofstream(report)<<"FAIL after "<<checks<<" checks: native file mention UI API failure\n";}catch(const std::exception& error){cleanup();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
