#pragma once
#include "HostedAppFixture.h"
#include "../Runtime/NativeHostConnection.h"
#include <fstream>

namespace coincide {
inline int hosted_app_bootstrap_tests(const std::filesystem::path& report){
    using namespace background_host;unsigned checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    const auto root=std::filesystem::temp_directory_path()/winrt::to_hstring("Coincide-Host-Connection-"+new_guid()).c_str();
    std::shared_ptr<Scope> scope;Handle child;bool owned{},stopped{};
    const auto stop=[&]{if(!scope||stopped)return;Client client(scope,file_identity(current_image()),std::chrono::seconds(3));Command command;command.operation=Operation::shutdown_host;const auto result=client.call(command);if(!result.GetNamedBoolean(L"retiring"))throw std::runtime_error("The empty owned fixture did not accept scoped Quit");stopped=true;if(child&&WaitForSingleObject(child.value,5000)!=WAIT_OBJECT_0)throw std::runtime_error("The empty owned host did not exit");};
    try{
        check(tests::bootstrap_hosted_app_fixture({})!=0,"An empty bootstrap path must be refused");check(tests::bootstrap_hosted_app_fixture(L"relative-fixture")!=0,"A relative bootstrap path must be refused");
        if(!std::filesystem::create_directory(root))throw std::runtime_error("The bootstrap fixture root must be unique");owned=true;scope=std::make_shared<Scope>(root);
        check(tests::bootstrap_hosted_app_fixture(root)!=0&&!std::filesystem::exists(scope->ledger_directory()),"A missing exact fixture marker must refuse before host dispatch");
        std::ofstream(root/L"synthetic-connection-fixture.txt",std::ios::binary)<<"wrong marker\n";
        check(tests::bootstrap_hosted_app_fixture(root)!=0&&!std::filesystem::exists(scope->ledger_directory()),"An incorrect fixture marker must refuse before any ledger creation");
        std::ofstream(root/L"synthetic-connection-fixture.txt",std::ios::binary|std::ios::trunc)<<std::string(129,'x');
        check(tests::bootstrap_hosted_app_fixture(root)!=0&&!std::filesystem::exists(scope->ledger_directory()),"An oversized marker must fail its bounded read without dispatch");
        std::ofstream(root/L"synthetic-connection-fixture.txt",std::ios::binary|std::ios::trunc)<<"COINCIDE_SYNTHETIC_HOST_CONNECTION\n";
        int sta_result{};std::thread sta([&]{winrt::init_apartment(winrt::apartment_type::single_threaded);sta_result=tests::bootstrap_hosted_app_fixture(root);winrt::uninit_apartment();});sta.join();
        check(sta_result!=0&&!std::filesystem::exists(scope->ledger_directory()),"A bootstrap invoked on an initialized UI apartment must refuse without dispatch");
        {auto restricted=WindowsProcess::start_bytes(current_image(),{L"--owned-background-host-bootstrap",root.wstring()},root,[](std::string_view){},4096);const auto exit=restricted->wait(std::chrono::seconds(10));check(exit&&exit->status!=0&&!std::filesystem::exists(scope->ledger_directory())&&ownership(*scope)==Ownership::free,"An owned restrictive job must remain denied without silently weakening production detach policy");}
        BOOL in_job{};if(!IsProcessInJob(GetCurrentProcess(),nullptr,&in_job))throw std::runtime_error("The bootstrap caller job could not be observed");
        if(in_job){JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};if(!QueryInformationJobObject(nullptr,JobObjectExtendedLimitInformation,&limits,sizeof(limits),nullptr))throw std::runtime_error("The bootstrap caller job limits could not be observed");if(!(limits.BasicLimitInformation.LimitFlags&(JOB_OBJECT_LIMIT_BREAKAWAY_OK|JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK))){
            check(tests::bootstrap_hosted_app_fixture(root)!=0&&!std::filesystem::exists(scope->ledger_directory())&&ownership(*scope)==Ownership::free,"The actual restrictive caller must refuse detach without creating another host");scope.reset();std::filesystem::remove_all(root);owned=false;
            std::ofstream output(report);output<<"PASS: "<<checks<<" restrictive-caller bootstrap guard checks; full unrestricted readiness suite NOT performed in this job\n";return output?0:2;
        }}
        check(tests::bootstrap_hosted_app_fixture(root)==0,"An explicit marked TEMP fixture may prepare its empty detached host");
        {auto pipe=pipe_io::connect(*scope,GetTickCount64()+3000);child=authenticate_peer(pipe.value,false,*scope,file_identity(current_image()));}
        const auto first_pid=GetProcessId(child.value);Client client(scope,file_identity(current_image()),std::chrono::seconds(3));
        check(client.list().empty(),"Bootstrap must not create or resume any provider session");check(ownership(*scope)==Ownership::owned,"The empty host must retain only its physical fixture scope");
        check(!std::filesystem::exists(root/L"workspace.json")&&!std::filesystem::exists(root/L"settings.json")&&!std::filesystem::exists(root/L"provider-profiles")&&!std::filesystem::exists(root/L"agent-tool-context-windows"),"Empty bootstrap must not write UI, account or tool-grant state");
        check(tests::bootstrap_hosted_app_fixture(root/L".")==0,"A physical alias must reuse the same empty fixture host");
        {auto pipe=pipe_io::connect(*scope,GetTickCount64()+3000);auto again=authenticate_peer(pipe.value,false,*scope,file_identity(current_image()));check(GetProcessId(again.value)==first_pid,"Repeated bootstrap must authenticate the original process rather than duplicate it");}
        check(client.list().empty(),"Repeated readiness must still send no Start/input or provider operation");
        stop();check(stopped&&ownership(*scope)==Ownership::free,"Explicit scoped Quit must release the empty fixture host");
        child.reset();scope.reset();std::filesystem::remove_all(root);owned=false;
        const auto wrong=std::filesystem::temp_directory_path()/winrt::to_hstring("Coincide-Wrong-Host-"+new_guid()).c_str();std::filesystem::create_directory(wrong);struct WrongCleanup{std::filesystem::path folder;~WrongCleanup(){std::error_code error;std::filesystem::remove_all(folder,error);}}wrong_cleanup{wrong};std::ofstream(wrong/L"synthetic-connection-fixture.txt",std::ios::binary)<<"COINCIDE_SYNTHETIC_HOST_CONNECTION\n";
        check(tests::bootstrap_hosted_app_fixture(wrong)!=0&&!std::filesystem::exists(wrong/L"agent-host-windows"),"A correct marker cannot authorize another TEMP folder prefix");
        const auto outside=std::filesystem::current_path()/winrt::to_hstring("Coincide-Host-Connection-"+new_guid()).c_str();std::filesystem::create_directory(outside);WrongCleanup outside_cleanup{outside};std::ofstream(outside/L"synthetic-connection-fixture.txt",std::ios::binary)<<"COINCIDE_SYNTHETIC_HOST_CONNECTION\n";
        check(tests::bootstrap_hosted_app_fixture(outside)!=0&&!std::filesystem::exists(outside/L"agent-host-windows"),"A marked folder outside physical TEMP must be refused");
        std::ofstream output(report);output<<"PASS: "<<checks<<" owned empty hosted-app bootstrap checks; no provider/auth/model operations\n";return output?0:2;
    }catch(const std::exception& error){try{stop();}catch(...){}std::ofstream(report)<<"FAIL after "<<checks<<": "<<error.what()<<'\n';}catch(...){try{stop();}catch(...){}std::ofstream(report)<<"FAIL after "<<checks<<": owned bootstrap fixture failure\n";}
    child.reset();scope.reset();if(owned){std::error_code error;std::filesystem::remove_all(root,error);}return 1;
}
} // namespace coincide
