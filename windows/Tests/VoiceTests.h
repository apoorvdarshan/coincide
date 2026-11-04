#pragma once
#include "../Runtime/OfflineVoice.h"
#include "../Runtime/VoiceCapture.h"
#include <fstream>

namespace coincide {
struct VoiceCaptureFixtureAccess {
    inline static bool fail_reset{},fail_unprepare{},fail_close{};
    inline static unsigned stopped{},resets{},unprepared{},closed{};
    static MMRESULT WINAPI stop(HWAVEIN){++stopped;return MMSYSERR_NOERROR;}
    static MMRESULT WINAPI reset(HWAVEIN){++resets;return fail_reset?MMSYSERR_ERROR:MMSYSERR_NOERROR;}
    static MMRESULT WINAPI unprepare(HWAVEIN,LPWAVEHDR header,UINT){++unprepared;if(fail_unprepare)return WAVERR_STILLPLAYING;header->dwFlags&=~WHDR_PREPARED;return MMSYSERR_NOERROR;}
    static MMRESULT WINAPI close(HWAVEIN){++closed;return fail_close?WAVERR_STILLPLAYING:MMSYSERR_NOERROR;}
    // Inject only teardown functions and an owned event; no waveInOpen/device query occurs.
    static bool teardown(bool reset_failure,bool buffer_failure,bool close_failure){
        if(VoiceCapture::driver_failed_)throw std::runtime_error("An earlier fixture did not restore its synthetic driver state");
        fail_reset=reset_failure;fail_unprepare=buffer_failure;fail_close=close_failure;stopped=resets=unprepared=closed=0;
        auto capture=std::unique_ptr<VoiceCapture>(new VoiceCapture);auto* state=capture->device_.get();state->input=reinterpret_cast<HWAVEIN>(1);state->event=CreateEventW(nullptr,FALSE,FALSE,nullptr);if(!state->event)throw std::runtime_error("Owned voice teardown event creation failed");
        state->prepared=1;state->headers[0].dwFlags=WHDR_PREPARED;capture->functions_.stop=&stop;capture->functions_.reset=&reset;capture->functions_.unprepare=&unprepare;capture->functions_.close=&close;
        capture->cancel();const bool retained=buffer_failure||close_failure;
        const bool passed=!capture->recording()&&stopped==1&&resets==1&&unprepared==1&&closed==(buffer_failure?0u:1u)&&capture->failed()==(reset_failure||retained)&&VoiceCapture::driver_failed_.load()==retained&&!capture->device_;
        capture.reset();if(retained){state->buffers[0][0]=123;CloseHandle(state->event);delete state;VoiceCapture::driver_failed_=false;}return passed;
    }
};
// The fixture executable must be the separately built, test-only VoiceFixture.cpp. No actual
// microphone, installed speech engine, models, account, network, or user settings are touched.
inline int voice_tests(const std::filesystem::path& report,const std::filesystem::path& fixture_executable){
    std::size_t checks{};const auto check=[&](bool result,const char* message){++checks;if(!result)throw std::runtime_error(message);};const auto rejects=[&](auto action,const char* message){bool rejected{};try{action();}catch(...){rejected=true;}check(rejected,message);};
    struct Directory{std::filesystem::path path;Directory(){winrt::guid id;winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&id)));path=std::filesystem::temp_directory_path()/(L"Coincide-Voice-Fixture-"+std::wstring(winrt::to_hstring(id)));std::filesystem::create_directory(path);}~Directory(){std::error_code error;std::filesystem::remove_all(path,error);}};
    try{
        Directory owned;const auto engine=owned.path/L"engine 空格"/L"whisper fixture.exe";std::filesystem::create_directory(engine.parent_path());std::filesystem::copy_file(fixture_executable,engine);
        const auto model_root=owned.path/L"models 空格",working=owned.path/L"private audio";std::filesystem::create_directory(model_root);std::filesystem::create_directory(working);
        const auto model=[&](const wchar_t* name){const auto path=model_root/name;std::ofstream file(path,std::ios::binary);file<<std::string(32,'m');return path;};
        OfflineVoiceOptions options{engine,model_root,model(L"owned model.bin"),working,"hi",2,std::chrono::seconds(3)};
        const std::vector<std::int16_t> pcm(8000,1000);const auto wav=VoiceAudio::wav(std::array<std::int16_t,3>{0,32767,-32768});
        check(wav.size()==50&&wav.substr(0,4)=="RIFF"&&wav.substr(36,4)=="data"&&static_cast<unsigned char>(wav[46])==255&&static_cast<unsigned char>(wav[47])==127&&static_cast<unsigned char>(wav[49])==128,"synthetic voice WAV must encode exact little-endian PCM16 mono samples");
        check(VoiceAudio::level({})==0&&VoiceAudio::level(pcm)>0&&VoiceAudio::level(pcm)<1,"voice meter must handle empty and bounded synthetic samples");
        const auto text=OfflineVoice::transcribe(options,pcm);
        check(text=="Owned offline fixture — 你好\nLanguage: hi","offline adapter must preserve UTF-8 output, explicit language, Unicode paths and isolated argument boundaries");
        check(std::filesystem::is_empty(working),"successful offline transcription must remove only its private recording/result directory");
        check(OfflineVoice::transcribe(options,std::span(pcm).first(4000)).empty()&&std::filesystem::is_empty(working),"short key slips must return without launching the offline engine or saving audio");
        const auto original_model=std::filesystem::file_size(options.model);std::ofstream(working/L"unrelated.txt")<<"preserve unrelated work";
        options.model=model(L"failure.bin");rejects([&]{OfflineVoice::transcribe(options,pcm);},"nonzero native engine exits must not produce a transcript");
        options.model=model(L"invalid.bin");rejects([&]{OfflineVoice::transcribe(options,pcm);},"invalid UTF-8 or NUL output must not enter a composer");
        options.model=model(L"oversized.bin");rejects([&]{OfflineVoice::transcribe(options,pcm);},"offline transcript files must obey their read bound");
        options.model=model(L"missing.bin");rejects([&]{OfflineVoice::transcribe(options,pcm);},"a successful engine exit without an output file must fail honestly");
        options.model=model(L"flood.bin");rejects([&]{OfflineVoice::transcribe(options,pcm);},"excess engine stdout must terminate the owned job without hanging");
        options.model=model(L"slow.bin");options.timeout=std::chrono::milliseconds(75);const auto start=std::chrono::steady_clock::now();rejects([&]{OfflineVoice::transcribe(options,pcm);},"offline engine deadlines must terminate the owned job");
        check(std::chrono::steady_clock::now()-start<std::chrono::seconds(2),"offline timeouts must not wait for the fake slow engine to finish");
        options.timeout=std::chrono::seconds(3);std::atomic_bool cancelled{};std::thread cancel([&]{std::this_thread::sleep_for(std::chrono::milliseconds(75));cancelled=true;});bool rejected{};try{OfflineVoice::transcribe(options,pcm,&cancelled);}catch(...){rejected=true;}cancel.join();check(rejected,"in-flight cancellation must reject the owned offline result");
        const auto before=std::chrono::steady_clock::now();rejects([&]{OfflineVoice::transcribe(options,pcm,&cancelled);},"pre-cancelled recordings must never launch an engine");check(std::chrono::steady_clock::now()-before<std::chrono::seconds(1),"pre-cancellation must return promptly");
        check(std::filesystem::is_regular_file(working/L"unrelated.txt")&&std::distance(std::filesystem::directory_iterator(working),std::filesystem::directory_iterator{})==1,"offline failure/cancel cleanup must preserve unrelated files and remove every owned recording");
        options.model=model(L"normal.bin");options.language="en --file other";rejects([&]{OfflineVoice::transcribe(options,pcm);},"language inputs must never inject CLI flags");options.language="auto";
        options.threads=0;rejects([&]{OfflineVoice::validate(options);},"offline thread resources must be explicit and bounded");options.threads=2;
        options.model=owned.path/L"outside.bin";std::ofstream(options.model)<<std::string(32,'m');rejects([&]{OfflineVoice::validate(options);},"offline models outside the app model root must be rejected");
        options.model=model(L"empty.bin");std::ofstream(options.model,std::ios::trunc);rejects([&]{OfflineVoice::validate(options);},"missing or empty optional models must fail before launch");
        options.model=model(L"normal.bin");options.executable=owned.path/L"metadata-only.exe";std::ofstream(options.executable)<<"This is not a native executable";rejects([&]{OfflineVoice::validate(options);},"an .exe filename without a native Windows binary must fail before microphone preparation");
        check(std::filesystem::file_size(model_root/L"owned model.bin")==original_model,"offline validation and engine jobs must leave original models unchanged");
        rejects([&]{VoiceCapture::start(false,true);},"disabled Voice settings must block microphone opens before any device access");rejects([&]{VoiceCapture::start(true,false);},"recording must require a direct user request before any device access");
        check(VoiceCapture::devices(false).empty(),"disabled input discovery must not query microphone devices");
        check(VoiceCaptureFixtureAccess::teardown(false,false,false),"synthetic microphone teardown must stop/reset, unprepare and close before freeing buffers/event");
        check(VoiceCaptureFixtureAccess::teardown(true,false,false),"a synthetic reset failure must remain visible even when later close succeeds");
        check(VoiceCaptureFixtureAccess::teardown(true,true,false),"a driver that retains queued headers must keep buffers/event alive and block another recording");
        check(VoiceCaptureFixtureAccess::teardown(false,false,true),"a failed microphone close must retain driver-owned memory rather than freeing live headers");
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows offline voice synthetic checks; microphone and real recognition not exercised\n";return output?0:2;
    }catch(const std::exception& error){std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';return 1;}catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL: Windows offline voice API error "<<static_cast<unsigned>(error.code())<<'\n';return 1;}
}
} // namespace coincide
