#include "../Runtime/ComputerUsePolicy.h"
#include "../Runtime/ComputerUseDesktopLease.h"
#include "../Core/LineFramer.h"
#include <filesystem>
#include <fstream>
#include <iostream>

// Dedicated console-only stand-in. It has no UIA, screen capture or input implementation.
// Mode files and traces live only in each test's unique working directory.
int wmain(int argc,wchar_t** argv){
    using namespace coincide::computer_use;winrt::init_apartment(winrt::apartment_type::multi_threaded);
    if(argc==2&&std::wstring_view(argv[1])==L"--computer-use-fixture-child"){Sleep(60000);return 0;}
    if(argc!=3||std::wstring_view(argv[1])!=L"--computer-use-helper")return 2;
    std::ifstream mode_file("computer-use-fixture-mode.txt");std::string mode;std::getline(mode_file,mode);
    std::unique_ptr<DesktopLease> lease;
    if(mode=="lease-hold"||mode=="lease-idle"||mode=="lease-short"){std::ifstream input("computer-use-fixture-lease.txt");std::string key;std::getline(input,key);lease=std::make_unique<DesktopLease>(DesktopLease::Scope::fixture(key));}
    if(mode=="early"){std::cout<<"{\"request_id\":\"00000000000000000000000000000000\",\"result\":{\"synthetic\":true}}\n"<<std::flush;Sleep(60000);return 0;}
    std::string line;while(std::getline(std::cin,line)){
        try{const auto request=Object::Parse(winrt::to_hstring(line));const auto id=text(request,L"request_id");std::ofstream("computer-use-fixture-trace.txt",std::ios::app)<<id<<'\n';
            if(mode=="hang"){Sleep(60000);return 0;}if(mode=="exit")return 7;if(mode=="oversized"){std::cout<<std::string(4*1024*1024+1,'x')<<'\n'<<std::flush;Sleep(60000);return 0;}if(mode=="malformed"){std::cout<<"{\n"<<std::flush;continue;}
            Object response,result;put(response,L"request_id",mode=="wrong-id"?std::string(32,'0'):id);result.SetNamedValue(L"synthetic",Value::CreateBooleanValue(true));
            if(lease){const auto thread=text(request,L"thread");if(text(request,L"operation")=="release_controls"){result.SetNamedValue(L"released",Value::CreateBooleanValue(lease->release(thread)));}else{auto guard=lease->try_acquire(thread,mode=="lease-short"?25:60000);result.SetNamedValue(L"lease_held",Value::CreateBooleanValue(guard.has_value()));if(mode=="lease-hold"){response.SetNamedValue(L"result",result);std::cout<<winrt::to_string(response.Stringify())<<'\n'<<std::flush;Sleep(60000);return 0;}}}
            if(mode=="child"){std::array<wchar_t,32768> module{};const auto count=GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));if(!count||count>=module.size())return 3;auto command=coincide::quote_windows_argument(module.data())+L" --computer-use-fixture-child";STARTUPINFOW startup{};startup.cb=sizeof(startup);PROCESS_INFORMATION child{};if(!CreateProcessW(module.data(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child))return 4;CloseHandle(child.hThread);result.SetNamedValue(L"owned_child_pid",Value::CreateNumberValue(child.dwProcessId));CloseHandle(child.hProcess);}
            response.SetNamedValue(L"result",result);std::cout<<winrt::to_string(response.Stringify())<<'\n'<<std::flush;
        }catch(...){return 5;}
    }return 0;
}
