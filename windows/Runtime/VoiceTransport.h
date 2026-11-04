#pragma once
#include "OfflineVoice.h"
#include "VoiceCapture.h"

namespace coincide {
// Interface lets hidden UI fixtures exercise a complete explicit dictation without opening a
// microphone or running an installed engine. Lifecycle calls are serialized on worker tasks.
class VoiceTransport {
public:
    virtual ~VoiceTransport()=default;
    virtual void prepare(const OfflineVoiceOptions&)=0;
    virtual void begin()=0;
    virtual std::vector<std::int16_t> finish()=0;
    virtual void cancel()noexcept=0;
    virtual bool failed()const noexcept=0;
    virtual std::string transcribe(const OfflineVoiceOptions&,std::span<const std::int16_t>,const std::atomic_bool*)=0;
};
class NativeVoiceTransport final:public VoiceTransport {
    std::unique_ptr<VoiceCapture> capture_;std::atomic_bool failed_{};
public:
    void prepare(const OfflineVoiceOptions& options)override{OfflineVoice::validate(options);}
    void begin()override{capture_=VoiceCapture::start(true,true);}
    std::vector<std::int16_t> finish()override{if(!capture_)throw std::runtime_error("No microphone recording is active");try{auto samples=capture_->finish();failed_=VoiceCapture::restart_required();capture_.reset();return samples;}catch(...){failed_=VoiceCapture::restart_required();capture_.reset();throw;}}
    void cancel()noexcept override{if(capture_){capture_->cancel();failed_=VoiceCapture::restart_required();capture_.reset();}}
    bool failed()const noexcept override{return failed_.load();}
    std::string transcribe(const OfflineVoiceOptions& options,std::span<const std::int16_t> samples,const std::atomic_bool* cancellation)override{return OfflineVoice::transcribe(options,samples,cancellation);}
};
} // namespace coincide
