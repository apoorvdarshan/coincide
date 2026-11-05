#pragma once
#include "../App/VoicePanel.h"
#include "InstructionImportPanelTests.h"

namespace coincide {
namespace voice_panel_fixture {
struct State{std::atomic<unsigned> prepared{},started{},finished{},cancelled{},transcribed{};std::atomic_bool block{};};
class Transport final:public VoiceTransport {
    std::shared_ptr<State> state_;
public:
    explicit Transport(std::shared_ptr<State> state):state_(std::move(state)){}
    void prepare(const OfflineVoiceOptions&)override{++state_->prepared;}
    void begin()override{++state_->started;}
    std::vector<std::int16_t> finish()override{++state_->finished;return std::vector<std::int16_t>(8000,500);}
    void cancel()noexcept override{++state_->cancelled;}
    bool failed()const noexcept override{return false;}
    std::string transcribe(const OfflineVoiceOptions&,std::span<const std::int16_t>,const std::atomic_bool* cancelled)override{
        ++state_->transcribed;const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(3);while(state_->block&&!cancelled->load()&&std::chrono::steady_clock::now()<deadline)std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if(cancelled->load())throw std::runtime_error("Owned synthetic transcription cancelled");return "Owned voice draft — 你好";
    }
};
}
inline int voice_panel_tests(const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& xaml_root){
    namespace f=instruction_import_panel_fixture;namespace ui=f::ui;
    std::size_t checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error("check "+std::to_string(checks)+": "+message);};std::shared_ptr<VoicePanel> panel;ui::Panel host{nullptr};
    const auto detach=[&]{if(panel){panel->close();std::uint32_t index{};if(host&&host.Children().IndexOf(panel->view(),index))host.Children().RemoveAt(index);panel.reset();}f::pump();};
    try{
        if(!xaml_root||(host=xaml_root.Content().try_as<ui::Panel>())==nullptr)throw std::runtime_error("Voice UI fixtures require an initialized hidden native Panel");
        instruction_import_fixture::Directory owned;const auto root=owned.path/L"Voice";const auto executable=owned.write(L"fake speech.exe","Owned metadata only — never executed");owned.write(L"Voice/models/owned.bin",std::string(32,'m'));
        OfflineVoiceSettingsStore store(root);auto settings=store.open();settings.executable=winrt::to_string(executable.wstring());settings.model="owned.bin";store.save(settings);
        auto state=std::make_shared<voice_panel_fixture::State>();VoiceDestination current{"owned-thread-one",7};unsigned attempts{},inserted{};std::string draft;
        panel=VoicePanel::create(root,[&]{return current;},[&](const VoiceDestination& origin,const std::string& text){++attempts;if(origin.thread_id!=current.thread_id||origin.draft_revision!=current.draft_revision)return false;++inserted;draft=text;return true;},nullptr,[state]{return std::make_shared<voice_panel_fixture::Transport>(state);});host.Children().Append(panel->view());
        const auto record=f::control<ui::Button>(panel->view(),L"VoiceRecord"),save=f::control<ui::Button>(panel->view(),L"VoiceSave");const auto models=f::control<ui::ComboBox>(panel->view(),L"VoiceModel");
        check(f::until([&]{return models.Items().Size()==1&&models.SelectedIndex()==0;})&&!record.IsEnabled()&&state->started==0&&state->prepared==0,"opening disabled Voice settings must discover only owned model metadata without starting a microphone or engine");
        f::control<ui::ToggleSwitch>(panel->view(),L"VoiceEnabled").IsOn(true);f::control<ui::ComboBox>(panel->view(),L"VoiceLanguage").SelectedIndex(1);f::control<ui::NumberBox>(panel->view(),L"VoiceThreads").Value(2);
        check(save.IsEnabled()&&!record.IsEnabled(),"editing Voice settings must require an explicit save before recording");f::invoke(panel->view(),L"VoiceSave");OfflineVoiceSettingsStore reopened(root);const auto restored=reopened.open();
        check(restored.enabled&&restored.language=="en"&&restored.threads==2&&record.IsEnabled()&&state->started==0,"native Save must persist selected voice options without recording");
        f::invoke(panel->view(),L"VoiceRecord");check(f::until([&]{return panel->phase()==VoicePanel::Phase::recording;})&&state->started==1&&attempts==0,"only explicit native Record may start the synthetic capture transport");
        ++current.draft_revision;f::invoke(panel->view(),L"VoiceStop");check(f::until([&]{return panel->phase()==VoicePanel::Phase::idle;})&&attempts==1&&inserted==0&&draft.empty(),"a changed originating draft must reject final transcript insertion");
        f::invoke(panel->view(),L"VoiceRecord");check(f::until([&]{return panel->phase()==VoicePanel::Phase::recording;}),"a settled recording must allow a later explicit recording");f::invoke(panel->view(),L"VoiceStop");
        check(f::until([&]{return panel->phase()==VoicePanel::Phase::idle;})&&attempts==2&&inserted==1&&draft=="Owned voice draft — 你好","explicit Stop must insert only into the matching original draft; no send or queue action exists");
        f::invoke(panel->view(),L"VoiceRecord");check(f::until([&]{return panel->phase()==VoicePanel::Phase::recording;}),"a third synthetic recording must start only after native action");const auto cancellations=state->cancelled.load();f::invoke(panel->view(),L"VoiceCancel");
        check(f::until([&]{return state->cancelled>cancellations;})&&panel->phase()==VoicePanel::Phase::idle&&attempts==2,"Cancel while recording must discard captured audio without inserting text");
        state->block=true;f::invoke(panel->view(),L"VoiceRecord");check(f::until([&]{return panel->phase()==VoicePanel::Phase::recording;}),"a cancellable synthetic transcription fixture must record explicitly");f::invoke(panel->view(),L"VoiceStop");check(f::until([&]{return state->transcribed>=3&&panel->phase()==VoicePanel::Phase::transcribing;}),"transcription must run on a worker while native Cancel remains available");const auto before_cancel=state->cancelled.load();f::invoke(panel->view(),L"VoiceCancel");
        check(f::until([&]{return state->cancelled>before_cancel;})&&attempts==2&&inserted==1,"cancelling a running transcription must block late draft insertion");
        state->block=false;f::invoke(panel->view(),L"VoiceRecord");check(f::until([&]{return panel->phase()==VoicePanel::Phase::recording;}),"changing the selected thread must not alter the existing recording origin");current.thread_id="owned-thread-two";f::invoke(panel->view(),L"VoiceStop");
        check(f::until([&]{return panel->phase()==VoicePanel::Phase::idle;})&&attempts==3&&inserted==1,"cross-thread transcript insertion must be rejected by the captured destination identity");
        state->block=true;f::invoke(panel->view(),L"VoiceRecord");check(f::until([&]{return panel->phase()==VoicePanel::Phase::recording;}),"shutdown fixture starts only after the explicit Record action");f::invoke(panel->view(),L"VoiceStop");check(f::until([&]{return state->transcribed>=5;}),"shutdown fixture must reach its synthetic worker before closing");const auto before_close=state->cancelled.load();panel->close();
        check(f::until([&]{return state->cancelled>before_close;})&&attempts==3&&inserted==1,"closing VoicePanel must cancel its owned work and suppress completion callbacks");
        check(local_file::read(executable,1024).bytes=="Owned metadata only — never executed","native Voice UI fixtures must never execute their metadata-only speech engine file");
        detach();std::ofstream output(report);output<<"PASS: "<<checks<<" Windows synthetic voice native panel checks; no microphone/engine execution\n";return output?0:2;
    }catch(const std::exception& error){detach();std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}catch(const winrt::hresult_error& error){detach();std::ofstream(report)<<"FAIL: Windows Voice panel API error "<<static_cast<unsigned>(error.code())<<'\n';return 1;}
}
} // namespace coincide
