#pragma once
#include "ComputerUsePolicy.h"
#include "AgentAccountScope.h"
#include <aclapi.h>
#include <sddl.h>
#include <cstring>
#include <limits>
#include <optional>
#include <type_traits>
#pragma comment(lib,"advapi32.lib")

namespace coincide::computer_use {
// A transient kernel-object lease, not a service, setting or network endpoint. The named
// mutex serializes actual input; a small user-only mapping retains the idle thread lease and
// expiry across independent app data roots. No window text, credentials or screenshots enter it.
class DesktopLease {
    struct Handle{HANDLE value{};~Handle(){if(value&&value!=INVALID_HANDLE_VALUE)CloseHandle(value);}Handle()=default;Handle(const Handle&)=delete;Handle& operator=(const Handle&)=delete;};
    static std::wstring sid(HANDLE process=GetCurrentProcess()){HANDLE raw{};if(!OpenProcessToken(process,TOKEN_QUERY,&raw))winrt::throw_last_error();Handle token;token.value=raw;DWORD length{};GetTokenInformation(raw,TokenUser,nullptr,0,&length);std::vector<BYTE> bytes(length);if(!length||!GetTokenInformation(raw,TokenUser,bytes.data(),length,&length))winrt::throw_last_error();PWSTR text{};if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid,&text))winrt::throw_last_error();const std::wstring result(text);LocalFree(text);return result;}
    static std::wstring object_name(HANDLE object){std::array<wchar_t,256> value{};DWORD length{};if(!GetUserObjectInformationW(object,UOI_NAME,value.data(),static_cast<DWORD>(sizeof(value)),&length)||!length||length>sizeof(value))throw std::runtime_error("Could not identify the Windows desktop scope");return value.data();}
    static std::wstring lower(std::wstring value){for(auto& ch:value)if(ch>=L'A'&&ch<=L'Z')ch=static_cast<wchar_t>(ch+32);return value;}
    static std::uint64_t creation(HANDLE process){FILETIME created{},exit{},kernel{},user{};if(!GetProcessTimes(process,&created,&exit,&kernel,&user))throw std::runtime_error("Could not verify the desktop lease owner");return(static_cast<std::uint64_t>(created.dwHighDateTime)<<32)|created.dwLowDateTime;}
public:
    class Scope {
        friend class DesktopLease;
        std::wstring sid_,name_;
        Scope(std::wstring user,DWORD session,std::wstring station,std::wstring desktop,bool fixture):sid_(std::move(user)){
            const auto identity=std::to_string(session)+":"+winrt::to_string(station)+":"+winrt::to_string(desktop);
            name_=L"Local\\Coincide-CU-Desktop-"+std::wstring(winrt::to_hstring(AgentAccountScope::fingerprint(fixture?"fixture-desktop-lease":"windows-desktop-lease",winrt::to_string(sid_),identity)).c_str());
        }
    public:
        static Scope for_window(HWND window){
            DWORD pid{};const auto thread=GetWindowThreadProcessId(window,&pid);DWORD session{},current{};if(!IsWindow(window)||!thread||!ProcessIdToSessionId(pid,&session)||!ProcessIdToSessionId(GetCurrentProcessId(),&current)||session!=current)throw std::runtime_error("The desktop lease target is stale or in another user session");
            Handle process;process.value=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process.value)throw std::runtime_error("The desktop lease target process is unavailable");const auto user=sid();if(sid(process.value)!=user)throw std::runtime_error("Computer Use cannot send input to another Windows user's process");
            const auto target=GetThreadDesktop(thread),own=GetThreadDesktop(GetCurrentThreadId());if(!target||!own)throw std::runtime_error("The target desktop is unavailable");const auto target_name=object_name(target),own_name=object_name(own);
            const auto input=OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS);if(!input)throw std::runtime_error("The active input desktop is unavailable");struct Close{HDESK value;~Close(){CloseDesktop(value);}}close{input};const auto input_name=object_name(input);
            if(lower(target_name)!=L"default"||lower(own_name)!=lower(target_name)||lower(input_name)!=lower(target_name)||!CompareObjectHandles(target,own)||!CompareObjectHandles(target,input))throw std::runtime_error("Computer Use does not control secure, foreign or inactive desktops");
            return Scope(user,session,lower(object_name(GetProcessWindowStation())),lower(target_name),false);
        }
        // Dedicated fixture namespace cannot reserve or disturb the actual desktop lease.
        static Scope fixture(const std::string& key){if(key.empty()||key.size()>128||key.find('\0')!=std::string::npos)throw std::invalid_argument("Invalid synthetic lease scope");DWORD session{};if(!ProcessIdToSessionId(GetCurrentProcessId(),&session))winrt::throw_last_error();return Scope(sid(),session,L"synthetic",winrt::to_hstring(key).c_str(),true);}
        std::wstring name()const{return name_;}
    };
private:
    struct Record {std::uint32_t magic{},version{},pid{},active{},active_thread{};std::uint32_t reserved{};std::uint64_t created{},expires{};char owner[33]{},thread[39]{};};
    static_assert(std::is_standard_layout_v<Record>);
    static constexpr std::uint32_t magic=0x43554c53,version=1;
    struct State {
        Handle mutex,mapping;Record* record{};std::string owner=random_id();std::uint64_t created=creation(GetCurrentProcess());std::function<std::uint64_t()> clock;std::atomic_bool closing{};
        ~State(){if(record)UnmapViewOfFile(record);}
    };
    std::shared_ptr<State> state_;
    static void verify_acl(HANDLE object,const std::wstring& user){
        PSID expected{};if(!ConvertStringSidToSidW(user.c_str(),&expected))winrt::throw_last_error();struct Free{void* value;~Free(){LocalFree(value);}}free_sid{expected};PSID owner{};PACL acl{};PSECURITY_DESCRIPTOR descriptor{};
        const auto error=GetSecurityInfo(object,SE_KERNEL_OBJECT,OWNER_SECURITY_INFORMATION|DACL_SECURITY_INFORMATION,&owner,nullptr,&acl,nullptr,&descriptor);if(error!=ERROR_SUCCESS)throw std::runtime_error("Could not validate the desktop lease security descriptor");Free free_descriptor{descriptor};
        if(!owner||!EqualSid(owner,expected)||!acl||acl->AceCount!=1)throw std::runtime_error("The desktop lease must be owned and accessible only by the current Windows user");void* raw{};if(!GetAce(acl,0,&raw))winrt::throw_last_error();const auto ace=static_cast<ACCESS_ALLOWED_ACE*>(raw);if(ace->Header.AceType!=ACCESS_ALLOWED_ACE_TYPE||!EqualSid(reinterpret_cast<PSID>(&ace->SidStart),expected))throw std::runtime_error("The desktop lease contains unexpected access permissions");
    }
    static void initialize(Record& record,bool abandoned){
        if(!record.magic&&!record.version){record={};record.magic=magic;record.version=version;}
        if(record.magic!=magic||record.version!=version)throw std::runtime_error("Unsupported shared desktop lease state");
        if(abandoned){record={};record.magic=magic;record.version=version;}
        if(record.pid&&(strnlen_s(record.owner,sizeof(record.owner))!=32||strnlen_s(record.thread,sizeof(record.thread))!=38||!record.created||!record.expires||record.active>1))throw std::runtime_error("Invalid shared desktop lease state");
    }
    struct Gate {std::shared_ptr<State> state;bool locked{},abandoned{};explicit Gate(std::shared_ptr<State> value):state(std::move(value)){const auto result=WaitForSingleObject(state->mutex.value,0);locked=result==WAIT_OBJECT_0||result==WAIT_ABANDONED;abandoned=result==WAIT_ABANDONED;if(result!=WAIT_TIMEOUT&&!locked)throw std::runtime_error("The shared desktop lease is unavailable");if(locked)try{initialize(*state->record,abandoned);}catch(...){ReleaseMutex(state->mutex.value);locked=false;throw;}}~Gate(){if(locked)ReleaseMutex(state->mutex.value);}};
    static bool alive(const Record& record){if(!record.pid)return false;const auto process=OpenProcess(SYNCHRONIZE|PROCESS_QUERY_LIMITED_INFORMATION,FALSE,record.pid);if(!process)return GetLastError()!=ERROR_INVALID_PARAMETER;Handle close;close.value=process;if(WaitForSingleObject(process,0)==WAIT_OBJECT_0)return false;try{return creation(process)==record.created;}catch(...){return true;}}
    static bool ours(const State& state,const Record& record,const std::string& thread){return record.pid==GetCurrentProcessId()&&record.created==state.created&&state.owner==record.owner&&thread==record.thread;}
public:
    class Guard {
        friend class DesktopLease;std::shared_ptr<State> state_;DWORD thread_{};bool abandoned_{};
        Guard(std::shared_ptr<State> state,bool abandoned):state_(std::move(state)),thread_(GetCurrentThreadId()),abandoned_(abandoned){}
    public:
        Guard(const Guard&)=delete;Guard& operator=(const Guard&)=delete;Guard(Guard&& other)noexcept:state_(std::move(other.state_)),thread_(other.thread_),abandoned_(other.abandoned_){}Guard& operator=(Guard&& other)noexcept{if(this!=&other&&finish()){state_=std::move(other.state_);thread_=other.thread_;abandoned_=other.abandoned_;}return *this;}
        bool abandoned()const{return abandoned_;}
        bool finish()noexcept{if(!state_)return true;if(GetCurrentThreadId()!=thread_)return false;state_->record->active=0;state_->record->active_thread=0;if(state_->closing){*state_->record={};state_->record->magic=magic;state_->record->version=version;}const bool released=ReleaseMutex(state_->mutex.value)!=FALSE;state_.reset();return released;}
        ~Guard(){(void)finish();}
    };
    explicit DesktopLease(const Scope& scope,std::function<std::uint64_t()> clock={}):state_(std::make_shared<State>()){
        state_->clock=clock?std::move(clock):std::function<std::uint64_t()>{[]{return GetTickCount64();}};
        const auto sddl=L"O:"+scope.sid_+L"D:P(A;;GA;;;"+scope.sid_+L")";PSECURITY_DESCRIPTOR descriptor{};if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&descriptor,nullptr))winrt::throw_last_error();struct Free{void* value;~Free(){LocalFree(value);}}free{descriptor};SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};
        state_->mutex.value=CreateMutexW(&attributes,FALSE,scope.name_.c_str());if(!state_->mutex.value)throw std::runtime_error("Could not open the user-scoped desktop input mutex");verify_acl(state_->mutex.value,scope.sid_);
        state_->mapping.value=CreateFileMappingW(INVALID_HANDLE_VALUE,&attributes,PAGE_READWRITE,0,sizeof(Record),(scope.name_+L".State").c_str());if(!state_->mapping.value)throw std::runtime_error("Could not open the user-scoped desktop lease record");verify_acl(state_->mapping.value,scope.sid_);
        state_->record=static_cast<Record*>(MapViewOfFile(state_->mapping.value,FILE_MAP_READ|FILE_MAP_WRITE,0,0,sizeof(Record)));if(!state_->record)throw std::runtime_error("Could not map the shared desktop lease record");
    }
    std::optional<Guard> try_acquire(const std::string& thread,std::uint32_t milliseconds=60000){
        const auto id=identifier(thread);if(!milliseconds||milliseconds>60000)throw std::invalid_argument("Invalid desktop lease duration");Gate gate(state_);if(!gate.locked)return{};auto& record=*state_->record;if(record.active)return{};const auto now=state_->clock();if(now>std::numeric_limits<std::uint64_t>::max()-milliseconds)throw std::invalid_argument("Invalid desktop lease clock");
        if(!ours(*state_,record,id)&&record.pid&&now<record.expires&&alive(record))return{};
        record.pid=GetCurrentProcessId();record.created=state_->created;record.expires=now+milliseconds;record.active=1;record.active_thread=GetCurrentThreadId();memcpy(record.owner,state_->owner.c_str(),state_->owner.size()+1);memcpy(record.thread,id.c_str(),id.size()+1);gate.locked=false;return Guard(state_,gate.abandoned);
    }
    bool release(const std::string& thread){const auto id=identifier(thread);Gate gate(state_);if(!gate.locked||state_->record->active||!ours(*state_,*state_->record,id))return false;*state_->record={};state_->record->magic=magic;state_->record->version=version;return true;}
    bool owns(const std::string& thread){const auto id=identifier(thread);Gate gate(state_);return gate.locked&&state_->clock()<state_->record->expires&&ours(*state_,*state_->record,id);}
    ~DesktopLease(){try{state_->closing=true;Gate gate(state_);if(gate.locked&&!state_->record->active&&state_->record->pid==GetCurrentProcessId()&&state_->owner==state_->record->owner){*state_->record={};state_->record->magic=magic;state_->record->version=version;}}catch(...){}}
    DesktopLease(const DesktopLease&)=delete;DesktopLease& operator=(const DesktopLease&)=delete;
};
} // namespace coincide::computer_use
