#pragma once
#include <winsock2.h>
#include <ws2tcpip.h>
#include "AppToolBridgeFiles.h"
#include <condition_variable>
#include <thread>
#include <roapi.h>
#pragma comment(lib,"ws2_32.lib")

namespace coincide::app_tools {
struct Apartment {HRESULT result{RoInitialize(RO_INIT_MULTITHREADED)};Apartment(){if(FAILED(result)&&result!=RPC_E_CHANGED_MODE)winrt::check_hresult(result);}~Apartment(){if(SUCCEEDED(result))RoUninitialize();}};
struct Reply {int status{200};std::string json;};
class Operation {
    friend class AppToolBridge;
    mutable std::mutex mutex_;std::condition_variable changed_;bool started_{},cancelled_{},finished_{};
    Request request_;Reply reply_;std::chrono::steady_clock::time_point deadline_;UploadPins uploads_;
    bool begin(){std::lock_guard lock(mutex_);if(started_||cancelled_||finished_||std::chrono::steady_clock::now()>=deadline_)return false;started_=true;return true;}
    void cancel()noexcept{std::lock_guard lock(mutex_);cancelled_=true;if(!started_){std::string{}.swap(request_.json);uploads_.handles.clear();}std::string{}.swap(reply_.json);changed_.notify_all();}
public:
    const std::string id;
    Operation(Request request,std::chrono::steady_clock::time_point deadline,UploadPins uploads={}):request_(std::move(request)),deadline_(deadline),uploads_(std::move(uploads)),id(random_secret(16)){}
    bool cancelled()const{std::lock_guard lock(mutex_);return cancelled_||finished_||std::chrono::steady_clock::now()>=deadline_;}
    // A controller may complete asynchronously on any thread. It must test cancelled() before
    // each side effect/after awaits. A late or repeated completion never replays the operation.
    bool complete(std::string json,int status=200){
        {std::lock_guard lock(mutex_);if(cancelled_||finished_||std::chrono::steady_clock::now()>=deadline_)return false;}
        try{Apartment apartment;if(status!=200&&status!=400&&status!=403&&status!=409&&status!=500&&status!=503)invalid();StrictJSON::validate(json,4*1024*1024);json=winrt::to_string(Value::Parse(winrt::to_hstring(json)).Stringify());}catch(...){json="{\"error\":\"App-tool response was invalid or too large\"}";status=500;}
        std::lock_guard lock(mutex_);if(cancelled_||finished_||std::chrono::steady_clock::now()>=deadline_)return false;finished_=true;reply_={status,std::move(json)};changed_.notify_all();return true;
    }
};

// One app-owned loopback listener. Lifecycle methods are called by the owner/UI thread; the
// dispatcher must enqueue a closure and return promptly. Handlers run only inside that closure.
// No browser, account, terminal, schedule or desktop controller is created by this foundation.
class AppToolBridge {
public:
    using Dispatcher=std::function<bool(std::function<void()>)>;
    using Handler=std::function<void(const Request&,const std::shared_ptr<Operation>&)>;
    struct Limits {std::chrono::milliseconds receive{std::chrono::seconds(15)},operation{std::chrono::seconds(950)},send{std::chrono::seconds(2)};std::size_t connections{16},grants{256},pending_dispatches{16};};
private:
    struct Socket {
        SOCKET value{INVALID_SOCKET};Socket()=default;explicit Socket(SOCKET socket):value(socket){}~Socket(){reset();}Socket(const Socket&)=delete;Socket& operator=(const Socket&)=delete;
        void reset(SOCKET socket=INVALID_SOCKET)noexcept{if(value!=INVALID_SOCKET)closesocket(value);value=socket;}
    };
    struct Grant {
        std::string key,thread,token;Channel channel;std::set<std::string> actions;Handler handler;std::shared_ptr<PrivateFiles::GrantFiles> files;
        std::atomic_bool valid{true};std::mutex mutex;bool busy{};std::set<std::string> request_ids;std::vector<std::weak_ptr<Operation>> operations;
        ~Grant(){if(!token.empty())SecureZeroMemory(token.data(),token.size());}
        void revoke()noexcept{valid=false;{std::lock_guard lock(mutex);for(const auto& weak:operations)if(const auto operation=weak.lock())operation->cancel();}files->revoke();}
    };
    struct Connection {Socket socket;std::thread thread;std::atomic_bool done{};std::weak_ptr<Grant> grant;explicit Connection(SOCKET value):socket(value){}};
    struct State {
        std::mutex mutex;std::atomic_bool stopping{};Dispatcher dispatcher;Limits limits;std::unique_ptr<PrivateFiles> files;
        std::map<std::string,std::shared_ptr<Grant>> grants;std::vector<std::shared_ptr<Connection>> connections;std::size_t dispatches{};unsigned short port{};
    };
    std::shared_ptr<State> state_;Socket listener_;std::thread listener_thread_;bool winsock_{},prepared_{};
    static std::string key(const std::string& thread,Channel channel){return channel_name(channel)+"/"+thread_key(thread);}
    static bool matches(std::string_view first,std::string_view second){if(first.size()!=second.size())return false;unsigned char different{};for(std::size_t i=0;i<first.size();++i)different|=static_cast<unsigned char>(first[i]^second[i]);return different==0;}
    static bool wait_socket(SOCKET socket,bool write,std::chrono::milliseconds timeout){fd_set set;FD_ZERO(&set);FD_SET(socket,&set);timeval time{static_cast<long>(timeout.count()/1000),static_cast<long>((timeout.count()%1000)*1000)};const auto result=select(0,write?nullptr:&set,write?&set:nullptr,nullptr,&time);return result>0;}
    static bool disconnected(SOCKET socket){if(!wait_socket(socket,false,std::chrono::milliseconds(0)))return false;char byte{};return recv(socket,&byte,1,MSG_PEEK)<=0;}
    static void respond(SOCKET socket,Reply reply,const State& state,const std::shared_ptr<Grant>& grant={})noexcept{
        try{
            if(reply.json.size()>4*1024*1024)reply={500,"{\"error\":\"App-tool response exceeds its bound\"}"};
            const auto bytes="HTTP/1.1 "+std::to_string(reply.status)+(reply.status==200?" OK":" Error")+"\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: "+std::to_string(reply.json.size())+"\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Coincide-Content-Trust: untrusted\r\nConnection: close\r\n\r\n"+reply.json;
            const auto deadline=std::chrono::steady_clock::now()+state.limits.send;std::size_t at{};
            while(at<bytes.size()&&!state.stopping&&(!grant||grant->valid)){
                if(std::chrono::steady_clock::now()>=deadline)return;if(!wait_socket(socket,true,std::chrono::milliseconds(25)))continue;
                const auto count=send(socket,bytes.data()+at,static_cast<int>(std::min<std::size_t>(bytes.size()-at,65536)),0);if(count>0)at+=static_cast<std::size_t>(count);else if(WSAGetLastError()!=WSAEWOULDBLOCK)return;
            }
        }catch(...){}
    }
    static std::optional<HTTPRequest> receive(SOCKET socket,const State& state){
        std::string bytes;bytes.reserve(16384);std::array<char,8192> chunk{};const auto deadline=std::chrono::steady_clock::now()+state.limits.receive;
        while(!state.stopping){if(std::chrono::steady_clock::now()>=deadline)throw std::runtime_error("App-tool request timed out");if(!wait_socket(socket,false,std::chrono::milliseconds(25)))continue;
            const auto count=recv(socket,chunk.data(),static_cast<int>(chunk.size()),0);if(count==0)return{};if(count<0){if(WSAGetLastError()==WSAEWOULDBLOCK)continue;return{};}
            bytes.append(chunk.data(),static_cast<std::size_t>(count));if(bytes.size()>HTTPRequest::maximum_headers+HTTPRequest::maximum_body+4)invalid();if(auto request=HTTPRequest::parse(bytes))return request;
        }return{};
    }
    static bool protected_output(const std::shared_ptr<State>& state,const std::shared_ptr<Grant>& grant,const std::string& body){
        if(body.find(grant->token)!=std::string::npos)return true;std::lock_guard lock(state->mutex);for(const auto& entry:state->grants)if(body.find(entry.second->token)!=std::string::npos)return true;return false;
    }
    static bool private_upload(const std::shared_ptr<State>& state,const Request& request,UploadPins& pins){
        if(request.channel!=Channel::browser||request.action!="upload")return false;const auto body=Object::Parse(winrt::to_hstring(request.json));std::vector<BY_HANDLE_FILE_INFORMATION> configurations;
        {std::lock_guard lock(state->mutex);for(const auto& entry:state->grants){BY_HANDLE_FILE_INFORMATION info{};if(!GetFileInformationByHandle(entry.second->files->configuration.get(),&info))invalid();configurations.push_back(info);}}
        for(const auto& raw:body.GetNamedArray(L"files")){const auto info=pins.add(std::filesystem::path(raw.GetString().c_str()));for(const auto& configuration:configurations)if(UploadPins::same_file(info,configuration))return true;}return false;
    }
    static void serve(const std::shared_ptr<State>& state,const std::shared_ptr<Connection>& connection)noexcept{
        struct Finished{std::shared_ptr<Connection> connection;~Finished(){shutdown(connection->socket.value,SD_BOTH);connection->done=true;}}finished{connection};
        std::shared_ptr<Grant> grant;std::shared_ptr<Operation> operation;bool claimed{};
        struct Release {std::shared_ptr<Grant>& grant;std::shared_ptr<Operation>& operation;bool& claimed;~Release(){if(operation)operation->cancel();if(grant&&claimed){std::lock_guard lock(grant->mutex);grant->busy=false;std::erase_if(grant->operations,[](const auto& value){const auto live=value.lock();return !live||live->cancelled();});}}}release{grant,operation,claimed};
        try {
            Apartment apartment;
            const auto incoming=receive(connection->socket.value,*state);if(!incoming)return;
            if(incoming->host!="127.0.0.1:"+std::to_string(state->port)||incoming->path.size()<2){respond(connection->socket.value,{403,"{\"error\":\"App-tool access denied\"}"},*state);return;}
            {std::lock_guard lock(state->mutex);const auto found=state->grants.find(incoming->path.substr(1));if(found!=state->grants.end()&&found->second->valid&&matches(incoming->authorization,"Bearer "+found->second->token))grant=found->second;}
            if(!grant){respond(connection->socket.value,{403,"{\"error\":\"App-tool access denied\"}"},*state);return;}
            auto request=Request::parse(grant->channel,incoming->body);if(!grant->actions.contains(request.action)){respond(connection->socket.value,{403,"{\"error\":\"This app action is not enabled\"}"},*state,grant);return;}
            UploadPins uploads;if(protected_output(state,grant,request.json)||private_upload(state,request,uploads)){respond(connection->socket.value,{403,"{\"error\":\"Private connection data cannot be submitted as app content\"}"},*state,grant);return;}
            request.thread_id=grant->thread;request.artifact_directory=grant->files->access.directory;request.timeout=std::min(request.timeout,state->limits.operation);
            const auto deadline=std::chrono::steady_clock::now()+request.timeout;operation=std::make_shared<Operation>(std::move(request),deadline,std::move(uploads));
            {std::lock_guard lock(grant->mutex);if(!grant->valid)return;if(grant->busy){respond(connection->socket.value,{409,"{\"error\":\"This thread tool already has an operation running\"}"},*state,grant);grant.reset();return;}
                if(!incoming->request_id.empty()&&(grant->request_ids.contains(incoming->request_id)||grant->request_ids.size()>=4096)){respond(connection->socket.value,{409,"{\"error\":\"Duplicate or exhausted app-tool request identity\"}"},*state,grant);grant.reset();return;}
                if(!incoming->request_id.empty())grant->request_ids.insert(incoming->request_id);grant->busy=true;claimed=true;grant->operations.push_back(operation);}
            {std::lock_guard lock(state->mutex);connection->grant=grant;if(state->stopping||state->dispatches>=state->limits.pending_dispatches){operation->cancel();respond(connection->socket.value,{503,"{\"error\":\"The app UI queue is unavailable\"}"},*state,grant);return;}++state->dispatches;}
            const auto dispatch_claim=std::make_shared<std::atomic_bool>(false);
            const auto work=[weak=std::weak_ptr<State>(state),grant,operation,dispatch_claim]{if(dispatch_claim->exchange(true))return;if(const auto live=weak.lock()){{std::lock_guard lock(live->mutex);if(live->dispatches)--live->dispatches;}if(live->stopping||!grant->valid||!operation->begin())return;
                    try{grant->handler(operation->request_,operation);}catch(...){operation->complete("{\"error\":\"The app action handler failed\"}",500);}}};
            bool dispatched{};try{dispatched=state->dispatcher(work);}catch(...){dispatched=false;}
            if(!dispatched){{std::lock_guard lock(state->mutex);if(!dispatch_claim->exchange(true)&&state->dispatches)--state->dispatches;}operation->cancel();respond(connection->socket.value,{503,"{\"error\":\"The app UI queue is unavailable\"}"},*state,grant);return;}
            Reply reply;
            for(;;){std::unique_lock lock(operation->mutex_);if(operation->finished_){reply=std::move(operation->reply_);break;}if(operation->cancelled_||state->stopping||!grant->valid)return;
                if(std::chrono::steady_clock::now()>=operation->deadline_){lock.unlock();operation->cancel();respond(connection->socket.value,{408,"{\"error\":\"The app action timed out; its result was not replayed\"}"},*state,grant);return;}
                operation->changed_.wait_for(lock,std::chrono::milliseconds(25));lock.unlock();if(disconnected(connection->socket.value)){operation->cancel();return;}
                if(wait_socket(connection->socket.value,false,std::chrono::milliseconds(0))){char byte{};if(recv(connection->socket.value,&byte,1,MSG_PEEK)>0){operation->cancel();respond(connection->socket.value,{400,"{\"error\":\"Send one JSON POST per connection\"}"},*state,grant);return;}}
            }
            if(state->stopping||!grant->valid)return;if(protected_output(state,grant,reply.json))reply={500,"{\"error\":\"The app action returned protected connection data\"}"};respond(connection->socket.value,std::move(reply),*state,grant);
        }catch(...){respond(connection->socket.value,{400,"{\"error\":\"Send one valid allowed JSON POST request\"}"},*state,grant);}
    }
    void listen_loop()noexcept{
        const auto state=state_;while(!state->stopping){
            std::vector<std::shared_ptr<Connection>> completed;{std::lock_guard lock(state->mutex);std::erase_if(state->connections,[&](const auto& connection){if(!connection->done)return false;completed.push_back(connection);return true;});}for(const auto& connection:completed)if(connection->thread.joinable())connection->thread.join();
            if(!wait_socket(listener_.value,false,std::chrono::milliseconds(25)))continue;if(state->stopping)break;sockaddr_in peer{};int size=sizeof(peer);const auto socket=accept(listener_.value,reinterpret_cast<sockaddr*>(&peer),&size);if(socket==INVALID_SOCKET)continue;
            if(peer.sin_family!=AF_INET||peer.sin_addr.s_addr!=htonl(INADDR_LOOPBACK)){closesocket(socket);continue;}u_long nonblocking=1;ioctlsocket(socket,FIONBIO,&nonblocking);SetHandleInformation(reinterpret_cast<HANDLE>(socket),HANDLE_FLAG_INHERIT,0);
            auto connection=std::make_shared<Connection>(socket);{std::lock_guard lock(state->mutex);if(state->stopping||state->connections.size()>=state->limits.connections)continue;state->connections.push_back(connection);try{connection->thread=std::thread([state,connection]{serve(state,connection);});}catch(...){connection->done=true;}}
        }
    }
public:
    AppToolBridge(const std::filesystem::path& parent,Dispatcher dispatcher):AppToolBridge(parent,std::move(dispatcher),Limits{}){}
    AppToolBridge(const std::filesystem::path& parent,Dispatcher dispatcher,Limits limits):state_(std::make_shared<State>()){
        if(!dispatcher||limits.receive<std::chrono::milliseconds(10)||limits.receive>std::chrono::seconds(30)||limits.operation<std::chrono::milliseconds(10)||limits.operation>std::chrono::seconds(950)||limits.send<std::chrono::milliseconds(10)||limits.send>std::chrono::seconds(5)||!limits.connections||limits.connections>16||!limits.grants||limits.grants>256||!limits.pending_dispatches||limits.pending_dispatches>16)throw std::invalid_argument("Invalid bounded app-tool bridge configuration");
        state_->dispatcher=std::move(dispatcher);state_->limits=limits;state_->files=std::make_unique<PrivateFiles>(parent);
    }
    AppToolBridge(const AppToolBridge&)=delete;AppToolBridge& operator=(const AppToolBridge&)=delete;~AppToolBridge(){stop();}
    void prepare(){
        if(state_->stopping)throw std::runtime_error("The app-tool bridge was closed");if(prepared_)return;WSADATA data{};if(WSAStartup(MAKEWORD(2,2),&data))throw std::runtime_error("Could not initialize the loopback app-tool connection");winsock_=true;try{
        listener_.reset(WSASocketW(AF_INET,SOCK_STREAM,IPPROTO_TCP,nullptr,0,WSA_FLAG_NO_HANDLE_INHERIT));if(listener_.value==INVALID_SOCKET)throw std::runtime_error("Could not create the loopback app-tool listener");BOOL exclusive=TRUE;if(setsockopt(listener_.value,SOL_SOCKET,SO_EXCLUSIVEADDRUSE,reinterpret_cast<const char*>(&exclusive),sizeof(exclusive)))throw std::runtime_error("Could not protect the loopback app-tool listener");
        sockaddr_in address{};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);address.sin_port=0;if(bind(listener_.value,reinterpret_cast<sockaddr*>(&address),sizeof(address))||listen(listener_.value,16))throw std::runtime_error("Could not bind the loopback app-tool listener");int size=sizeof(address);if(getsockname(listener_.value,reinterpret_cast<sockaddr*>(&address),&size)||!address.sin_port)throw std::runtime_error("Could not locate the loopback app-tool port");u_long nonblocking=1;if(ioctlsocket(listener_.value,FIONBIO,&nonblocking))throw std::runtime_error("Could not bound the loopback app-tool listener");
        state_->port=ntohs(address.sin_port);listener_thread_=std::thread([this]{listen_loop();});prepared_=true;
        }catch(...){listener_.reset();state_->port=0;if(winsock_){WSACleanup();winsock_=false;}throw;}
    }
    unsigned short port()const{return state_->stopping?0:state_->port;}
    // Thread-safe plain-value snapshot for provider workers; never exposes header contents.
    std::string current_instructions(const std::string& thread)const{
        const auto id=thread_key(thread);std::string result;std::lock_guard lock(state_->mutex);if(state_->stopping)return result;
        for(const auto& entry:state_->grants)if(entry.second->valid&&thread_key(entry.second->thread)==id){if(!result.empty())result+="\n\n";result+=entry.second->files->access.instructions;}return result;
    }
    Access enable(const std::string& thread,Channel channel,std::set<std::string> actions,Handler handler){
        if(!handler||actions.empty())throw std::invalid_argument("App-tool grants require explicit supported actions and a dispatcher handler");for(const auto& action:actions)if(!Request::actions(channel).contains(action))invalid();prepare();const auto name=key(thread,channel);
        {std::lock_guard lock(state_->mutex);if(state_->stopping)throw std::runtime_error("The app-tool bridge was closed");if(const auto found=state_->grants.find(name);found!=state_->grants.end()){if(found->second->actions!=actions)throw std::runtime_error("Revoke the old app-tool grant before changing its action permissions");return found->second->files->access;}if(state_->grants.size()>=state_->limits.grants)throw std::runtime_error("Too many app-tool grants");}
        auto grant=std::make_shared<Grant>();grant->key=name;grant->thread=thread;grant->channel=channel;grant->actions=std::move(actions);grant->handler=std::move(handler);grant->token=random_secret();grant->files=state_->files->create(thread,channel,state_->port,grant->token,grant->actions);
        std::lock_guard lock(state_->mutex);if(state_->stopping){grant->revoke();throw std::runtime_error("The app-tool bridge was closed");}state_->grants.emplace(name,grant);return grant->files->access;
    }
    void disable(const std::string& thread,std::optional<Channel> channel=std::nullopt){
        const auto id=thread_key(thread);std::vector<std::shared_ptr<Grant>> removed;
        {std::lock_guard lock(state_->mutex);std::erase_if(state_->grants,[&](const auto& item){if(thread_key(item.second->thread)!=id||(channel&&item.second->channel!=*channel))return false;removed.push_back(item.second);return true;});}
        for(const auto& grant:removed)grant->revoke();
        std::lock_guard lock(state_->mutex);for(const auto& connection:state_->connections)if(const auto grant=connection->grant.lock();grant&&!grant->valid)shutdown(connection->socket.value,SD_BOTH);
    }
    void stop()noexcept{
        if(!state_||state_->stopping.exchange(true))return;
        std::vector<std::shared_ptr<Grant>> grants;{std::lock_guard lock(state_->mutex);for(const auto& item:state_->grants)grants.push_back(item.second);state_->grants.clear();}for(const auto& grant:grants)grant->revoke();
        {std::lock_guard lock(state_->mutex);for(const auto& connection:state_->connections)shutdown(connection->socket.value,SD_BOTH);}
        if(listener_thread_.joinable())listener_thread_.join();listener_.reset();
        for(const auto& connection:state_->connections)if(connection->thread.joinable())connection->thread.join();state_->connections.clear();if(winsock_){WSACleanup();winsock_=false;}
    }
};
} // namespace coincide::app_tools
