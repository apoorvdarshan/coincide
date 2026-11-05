#include <windows.h>
#undef GetObject
#undef GetCurrentTime
#include "HostedAppFixture.h"
#include "../Runtime/AgentFactory.h"
#include "../Runtime/HostIPC.h"
#include "../Runtime/HostToolContextStore.h"
#include "../Runtime/NativeHostConnection.h"

namespace coincide::tests {
int run_hosted_app_fixture(const std::filesystem::path& directory) noexcept{
    try{
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        struct Apartment{~Apartment(){winrt::uninit_apartment();}}apartment;
        if(!local_file::local_path(directory))return 2;
        auto scope=std::make_shared<background_host::Scope>(directory);
        const background_host::Scope temporary(std::filesystem::temp_directory_path());
        if(!local_file::within(temporary.directory(),scope->directory())
            ||!scope->directory().filename().wstring().starts_with(L"Coincide-Host-Connection-"))return 2;
        if(local_file::read(scope->directory()/L"synthetic-connection-fixture.txt",128).bytes!="COINCIDE_SYNTHETIC_HOST_CONNECTION\n")return 2;
        const auto image=background_host::current_image();const auto identity=background_host::file_identity(image);
        auto contexts=std::make_shared<HostToolContextStore>(scope,identity);
        background_host::Core core(scope,[scope,image,identity,contexts](const auto& key,const auto& source)->std::unique_ptr<AgentSession>{
            if((key.provider!="codex"&&key.provider!="claude")||source.profile_id!="default"||!source.profile_directory.empty()
                ||!local_file::within(scope->directory(),source.cwd)||background_host::file_identity(source.executable)!=identity)
                throw std::invalid_argument("The owned host fixture refused a non-synthetic launch");
            // Ignore supplied argv. Only this executable's existing deterministic protocol
            // fixtures can run; no account, model, CLI override or arbitrary command is used.
            AgentLaunch launch;launch.executable=image;launch.cwd=source.cwd;
            launch.arguments={key.provider=="claude"?L"--claude-session-fixture":L"--codex-session-fixture",L"normal"};
            launch.fixture_account_reviewed=true;launch.profile_id="default";launch.profile_directory=source.cwd;
            launch.session_id=source.session_id;launch.saved_profile_id=source.saved_profile_id;launch.saved_account_scope=source.saved_account_scope;
            launch.instructions=source.instructions;launch.tool_context=contexts->supplier(key.thread);
            return make_agent_session(key.provider,std::move(launch));
        });
        background_host::Server server(core,scope,{identity});server.run();return 0;
    }catch(...){return 3;}
}
int bootstrap_hosted_app_fixture(const std::filesystem::path& directory) noexcept{
    try{
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        struct Apartment{~Apartment(){winrt::uninit_apartment();}}apartment;
        if(!local_file::local_path(directory))return 2;
        auto scope=std::make_shared<background_host::Scope>(directory);
        const background_host::Scope temporary(std::filesystem::temp_directory_path());
        if(!local_file::within(temporary.directory(),scope->directory())
            ||!scope->directory().filename().wstring().starts_with(L"Coincide-Host-Connection-"))return 2;
        if(local_file::read(scope->directory()/L"synthetic-connection-fixture.txt",128).bytes!="COINCIDE_SYNTHETIC_HOST_CONNECTION\n")return 2;
        const auto image=background_host::current_image();
        NativeHostConnectionFixture fixture;fixture.executable=image;
        fixture.spawn=[image](const auto& executable,const auto& arguments,const auto& cwd){
            if(executable!=image||arguments!=std::vector<std::wstring>{L"--background-agent-host",cwd.wstring()})
                throw std::invalid_argument("The empty owned fixture refused a different startup command");
            auto child=std::make_shared<background_host::DetachedProcess>(background_host::DetachedProcess::start(image,{L"--owned-background-host-fixture",cwd.wstring()},cwd));
            return NativeHostFixtureChild{child,[child]{return child->alive();}};
        };
        NativeHostConnectOptions options;options.scope=scope;options.deadline=std::chrono::steady_clock::now()+std::chrono::seconds(15);options.request_timeout=std::chrono::milliseconds(250);
        const auto connected=ensure_native_host_fixture(std::move(options),fixture);
        if(!connected.ready()||!connected.authenticated||connected.disposition==NativeHostConnectDisposition::review||!connected.sessions.empty())return 3;
        // NativeHostConnection performs authenticated list/readiness only. The host intentionally
        // remains alive for the separate owned UI process; only explicit Start can create a session.
        return 0;
    }catch(...){return 3;}
}
} // namespace coincide::tests
