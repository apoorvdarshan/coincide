#pragma once
#include "WindowsProcess.h"
#ifdef GetObject
#undef GetObject
#endif
#include "AgentFactory.h"
#include "HostToolContextStore.h"

namespace coincide {
// Resolved from trusted application preferences/profile metadata, never from hosted argv.
struct NativeHostCursorProfile {ProviderAccountRecord record;std::filesystem::path cache;};
struct NativeHostProgram {
    std::string provider,profile_id{"default"};
    std::filesystem::path executable,profile_directory;
    std::optional<NativeHostCursorProfile> cursor;
};
struct NativeHostFactoryOptions {
    std::shared_ptr<background_host::Scope> scope;
    std::optional<background_host::FileIdentity> expected_ui_image;
    std::function<NativeHostProgram(const std::string&,const std::string&)> resolve;
    // Default performs only the official native metadata check. Tests inject synthetic metadata.
    std::function<ProviderAccountMetadata(const ProviderAccountProgram&,const ProviderAccountRecord&,const std::filesystem::path&,const ProviderAccounts::Cancel&)> probe;
    std::function<std::unique_ptr<AgentSession>(const std::string&,AgentLaunch,std::optional<ACPLaunchOptions>)> make;
    ProviderAccounts::Cancel cancel{std::make_shared<std::atomic_bool>(false)};
    std::string tool_descriptions; // fixed application-owned guide; not serialized in hosted Launch
};
class NativeHostFactory {
    struct Pins {
        std::vector<background_host::Handle> handles;
        std::vector<std::shared_ptr<ACPFileSystem>> paths;
        std::filesystem::path directory(const std::filesystem::path& path){
            if(!local_file::local_path(path))throw std::invalid_argument("Hosted paths must be absolute local folders");
            auto validated=std::make_shared<ACPFileSystem>(path);const auto physical=validated->root();paths.push_back(std::move(validated));
            // Strong directory-list opens participate in share/delete exclusion. Attribute-only
            // handles alone do not keep a selected directory from being renamed on Windows.
            auto part=physical.root_path();pin_directory(part);for(const auto& component:physical.relative_path()){part/=component;pin_directory(part);}return physical;
        }
        void pin_directory(const std::filesystem::path& path){
            background_host::Handle handle(CreateFileW(path.c_str(),FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};
            if(!handle||!GetFileInformationByHandle(handle.value,&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE)))throw std::runtime_error("A hosted folder is linked, unavailable or being replaced");handles.push_back(std::move(handle));
        }
        std::filesystem::path file(const std::filesystem::path& path,bool executable){
            if(!local_file::local_path(path))throw std::invalid_argument("A hosted program must use an absolute local path");
            auto parent=std::make_shared<ACPFileSystem>(path.parent_path());const auto literal=parent->literal(winrt::to_string(path.wstring()));directory(path.parent_path());
            background_host::Handle handle(CreateFileW(literal.c_str(),GENERIC_READ|FILE_READ_ATTRIBUTES,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};
            if(!handle||!GetFileInformationByHandle(handle.value,&info)||(info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE))||info.nNumberOfLinks!=1)throw std::runtime_error("A hosted program file is linked or unavailable");
            if(executable&&!ProviderDiscovery::windows_executable(literal))throw std::invalid_argument("A hosted provider must be a native Windows executable");handles.push_back(std::move(handle));paths.push_back(std::move(parent));return literal;
        }
    };
    NativeHostFactoryOptions options_;
    static bool profile(const std::string& value){if(value=="default")return true;if(value.size()!=36)return false;try{return winrt::guid(winrt::to_hstring(value))!=winrt::guid{};}catch(...){return false;}}
    static void scope(const std::string& value){if(!value.empty()&&(value.size()!=64||value.find_first_not_of("0123456789abcdef")!=std::string::npos))throw std::invalid_argument("Invalid hosted account scope");}
    static background_host::FileIdentity identity(const std::filesystem::path& path){background_host::Handle file(CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));FILE_ID_INFO info{};if(!file||!GetFileInformationByHandleEx(file.value,FileIdInfo,&info,sizeof(info)))throw std::runtime_error("Could not bind the hosted file or folder identity");background_host::FileIdentity result;result.volume=info.VolumeSerialNumber;std::copy(std::begin(info.FileId.Identifier),std::end(info.FileId.Identifier),result.id.begin());return result;}
    static bool same(const std::filesystem::path& a,const std::filesystem::path& b){return identity(a)==identity(b);}
public:
    explicit NativeHostFactory(NativeHostFactoryOptions options):options_(std::move(options)){
        if(!options_.scope||!options_.resolve||!options_.cancel)throw std::invalid_argument("The native host needs a physical scope, cancellation state and trusted provider resolver");
        if(options_.tool_descriptions.size()>64*1024||options_.tool_descriptions.find('\0')!=std::string::npos||!local_file::utf8(options_.tool_descriptions))throw std::invalid_argument("Invalid static hosted tool guide");
        if(!options_.probe)options_.probe=[](const auto& program,const auto& record,const auto& folder,const auto& cancel){return ProviderAccounts::check(program,record,folder,cancel);};
        if(!options_.make)options_.make=[](const auto& provider,auto launch,auto acp){return make_agent_session(provider,std::move(launch),std::move(acp));};
    }
    std::unique_ptr<AgentSession> operator()(const background_host::Key& supplied_key,const background_host::Launch& source)const{
        APTTYPE apartment{};APTTYPEQUALIFIER qualifier{};if(SUCCEEDED(CoGetApartmentType(&apartment,&qualifier))&&(apartment==APTTYPE_STA||apartment==APTTYPE_MAINSTA))throw std::runtime_error("Native host setup must run off the UI apartment");
        const auto cancelled=[&]{if(options_.cancel->load())throw std::runtime_error("Native hosted setup was cancelled");};cancelled();const auto key=background_host::checked(supplied_key);background_host::validate(source);options_.scope->verify();
        if(key.provider!="codex"&&key.provider!="claude"&&key.provider!="cursor")throw std::invalid_argument("This provider has no verified native hosted account flow yet");
        if(key.provider!="cursor"&&source.profile_id!="default")throw std::invalid_argument("This native hosted provider currently supports only its default account profile");
        if(source.arguments!=std::vector<std::wstring>{L"app-server"})throw std::invalid_argument("Hosted providers cannot select custom commands or fixture arguments");
        if(!profile(source.profile_id)||(!source.saved_profile_id.empty()&&source.saved_profile_id!=source.profile_id))throw std::invalid_argument("The hosted profile does not match its original account binding");scope(source.saved_account_scope);
        if(!source.session_id.empty()&&(source.saved_profile_id.empty()||source.saved_account_scope.empty()))throw std::invalid_argument("Review this saved conversation's original verified account before hosting it");
        const auto program=options_.resolve(key.provider,source.profile_id);
        if(program.provider!=key.provider||program.profile_id!=source.profile_id||program.executable.empty())throw std::invalid_argument("The trusted provider selection changed");
        if(program.profile_directory.empty()!=source.profile_directory.empty()||(source.profile_id!="default"&&source.profile_directory.empty()))throw std::invalid_argument("The hosted account requires its exact explicit profile folder");
        auto pins=std::make_shared<Pins>();pins->directory(options_.scope->directory());pins->directory(source.cwd);const auto executable=pins->file(source.executable,true),trusted=pins->file(program.executable,true);if(!same(executable,trusted))throw std::invalid_argument("The hosted executable differs from the selected native provider");
        if(!source.profile_directory.empty()){pins->directory(source.profile_directory);pins->directory(program.profile_directory);if(!same(source.profile_directory,program.profile_directory))throw std::invalid_argument("The hosted profile folder differs from the selected account");}
        AgentLaunch launch;launch.executable=source.executable;launch.arguments=source.arguments;launch.cwd=source.cwd;launch.session_id=source.session_id;launch.profile_id=source.profile_id;launch.profile_directory=source.profile_directory;launch.saved_profile_id=source.saved_profile_id;launch.saved_account_scope=source.saved_account_scope;launch.instructions=source.instructions;
        HostToolContextStore contexts(options_.scope,options_.expected_ui_image);auto fresh=contexts.supplier(key.thread);const auto descriptions=options_.tool_descriptions;launch.tool_context=[fresh=std::move(fresh),pins,descriptions]{static_cast<void>(pins);auto result=fresh();if(!result.empty()&&!descriptions.empty())result+="\n"+descriptions;return result;};
        std::optional<ACPLaunchOptions> acp;
        if(key.provider=="cursor"){
            if(!program.cursor||source.profile_id=="default"||source.profile_directory.empty())throw std::invalid_argument("A hosted Cursor session needs its verified separate account profile");
            const auto& record=program.cursor->record;ProviderAccountStore::validate(record);if(record.provider!=key.provider||record.id!=source.profile_id)throw std::invalid_argument("The hosted Cursor record belongs to another profile");
            auto name=trusted.filename().wstring();std::transform(name.begin(),name.end(),name.begin(),[](wchar_t c){return static_cast<wchar_t>(std::towlower(c));});
            if(name!=L"cursor-agent.exe"){pins->file(trusted.parent_path()/L"index.js",false);pins->file(trusted.parent_path()/L"package.json",false);}
            const auto spec=ACPVendorLaunch::inspect("cursor",trusted);if(!same(spec.executable,executable))throw std::invalid_argument("The selected Cursor runtime changed");
            for(const auto& argument:spec.options.command_prefix)pins->file(std::filesystem::path(argument),false);pins->directory(program.cursor->cache);
            const auto account_program=ProviderAccountProgram::from(spec);const auto metadata=options_.probe(account_program,record,source.profile_directory,options_.cancel);cancelled();
            if(metadata.state!=ProviderAccountState::verified||metadata.profile_id!=source.profile_id||metadata.provider!="cursor"||metadata.identity_source!="cursor-status-getMe")throw std::runtime_error("Verify the original Cursor account before hosting this conversation");scope(metadata.scope);if(metadata.scope.empty()||(!source.saved_account_scope.empty()&&metadata.scope!=source.saved_account_scope))throw std::runtime_error("The hosted Cursor account changed");
            acp=make_verified_acp_options(spec,account_program,record,source.profile_directory,program.cursor->cache,metadata,source.saved_account_scope,!source.session_id.empty());
        }else if(program.cursor)throw std::invalid_argument("Cursor account options cannot apply to another hosted provider");
        cancelled();auto session=options_.make(key.provider,std::move(launch),std::move(acp));if(!session)throw std::runtime_error("The native hosted provider factory returned no session");return session;
    }
};
} // namespace coincide
