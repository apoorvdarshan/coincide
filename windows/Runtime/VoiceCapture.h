#pragma once
#include "VoiceAudio.h"
#include <windows.h>
#include <mmsystem.h>
#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <thread>
#pragma comment(lib,"winmm.lib")

namespace coincide {
struct VoiceInputDevice{UINT id{};std::wstring name;};

// Explicit user action only. All lifecycle calls belong to one worker owner; readers may poll
// recording/full/level. Construction/destruction and disabled starts do not open a microphone.
class VoiceCapture {
public:
    static std::vector<VoiceInputDevice> devices(bool enabled){
        std::vector<VoiceInputDevice> result;if(!enabled)return result;const auto count=std::min<UINT>(waveInGetNumDevs(),256);
        for(UINT id=0;id<count;++id){WAVEINCAPSW info{};if(waveInGetDevCapsW(id,&info,sizeof(info))==MMSYSERR_NOERROR)result.push_back({id,info.szPname});}return result;
    }
    static std::unique_ptr<VoiceCapture> start(bool enabled,bool user_requested,UINT device=WAVE_MAPPER){
        if(!enabled||!user_requested)throw std::invalid_argument("Microphone recording requires enabled Voice settings and a direct user action");
        if(driver_failed_)throw std::runtime_error("Windows did not release an earlier recording; restart the app before using the microphone again");
        auto result=std::unique_ptr<VoiceCapture>(new VoiceCapture);result->open(device);return result;
    }
    ~VoiceCapture(){cancel();}
    VoiceCapture(const VoiceCapture&)=delete;VoiceCapture& operator=(const VoiceCapture&)=delete;
    bool recording()const{return !ended_.load();}
    bool full()const{return full_.load();}
    bool failed()const{return failed_.load();}
    static bool restart_required(){return driver_failed_.load();}
    float level()const{return level_.load();}
    std::vector<std::int16_t> finish(){stop();std::lock_guard lock(samples_mutex_);if(failed_){samples_.clear();throw std::runtime_error("Windows could not finish the microphone recording");}return std::move(samples_);}
    void cancel()noexcept{stop();std::lock_guard lock(samples_mutex_);samples_.clear();level_=0;}
private:
    static constexpr std::size_t block_samples=1600,blocks=4;
    friend struct VoiceCaptureFixtureAccess;
    struct DeviceFunctions{decltype(&waveInOpen) open=&waveInOpen;decltype(&waveInPrepareHeader) prepare=&waveInPrepareHeader;decltype(&waveInAddBuffer) add=&waveInAddBuffer;decltype(&waveInStart) start=&waveInStart;decltype(&waveInStop) stop=&waveInStop;decltype(&waveInReset) reset=&waveInReset;decltype(&waveInUnprepareHeader) unprepare=&waveInUnprepareHeader;decltype(&waveInClose) close=&waveInClose;} functions_;
    struct DeviceState{HWAVEIN input{};HANDLE event{};std::array<std::array<std::int16_t,block_samples>,blocks> buffers{};std::array<WAVEHDR,blocks> headers{};std::size_t prepared{};};
    std::unique_ptr<DeviceState> device_=std::make_unique<DeviceState>();inline static std::atomic_bool driver_failed_{};
    std::thread worker_;std::atomic_bool stopping_{},ended_{true},full_{},failed_{};std::atomic<float> level_{};std::mutex samples_mutex_,device_mutex_;std::vector<std::int16_t> samples_;
    VoiceCapture()=default;
    static void check(MMRESULT result){if(result!=MMSYSERR_NOERROR)throw std::runtime_error("Windows could not open the selected microphone; check its availability and microphone privacy settings");}
    void open(UINT device_id){
        auto& device=*device_;device.event=CreateEventW(nullptr,FALSE,FALSE,nullptr);if(!device.event)throw std::runtime_error("Could not create the microphone event");
        WAVEFORMATEX format{};format.wFormatTag=WAVE_FORMAT_PCM;format.nChannels=1;format.nSamplesPerSec=VoiceAudio::sample_rate;format.wBitsPerSample=16;format.nBlockAlign=2;format.nAvgBytesPerSec=VoiceAudio::sample_rate*2;
        check(functions_.open(&device.input,device_id,&format,reinterpret_cast<DWORD_PTR>(device.event),0,CALLBACK_EVENT));samples_.reserve(VoiceAudio::maximum_samples);
        for(auto& header:device.headers){header.lpData=reinterpret_cast<LPSTR>(device.buffers[device.prepared].data());header.dwBufferLength=block_samples*sizeof(std::int16_t);check(functions_.prepare(device.input,&header,sizeof(header)));++device.prepared;check(functions_.add(device.input,&header,sizeof(header)));}
        ended_=false;worker_=std::thread([this]{collect();});check(functions_.start(device.input));
    }
    void collect()noexcept{
        auto& device=*device_;for(;;){const auto wait=WaitForSingleObject(device.event,100);if(wait==WAIT_FAILED){failed_=true;break;}
            bool reached{};for(auto& header:device.headers)if(header.dwFlags&WHDR_DONE){
                const auto count=std::min<std::size_t>(header.dwBytesRecorded/sizeof(std::int16_t),block_samples);
                {std::lock_guard lock(samples_mutex_);const auto remaining=VoiceAudio::maximum_samples-samples_.size();const auto append=std::min(count,remaining);const auto data=std::span(reinterpret_cast<std::int16_t*>(header.lpData),append);level_=VoiceAudio::level(data);samples_.insert(samples_.end(),data.begin(),data.end());reached=samples_.size()==VoiceAudio::maximum_samples;}
                if(reached){full_=true;break;}{std::lock_guard lock(device_mutex_);if(!stopping_&&functions_.add(device.input,&header,sizeof(header))!=MMSYSERR_NOERROR){failed_=true;reached=true;break;}}
            }
            if(reached){std::lock_guard lock(device_mutex_);const auto stopped=functions_.stop(device.input),reset=functions_.reset(device.input);if(stopped!=MMSYSERR_NOERROR||reset!=MMSYSERR_NOERROR)failed_=true;break;}if(stopping_)break;
        }ended_=true;
    }
    void stop()noexcept{
        if(!device_){ended_=true;return;}auto& device=*device_;stopping_=true;
        if(device.input){std::lock_guard lock(device_mutex_);const auto stopped=functions_.stop(device.input),reset=functions_.reset(device.input);if(stopped!=MMSYSERR_NOERROR||reset!=MMSYSERR_NOERROR)failed_=true;}
        if(device.event)SetEvent(device.event);if(worker_.joinable())worker_.join();
        if(device.input){
            bool returned=true;for(std::size_t i=0;i<device.prepared;++i)if(functions_.unprepare(device.input,&device.headers[i],sizeof(WAVEHDR))!=MMSYSERR_NOERROR)returned=false;
            if(returned&&functions_.close(device.input)==MMSYSERR_NOERROR)device.input=nullptr;
            else {
                // A broken driver may still own these buffers/event. Retain that small, fixed
                // allocation until process exit, fail visibly and forbid another recording.
                // Freeing the headers here would allow an asynchronous driver use-after-free.
                failed_=true;driver_failed_=true;(void)device_.release();ended_=true;return;
            }
        }
        if(device.event){CloseHandle(device.event);device.event=nullptr;}device_.reset();ended_=true;
    }
};
} // namespace coincide
