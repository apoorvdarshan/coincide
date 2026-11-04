#include <windows.h>
#undef GetObject
#include "BackgroundAgentSessionFixtureRuntime.h"
#include "../Runtime/NativeHostConnection.h"

using namespace coincide;using namespace coincide::background_host;
namespace {
class SetupFailureSession final:public AgentSession {
    std::shared_ptr<background_proxy_fixture::State> state_;
public:
    explicit SetupFailureSession(std::shared_ptr<background_proxy_fixture::State> state):state_(std::move(state)){++state_->factories;state_->write();}
    bool send(CodexTurn)override{++state_->sends;state_->events.push_back({SessionEvent::Kind::error,"","Synthetic auth/setup failed before account verification",""});state_->events.push_back({SessionEvent::Kind::completed,"native-setup","failed",""});state_->write();return true;}
    bool busy()const noexcept override{return false;}void interrupt()noexcept override{++state_->interrupts;state_->write();}bool refresh_models()override{return false;}bool queue(CodexTurn,std::string)override{return false;}std::vector<AgentQueuedTurn> queued()const override{return{};}std::size_t queued_count()const override{return 0;}bool queue_paused()const override{return true;}bool remove_queued(const std::string&)override{return false;}bool resume_queue()override{return false;}bool steer(CodexTurn,std::string)override{return false;}void respond(std::string,std::string)override{}std::vector<SessionEvent> take_events()override{auto result=std::move(state_->events);state_->events.clear();return result;}void close()noexcept override{}void shutdown()noexcept override{++state_->shutdowns;state_->write();}
};
}
int wmain(int argc,wchar_t** argv){
    try{winrt::init_apartment(winrt::apartment_type::multi_threaded);if(argc!=5||std::wstring_view(argv[1])!=L"--hosted-agent-fixture-server")return 64;const std::filesystem::path root(argv[2]);if(!local_file::local_path(root))return 65;auto scope=std::make_shared<Scope>(root);if(!native_host_connection_detail::within_temporary(*scope)||!scope->directory().filename().wstring().starts_with(L"Coincide-Host-Proxy-Facade-")||local_file::read(scope->directory()/L"synthetic-connection-fixture.txt",128).bytes!="COINCIDE_SYNTHETIC_HOST_CONNECTION\n")return 65;const std::wstring mode(argv[4]);if(mode!=L"normal"&&mode!=L"setup")return 66;auto state=std::make_shared<background_proxy_fixture::State>(root);Core core(scope,[state,mode](const Key&,const Launch& launch)->std::unique_ptr<AgentSession>{state->profile_id=launch.profile_id;if(mode==L"setup")return std::make_unique<SetupFailureSession>(state);return std::make_unique<background_proxy_fixture::Session>(state);});Server server(core,scope,{file_identity(current_image()),file_identity(argv[3])});std::ofstream(root/L"server-ready.txt")<<GetCurrentProcessId();server.run();return 0;}catch(...){return 1;}
}
