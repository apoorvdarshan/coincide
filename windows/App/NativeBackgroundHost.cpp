#include <windows.h>
#undef GetObject
#undef GetCurrentTime
#include "../Runtime/NativeBackgroundHost.h"
#include "../Runtime/NativeHostResolver.h"
#include "../Runtime/HostIPC.h"
#include "AgentToolGuide.h"

namespace coincide {
int run_native_background_host(const std::filesystem::path& physical_data_directory) noexcept{
    bool initialized{};int failure=2;
    try{
        winrt::init_apartment(winrt::apartment_type::multi_threaded);initialized=true;
        struct Apartment {bool& initialized;~Apartment(){if(initialized)winrt::uninit_apartment();}} apartment{initialized};
        if(!local_file::local_path(physical_data_directory)||physical_data_directory!=physical_data_directory.lexically_normal())return 2;
        auto scope=std::make_shared<background_host::Scope>(physical_data_directory);
        const auto actual=scope->directory().wstring(),declared=physical_data_directory.wstring();
        if(CompareStringOrdinal(actual.c_str(),static_cast<int>(actual.size()),declared.c_str(),static_cast<int>(declared.size()),TRUE)!=CSTR_EQUAL)return 2;
        // Strong ancestor pins deny renaming/replacement during this process lifetime.
        ACPFileSystem data(scope->directory());std::vector<background_host::Handle> ancestors;
        auto path=scope->directory().root_path();
        const auto pin=[&](const auto& folder){background_host::Handle handle(CreateFileW(folder.c_str(),FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};if(!handle||!GetFileInformationByHandle(handle.value,&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE)))throw std::runtime_error("The native host data folder is unavailable");ancestors.push_back(std::move(handle));};
        pin(path);for(const auto& part:scope->directory().relative_path()){path/=part;pin(path);}
        const auto image=background_host::current_image();background_host::Handle image_pin(CreateFileW(image.c_str(),GENERIC_READ|FILE_READ_ATTRIBUTES,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION image_info{};
        if(!image_pin||!GetFileInformationByHandle(image_pin.value,&image_info)||(image_info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE))||image_info.nNumberOfLinks!=1||!ProviderDiscovery::windows_executable(image))return 2;
        const auto expected=background_host::file_identity(image);auto resolver=std::make_shared<NativeHostResolver>(scope);
        NativeHostFactoryOptions options;options.scope=scope;options.expected_ui_image=expected;
        options.resolve=[resolver](const auto& provider,const auto& profile){return(*resolver)(provider,profile);};
        options.tool_descriptions=app_tool_descriptions();
        NativeHostFactory factory(std::move(options));
        // No factory invocation occurs until an authenticated, validated explicit Start.
        // Core is the sole runtime owner; UI disconnect does not stop active work. It only
        // writes the private host ledger, never WorkspaceStore/settings/profile metadata.
        failure=3;background_host::Core core(scope,[factory=std::move(factory)](const auto& key,const auto& launch){return factory(key,launch);});
        background_host::Server server(core,scope,{expected});server.run();return 0;
    }catch(...){
        // Keep helper errors bounded and generic; no MessageBox, CLI JSON, path, auth data,
        // provider stderr or secret-bearing exception text can escape this entrypoint.
        // Apartment RAII above unwinds initialized calls; failure before it needs no cleanup.
        return failure;
    }
}
} // namespace coincide
