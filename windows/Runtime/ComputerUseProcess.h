#pragma once
#include "ComputerUsePolicy.h"
#include "WindowsProcess.h"
#include <condition_variable>
#include <thread>

namespace coincide::computer_use {
// One serialized request at a time, with a disposable owned native helper job. A failure is
// never replayed. Killing/restarting the helper changes generation and invalidates observations.
class ProcessBackend final:public Backend {
    std::filesystem::path executable_,cwd_;DWORD owner_{};std::chrono::milliseconds timeout_;
    std::unique_ptr<WindowsProcess> process_;std::atomic<std::uint64_t> epoch_{1};std::mutex output_;
    LineFramer framer_{4*1024*1024};std::vector<std::string> responses_;std::string channel_error_;
    void start(){
        if(process_)return;framer_=LineFramer{4*1024*1024};responses_.clear();channel_error_.clear();
        process_=WindowsProcess::start_bytes(executable_,{L"--computer-use-helper",std::to_wstring(owner_)},cwd_,[this](std::string_view bytes){
            std::lock_guard lock(output_);try{framer_.consume(bytes,[&](std::string line){if(responses_.size()>=2)throw std::runtime_error("Unexpected native helper output");responses_.push_back(std::move(line));});}catch(...){channel_error_="The native helper exceeded its response boundary";}
        },64*1024*1024);++epoch_;
    }
public:
    ProcessBackend(std::filesystem::path executable,std::filesystem::path cwd,DWORD owning_app_pid,std::chrono::milliseconds timeout=std::chrono::seconds(10)):executable_(std::move(executable)),cwd_(std::move(cwd)),owner_(owning_app_pid),timeout_(timeout){
        if(!executable_.is_absolute()||!cwd_.is_absolute()||!std::filesystem::is_regular_file(executable_)||!std::filesystem::is_directory(cwd_)||!owner_||timeout_<std::chrono::milliseconds(100)||timeout_>std::chrono::seconds(30))throw std::invalid_argument("Computer Use needs an available owned native helper and bounded timeout");
    }
    std::uint64_t generation()const override{return epoch_.load();}
    void release_controls(const std::string& thread)override{if(!process_)return;Object value;put(value,L"thread",identifier(thread));put(value,L"operation","release_controls");value.SetNamedValue(L"arguments",Object{});(void)request(value,[]{return false;});}
    void stop()noexcept override{if(process_){process_->stop();process_.reset();++epoch_;}std::lock_guard lock(output_);responses_.clear();channel_error_.clear();}
    Object request(const Object& value,const std::function<bool()>& cancelled)override{
        if(cancelled())throw std::runtime_error("Computer Use permission was revoked");const auto request_id=random_id();auto outgoing=Object::Parse(value.Stringify());put(outgoing,L"request_id",request_id);const auto bytes=winrt::to_string(outgoing.Stringify());if(bytes.size()>262144)throw std::invalid_argument("Native helper request exceeds its bound");start();
        std::atomic_bool wrote{},write_failed{};std::thread writer([&]{try{process_->write_line(bytes);}catch(...){write_failed=true;}wrote=true;});
        struct Join{std::thread& thread;~Join(){if(thread.joinable())thread.join();}} join{writer};const auto deadline=std::chrono::steady_clock::now()+timeout_;
        std::optional<std::string> pending;try{for(;;){
            if(cancelled())throw std::runtime_error("Computer Use was revoked during the native request");
            if(std::chrono::steady_clock::now()>=deadline)throw std::runtime_error("The native Computer Use helper timed out; no action was replayed");
            if(write_failed)throw std::runtime_error("The native helper input channel closed");
            {std::lock_guard lock(output_);if(!channel_error_.empty())throw std::runtime_error(channel_error_);if(!responses_.empty()){if(pending||responses_.size()!=1)throw std::runtime_error("Unexpected extra Computer Use response");pending=std::move(responses_.front());responses_.erase(responses_.begin());}}
            // A helper can emit output before reading its input. Never join a still-blocked
            // pipe writer merely because a response arrived; deadline/revocation stay active.
            if(pending&&wrote){if(writer.joinable())writer.join();if(cancelled())throw std::runtime_error("Computer Use permission was revoked");const auto object=Object::Parse(winrt::to_hstring(*pending));keys(object,{L"result",L"error",L"request_id"});if(text(object,L"request_id")!=request_id||object.HasKey(L"result")==object.HasKey(L"error"))throw std::runtime_error("The native helper response does not match its request");if(object.HasKey(L"error"))throw std::runtime_error(text(object,L"error"));return object.GetNamedObject(L"result");}
            if(wrote&&process_->wait(std::chrono::milliseconds(0)))throw std::runtime_error("The native helper exited; observe again before another action");Sleep(10);
        }}catch(...){if(process_)process_->stop();if(writer.joinable())writer.join();stop();throw;}
    }
    ~ProcessBackend(){stop();}
};
} // namespace coincide::computer_use
