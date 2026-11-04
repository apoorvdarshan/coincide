#pragma once
#include "../App/QuestionForm.h"
#include <winrt/Microsoft.UI.Xaml.Automation.Peers.h>
#include <winrt/Microsoft.UI.Xaml.Automation.Provider.h>
#include <windows.h>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <thread>

namespace coincide {
// Run on the initialized WinUI dispatcher. The caller supplies a hidden Window's Grid/Panel
// XamlRoot; these controls are never activated and never call a runtime/provider/account.
inline int question_form_tests(const std::filesystem::path& report,
        const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root) {
    namespace xaml=winrt::Microsoft::UI::Xaml;
    namespace ui=xaml::Controls;
    namespace peers=xaml::Automation::Peers;
    namespace providers=xaml::Automation::Provider;
    namespace json=winrt::Windows::Data::Json;
    int checks{};
    ui::Panel host{nullptr};ui::StackPanel mounted{nullptr};
    auto check=[&](bool condition,const char* failure){++checks;if(!condition)throw std::runtime_error(failure);};
    auto pump=[] {
        MSG message{};
        // Limit reentrant dispatch to pending work; a broken test must not wait forever.
        for(unsigned count=0;count<512&&PeekMessageW(&message,nullptr,0,0,PM_REMOVE);++count){
            if(message.message==WM_QUIT){PostQuitMessage(static_cast<int>(message.wParam));break;}
            TranslateMessage(&message);DispatchMessageW(&message);
        }
    };
    auto until=[&](auto predicate){
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);
        while(!predicate()&&std::chrono::steady_clock::now()<deadline){pump();std::this_thread::sleep_for(std::chrono::milliseconds(1));}
        pump();return predicate();
    };
    auto controls=[](const ui::StackPanel& form,const wchar_t* identity){
        std::vector<ui::Control> result;
        for(const auto& child:form.Children())if(xaml::Automation::AutomationProperties::GetAutomationId(child)==identity)
            if(const auto value=child.try_as<ui::Control>())result.push_back(value);
        return result;
    };
    auto button=[&](const wchar_t* identity){const auto values=controls(mounted,identity);if(values.size()!=1)throw std::runtime_error("Missing native question button");return values.front().as<ui::Button>();};
    auto invoke=[&](const wchar_t* identity){
        const peers::ButtonAutomationPeer peer(button(identity));
        peer.GetPattern(peers::PatternInterface::Invoke).as<providers::IInvokeProvider>().Invoke();pump();
    };
    auto unmount=[&]{if(host&&mounted){std::uint32_t index{};if(host.Children().IndexOf(mounted,index))host.Children().RemoveAt(index);}mounted=nullptr;pump();};
    struct Capture{std::vector<std::string> responses;unsigned errors{};bool throw_once{};};
    auto mount=[&](const wchar_t* document){
        unmount();auto state=std::make_shared<Capture>();
        mounted=question_form(json::JsonObject::Parse(document),[state](std::string response){if(state->throw_once){state->throw_once=false;throw std::runtime_error("Fixture submission failure");}state->responses.push_back(std::move(response));},
            [state](winrt::hstring){++state->errors;});
        host.Children().Append(mounted);mounted.Measure({800,1600});mounted.Arrange({0,0,800,1600});mounted.UpdateLayout();pump();return state;
    };
    auto answers=[](const Capture& state,const wchar_t* id){return json::JsonObject::Parse(winrt::to_hstring(state.responses.back())).GetNamedObject(L"answers").GetNamedObject(id).GetNamedArray(L"answers");};
    try {
        if(!xaml_root)throw std::runtime_error("Question form tests require an initialized hidden XamlRoot");
        host=xaml_root.Content().try_as<ui::Panel>();
        if(!host)throw std::runtime_error("Question form tests require a Panel as the hidden Window content");
        auto state=mount(LR"json({"questions":[{"id":"choice","question":"Choose explicitly","options":[{"label":"First (Recommended)"},{"label":"Second"},{"label":"Second"}]}]})json");
        auto choices=controls(mounted,L"QuestionOption");
        check(choices.size()==2&&choices.front().try_as<ui::RadioButton>(),"Single-select options must be native deduplicated radio controls");
        check(choices.front().as<ui::RadioButton>().IsChecked().Value()&&!choices.back().as<ui::RadioButton>().IsChecked().Value(),"The first recommended choice must be preselected");
        check(state->responses.empty(),"Building or preselecting a question must never submit it");
        choices.back().as<ui::RadioButton>().IsChecked(true);pump();
        auto answer=controls(mounted,L"QuestionAnswer").front().as<ui::TextBox>();
        check(answer.Text()==L"Second"&&state->responses.empty(),"Choosing an option must synchronize text while waiting for explicit Submit");
        answer.Text(L"A custom answer");pump();
        check(!choices.front().as<ui::RadioButton>().IsChecked().Value()&&!choices.back().as<ui::RadioButton>().IsChecked().Value(),"Typing a custom answer must clear option selection");
        invoke(L"SubmitAnswer");check(until([&]{return state->responses.size()==1;}),"Native Submit automation must deliver the custom answer");
        check(answers(*state,L"choice").Size()==1&&answers(*state,L"choice").GetStringAt(0)==L"A custom answer","Custom answers must use the normalized answer schema");
        check(!button(L"SubmitAnswer").IsEnabled()&&!button(L"DismissQuestion").IsEnabled(),"Successful submission must disable repeat responses");

        state=mount(LR"json({"questions":[{"id":"match","question":"Match text","options":[{"label":"First"},{"label":"Second"}]}]})json");
        choices=controls(mounted,L"QuestionOption");answer=controls(mounted,L"QuestionAnswer").front().as<ui::TextBox>();
        answer.Text(L"Different");pump();answer.Text(L"Second");pump();
        check(choices.back().as<ui::RadioButton>().IsChecked().Value(),"Typing an exact option label must restore its selected radio");
        invoke(L"SubmitAnswer");check(until([&]{return state->responses.size()==1;})&&answers(*state,L"match").GetStringAt(0)==L"Second","An exact label must be sent only once");

        state=mount(LR"json({"questions":[{"id":"immediate","question":"Immediate custom answer","options":[{"label":"Default"}]}]})json");
        controls(mounted,L"QuestionAnswer").front().as<ui::TextBox>().Text(L"Fresh custom text");
        invoke(L"SubmitAnswer");check(until([&]{return state->responses.size()==1;})&&answers(*state,L"immediate").GetStringAt(0)==L"Fresh custom text","Submit must use current text even before any deferred TextChanged work");
        state=mount(LR"json({"questions":[{"id":"cleared","question":"Clear the default","options":[{"label":"Default"}]}]})json");
        controls(mounted,L"QuestionAnswer").front().as<ui::TextBox>().Text(L"");
        invoke(L"SubmitAnswer");check(until([&]{return state->errors==1;})&&state->responses.empty()&&button(L"SubmitAnswer").IsEnabled(),"Clearing a required single answer must validate rather than send a stale selected label");

        state=mount(LR"json({"questions":[{"id":"many","question":"Choose several","allowsMultipleSelection":true,"options":[{"label":"One"},{"label":"Two"}]}]})json");
        choices=controls(mounted,L"QuestionOption");
        check(choices.size()==2&&choices.front().try_as<ui::CheckBox>()&&!choices.front().as<ui::CheckBox>().IsChecked().Value(),"Multiple-selection questions must use unselected native checkboxes");
        invoke(L"SubmitAnswer");check(until([&]{return state->errors==1;}),"Empty required answers must show validation");
        check(state->responses.empty()&&button(L"SubmitAnswer").IsEnabled()&&mounted.Parent(),"Required validation must preserve the mounted question and enabled Submit");
        choices.front().as<ui::CheckBox>().IsChecked(true);choices.back().as<ui::CheckBox>().IsChecked(true);
        controls(mounted,L"QuestionAnswer").front().as<ui::TextBox>().Text(L"Other");pump();
        invoke(L"SubmitAnswer");check(until([&]{return state->responses.size()==1;}),"A valid multiple answer must remain submittable after validation");
        const auto multiple=answers(*state,L"many");check(multiple.Size()==3&&multiple.GetStringAt(0)==L"One"&&multiple.GetStringAt(1)==L"Two"&&multiple.GetStringAt(2)==L"Other","All selected options and custom text must survive multiple selection");

        state=mount(LR"json({"questions":[{"id":"only","question":"Options only","allowsFreeText":false,"options":[{"label":"Keep"},{"label":"Change"}]}]})json");
        check(controls(mounted,L"QuestionAnswer").empty(),"Options-only questions must not expose a free-text input");
        invoke(L"SubmitAnswer");check(until([&]{return state->responses.size()==1;})&&answers(*state,L"only").GetStringAt(0)==L"Keep","The default options-only radio must require and support explicit Submit");

        state=mount(LR"json({"questions":[{"id":"secret","question":"Secret fixture","isSecret":true}]})json");
        const auto password=controls(mounted,L"QuestionAnswer").front().try_as<ui::PasswordBox>();
        check(static_cast<bool>(password),"Secret answers must use a native PasswordBox");password.Password(L"fixture-value");pump();
        invoke(L"SubmitAnswer");check(until([&]{return state->responses.size()==1;})&&answers(*state,L"secret").GetStringAt(0)==L"fixture-value","Committed secret values must use the normalized response schema");

        state=mount(LR"json({"questions":[{"id":"optional","question":"Optional","required":false,"allowsFreeText":false,"allowsMultipleSelection":true,"options":[{"label":"One"}]}]})json");
        invoke(L"SubmitAnswer");check(until([&]{return state->responses.size()==1;})&&answers(*state,L"optional").Size()==0,"Optional options-only questions must allow an empty answer");

        state=mount(LR"json({"questions":[{"id":"retry","question":"Retry fixture","options":[{"label":"Default"}]}]})json");state->throw_once=true;
        invoke(L"SubmitAnswer");check(until([&]{return state->errors==1;})&&state->responses.empty()&&button(L"SubmitAnswer").IsEnabled(),"A failed response callback must preserve the form for retry");
        invoke(L"SubmitAnswer");check(until([&]{return state->responses.size()==1;}),"A response must be retryable after callback failure");

        state=mount(LR"json({"questions":[{"id":"dismiss","question":"Dismiss fixture"}]})json");invoke(L"DismissQuestion");
        check(until([&]{return state->responses.size()==1;})&&json::JsonObject::Parse(winrt::to_hstring(state->responses.front())).GetNamedObject(L"answers").Size()==0,"Dismiss must be an explicit empty response");
        unmount();std::ofstream output(report);output<<"PASS: "<<checks<<" native question form checks\n";return output?0:2;
    }catch(const winrt::hresult_error& error){unmount();std::ofstream(report)<<"FAIL: "<<winrt::to_string(error.message())<<'\n';}
    catch(const std::exception& error){unmount();std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}
    return 1;
}
} // namespace coincide
