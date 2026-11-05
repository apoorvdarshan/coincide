#pragma once
#include "BackgroundHost.h"
#include <atomic>
#include <array>
#include <memory>

namespace coincide::background_host {
class OutcomeUncertain:public std::runtime_error {public:OutcomeUncertain():std::runtime_error("The background-host response was not confirmed. Preserve the delivery ID and review its durable status; do not resend the turn."){} };
namespace pipe_io {
inline constexpr std::size_t maximum=4*1024*1024;
inline std::atomic<unsigned> quarantined{};
// Every kernel-referenced byte belongs to this heap operation. On an exceptional deadline
// the entire OVERLAPPED/event/buffer remains alive until completion, or process lifetime if
// cancellation itself cannot settle. No caller stack/string buffer is submitted to the OS.
struct Operation {OVERLAPPED value{};Handle event;std::vector<char> bytes;bool pending{};explicit Operation(std::size_t size=0):bytes(size){if(quarantined)throw std::runtime_error("Private host IPC is disabled after incomplete cancellation");event.reset(CreateEventW(nullptr,TRUE,FALSE,nullptr));if(!event)winrt::throw_last_error();value.hEvent=event.value;}};
struct Completion {DWORD bytes{},error{ERROR_OPERATION_ABORTED};};
// Cancellation can lose the race to a successful completion. Settle the exact operation
// before inspecting its final result; a signaled event alone does not distinguish success
// from ERROR_OPERATION_ABORTED. Exceptional/owner-stop callers deliberately ignore success.
inline Completion cancel(HANDLE pipe,std::unique_ptr<Operation>& operation){
    if(!operation||!operation->pending)return{};
    (void)CancelIoEx(pipe,&operation->value);
    if(WaitForSingleObject(operation->event.value,1000)!=WAIT_OBJECT_0){++quarantined;operation.release();throw std::runtime_error("A canceled private host pipe did not settle; further IPC is disabled");}
    DWORD copied{};const auto completed=GetOverlappedResult(pipe,&operation->value,&copied,FALSE);const auto error=completed?ERROR_SUCCESS:GetLastError();
    if(!completed&&error==ERROR_IO_INCOMPLETE){++quarantined;operation.release();throw std::runtime_error("A canceled private host pipe did not settle; further IPC is disabled");}
    operation->pending=false;return{copied,error};
}
inline DWORD await(HANDLE pipe,std::unique_ptr<Operation>& operation,std::uint64_t deadline,const std::function<void()>& tick,const std::function<bool()>& stop){
    try{for(;;){
        const auto status=WaitForSingleObject(operation->event.value,10);
        if(status==WAIT_OBJECT_0){
            if(stop&&stop())throw std::runtime_error("The private host pipe deadline expired");
            DWORD copied{};const auto completed=GetOverlappedResult(pipe,&operation->value,&copied,FALSE);const auto error=completed?ERROR_SUCCESS:GetLastError();
            if(!completed){if(error!=ERROR_IO_INCOMPLETE)operation->pending=false;throw std::runtime_error("The private host pipe closed");}
            operation->pending=false;return copied;
        }
        if(status!=WAIT_TIMEOUT)throw std::runtime_error("The private host pipe wait failed");
        if(stop&&stop())throw std::runtime_error("The private host pipe deadline expired");
        if(GetTickCount64()>=deadline){const auto completion=cancel(pipe,operation);if(completion.error==ERROR_SUCCESS)return completion.bytes;throw std::runtime_error("The private host pipe deadline expired");}
        if(tick)tick();
    }}catch(...){cancel(pipe,operation);throw;}
}
inline void transfer(HANDLE pipe,bool write,char* bytes,std::size_t size,std::uint64_t deadline,const std::function<void()>& tick={},const std::function<bool()>& stop={}){if(quarantined)throw std::runtime_error("Private host IPC is disabled after incomplete cancellation");std::size_t at{};while(at<size){const auto amount=static_cast<DWORD>(std::min<std::size_t>(size-at,65536));auto operation=std::make_unique<Operation>(amount);if(write)std::copy_n(bytes+at,amount,operation->bytes.data());DWORD copied{};const auto done=write?WriteFile(pipe,operation->bytes.data(),amount,&copied,&operation->value):ReadFile(pipe,operation->bytes.data(),amount,&copied,&operation->value);if(!done){if(GetLastError()!=ERROR_IO_PENDING)throw std::runtime_error("The private host pipe disconnected");operation->pending=true;copied=await(pipe,operation,deadline,tick,stop);}if(!copied||copied>amount)throw std::runtime_error("The private host pipe returned an invalid transfer length");if(!write)std::copy_n(operation->bytes.data(),copied,bytes+at);at+=copied;}}
inline Handle connect(const Scope& scope,std::uint64_t deadline){for(;;){Handle pipe(CreateFileW(scope.pipe().c_str(),GENERIC_READ|GENERIC_WRITE|READ_CONTROL,0,nullptr,OPEN_EXISTING,FILE_FLAG_OVERLAPPED|SECURITY_SQOS_PRESENT|SECURITY_IDENTIFICATION,nullptr));if(pipe)return pipe;if(GetLastError()!=ERROR_PIPE_BUSY||GetTickCount64()>=deadline)throw std::runtime_error("The authenticated background host is unavailable");WaitNamedPipeW(scope.pipe().c_str(),25);}}
inline void send(HANDLE pipe,std::string bytes,std::uint64_t deadline,const std::function<void()>& tick={},const std::function<bool()>& stop={}){if(bytes.empty()||bytes.size()>maximum)throw std::invalid_argument("Host IPC frame exceeds its bound");const auto size=static_cast<std::uint32_t>(bytes.size());std::array<char,4> header{};for(unsigned i=0;i<4;++i)header[i]=static_cast<char>((size>>(i*8))&255);transfer(pipe,true,header.data(),header.size(),deadline,tick,stop);transfer(pipe,true,bytes.data(),bytes.size(),deadline,tick,stop);}
inline std::string receive(HANDLE pipe,std::uint64_t deadline,const std::function<void()>& tick={},const std::function<bool()>& stop={}){std::array<char,4> header{};transfer(pipe,false,header.data(),header.size(),deadline,tick,stop);std::uint32_t size{};for(unsigned i=0;i<4;++i)size|=static_cast<std::uint32_t>(static_cast<unsigned char>(header[i]))<<(i*8);if(!size||size>maximum)throw std::runtime_error("Invalid bounded host IPC frame");std::string bytes(size,'\0');transfer(pipe,false,bytes.data(),bytes.size(),deadline,tick,stop);if(!local_file::utf8(bytes)||bytes.find('\0')!=std::string::npos)throw std::runtime_error("Host IPC requires bounded UTF-8 JSON");return bytes;}
}
class Server {
    Core& core_;std::shared_ptr<Scope> scope_;std::vector<FileIdentity> peer_images_;Handle pipe_;
public:
    // Override peer_image only in an owned synthetic fixture. Production uses this exact app
    // image by default; no request payload can select a trusted executable or factory.
    Server(Core& core,std::shared_ptr<Scope> scope,std::vector<FileIdentity> fixture_peer_images={}):core_(core),scope_(std::move(scope)),peer_images_(std::move(fixture_peer_images)){if(peer_images_.empty())peer_images_.push_back(file_identity(current_image()));if(peer_images_.size()>2)throw std::invalid_argument("Too many fixture host identities");UserSecurity security(scope_->sid());pipe_.reset(CreateNamedPipeW(scope_->pipe().c_str(),PIPE_ACCESS_DUPLEX|FILE_FLAG_OVERLAPPED|FILE_FLAG_FIRST_PIPE_INSTANCE,PIPE_TYPE_BYTE|PIPE_READMODE_BYTE|PIPE_WAIT|PIPE_REJECT_REMOTE_CLIENTS,1,65536,65536,0,&security.attributes));if(!pipe_)throw std::runtime_error("Another process owns the private host endpoint");verify_security(pipe_.value,scope_->sid(),SE_FILE_OBJECT);}
    bool serve_once(std::chrono::milliseconds connect_timeout=std::chrono::milliseconds(250),const std::function<bool()>& stop={}){const auto tick=[&]{try{core_.pump();}catch(...){} };auto operation=std::make_unique<pipe_io::Operation>();const auto connected=ConnectNamedPipe(pipe_.value,&operation->value);const auto error=connected?ERROR_SUCCESS:GetLastError();if(!connected&&error==ERROR_IO_PENDING){operation->pending=true;try{(void)pipe_io::await(pipe_.value,operation,GetTickCount64()+static_cast<std::uint64_t>(connect_timeout.count()),tick,stop);}catch(...){DisconnectNamedPipe(pipe_.value);return false;}}else if(!connected&&error!=ERROR_PIPE_CONNECTED)throw std::runtime_error("The private host listener failed");struct Disconnect{HANDLE pipe;~Disconnect(){CancelIoEx(pipe,nullptr);DisconnectNamedPipe(pipe);}}disconnect{pipe_.value};
        try{
            if(stop&&stop())return false;
            Handle peer;for(const auto& expected:peer_images_)try{peer=authenticate_peer(pipe_.value,true,*scope_,expected);break;}catch(...){}
            if(!peer)throw std::runtime_error("The client is not this trusted app");
            const auto deadline=GetTickCount64()+5000;
            const auto incoming=Object::Parse(winrt::to_hstring(pipe_io::receive(pipe_.value,deadline,tick,stop)));
            keys(incoming,{L"version",L"scope",L"command"});
            if(integer(incoming,L"version")!=1||text(incoming,L"scope",64)!=scope_->id())throw std::runtime_error("Background-host protocol/scope mismatch");
            const auto command_value=command(incoming.GetNamedObject(L"command"));
            if(stop&&stop())return false;
            Object reply;put(reply,L"id",command_value.id);put(reply,L"scope",scope_->id());reply.SetNamedValue(L"version",Value::CreateNumberValue(1));
            try{reply.SetNamedValue(L"result",core_.perform(command_value));}catch(...){put(reply,L"error","The host refused this request; preserve its delivery ID and review the durable session state");}
            pipe_io::send(pipe_.value,winrt::to_string(reply.Stringify()),deadline,tick,stop);
            char received{};pipe_io::transfer(pipe_.value,false,&received,1,deadline,tick,stop);return received=='A';
        }catch(...){return false;}}

    void run(const std::function<bool()>& stop={},std::chrono::milliseconds idle_grace=std::chrono::seconds(30)){if(idle_grace<std::chrono::milliseconds(100)||idle_grace>std::chrono::minutes(5))throw std::invalid_argument("Invalid host idle grace");std::optional<std::uint64_t> idle_since;while(!(stop&&stop())){const auto served=serve_once(std::chrono::milliseconds(100),stop);const auto now=GetTickCount64();if(core_.busy()){idle_since.reset();continue;}if(core_.retire_requested())break;if(served||!idle_since)idle_since=now;else if(now-*idle_since>=static_cast<std::uint64_t>(idle_grace.count()))break;}}
};
struct EventBatch {SessionInfo session;std::uint64_t after{};std::vector<LoggedEvent> events;};
struct PersistReceipt {std::string epoch;std::uint64_t sequence{};bool transcript_durable{},index_durable{};};
class Client {
    std::shared_ptr<Scope> scope_;FileIdentity expected_;std::chrono::milliseconds timeout_;
public:
    Client(std::shared_ptr<Scope> scope,std::optional<FileIdentity> expected=std::nullopt,std::chrono::milliseconds timeout=std::chrono::seconds(5)):scope_(std::move(scope)),expected_(expected.value_or(file_identity(current_image()))),timeout_(timeout){if(!scope_||timeout<std::chrono::milliseconds(50)||timeout>std::chrono::seconds(30))throw std::invalid_argument("Host client requires a pinned scope and bounded deadline");}
    Object call(const Command& command_value)const{scope_->verify();const auto validated=command(encode(command_value));const auto deadline=GetTickCount64()+static_cast<std::uint64_t>(timeout_.count());auto pipe=pipe_io::connect(*scope_,deadline);auto peer=authenticate_peer(pipe.value,false,*scope_,expected_);verify_security(pipe.value,scope_->sid(),SE_FILE_OBJECT);Object request;request.SetNamedValue(L"version",Value::CreateNumberValue(1));put(request,L"scope",scope_->id());request.SetNamedValue(L"command",encode(validated));try{pipe_io::send(pipe.value,winrt::to_string(request.Stringify()),deadline);const auto response_bytes=pipe_io::receive(pipe.value,deadline);char received='A';pipe_io::transfer(pipe.value,true,&received,1,deadline);const auto response=Object::Parse(winrt::to_hstring(response_bytes));keys(response,{L"version",L"scope",L"id",L"result",L"error"});if(integer(response,L"version")!=1||text(response,L"scope",64)!=scope_->id()||text(response,L"id",38)!=validated.id||response.HasKey(L"result")==response.HasKey(L"error"))throw OutcomeUncertain();if(response.HasKey(L"error"))throw std::runtime_error("The host refused the command; review its durable state before any new input");return response.GetNamedObject(L"result");}catch(const OutcomeUncertain&){throw;}catch(...){throw OutcomeUncertain();}}
    SessionInfo status(Key key,const std::string& epoch)const{Command value;value.operation=Operation::status;value.key=checked(std::move(key));value.epoch=guid(epoch);auto state=info(call(value).GetNamedObject(L"session"));if(state.key!=value.key||state.epoch!=value.epoch||!state.snapshots_included)throw std::runtime_error("The host returned another or incomplete session snapshot");return state;}
    std::string delivery_status(Key key,const std::string& epoch,const std::string& delivery)const{Command value;value.operation=Operation::delivery_status;value.key=checked(std::move(key));value.epoch=guid(epoch);value.delivery_id=guid(delivery);return text(call(value),L"status",32);}
    std::vector<SessionInfo> list()const{Command value;std::vector<SessionInfo> sessions;const auto raw=call(value).GetNamedArray(L"sessions");if(raw.Size()>128)throw std::runtime_error("Invalid bounded host session list");for(const auto& item:raw)sessions.push_back(info(item.GetObject()));return sessions;}
    EventBatch poll(Key key,const std::string& epoch,std::uint64_t after)const{key=checked(std::move(key));Command value;value.operation=Operation::poll;value.key=key;value.epoch=guid(epoch);value.sequence=after;const auto result=call(value);EventBatch batch{info(result.GetNamedObject(L"session")),after,{}};if(batch.session.key!=key||batch.session.epoch!=value.epoch||after<batch.session.acknowledged||after>batch.session.last)throw std::runtime_error("Host event batch does not match its requested session/cursor");const auto events=result.GetNamedArray(L"events");if(events.Size()>128)throw std::runtime_error("Host event batch exceeds its bound");auto sequence=after;for(const auto& item:events){auto event=logged(item.GetObject());if(event.epoch!=value.epoch||event.sequence!=++sequence||sequence>batch.session.last)throw std::runtime_error("Host events are not a contiguous durable batch");batch.events.push_back(std::move(event));}return batch;}
    bool persist_and_ack(const EventBatch& batch,const std::function<PersistReceipt(const std::vector<LoggedEvent>&)>& persist)const{if(!batch.events.empty()&&batch.events.front().sequence!=batch.after+1)throw std::invalid_argument("Host UI batch is incomplete");return persist_and_ack(batch.session.key,batch.session.epoch,batch.events,persist);}
    // Poll never acknowledges. Persist must atomically save stable epoch/sequence event IDs
    // with transcript AND index. A crash after that commit but before ACK replays the same IDs;
    // the UI callback must recognize them, then confirm its already-durable receipt.
    bool persist_and_ack(const Key& key,const std::string& epoch,const std::vector<LoggedEvent>& events,const std::function<PersistReceipt(const std::vector<LoggedEvent>&)>& persist)const{if(events.empty())return true;if(!persist)throw std::invalid_argument("Host events require a durable UI persistence callback");auto sequence=events.front().sequence;if(!sequence)throw std::invalid_argument("Invalid hosted event cursor");for(const auto& event:events)if(event.epoch!=guid(epoch)||event.sequence!=sequence++)throw std::invalid_argument("Host events must persist in contiguous sequence");const auto receipt=persist(events);if(!receipt.transcript_durable||!receipt.index_durable||receipt.epoch!=epoch||receipt.sequence!=events.back().sequence)return false;Command ack;ack.operation=Operation::acknowledge;ack.key=key;ack.epoch=epoch;ack.sequence=receipt.sequence;return text(call(ack),L"status",32)=="ok";}
};
} // namespace coincide::background_host
