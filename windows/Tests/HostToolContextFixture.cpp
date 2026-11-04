#include "../Runtime/HostToolContextStore.h"
#include <fstream>
using namespace coincide;using namespace coincide::background_host;
int wmain(int argc,wchar_t** argv){winrt::init_apartment(winrt::apartment_type::multi_threaded);try{
    if(argc!=4||std::wstring_view(argv[1])!=L"--context-fixture-owner")return 64;const std::filesystem::path root(argv[2]);const auto thread=guid(winrt::to_string(argv[3]));if(!local_file::within(std::filesystem::temp_directory_path(),root)||!root.filename().wstring().starts_with(L"Coincide-Tool-Context-")||local_file::read(root/L"synthetic-context-fixture.txt",128).bytes!="COINCIDE_SYNTHETIC_TOOL_CONTEXT\n")return 65;
    auto scope=std::make_shared<Scope>(root);HostToolContextStore store(scope);app_tools::PrivateFiles files(root);auto grant=files.create(thread,app_tools::Channel::browser,12345,"SYNTHETIC_HEADER_NEVER_CONTEXT",{"read"});store.publish(thread,grant->access.instructions,1);std::ofstream(root/L"owner-ready.txt")<<GetCurrentProcessId();for(;;)Sleep(100);
}catch(...){return 1;}}
