#pragma once
#include "NativeStrings.h"
#include "../Runtime/OfflineVoiceSettings.h"
#include "../Runtime/VoiceTransport.h"
#include <shobjidl.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <functional>

namespace coincide {
struct VoiceDestination{std::string thread_id;std::uint64_t draft_revision{};};
class VoicePanel:public std::enable_shared_from_this<VoicePanel>{
public:
    enum class Phase{idle,preparing,recording,transcribing};
    using Destination=std::function<VoiceDestination()>;
    // Root must compare BOTH fields against the current thread/draft and return false on change.
    // This callback inserts a draft only; VoicePanel never sends or queues an agent message.
    using Insert=std::function<bool(const VoiceDestination&,const std::string&)>;
    using Factory=std::function<std::shared_ptr<VoiceTransport>()>;
    using SettingsChanged=std::function<bool(const OfflineVoiceSettings&)>;
    static std::shared_ptr<VoicePanel> create(std::filesystem::path voice_directory,Destination destination,Insert insert,HWND owner=nullptr,Factory factory={},SettingsChanged settings_changed={}){
        auto result=std::shared_ptr<VoicePanel>(new VoicePanel(std::move(voice_directory),std::move(destination),std::move(insert),owner,std::move(factory),std::move(settings_changed)));
        try{result->settings_=result->store_.open();result->loaded_=true;}catch(const std::exception& error){result->load_error_=error.what();}catch(const winrt::hresult_error& error){result->load_error_=winrt::to_string(error.message());}
        result->build();result->refresh_models();return result;
    }
    ~VoicePanel(){close();}
    winrt::Microsoft::UI::Xaml::Controls::Grid view()const{return root_;}
    Phase phase()const{return phase_;}
    bool active()const{return phase_!=Phase::idle;}
    bool shortcut_begin(){if(closed_||active()||dirty_||!loaded_||!settings_.enabled||!settings_.shortcut_enabled)return false;record();return active();}
    void shortcut_finish(){if(closed_)return;if(phase_==Phase::preparing)finish_after_prepare_=true;else finish();}
    void cancel(){++generation_;finish_after_prepare_=false;cancel_session();phase_=Phase::idle;if(!closed_){status_.Text(ui_text(L"Cancelled"));update();}}
    void close(){if(closed_)return;closed_=true;++models_generation_;cancel();}
private:
    using Grid=winrt::Microsoft::UI::Xaml::Controls::Grid;using Button=winrt::Microsoft::UI::Xaml::Controls::Button;using TextBlock=winrt::Microsoft::UI::Xaml::Controls::TextBlock;using TextBox=winrt::Microsoft::UI::Xaml::Controls::TextBox;using ComboBox=winrt::Microsoft::UI::Xaml::Controls::ComboBox;using Toggle=winrt::Microsoft::UI::Xaml::Controls::ToggleSwitch;using NumberBox=winrt::Microsoft::UI::Xaml::Controls::NumberBox;
    struct Session{std::mutex mutex;std::shared_ptr<VoiceTransport> transport;std::atomic_bool cancelled{};VoiceDestination destination;OfflineVoiceOptions options;};
    OfflineVoiceSettingsStore store_;OfflineVoiceSettings settings_;Destination destination_;Insert insert_;HWND owner_{};Factory factory_;SettingsChanged settings_changed_;std::shared_ptr<Session> session_;Phase phase_=Phase::idle;bool closed_{},loaded_{},populating_{},dirty_{},finish_after_prepare_{};std::uint64_t generation_{},models_generation_{};std::string load_error_;std::vector<std::string> models_;
    Grid root_{nullptr};Toggle enabled_{nullptr},shortcut_enabled_{nullptr};TextBox executable_{nullptr};ComboBox model_{nullptr},language_{nullptr},shortcut_mode_{nullptr};NumberBox threads_{nullptr};Button choose_{nullptr},refresh_{nullptr},save_{nullptr},record_{nullptr},stop_{nullptr},cancel_{nullptr};TextBlock status_{nullptr};
    VoicePanel(std::filesystem::path directory,Destination destination,Insert insert,HWND owner,Factory factory,SettingsChanged settings_changed):store_(std::move(directory)),destination_(std::move(destination)),insert_(std::move(insert)),owner_(owner),factory_(factory?std::move(factory):Factory{[]{return std::make_shared<NativeVoiceTransport>();}}),settings_changed_(std::move(settings_changed)){}
    static void identify(const winrt::Microsoft::UI::Xaml::DependencyObject& element,const wchar_t* name){winrt::Microsoft::UI::Xaml::Automation::AutomationProperties::SetAutomationId(element,name);}
    void update(){
        if(!root_)return;const bool idle=phase_==Phase::idle&&!closed_;for(const auto& button:{choose_,refresh_})button.IsEnabled(idle&&loaded_);enabled_.IsEnabled(idle&&loaded_);model_.IsEnabled(idle&&loaded_);language_.IsEnabled(idle&&loaded_);threads_.IsEnabled(idle&&loaded_);shortcut_enabled_.IsEnabled(idle&&loaded_);shortcut_mode_.IsEnabled(idle&&loaded_);
        save_.IsEnabled(idle&&loaded_&&(dirty_||(settings_.enabled&&settings_.shortcut_enabled)));record_.IsEnabled(idle&&loaded_&&!dirty_&&settings_.enabled&&static_cast<bool>(destination_)&&static_cast<bool>(insert_));stop_.IsEnabled(phase_==Phase::recording&&!closed_);cancel_.IsEnabled(!idle&&!closed_);
    }
    void changed(){if(populating_)return;dirty_=true;status_.Text(ui_text(L"Save voice settings before recording."));update();}
    OfflineVoiceSettings draft()const{
        OfflineVoiceSettings value;value.enabled=enabled_.IsOn();value.shortcut_enabled=shortcut_enabled_.IsOn();const auto behavior=shortcut_mode_.SelectedIndex();if(behavior<0||behavior>1)throw std::invalid_argument("Choose a dictation shortcut behavior");value.shortcut_mode=behavior==0?VoiceShortcutMode::hold:VoiceShortcutMode::toggle;value.executable=winrt::to_string(executable_.Text());const auto model=model_.SelectedIndex(),language=language_.SelectedIndex();
        if(model>=0&&static_cast<std::size_t>(model)<models_.size())value.model=models_[model];if(language>=0&&static_cast<std::size_t>(language)<std::size(voice_languages))value.language=voice_languages[language].code;
        const auto threads=threads_.Value();if(!std::isfinite(threads)||threads!=std::floor(threads)||threads<1||threads>16)throw std::invalid_argument("Choose a whole CPU thread count from 1 to 16");value.threads=static_cast<unsigned>(threads);return value;
    }
    void save(){if(closed_||active()||!loaded_)return;try{const auto value=draft();store_.save(value);settings_=value;dirty_=false;const bool registered=!settings_changed_||settings_changed_(settings_);status_.Text(registered?ui_text(L"Saved"):ui_text(L"Saved. The global dictation shortcut is unavailable or already used by another action or app."));}catch(const std::exception& error){status_.Text(winrt::to_hstring(error.what()));}catch(const winrt::hresult_error& error){status_.Text(error.message());}update();}
    void build(){
        namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace xaml=winrt::Microsoft::UI::Xaml;populating_=true;
        root_=Grid{};identify(root_,L"VoicePanel");ui::ScrollViewer scroll;ui::StackPanel body;body.Spacing(10);body.Padding({12,8,12,12});scroll.Content(body);root_.Children().Append(scroll);const auto weak=weak_from_this();
        TextBlock explanation;explanation.Text(ui_text(L"Offline dictation uses a locally installed whisper.cpp CLI and a model in Coincide's model folder. Audio is transcribed on this PC. Text is inserted into the original draft only; it is never sent automatically."));explanation.TextWrapping(xaml::TextWrapping::Wrap);body.Children().Append(explanation);
        enabled_=Toggle{};enabled_.Header(winrt::box_value(ui_text(L"Enable Voice")));identify(enabled_,L"VoiceEnabled");enabled_.IsOn(settings_.enabled);enabled_.Toggled([weak](const auto&,const auto&){if(const auto self=weak.lock())self->changed();});body.Children().Append(enabled_);
        shortcut_enabled_=Toggle{};shortcut_enabled_.Header(winrt::box_value(ui_text(L"Global dictation shortcut: Ctrl+Shift+Space")));identify(shortcut_enabled_,L"VoiceShortcutEnabled");shortcut_enabled_.IsOn(settings_.shortcut_enabled);shortcut_enabled_.Toggled([weak](const auto&,const auto&){if(const auto self=weak.lock())self->changed();});body.Children().Append(shortcut_enabled_);
        shortcut_mode_=ComboBox{};shortcut_mode_.Header(winrt::box_value(ui_text(L"Dictation shortcut behavior")));identify(shortcut_mode_,L"VoiceShortcutMode");shortcut_mode_.Items().Append(winrt::box_value(ui_text(L"Hold to dictate")));shortcut_mode_.Items().Append(winrt::box_value(ui_text(L"Tap to start or stop")));shortcut_mode_.SelectedIndex(settings_.shortcut_mode==VoiceShortcutMode::hold?0:1);shortcut_mode_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->changed();});body.Children().Append(shortcut_mode_);
        TextBlock shortcut_help;shortcut_help.Text(ui_text(L"The global shortcut is off by default. When Voice and this shortcut are enabled, use it from any app to dictate into the selected Coincide conversation. Release a held shortcut to transcribe, or tap again in tap mode. Text is never sent automatically."));shortcut_help.TextWrapping(xaml::TextWrapping::Wrap);body.Children().Append(shortcut_help);
        executable_=TextBox{};executable_.Header(winrt::box_value(ui_text(L"Offline speech engine")));executable_.IsReadOnly(true);executable_.Text(winrt::to_hstring(settings_.executable));identify(executable_,L"VoiceEngine");executable_.TextChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->changed();});body.Children().Append(executable_);
        choose_=Button{};choose_.Content(winrt::box_value(ui_text(L"Choose whisper-cli.exe…")));identify(choose_,L"VoiceChooseEngine");choose_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->choose_engine();});body.Children().Append(choose_);
        TextBlock folder;folder.Text(winrt::hstring(store_.models_root().wstring()));folder.IsTextSelectionEnabled(true);folder.TextWrapping(xaml::TextWrapping::Wrap);identify(folder,L"VoiceModelsFolder");body.Children().Append(folder);
        model_=ComboBox{};model_.Header(winrt::box_value(ui_text(L"Whisper model")));model_.PlaceholderText(ui_text(L"No model selected"));identify(model_,L"VoiceModel");model_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->changed();});body.Children().Append(model_);
        refresh_=Button{};refresh_.Content(winrt::box_value(ui_text(L"Refresh Models")));identify(refresh_,L"VoiceRefreshModels");refresh_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->refresh_models();});body.Children().Append(refresh_);
        language_=ComboBox{};language_.Header(winrt::box_value(ui_text(L"Language")));identify(language_,L"VoiceLanguage");int selected{};for(const auto& language:voice_languages){ui::ComboBoxItem item;item.Content(winrt::box_value(ui_text(language.label)));language_.Items().Append(item);if(settings_.language==language.code)selected=static_cast<int>(language_.Items().Size()-1);}language_.SelectedIndex(selected);language_.SelectionChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->changed();});body.Children().Append(language_);
        threads_=NumberBox{};threads_.Header(winrt::box_value(ui_text(L"CPU threads")));threads_.Minimum(1);threads_.Maximum(16);threads_.SmallChange(1);threads_.Value(settings_.threads);identify(threads_,L"VoiceThreads");threads_.ValueChanged([weak](const auto&,const auto&){if(const auto self=weak.lock())self->changed();});body.Children().Append(threads_);
        save_=Button{};save_.Content(winrt::box_value(ui_text(L"Save")));identify(save_,L"VoiceSave");save_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->save();});body.Children().Append(save_);
        ui::StackPanel controls;controls.Orientation(ui::Orientation::Horizontal);controls.Spacing(8);
        record_=Button{};record_.Content(winrt::box_value(ui_text(L"Record")));identify(record_,L"VoiceRecord");record_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->record();});controls.Children().Append(record_);
        stop_=Button{};stop_.Content(winrt::box_value(ui_text(L"Stop")));identify(stop_,L"VoiceStop");stop_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->finish();});controls.Children().Append(stop_);
        cancel_=Button{};cancel_.Content(winrt::box_value(ui_text(L"Cancel")));identify(cancel_,L"VoiceCancel");cancel_.Click([weak](const auto&,const auto&){if(const auto self=weak.lock())self->cancel();});controls.Children().Append(cancel_);body.Children().Append(controls);
        status_=TextBlock{};status_.TextWrapping(xaml::TextWrapping::Wrap);identify(status_,L"VoiceStatus");status_.Text(load_error_.empty()?(settings_.enabled?ui_text(L"Ready. Choose Record or use an enabled dictation shortcut."):ui_text(L"Voice is off until you enable it. No model or speech engine is downloaded automatically.")):winrt::to_hstring(load_error_));body.Children().Append(status_);populating_=false;update();
    }
    winrt::fire_and_forget refresh_models(){
        const auto lifetime=shared_from_this();if(closed_||active()||!loaded_)co_return;const auto generation=++models_generation_;const auto root=store_.directory();std::vector<std::string> models;std::string error;const winrt::apartment_context ui;
        co_await winrt::resume_background();try{OfflineVoiceSettingsStore reader(root);models=reader.models();}catch(const std::exception& failure){error=failure.what();}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());}
        try{co_await ui;}catch(...){co_return;}if(closed_||generation!=models_generation_||active())co_return;const auto index=model_.SelectedIndex();const auto desired=index>=0&&static_cast<std::size_t>(index)<models_.size()?models_[index]:settings_.model;populating_=true;models_=std::move(models);model_.Items().Clear();for(const auto& name:models_)model_.Items().Append(winrt::box_value(winrt::to_hstring(name)));const auto selected=std::find(models_.begin(),models_.end(),desired);model_.SelectedIndex(selected==models_.end()?-1:static_cast<int>(selected-models_.begin()));populating_=false;if(!error.empty())status_.Text(winrt::to_hstring(error));update();
    }
    void choose_engine(){
        if(closed_||active())return;try{winrt::com_ptr<IFileOpenDialog> dialog;winrt::check_hresult(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(dialog.put())));DWORD options{};winrt::check_hresult(dialog->GetOptions(&options));winrt::check_hresult(dialog->SetOptions(options|FOS_FORCEFILESYSTEM|FOS_FILEMUSTEXIST));COMDLG_FILTERSPEC filter{L"Native executable",L"*.exe"};winrt::check_hresult(dialog->SetFileTypes(1,&filter));const auto result=dialog->Show(owner_);if(result==HRESULT_FROM_WIN32(ERROR_CANCELLED))return;winrt::check_hresult(result);winrt::com_ptr<IShellItem> item;winrt::check_hresult(dialog->GetResult(item.put()));PWSTR path{};winrt::check_hresult(item->GetDisplayName(SIGDN_FILESYSPATH,&path));const winrt::hstring chosen(path);CoTaskMemFree(path);executable_.Text(chosen);}catch(const std::exception& error){status_.Text(winrt::to_hstring(error.what()));}catch(const winrt::hresult_error& error){status_.Text(error.message());}
    }
    static void cancel_locked(const std::shared_ptr<Session>& session){std::lock_guard lock(session->mutex);session->transport->cancel();}
    static winrt::fire_and_forget cancel_worker(std::shared_ptr<Session> session,winrt::Microsoft::UI::Dispatching::DispatcherQueue dispatcher=nullptr,std::weak_ptr<VoicePanel> owner={},std::uint64_t generation=0){
        co_await winrt::resume_background();cancel_locked(session);if(dispatcher&&session->transport->failed())try{dispatcher.TryEnqueue([owner,generation]{if(const auto self=owner.lock();self&&!self->closed_&&self->generation_==generation)self->status_.Text(ui_text(L"Windows did not release the microphone cleanly. Restart Coincide before recording again."));});}catch(...){}
    }
    void cancel_session(){if(session_){auto session=std::move(session_);session->cancelled=true;cancel_worker(std::move(session),closed_?nullptr:root_.DispatcherQueue(),weak_from_this(),generation_);}}
    winrt::fire_and_forget record(){
        const auto lifetime=shared_from_this();if(closed_||active()||dirty_||!loaded_||!settings_.enabled||!destination_||!insert_)co_return;std::shared_ptr<Session> session;
        try{session=std::make_shared<Session>();session->destination=destination_();if(session->destination.thread_id.empty())throw std::runtime_error("Select a conversation before recording");session->options=store_.options(settings_);session->transport=factory_();if(!session->transport)throw std::runtime_error("The voice capture transport is unavailable");}catch(const std::exception& error){status_.Text(winrt::to_hstring(error.what()));co_return;}catch(const winrt::hresult_error& error){status_.Text(error.message());co_return;}
        const auto generation=++generation_;finish_after_prepare_=false;session_=session;phase_=Phase::preparing;status_.Text(ui_text(L"Preparing microphone…"));update();std::string error;const winrt::apartment_context ui;
        co_await winrt::resume_background();try{std::lock_guard lock(session->mutex);if(!session->cancelled){session->transport->prepare(session->options);if(!session->cancelled)session->transport->begin();}}catch(const std::exception& failure){error=failure.what();cancel_locked(session);}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());cancel_locked(session);}
        try{co_await ui;}catch(...){session->cancelled=true;cancel_worker(session);co_return;}if(closed_||generation!=generation_||session->cancelled)co_return;
        if(!error.empty()){session_.reset();phase_=Phase::idle;finish_after_prepare_=false;status_.Text(winrt::to_hstring(error));}else{phase_=Phase::recording;status_.Text(ui_text(L"Recording… Stop to transcribe, or Cancel to discard."));}update();if(finish_after_prepare_&&phase_==Phase::recording){finish_after_prepare_=false;finish();}
    }
    winrt::fire_and_forget finish(){
        const auto lifetime=shared_from_this();if(closed_||phase_!=Phase::recording||!session_)co_return;const auto session=session_;const auto generation=generation_;phase_=Phase::transcribing;status_.Text(ui_text(L"Transcribing…"));update();std::string text,error;const winrt::apartment_context ui;
        co_await winrt::resume_background();try{std::lock_guard lock(session->mutex);auto samples=session->transport->finish();if(!session->cancelled)text=session->transport->transcribe(session->options,samples,&session->cancelled);}catch(const std::exception& failure){error=failure.what();cancel_locked(session);}catch(const winrt::hresult_error& failure){error=winrt::to_string(failure.message());cancel_locked(session);}
        try{co_await ui;}catch(...){session->cancelled=true;cancel_worker(session);co_return;}if(closed_||generation!=generation_||session->cancelled)co_return;session_.reset();phase_=Phase::idle;
        if(!error.empty())status_.Text(winrt::to_hstring(error));else if(text.empty())status_.Text(ui_text(L"No speech was heard."));else try{status_.Text(insert_(session->destination,text)?ui_text(L"Inserted into draft"):ui_text(L"The conversation or draft changed. The transcript was discarded."));}catch(const std::exception& failure){status_.Text(winrt::to_hstring(failure.what()));}catch(const winrt::hresult_error& failure){status_.Text(failure.message());}update();
    }
};
} // namespace coincide
