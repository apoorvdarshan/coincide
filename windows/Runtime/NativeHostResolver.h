#pragma once
// Implementation-only header. The containing TU must include windows.h and undef
// GetObject before its first WinRT include, as NativeBackgroundHost.cpp does.
#include "NativeHostFactory.h"
#include "Preferences.h"

namespace coincide {
struct NativeHostResolverServices {
    // Trusted application-owned seams, never serialized or accepted through IPC.
    std::function<Preferences()> preferences;
    std::function<std::vector<ProviderAccountRecord>()> profiles;
    std::function<std::filesystem::path(const std::string&)> discover;
    std::function<ACPLaunchSpec(const std::string&,const std::filesystem::path&)> inspect;
};

// Resolving is file/metadata-only. The frozen factory performs fresh Cursor account
// verification and reconstructs all native argv/environment itself after resolution.
class NativeHostResolver {
    using Handle=background_host::Handle;
    std::shared_ptr<background_host::Scope> scope_;
    NativeHostResolverServices services_;
    static Handle pin_directory(const std::filesystem::path& path){
        Handle value(CreateFileW(path.c_str(),FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
        BY_HANDLE_FILE_INFORMATION info{};
        if(!value||!GetFileInformationByHandle(value.value,&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)
            ||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE)))
            throw std::runtime_error("The hosted metadata folder is linked or unavailable");
        return value;
    }
    static Handle pin_settings(const std::filesystem::path& path){
        Handle value(CreateFileW(path.c_str(),GENERIC_READ|FILE_READ_ATTRIBUTES,FILE_SHARE_READ,
            nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
        if(!value){const auto error=GetLastError();if(error==ERROR_FILE_NOT_FOUND)return{};
            throw std::runtime_error("The hosted provider settings are unavailable");}
        BY_HANDLE_FILE_INFORMATION info{};LARGE_INTEGER size{};
        if(!GetFileInformationByHandle(value.value,&info)||!GetFileSizeEx(value.value,&size)
            ||(info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE))
            ||info.nNumberOfLinks!=1||size.QuadPart<0||size.QuadPart>1024*1024)
            throw std::runtime_error("The hosted provider settings are linked or exceed their bound");
        return value;
    }
    static bool profile_id(const std::string& value){
        if(value=="default")return true;if(value.size()!=36)return false;
        try{return winrt::guid(winrt::to_hstring(value))!=winrt::guid{};}catch(...){return false;}
    }
    std::filesystem::path cursor_cache()const{
        // Created only by an explicit, already validated Cursor Start. Keep compilation
        // cache in the private runtime tree, separate from credentials and UI transcripts.
        scope_->prepare_private_directory();auto parent=pin_directory(scope_->ledger_directory());
        const auto path=scope_->ledger_directory()/L"cursor-node-cache";
        background_host::UserSecurity security(scope_->sid(),true);
        if(!CreateDirectoryW(path.c_str(),&security.attributes)&&GetLastError()!=ERROR_ALREADY_EXISTS)
            throw std::runtime_error("Could not prepare the private hosted Cursor cache");
        auto cache=pin_directory(path);Handle permissions(CreateFileW(path.c_str(),READ_CONTROL,
            FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));
        if(!permissions)throw std::runtime_error("Could not inspect the private hosted Cursor cache");
        background_host::verify_security(permissions.value,scope_->sid(),SE_FILE_OBJECT);return path;
    }
public:
    explicit NativeHostResolver(std::shared_ptr<background_host::Scope> scope,NativeHostResolverServices services={})
        :scope_(std::move(scope)),services_(std::move(services)){
        if(!scope_)throw std::invalid_argument("A native provider resolver needs its physical data scope");
        // Capturing defaults does not read settings/profiles, inspect a CLI, create a cache,
        // query an account, or start a process. Readiness/list must stay inert.
        if(!services_.preferences)services_.preferences=[scope=scope_]{
            scope->verify();auto folder=pin_directory(scope->directory());auto file=pin_settings(scope->directory()/L"settings.json");
            return PreferencesStore(scope->directory()).open();
        };
        if(!services_.profiles)services_.profiles=[scope=scope_]{
            scope->verify();auto folder=pin_directory(scope->directory());
            const auto path=scope->directory()/L"provider-profiles";
            if(GetFileAttributesW(path.c_str())==INVALID_FILE_ATTRIBUTES){const auto error=GetLastError();
                if(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND)return std::vector<ProviderAccountRecord>{};
                throw std::runtime_error("The hosted provider metadata is unavailable");}
            ACPFileSystem data(scope->directory());const auto safe=data.working_directory(winrt::to_string(path.wstring()));
            auto metadata=pin_directory(safe);
            return ProviderAccountStore(safe).open();
        };
        if(!services_.discover)services_.discover=[](const auto& provider){return ProviderDiscovery::discover(provider);};
        if(!services_.inspect)services_.inspect=[](const auto& provider,const auto& path){return ACPVendorLaunch::inspect(provider,path);};
    }
    NativeHostProgram operator()(const std::string& provider,const std::string& profile)const{
        if(provider!="codex"&&provider!="claude"&&provider!="cursor")
            throw std::invalid_argument("This provider has no verified hosted account flow");
        if(!profile_id(profile)||(provider!="cursor"&&profile!="default")||(provider=="cursor"&&profile=="default"))
            throw std::invalid_argument("The hosted provider needs its exact supported account profile");
        scope_->verify();auto data=pin_directory(scope_->directory());const auto preferences=services_.preferences();
        validate_preferences(preferences);const auto& selected=preferences.providers.at(provider);
        if(!selected.enabled)throw std::runtime_error("This provider is disabled in Settings");
        // The explicit per-conversation profile is authoritative; the Settings default may
        // change for NEW conversations without moving an existing native session's account.
        auto executable=selected.executable.empty()?services_.discover(provider)
            :std::filesystem::path(winrt::to_hstring(selected.executable).c_str());
        if(!local_file::local_path(executable)||executable!=executable.lexically_normal()
            ||!ProviderDiscovery::windows_executable(executable))
            throw std::runtime_error("The selected hosted provider needs an existing literal native Windows executable");
        NativeHostProgram result{provider,profile,executable,{},std::nullopt};
        if(provider=="cursor"){
            const auto records=services_.profiles();if(records.size()>100)throw std::runtime_error("Too many hosted provider profiles");
            std::set<std::string> ids;const ProviderAccountRecord* original{};
            for(const auto& record:records){ProviderAccountStore::validate(record);
                auto id=winrt::to_string(winrt::to_hstring(winrt::guid(winrt::to_hstring(record.id))));
                if(!ids.insert(id).second)throw std::runtime_error("Repeated hosted provider profile identity");
                if(record.id==profile&&record.provider==provider)original=&record;
            }
            if(!original||original->identity_source!="cursor-status-getMe"||original->last_scope.empty()||original->verified_at.empty())
                throw std::runtime_error("Verify this conversation's original Cursor profile in Accounts before hosting it");
            ProviderAccountStore profiles(scope_->directory()/L"provider-profiles");const auto folder=profiles.profile(*original);
            ACPFileSystem profile_pin(scope_->directory());result.profile_directory=profile_pin.working_directory(winrt::to_string(folder.wstring()));
            const auto program=services_.inspect(provider,executable);
            if(program.provider!=provider||!local_file::local_path(program.executable)||!ProviderDiscovery::windows_executable(program.executable))
                throw std::runtime_error("The selected Cursor installation could not be inspected");
            result.executable=program.executable;result.cursor=NativeHostCursorProfile{*original,cursor_cache()};
        }
        scope_->verify();return result;
    }
};
} // namespace coincide
