#pragma once
#include "../Runtime/ComputerUseProcess.h"
#include <filesystem>
#include <fstream>

namespace coincide {
// Runs only the dedicated fake helper EXE. The fixture binary contains no UIA/capture/input.
inline int computer_use_process_tests(const std::filesystem::path& report,const std::filesystem::path& fixture){
    using namespace computer_use;int checks{};auto check=[&](bool condition,const char* message){++checks;if(!condition)throw std::runtime_error(message);};auto rejects=[&](auto operation,const char* message){bool rejected{};try{operation();}catch(...){rejected=true;}check(rejected,message);};
    const auto root=std::filesystem::temp_directory_path()/(L"Coincide-CU-pipe-fixture-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
    struct Cleanup{std::filesystem::path path;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(path,ignored);}}cleanup{root};
    try{
        if(!fixture.is_absolute()||fixture.filename()!=L"CoincideComputerUseFixture.exe"||!std::filesystem::is_regular_file(fixture))throw std::invalid_argument("Pass the exact dedicated Computer Use fixture executable");
        std::filesystem::create_directories(root);Object request;put(request,L"thread","{65e2f1d1-cc61-40b5-95bd-d29c345c444c}");put(request,L"operation","list_windows");request.SetNamedValue(L"arguments",Object{});
        auto mode=[&](std::string value){std::ofstream(root/L"computer-use-fixture-mode.txt",std::ios::trunc)<<value;std::ofstream(root/L"computer-use-fixture-trace.txt",std::ios::trunc);};
        auto count=[&]{std::ifstream input(root/L"computer-use-fixture-trace.txt");return static_cast<unsigned>(std::count(std::istreambuf_iterator<char>(input),std::istreambuf_iterator<char>(),'\n'));};
        mode("normal");ProcessBackend backend(fixture,root,GetCurrentProcessId(),std::chrono::milliseconds(1500));const auto initial=backend.generation();
        check(backend.request(request,[]{return false;}).GetNamedBoolean(L"synthetic"),"A private fixture request must receive its exact correlated result");check(backend.generation()!=initial&&count()==1,"Starting one owned helper must advance its token generation exactly once");
        const auto current=backend.generation();check(backend.request(request,[]{return false;}).GetNamedBoolean(L"synthetic")&&backend.generation()==current&&count()==2,"Sequential calls must reuse the owned helper without duplicating requests");backend.stop();check(backend.generation()!=current,"Explicit stop must invalidate the helper generation");
        mode("early");auto large=Object::Parse(request.Stringify());put(large,L"padding",std::string(200000,'x'));const auto early=GetTickCount64();rejects([&]{backend.request(large,[]{return false;});},"An early reply must not deadlock a pipe writer that the helper never drains");check(GetTickCount64()-early<6000,"A blocked pipe writer must be released by the owned-job deadline");check(count()==0,"The early-response helper must not receive/replay the blocked request");
        for(const auto value:{"wrong-id","malformed","exit","oversized"}){mode(value);rejects([&]{backend.request(request,[]{return false;});},"Malformed, mismatched, exited or oversized helpers must fail without a replay");check(count()==1,"Every failed IPC command must appear at most once in its fixture trace");}
        mode("hang");std::atomic_bool cancel{};std::jthread cancellation([&]{Sleep(150);cancel=true;});const auto begin=GetTickCount64();rejects([&]{backend.request(request,[&]{return cancel.load();});},"Revocation must cancel an owned helper request instead of replaying it");cancellation.join();check(GetTickCount64()-begin<6000&&count()<=1,"Cancellation must stop the owned process within its bounded cleanup time without a replay");
        mode("child");const auto reply=backend.request(request,[]{return false;});const auto child_pid=static_cast<DWORD>(integer(reply,L"owned_child_pid",1,MAXDWORD));const auto child=OpenProcess(SYNCHRONIZE,FALSE,child_pid);check(child!=nullptr,"The deterministic helper must expose only its synthetic owned descendant");backend.stop();const auto stopped=WaitForSingleObject(child,5000)==WAIT_OBJECT_0;CloseHandle(child);check(stopped,"Stopping the helper job must terminate its synthetic descendant too");
        mode("normal");check(backend.request(request,[]{return false;}).GetNamedBoolean(L"synthetic")&&count()==1,"A later explicit call may start a clean helper after a failure");backend.stop();
        std::ofstream output(report);output<<"PASS: "<<checks<<" Windows Computer Use owned-pipe/timeout checks (fake helper only)\n";return output?0:2;
    }catch(const winrt::hresult_error& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<winrt::to_string(error.message())<<'\n';}catch(const std::exception& error){std::ofstream(report)<<"FAIL after "<<checks<<" checks: "<<error.what()<<'\n';}return 1;
}
} // namespace coincide
