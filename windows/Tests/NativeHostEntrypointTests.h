#pragma once
#include "../Runtime/NativeHostConnection.h"
#include <fstream>

namespace coincide {
// Launch the actual fixed headless entrypoint against an empty owned data directory.
// No Start/input/provider/auth/model operation is sent; this tests readiness and scoped Quit.
inline int native_host_entrypoint_tests(const std::filesystem::path& report){
    using namespace background_host;std::size_t checks{};const auto check=[&](bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);};
    const auto directory=std::filesystem::temp_directory_path()/winrt::to_hstring("Coincide-NativeHost-Entrypoint-"+new_guid()).c_str();
    std::shared_ptr<Scope> scope;Handle process;bool stopped{};
    const auto quit=[&]{if(!scope||stopped)return;Client client(scope,file_identity(current_image()),std::chrono::seconds(3));Command command;command.operation=Operation::shutdown_host;const auto result=client.call(command);if(!result.GetNamedBoolean(L"retiring")||result.GetNamedBoolean(L"needs_persistence"))throw std::runtime_error("The empty owned host did not confirm scoped shutdown");stopped=true;};
    try{
        std::filesystem::create_directory(directory);scope=std::make_shared<Scope>(directory);
        NativeHostConnectOptions options;options.scope=scope;options.deadline=std::chrono::steady_clock::now()+std::chrono::seconds(20);options.request_timeout=std::chrono::milliseconds(250);
        BOOL in_job{};if(!IsProcessInJob(GetCurrentProcess(),nullptr,&in_job))winrt::throw_last_error();
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};if(in_job&&!QueryInformationJobObject(nullptr,JobObjectExtendedLimitInformation,&limits,sizeof(limits),nullptr))winrt::throw_last_error();
        const bool restricted=in_job&&!(limits.BasicLimitInformation.LimitFlags&(JOB_OBJECT_LIMIT_BREAKAWAY_OK|JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK));
        auto started=ensure_native_host(options);
        if(restricted){
            check(!started.ready()&&!started.authenticated&&!started.error.empty(),"A restricted caller must report its detached-host refusal without claiming readiness");
            check(ownership(*scope)==Ownership::free,"A restricted caller must not transfer native runtime ownership");
            check(!std::filesystem::exists(scope->ledger_directory())&&!std::filesystem::exists(directory/L"settings.json")&&!std::filesystem::exists(directory/L"provider-profiles"),"A restricted caller must preserve its empty scope without host/provider setup");
            started.scope.reset();options.scope.reset();scope.reset();std::filesystem::remove_all(directory);
            std::ofstream output(report);output<<"PASS: "<<checks<<" restricted-job native host refusal checks; unrestricted readiness/quit NOT performed in this job\n";return output?0:2;
        }
        check(started.ready()&&started.authenticated&&started.spawned&&started.disposition==NativeHostConnectDisposition::ready_started,"The actual native headless entrypoint must prove authenticated readiness");
        check(started.sessions.empty(),"Readiness must create no provider sessions");
        check(ownership(*scope)==Ownership::owned,"The actual entrypoint must hold only its physical data-scope lease");
        check(!std::filesystem::exists(directory/L"settings.json")&&!std::filesystem::exists(directory/L"provider-profiles")&&!std::filesystem::exists(directory/L"workspace.json"),"An empty host must not create settings, account profiles or UI workspace data");
        {auto pipe=pipe_io::connect(*scope,GetTickCount64()+3000);process=authenticate_peer(pipe.value,false,*scope,started.expected_image);}
        check(static_cast<bool>(process),"The headless peer must retain its exact verified process handle");
        options.deadline=std::chrono::steady_clock::now()+std::chrono::seconds(5);auto existing=ensure_native_host(options);
        check(existing.ready()&&existing.authenticated&&!existing.spawned&&existing.disposition==NativeHostConnectDisposition::ready_existing,"A second connection must reuse the authenticated host without dispatching another process");
        check(existing.sessions.empty(),"Repeated readiness must still perform no provider setup");
        quit();check(stopped,"An empty host must accept its explicit scoped Quit");
        check(WaitForSingleObject(process.value,5000)==WAIT_OBJECT_0,"Scoped Quit must exit the exact owned native host process");
        check(ownership(*scope)==Ownership::free,"Native host exit must release its physical scope");
        check(!std::filesystem::exists(directory/L"provider-profiles")&&!std::filesystem::exists(scope->ledger_directory()/L"cursor-node-cache"),"Inert readiness and Quit must not inspect/create account or runtime caches");
        process.reset();started.scope.reset();existing.scope.reset();options.scope.reset();scope.reset();std::filesystem::remove_all(directory);
        std::ofstream output(report);output<<"PASS: "<<checks<<" actual headless entrypoint/readiness/quit checks; no provider or account operations\n";return output?0:2;
    }catch(const std::exception& error){try{quit();if(process)WaitForSingleObject(process.value,5000);}catch(...){}std::ofstream(report)<<"FAIL: "<<error.what()<<'\n';}
    catch(...){try{quit();if(process)WaitForSingleObject(process.value,5000);}catch(...){}std::ofstream(report)<<"FAIL: The owned native host entrypoint fixture could not complete\n";}
    process.reset();scope.reset();std::error_code ignored;std::filesystem::remove_all(directory,ignored);return 1;
}
} // namespace coincide
