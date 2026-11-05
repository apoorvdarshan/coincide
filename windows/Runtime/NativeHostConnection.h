#pragma once
#include "BackgroundHostProcess.h"

namespace coincide {
enum class NativeHostConnectDisposition {ready_existing,ready_started,review,owned_unreachable,unavailable,start_failed,cancelled};
struct NativeHostConnectOptions {
    std::shared_ptr<background_host::Scope> scope;
    std::chrono::steady_clock::time_point deadline{std::chrono::steady_clock::now()+std::chrono::seconds(5)};
    std::shared_ptr<std::atomic_bool> cancel{std::make_shared<std::atomic_bool>(false)};
    std::chrono::milliseconds request_timeout{100};
};
struct NativeHostConnection {
    std::shared_ptr<background_host::Scope> scope;
    background_host::FileIdentity expected_image;
    NativeHostConnectDisposition disposition{NativeHostConnectDisposition::unavailable};
    background_host::Ownership ownership{background_host::Ownership::unavailable};
    bool spawned{},authenticated{};
    std::vector<background_host::SessionInfo> sessions;
    std::string error;
    bool ready()const noexcept{return authenticated&&(disposition==NativeHostConnectDisposition::ready_existing||disposition==NativeHostConnectDisposition::ready_started||disposition==NativeHostConnectDisposition::review);}
};
// Only the explicit synthetic entrypoint below accepts this seam. Production callers cannot
// select an executable, command line or process factory through NativeHostConnectOptions.
struct NativeHostFixtureChild {std::shared_ptr<void> lifetime;std::function<bool()> alive;};
struct NativeHostConnectionFixture {
    std::filesystem::path executable;
    std::function<NativeHostFixtureChild(const std::filesystem::path&,const std::vector<std::wstring>&,const std::filesystem::path&)> spawn;
};
namespace native_host_connection_detail {
using Clock=std::chrono::steady_clock;using Handle=background_host::Handle;
// Resolve both sides through directory handles: weakly_canonical does not necessarily expand
// the runner's DOS 8.3 TEMP spelling to the physical Scope.directory() long name.
inline bool within_temporary(const background_host::Scope& scope,const std::filesystem::path& temporary=std::filesystem::temp_directory_path()){background_host::Scope physical_temp(temporary);return local_file::within(physical_temp.directory(),scope.directory());}
struct Pins {
    std::vector<Handle> directories;Handle image;
    void directory(const std::filesystem::path& path){
        if(!local_file::local_path(path)||path!=path.lexically_normal())throw std::invalid_argument("Native host paths must be literal local paths");
        auto part=path.root_path();const auto pin=[&](const auto& value){Handle handle(CreateFileW(value.c_str(),FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};if(!handle||!GetFileInformationByHandle(handle.value,&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE)))throw std::runtime_error("A native host folder is linked, unavailable or being replaced");directories.push_back(std::move(handle));};pin(part);for(const auto& item:path.relative_path()){part/=item;pin(part);}
    }
    background_host::FileIdentity executable(const std::filesystem::path& path){
        if(!local_file::local_path(path)||path!=path.lexically_normal())throw std::invalid_argument("The native host image must be an absolute literal local file");directory(path.parent_path());image.reset(CreateFileW(path.c_str(),GENERIC_READ|FILE_READ_ATTRIBUTES,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};FILE_ID_INFO identity{};DWORD binary{};
        if(!image||!GetFileInformationByHandle(image.value,&info)||!GetFileInformationByHandleEx(image.value,FileIdInfo,&identity,sizeof(identity))||(info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE))||info.nNumberOfLinks!=1||!GetBinaryTypeW(path.c_str(),&binary)||(binary!=SCS_32BIT_BINARY&&binary!=SCS_64BIT_BINARY))throw std::runtime_error("The exact native host image is unavailable, linked or invalid");background_host::FileIdentity result;result.volume=identity.VolumeSerialNumber;std::copy(std::begin(identity.FileId.Identifier),std::end(identity.FileId.Identifier),result.id.begin());return result;
    }
};
struct Starter {
    Handle mutex;bool acquired{};
    ~Starter(){if(acquired)ReleaseMutex(mutex.value);}
};
#pragma push_macro("GetObject")
#ifdef GetObject
#undef GetObject
#endif
template<class T>inline background_host::Object object(const T& value){if constexpr(requires{value.GetObject();})return value.GetObject();else return value.GetObjectW();}
#pragma pop_macro("GetObject")
inline NativeHostConnection run(NativeHostConnectOptions options,const NativeHostConnectionFixture* fixture){
    using namespace background_host;NativeHostConnection result;result.scope=options.scope;
    const auto cancelled=[&]{return options.cancel&&options.cancel->load();};
    const auto expired=[&]{return Clock::now()>=options.deadline;};
    const auto failure=[&](NativeHostConnectDisposition disposition,std::string error){result.disposition=disposition;result.error=std::move(error);return result;};
    try{
        APTTYPE apartment{};APTTYPEQUALIFIER qualifier{};if(FAILED(CoGetApartmentType(&apartment,&qualifier))||apartment!=APTTYPE_MTA)return failure(NativeHostConnectDisposition::review,"Native host connection requires an initialized MTA worker.");
        if(!options.scope||!options.cancel||options.request_timeout<std::chrono::milliseconds(50)||options.request_timeout>std::chrono::milliseconds(250)||options.deadline>Clock::now()+std::chrono::seconds(30))return failure(NativeHostConnectDisposition::review,"Native host connection needs a physical scope and bounded deadline.");
        if(cancelled())return failure(NativeHostConnectDisposition::cancelled,"Native host connection was cancelled before starting.");if(expired())return failure(NativeHostConnectDisposition::start_failed,"Native host connection deadline expired before starting.");
        options.scope->verify();Pins pins;pins.directory(options.scope->directory());const auto executable=fixture?fixture->executable:current_image();result.expected_image=pins.executable(executable);
        if(fixture){const auto root=options.scope->directory();if(!within_temporary(*options.scope)||(!root.filename().wstring().starts_with(L"Coincide-Host-Connection-")&&!root.filename().wstring().starts_with(L"Coincide-Host-IPC-Connection-"))||local_file::read(root/L"synthetic-connection-fixture.txt",128).bytes!="COINCIDE_SYNTHETIC_HOST_CONNECTION\n"||!fixture->spawn)return failure(NativeHostConnectDisposition::review,"The alternate host factory requires its exact owned synthetic fixture scope.");}
        auto readiness=[&](){
            const auto remaining=std::chrono::duration_cast<std::chrono::milliseconds>(options.deadline-Clock::now());if(remaining<std::chrono::milliseconds(50)||cancelled())return false;
            try{Client client(options.scope,result.expected_image,std::min(options.request_timeout,remaining));Command list;const auto reply=client.call(list);if(cancelled()||expired())return false;const auto raw=reply.GetNamedArray(L"sessions");if(raw.Size()>128)throw std::runtime_error("Host list exceeded its bound");std::vector<SessionInfo> sessions;std::set<std::string> keys;bool review=reply.GetNamedBoolean(L"blocked",false);for(const auto& value:raw){auto session=info(object(value));if(!keys.insert(session.key.name()).second)throw std::runtime_error("Host list repeated a session");review=review||session.review;sessions.push_back(std::move(session));}
                result.ownership=ownership(*options.scope);if(result.ownership!=Ownership::owned)return false;result.sessions=std::move(sessions);result.authenticated=true;result.disposition=review?NativeHostConnectDisposition::review:result.spawned?NativeHostConnectDisposition::ready_started:NativeHostConnectDisposition::ready_existing;result.error=review?"The authenticated host has interrupted or blocked work requiring review.":std::string{};return true;
            }catch(...){return false;}
        };
        auto connect_owned=[&](){while(!cancelled()&&!expired()){if(readiness())return true;Sleep(10);}return false;};
        result.ownership=ownership(*options.scope);
        if(result.ownership==Ownership::unavailable)return failure(NativeHostConnectDisposition::unavailable,"Native host ownership could not be verified; no host was started.");
        if(result.ownership==Ownership::owned){if(connect_owned())return result;if(cancelled())return failure(NativeHostConnectDisposition::cancelled,"Connection to the owned host was cancelled; no replacement was started.");return failure(NativeHostConnectDisposition::owned_unreachable,"Another host owns this data scope but could not be authenticated. No replacement or local fallback was started.");}
        Starter starter;UserSecurity security(options.scope->sid());starter.mutex.reset(CreateMutexW(&security.attributes,FALSE,(L"Global\\Coincide-Host-Start-"+std::wstring(winrt::to_hstring(options.scope->id()))).c_str()));if(!starter.mutex)throw std::runtime_error("Could not open the native host starter lease");verify_security(starter.mutex.value,options.scope->sid());
        while(!cancelled()&&!expired()){const auto status=WaitForSingleObject(starter.mutex.value,10);if(status==WAIT_OBJECT_0||status==WAIT_ABANDONED){starter.acquired=true;break;}if(status!=WAIT_TIMEOUT)throw std::runtime_error("Native host starter lease is unavailable");}
        if(cancelled())return failure(NativeHostConnectDisposition::cancelled,"Native host startup was cancelled while waiting for its starter lease.");if(!starter.acquired)return failure(NativeHostConnectDisposition::start_failed,"Native host startup deadline expired while waiting for another starter.");
        // A concurrent starter may have acquired HostLease while this worker waited. Never
        // spawn when owned/unverifiable, even if that owner's endpoint cannot be reached.
        result.ownership=ownership(*options.scope);if(result.ownership==Ownership::unavailable)return failure(NativeHostConnectDisposition::unavailable,"Host ownership became unverifiable; no replacement was started.");if(result.ownership==Ownership::owned){if(connect_owned())return result;if(cancelled())return failure(NativeHostConnectDisposition::cancelled,"Connection to the concurrently started host was cancelled.");return failure(NativeHostConnectDisposition::owned_unreachable,"The concurrently started host owns this scope but could not be authenticated; no replacement was started.");}
        if(cancelled()||expired())return failure(cancelled()?NativeHostConnectDisposition::cancelled:NativeHostConnectDisposition::start_failed,"Native host startup stopped before dispatch.");
        const std::vector<std::wstring> arguments{L"--background-agent-host",options.scope->directory().wstring()};NativeHostFixtureChild child;
        // Mark dispatch before crossing a process API/injected boundary: an exception can
        // follow successful CreateProcess, so false must never imply that no host can exist.
        result.spawned=true;if(fixture)child=fixture->spawn(executable,arguments,options.scope->directory());else{auto detached=std::make_shared<DetachedProcess>(DetachedProcess::start(executable,arguments,options.scope->directory()));child={detached,[detached]{return detached->alive();}};}
        if(!child.alive||!child.lifetime)throw std::runtime_error("The native host starter returned no owned process handle");
        while(!cancelled()&&!expired()){result.ownership=ownership(*options.scope);if(result.ownership==Ownership::unavailable)return failure(NativeHostConnectDisposition::unavailable,"The started host's ownership became unverifiable; its status must be reviewed.");if(result.ownership==Ownership::owned&&readiness())return result;if(!child.alive()&&result.ownership==Ownership::free)return failure(NativeHostConnectDisposition::start_failed,"The native host exited before authenticated readiness; no provider was started.");Sleep(10);}
        if(cancelled())return failure(NativeHostConnectDisposition::cancelled,"Native host readiness was cancelled. A dispatched host may still own this scope; do not fall back locally.");
        return failure(result.ownership==Ownership::owned?NativeHostConnectDisposition::owned_unreachable:NativeHostConnectDisposition::start_failed,"Native host readiness deadline expired. Preserve the data scope and review ownership before retrying.");
    }catch(const std::exception& error){std::string detail=error.what();if(detail.size()>1024||detail.find('\0')!=std::string::npos||!local_file::utf8(detail))detail="Native scope, image or startup verification failed";return failure(result.spawned?NativeHostConnectDisposition::start_failed:NativeHostConnectDisposition::unavailable,std::move(detail));}catch(...){return failure(result.spawned?NativeHostConnectDisposition::start_failed:NativeHostConnectDisposition::unavailable,"Native host setup could not verify its scope, image, ownership or startup. No local runtime fallback is authorized.");}
}
} // namespace native_host_connection_detail
inline NativeHostConnection ensure_native_host(NativeHostConnectOptions options){return native_host_connection_detail::run(std::move(options),nullptr);}
inline NativeHostConnection ensure_native_host_fixture(NativeHostConnectOptions options,const NativeHostConnectionFixture& fixture){return native_host_connection_detail::run(std::move(options),&fixture);}
} // namespace coincide
