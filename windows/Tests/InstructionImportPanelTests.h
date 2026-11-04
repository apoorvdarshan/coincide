#pragma once
#include "../App/InstructionsPanel.h"
#include "../App/ImportPanel.h"
#include "InstructionImportTests.h"
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#include <thread>

namespace coincide {
namespace instruction_import_panel_fixture {
namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
inline xaml::DependencyObject find(const xaml::DependencyObject& root,const wchar_t* id,unsigned depth=0){
    if(!root||depth>32)return nullptr;if(xaml::Automation::AutomationProperties::GetAutomationId(root)==id)return root;
    if(const auto panel=root.try_as<ui::Panel>())for(const auto& child:panel.Children())if(const auto value=find(child,id,depth+1))return value;
    if(const auto border=root.try_as<ui::Border>())return find(border.Child(),id,depth+1);
    if(const auto content=root.try_as<ui::ContentControl>())if(const auto child=content.Content().try_as<xaml::DependencyObject>())return find(child,id,depth+1);return nullptr;
}
template<class T>T control(const xaml::DependencyObject& root,const wchar_t* id){const auto value=find(root,id);if(!value)throw std::runtime_error("An owned instruction/import fixture control is missing");return value.as<T>();}
inline void pump(){MSG message{};for(unsigned count=0;count<512&&PeekMessageW(&message,nullptr,0,0,PM_REMOVE);++count){if(message.message==WM_QUIT){PostQuitMessage(static_cast<int>(message.wParam));break;}TranslateMessage(&message);DispatchMessageW(&message);}}
template<class Predicate>bool until(Predicate condition){const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(5);while(!condition()&&std::chrono::steady_clock::now()<end){pump();std::this_thread::sleep_for(std::chrono::milliseconds(1));}pump();return condition();}
inline void invoke(const xaml::DependencyObject& root,const wchar_t* id){const xaml::Automation::Peers::ButtonAutomationPeer peer(control<ui::Button>(root,id));peer.GetPattern(xaml::Automation::Peers::PatternInterface::Invoke).as<xaml::Automation::Provider::IInvokeProvider>().Invoke();pump();}
inline std::wstring logical_text(std::wstring_view value){std::wstring result;for(std::size_t i=0;i<value.size();++i){if(value[i]==L'\r'){result+=L'\n';if(i+1<value.size()&&value[i+1]==L'\n')++i;}else result+=value[i];}return result;}
inline std::string escaped(std::wstring_view value){std::string result;for(const auto ch:value){if(ch==L'\r')result+="\\r";else if(ch==L'\n')result+="\\n";else if(ch==L'\t')result+="\\t";else result+=winrt::to_string(std::wstring_view(&ch,1));}return result;}
}
inline int instruction_import_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace fixture=instruction_import_panel_fixture;namespace ui=fixture::ui;namespace xaml=fixture::xaml;
    std::size_t checks{};const auto check=[&](bool passed,const std::string& message){++checks;if(!passed)throw std::runtime_error("check "+std::to_string(checks)+": "+message);};
    std::shared_ptr<InstructionsPanel> instructions;std::shared_ptr<ImportPanel> imports;ui::Panel host{nullptr};
    const auto detach=[&]{if(instructions){instructions->close();std::uint32_t index{};if(host&&host.Children().IndexOf(instructions->view(),index))host.Children().RemoveAt(index);instructions.reset();}if(imports){imports->close();std::uint32_t index{};if(host&&host.Children().IndexOf(imports->view(),index))host.Children().RemoveAt(index);imports.reset();}fixture::pump();};
    try{
        if(!xaml_root||(host=xaml_root.Content().try_as<ui::Panel>())==nullptr)throw std::runtime_error("Instruction/import panel fixtures require an initialized hidden WinUI Panel");
        instruction_import_fixture::Directory owned;const auto project=owned.path/L"project";owned.write(L"project/AGENTS.md","Owned instruction preview — 你好\n");
        const auto home=owned.path/L"home";InstructionLocations locations{home,home/L".claude",home/L".codex",home/L".grok",home/L".config/opencode",home/L".gemini",home/L".config/coincide"};const auto master=owned.write(L"home/.config/coincide/AGENTS.md","Owned fixture master remains read only\n");
        instructions=InstructionsPanel::create(locations);host.Children().Append(instructions->view());instructions->set_project(project);
        const auto files=fixture::control<ui::ListView>(instructions->view(),L"InstructionFiles");
        check(fixture::until([&]{return files.Items().Size()==3&&files.IsEnabled();}),"native instruction discovery must complete without blocking the dispatcher");
        files.SelectedIndex(0);const auto reading=fixture::control<ui::TextBox>(instructions->view(),L"InstructionPreview");
        const auto instruction_loaded=fixture::until([&]{return fixture::logical_text(std::wstring_view(reading.Text()))==L"Owned instruction preview — 你好\n";});
        check(instruction_loaded&&reading.IsReadOnly(),"instruction selection must populate a native read-only text preview; displayed="+fixture::escaped(std::wstring_view(reading.Text()))+"; readOnly="+std::to_string(reading.IsReadOnly()));
        instructions->show_global();check(fixture::until([&]{return files.Items().Size()>=8&&files.IsEnabled();}),"global instruction mode must refresh paths independently of project rules");files.SelectedIndex(0);
        const auto master_loaded=fixture::until([&]{return fixture::logical_text(std::wstring_view(reading.Text()))==L"Owned fixture master remains read only\n";});
        check(master_loaded&&local_file::read(master,1024).bytes=="Owned fixture master remains read only\n","global master preview must never edit or replace its file; displayed="+fixture::escaped(std::wstring_view(reading.Text())));
        detach();const auto source=owned.write(L"history/fixture.jsonl",instruction_import_fixture::canonical());const auto original=local_file::read(source,ImportService::maximum_bytes).bytes;unsigned commits{};bool duplicate{};
        imports=ImportPanel::create({{"codex",owned.path/L"history"}},[&](const auto& preview){if(preview->provider!="codex"||preview->messages.size()!=3)throw std::runtime_error("Unexpected explicit import callback payload");++commits;},[&](const auto&){return duplicate?std::optional<std::string>{"owned-existing-thread"}:std::nullopt;});
        host.Children().Append(imports->view());imports->refresh();const auto candidates=fixture::control<ui::ListView>(imports->view(),L"ImportCandidates");
        check(fixture::until([&]{return candidates.Items().Size()==1&&candidates.IsEnabled();}),"native import discovery must list only owned history fixtures");candidates.SelectedIndex(0);
        const auto commit=fixture::control<ui::Button>(imports->view(),L"ImportSession");
        check(fixture::until([&]{return imports->selected_preview()&&commit.IsEnabled();})&&commits==0,"preview selection must never commit an import before explicit native action");
        fixture::invoke(imports->view(),L"ImportSession");check(fixture::until([&]{return commits==1;})&&!commit.IsEnabled(),"explicit Import must deliver the immutable preview once and disable repeat submission");
        check(local_file::read(source,ImportService::maximum_bytes).bytes==original,"native preview/import actions must leave source JSONL unchanged");
        duplicate=true;imports->select_file(source);check(fixture::until([&]{return imports->selected_preview()&&fixture::control<ui::TextBlock>(imports->view(),L"ImportStatus").Text()==L"This native session is already imported.";})&&!commit.IsEnabled()&&commits==1,"an existing native session must disable duplicate import without invoking the transaction callback");
        duplicate=false;imports->select_file(source);check(fixture::until([&]{return imports->selected_preview()&&commit.IsEnabled();}),"a fresh preview must re-enable explicit import");
        owned.write(L"history/fixture.jsonl",original+"{partial");fixture::invoke(imports->view(),L"ImportSession");
        check(fixture::until([&]{return commit.IsEnabled()&&std::wstring_view(fixture::control<ui::TextBlock>(imports->view(),L"ImportStatus").Text()).find(L"changed after its preview")!=std::wstring::npos;})&&commits==1,"changed sources must reject the native Import action before the transaction callback");
        detach();std::ofstream output(report);output<<"PASS: "<<checks<<" Windows instruction/import native panel checks\n";return output?0:2;
    }catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}catch(const winrt::hresult_error&){detach();std::ofstream(report)<<"FAIL: Windows instruction/import panel API error\n";return 1;}
}
} // namespace coincide
