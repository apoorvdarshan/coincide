#pragma once
#include "NativeStrings.h"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <functional>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

namespace coincide {
namespace question_ui {
namespace xaml=winrt::Microsoft::UI::Xaml;
namespace ui=xaml::Controls;
namespace json=winrt::Windows::Data::Json;
inline void identify(const xaml::DependencyObject& value,const wchar_t* id){xaml::Automation::AutomationProperties::SetAutomationId(value,id);}
inline bool boolean(const json::JsonObject& value,const wchar_t* key,bool fallback){const auto raw=value.GetNamedValue(key,json::JsonValue::CreateNullValue());return raw.ValueType()==json::JsonValueType::Null?fallback:raw.GetBoolean();}
inline bool blank(const winrt::hstring& text){
    for(const auto value:text)if(!((value>=9&&value<=13)||value==0x20||value==0x85||value==0xa0||value==0x1680
            ||(value>=0x2000&&value<=0x200a)||value==0x2028||value==0x2029||value==0x202f||value==0x205f||value==0x3000))return false;
    return true;
}
struct Option{winrt::hstring label;ui::Control view{nullptr};};
struct Field{
    winrt::hstring id;
    bool multiple{},free_text{true},required{true},syncing{};
    int selected{-1};
    ui::Control answer{nullptr};
    std::vector<Option> options;
    winrt::hstring text()const{if(const auto password=answer.try_as<ui::PasswordBox>())return password.Password();if(const auto box=answer.try_as<ui::TextBox>())return box.Text();return{};}
    void text(const winrt::hstring& value){if(const auto password=answer.try_as<ui::PasswordBox>())password.Password(value);else if(const auto box=answer.try_as<ui::TextBox>())box.Text(value);}
    void choose(std::size_t index){
        if(syncing||multiple)return;
        syncing=true;selected=static_cast<int>(index);if(free_text)text(options[index].label);syncing=false;
    }
    void edited(){
        if(syncing||multiple||!free_text)return;
        syncing=true;const auto value=text();selected=-1;
        for(std::size_t index=0;index<options.size();++index){
            const bool matches=value==options[index].label;
            options[index].view.as<ui::RadioButton>().IsChecked(matches);
            if(matches)selected=static_cast<int>(index);
        }
        syncing=false;
    }
    std::vector<winrt::hstring> values()const{
        std::vector<winrt::hstring> result;
        // TextChanged can be delivered after the current dispatcher turn. A single-answer
        // editor is authoritative at Submit, including a deliberately cleared required value.
        // The radio's Checked handler writes its label to this editor synchronously.
        if(!multiple&&free_text){const auto value=text();if(!blank(value))result.push_back(value);return result;}
        if(multiple){for(const auto& option:options){const auto checked=option.view.as<ui::CheckBox>().IsChecked();if(checked&&checked.Value())result.push_back(option.label);}}
        else{for(const auto& option:options){const auto checked=option.view.as<ui::RadioButton>().IsChecked();if(checked&&checked.Value()){result.push_back(option.label);break;}}}
        if(free_text&&(multiple||result.empty())){const auto value=text();if(!blank(value)&&std::find(result.begin(),result.end(),value)==result.end())result.push_back(value);}
        return result;
    }
};
struct Form{
    std::vector<std::shared_ptr<Field>> fields;
    std::function<void(std::string)> submit;
    std::function<void(winrt::hstring)> error;
    ui::TextBlock error_view{nullptr};
    bool submitted{};
    void fail(const winrt::hstring& message){error_view.Text(message);error_view.Visibility(xaml::Visibility::Visible);if(error)try{error(message);}catch(...) {}}
};
inline ui::TextBlock text(const winrt::hstring& value){ui::TextBlock result;result.Text(value);result.TextWrapping(xaml::TextWrapping::Wrap);return result;}
} // namespace question_ui

// Every choice remains a user action followed by an explicit Submit. View events retain only weak
// field references, so disposing a prompt cannot leave a control/callback ownership cycle behind.
inline winrt::Microsoft::UI::Xaml::Controls::StackPanel question_form(winrt::Windows::Data::Json::JsonObject params,
        std::function<void(std::string)> submit,std::function<void(winrt::hstring)> error={}){
    namespace ui=question_ui::ui;namespace xaml=question_ui::xaml;namespace json=question_ui::json;
    if(!submit)throw std::invalid_argument("A question form needs a response handler");
    const auto questions=params.GetNamedArray(L"questions");
    if(!questions.Size()||questions.Size()>32)throw std::invalid_argument("Invalid number of questions");
    ui::StackPanel root;root.Spacing(8);question_ui::identify(root,L"QuestionForm");
    auto form=std::make_shared<question_ui::Form>();form->submit=std::move(submit);form->error=std::move(error);
    std::unordered_set<std::wstring> identities;std::size_t total_options{};
    static std::atomic<std::uint64_t> next_group{1};const auto group_id=next_group.fetch_add(1);
    for(const auto& raw:questions){
        const auto question=raw.GetObject();auto field=std::make_shared<question_ui::Field>();
        field->id=question.GetNamedString(L"id");
        if(question_ui::blank(field->id)||field->id.size()>128||!identities.insert(std::wstring(field->id)).second)throw std::invalid_argument("Invalid question identity");
        field->multiple=question_ui::boolean(question,L"allowsMultipleSelection",false);
        field->free_text=question_ui::boolean(question,L"allowsFreeText",true);
        field->required=question_ui::boolean(question,L"required",question_ui::boolean(question,L"isRequired",true));
        const auto heading=question.GetNamedString(L"header",L"");if(!heading.empty())root.Children().Append(question_ui::text(heading));
        const auto prompt=question.GetNamedString(L"question");if(prompt.size()>65536)throw std::invalid_argument("The question text exceeds its limit");
        root.Children().Append(question_ui::text(prompt));
        if(question_ui::boolean(question,L"isSecret",false)){ui::PasswordBox answer;answer.MaxLength(16384);field->answer=answer;}
        else{ui::TextBox answer;answer.PlaceholderText(ui_text(L"Your answer"));answer.MaxLength(16384);field->answer=answer;}
        question_ui::identify(field->answer,L"QuestionAnswer");
        xaml::Automation::AutomationProperties::SetName(field->answer,prompt);
        const auto choices=question.GetNamedArray(L"options",json::JsonArray{});
        if(choices.Size()>128)throw std::invalid_argument("The question has too many options");
        std::unordered_set<std::wstring> labels;
        for(const auto& entry:choices){
            const auto option=entry.GetObject();const auto label=option.GetNamedString(L"label");
            const auto description=option.GetNamedString(L"description",L"");
            if(question_ui::blank(label)||label.size()>4096||description.size()>8192)throw std::invalid_argument("Invalid question option");
            if(!labels.insert(std::wstring(label)).second)continue;
            if(++total_options>512)throw std::invalid_argument("The question form has too many options");
            ui::StackPanel content;content.Spacing(2);content.Children().Append(question_ui::text(label));
            if(!description.empty()){auto detail=question_ui::text(description);detail.Opacity(0.7);content.Children().Append(detail);}
            ui::Control control{nullptr};
            if(field->multiple){ui::CheckBox choice;choice.Content(content);control=choice;}
            else{
                ui::RadioButton choice;choice.GroupName(L"CoincideQuestion"+winrt::to_hstring(group_id)+L"/"+field->id);choice.Content(content);control=choice;
                const auto index=field->options.size();choice.Checked([weak=std::weak_ptr<question_ui::Field>(field),index](const auto&,const auto&){if(const auto value=weak.lock())value->choose(index);});
            }
            question_ui::identify(control,L"QuestionOption");xaml::Automation::AutomationProperties::SetName(control,label);
            field->options.push_back({label,control});root.Children().Append(control);
        }
        if(field->free_text){
            root.Children().Append(field->answer);
            if(const auto box=field->answer.try_as<ui::TextBox>())box.TextChanging([weak=std::weak_ptr<question_ui::Field>(field)](const auto&,const auto&){if(const auto value=weak.lock())value->edited();});
            else field->answer.as<ui::PasswordBox>().PasswordChanged([weak=std::weak_ptr<question_ui::Field>(field)](const auto&,const auto&){if(const auto value=weak.lock())value->edited();});
        }else{field->answer.IsEnabled(false);field->answer.Visibility(xaml::Visibility::Collapsed);}
        if(!field->multiple&&!field->options.empty()){field->choose(0);field->options.front().view.as<ui::RadioButton>().IsChecked(true);}
        form->fields.push_back(std::move(field));
    }
    form->error_view=question_ui::text(L"");question_ui::identify(form->error_view,L"QuestionValidationError");form->error_view.Visibility(xaml::Visibility::Collapsed);root.Children().Append(form->error_view);
    ui::Button submit_button;submit_button.Content(winrt::box_value(ui_text(L"Submit")));question_ui::identify(submit_button,L"SubmitAnswer");
    ui::Button dismiss_button;dismiss_button.Content(winrt::box_value(ui_text(L"Dismiss")));question_ui::identify(dismiss_button,L"DismissQuestion");
    const auto weak_submit=winrt::make_weak(submit_button),weak_dismiss=winrt::make_weak(dismiss_button);
    submit_button.Click([form,weak_submit,weak_dismiss](const auto&,const auto&){
        if(form->submitted)return;
        json::JsonObject result,answers;
        for(const auto& field:form->fields){
            const auto selected=field->values();
            if(field->required&&selected.empty()){form->fail(ui_text(L"Answer every required question before submitting."));field->answer.Focus(xaml::FocusState::Programmatic);return;}
            json::JsonArray values;for(const auto& value:selected)values.Append(json::JsonValue::CreateStringValue(value));
            json::JsonObject entry;entry.SetNamedValue(L"answers",values);answers.SetNamedValue(field->id,entry);
        }
        result.SetNamedValue(L"answers",answers);form->submitted=true;
        try{form->submit(winrt::to_string(result.Stringify()));if(const auto value=weak_submit.get())value.IsEnabled(false);if(const auto value=weak_dismiss.get())value.IsEnabled(false);}
        catch(...){form->submitted=false;form->fail(ui_text(L"Could not submit the answer. Try again."));}
    });
    dismiss_button.Click([form,weak_submit,weak_dismiss](const auto&,const auto&){
        if(form->submitted)return;form->submitted=true;
        try{form->submit("{\"answers\":{}}");if(const auto value=weak_submit.get())value.IsEnabled(false);if(const auto value=weak_dismiss.get())value.IsEnabled(false);}
        catch(...){form->submitted=false;form->fail(ui_text(L"Could not dismiss the question. Try again."));}
    });
    root.Children().Append(submit_button);root.Children().Append(dismiss_button);return root;
}
} // namespace coincide
