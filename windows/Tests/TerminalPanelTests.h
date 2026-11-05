#pragma once
#include "../App/TerminalPanel.h"
#include "InstructionImportPanelTests.h"

namespace coincide {
inline int terminal_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace f=instruction_import_panel_fixture;namespace ui=f::ui;
    std::size_t checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error("check "+std::to_string(checks)+": "+message);};
    std::shared_ptr<TerminalPanel> panel;ui::Panel host{nullptr};
    const auto detach=[&]{if(panel){panel->close();std::uint32_t at{};if(host&&host.Children().IndexOf(panel->view(),at))host.Children().RemoveAt(at);panel.reset();}f::pump();};
    try{
        if(!xaml_root||(host=xaml_root.Content().try_as<ui::Panel>())==nullptr)throw std::runtime_error("Terminal fixtures require an initialized native Panel");
        instruction_import_fixture::Directory owned;const std::string first="{11111111-1111-1111-1111-111111111111}",second="{22222222-2222-2222-2222-222222222222}";
        panel=TerminalPanel::create(owned.path,true);host.Children().Append(panel->view());panel->select_thread(first,owned.path);
        bool allowed{},guard_seen{};panel->set_command_guard([&](const auto& thread,const auto& cwd){guard_seen=thread==first&&cwd==owned.path;return allowed;});
        bool rejected{};try{(void)panel->new_tab();}catch(const std::runtime_error&){rejected=true;}
        check(rejected&&guard_seen&&panel->panes(first).empty(),"A repository lease must reject a new terminal before creating a pane or child");
        allowed=true;panel->set_visible(true);
        check(f::until([&]{const auto panes=panel->panes(first);return panes.size()==1&&!panes[0].starting&&panes[0].running;}),"The owned ConPTY fixture must start without invoking a real shell");
        const auto pane=panel->panes(first).front().id;
        check(f::until([&]{return panel->read(first,pane).text.find("TERMINAL_FIXTURE_READY")!=std::string::npos;}),"The native panel must consume its owned child output");
        check(panel->read(first,pane).text.find("你好")!=std::string::npos,"Native terminal reads must preserve UTF-8 output");
        rejected=false;try{(void)panel->read(second,pane);}catch(const std::invalid_argument&){rejected=true;}
        check(rejected&&!panel->interrupt(second,pane),"A terminal pane must remain scoped to its originating conversation");
        const auto short_read=panel->read(first,pane,7);check(short_read.truncated&&short_read.text.size()<=7,"Terminal read tails must respect their bound");
        rejected=false;try{(void)panel->read(first,pane,65537);}catch(const std::invalid_argument&){rejected=true;}check(rejected,"Oversized terminal reads must fail before accessing output");
        auto input=f::control<ui::TextBox>(panel->view(),L"TerminalInput");allowed=false;input.Text(L"Retain blocked input 你好");f::pump();
        check(input.Text()==L"Retain blocked input 你好"&&!panel->interrupt(first,pane),"Blocked terminal input must stay in its editor and must not reach the child");
        rejected=false;try{(void)panel->split();}catch(const std::runtime_error&){rejected=true;}check(rejected&&panel->panes(first).size()==1,"A blocked split must not create another child");
        input.Text(L"");allowed=true;input.Text(L"Owned input 你好");check(f::until([&]{return input.Text().empty();}),"Accepted terminal text must clear only after entering the owned child queue");
        check(panel->interrupt(first,pane),"Explicit Interrupt must target the owned pane");
        check(f::until([&]{return panel->read(first,pane).text.find("CTRL_C_MARKER")!=std::string::npos;}),"Explicit Interrupt must reach the correct fixture process");
        const auto split=panel->split();check(!split.empty()&&panel->panes(first).size()==2,"Native splits must keep separate scoped panes");
        panel->close_tab();check(panel->panes(first).empty(),"Closing a tab must remove all its panes");
        panel->close();check(panel->new_tab().empty()&&panel->panes(first).empty(),"A closed terminal controller must not create sessions");
        detach();std::ofstream output(report);output<<"PASS: "<<checks<<" Windows terminal native panel checks; owned synthetic ConPTY only\n";return output?0:2;
    }catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}
    catch(const winrt::hresult_error&){detach();std::ofstream(report)<<"FAIL after "<<checks<<" checks: native terminal panel API failure\n";}return 1;
}
} // namespace coincide
