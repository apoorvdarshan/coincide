#pragma once
#include <windows.h>
#include <sddl.h>
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Microsoft.Windows.AppNotifications.h>
#include "AgentAccountScope.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#pragma comment(lib,"advapi32.lib")

namespace coincide {
struct WindowsNotificationPayload {
    std::string thread_id, tag, group, argument;
    std::wstring xml;
    std::int64_t expires{};
};

// The injected boundary lets policy tests inspect every operation without registering an
// activator or delivering an OS notification. Native removal is asynchronous, never .get().
struct WindowsNotificationTransport {
    using Invoked=std::function<void(std::string)>;
    virtual ~WindowsNotificationTransport()=default;
    virtual void start(Invoked)=0;
    virtual void stop()noexcept=0;
    virtual bool permitted()=0;
    virtual void show(const WindowsNotificationPayload&)=0;
    virtual winrt::Windows::Foundation::IAsyncAction remove(std::string tag,std::string group)=0;
    virtual winrt::Windows::Foundation::IAsyncAction remove_group(std::string group)=0;
};

class AppNotificationTransport final:public WindowsNotificationTransport {
    using Manager=winrt::Microsoft::Windows::AppNotifications::AppNotificationManager;
    Manager manager_{nullptr};winrt::event_token invoked_{};bool subscribed_{},registered_{};
public:
    void start(Invoked callback)override{
        if(registered_)return;
        // No WinRT factory or OS registration is touched until the caller explicitly enables.
        if(!Manager::IsSupported())throw std::runtime_error("Windows app notifications are unavailable");
        manager_=Manager::Default();
        invoked_=manager_.NotificationInvoked([callback=std::move(callback)](const auto&,const auto& args){
            try{callback(winrt::to_string(args.Argument()));}catch(...){/* Native event boundaries never propagate. */}
        });subscribed_=true;
        try{manager_.Register();registered_=true;}catch(...){stop();throw;}
    }
    void stop()noexcept override{
        if(manager_){if(subscribed_)manager_.NotificationInvoked(invoked_);if(registered_)try{manager_.Unregister();}catch(...){}}
        subscribed_=false;registered_=false;manager_=nullptr;
    }
    bool permitted()override{return registered_&&manager_.Setting()==winrt::Microsoft::Windows::AppNotifications::AppNotificationSetting::Enabled;}
    void show(const WindowsNotificationPayload& payload)override{
        if(!registered_)throw std::logic_error("Enable app notifications before delivery");
        winrt::Microsoft::Windows::AppNotifications::AppNotification value(payload.xml);
        value.Tag(winrt::to_hstring(payload.tag));value.Group(winrt::to_hstring(payload.group));
        value.Expiration(winrt::clock::from_sys(std::chrono::sys_seconds{std::chrono::seconds{payload.expires}}));
        manager_.Show(value);
        if(!value.Id())throw std::runtime_error("Windows did not accept the app notification");
    }
    winrt::Windows::Foundation::IAsyncAction remove(std::string tag,std::string group)override{
        const auto manager=manager_;if(manager)co_await manager.RemoveByTagAndGroupAsync(winrt::to_hstring(tag),winrt::to_hstring(group));
    }
    winrt::Windows::Foundation::IAsyncAction remove_group(std::string group)override{
        const auto manager=manager_;if(manager)co_await manager.RemoveByGroupAsync(winrt::to_hstring(group));
    }
    ~AppNotificationTransport(){stop();}
};

// All public operations, including activation, run on the caller's UI thread. The native
// callback is posted there using Post. It receives no executable, URL, path, or arbitrary args.
// Registration/cold-start forwarding to a nondefault DataRoot belongs to app lifecycle code;
// a mismatched user/data scope is rejected here, never opened from untrusted activation text.
class WindowsNotifications:public std::enable_shared_from_this<WindowsNotifications> {
public:
    using Post=std::function<bool(std::function<void()>)>;
    using Activate=std::function<void(std::string)>;
    using Eligible=std::function<bool(const std::string&)>;
    using Clock=std::function<std::int64_t()>;
    using Error=std::function<void(std::string)>;
private:
    using Object=winrt::Windows::Data::Json::JsonObject;
    using Value=winrt::Windows::Data::Json::JsonValue;
    struct Route{std::string thread,token;std::int64_t created{},expires{};bool delivered{};};
    std::filesystem::path directory_;HANDLE directory_handle_{INVALID_HANDLE_VALUE};
    std::string scope_,group_;Object original_{nullptr};std::optional<std::string> snapshot_;
    std::map<std::string,Route> routes_;std::set<std::string> removing_;Post post_;Activate activate_;Eligible eligible_;Clock clock_;Error error_;
    std::shared_ptr<WindowsNotificationTransport> transport_;bool enabled_{},closed_{},disable_pending_{},changing_{};
    static constexpr std::size_t maximum_routes=1000,maximum_file=256*1024;
    static std::string random_token(){
        std::array<unsigned char,16> bytes{};if(BCryptGenRandom(nullptr,bytes.data(),static_cast<ULONG>(bytes.size()),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)throw std::runtime_error("Could not create a notification routing ID");
        constexpr char hex[]="0123456789abcdef";std::string result;for(const auto byte:bytes){result+=hex[byte>>4];result+=hex[byte&15];}return result;
    }
    static bool hex(std::string_view value,std::size_t count){return value.size()==count&&std::all_of(value.begin(),value.end(),[](char ch){return(ch>='0'&&ch<='9')||(ch>='a'&&ch<='f');});}
    static std::string identity(const std::string& value){
        if(value.size()!=36&&value.size()!=38)throw std::invalid_argument("Invalid notification conversation identity");
        const winrt::guid id(winrt::to_hstring(value));if(id==winrt::guid{})throw std::invalid_argument("An empty conversation cannot receive notifications");return winrt::to_string(winrt::to_hstring(id));
    }
    static std::string user_sid(){
        HANDLE token{};if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&token))winrt::throw_last_error();
        struct Close{HANDLE value;~Close(){CloseHandle(value);}} close{token};DWORD length{};GetTokenInformation(token,TokenUser,nullptr,0,&length);
        std::vector<unsigned char> bytes(length);if(!length||!GetTokenInformation(token,TokenUser,bytes.data(),length,&length))winrt::throw_last_error();
        PWSTR sid{};if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid,&sid))winrt::throw_last_error();
        const auto result=winrt::to_string(sid);LocalFree(sid);return result;
    }
    std::filesystem::path file()const{return directory_/L"notification-routes.json";}
    static std::optional<std::string> read(const std::filesystem::path& path){
        if(!std::filesystem::exists(path))return{};
        if(std::filesystem::file_size(path)>maximum_file)throw std::runtime_error("Notification routing metadata exceeds its bound");
        std::ifstream stream(path,std::ios::binary);if(!stream)throw std::runtime_error("Could not read notification routing metadata");
        std::string bytes;std::array<char,8192> block{};
        while(stream&&bytes.size()<=maximum_file){stream.read(block.data(),static_cast<std::streamsize>(std::min(block.size(),maximum_file+1-bytes.size())));bytes.append(block.data(),static_cast<std::size_t>(stream.gcount()));}
        if(stream.bad()||(!stream.eof()&&stream.fail())||bytes.size()>maximum_file)throw std::runtime_error("Notification routing metadata could not be read within its bound");return bytes;
    }
    static std::int64_t timestamp(const Object& value,const wchar_t* key){
        const auto number=value.GetNamedNumber(key);if(!std::isfinite(number)||number<0||number>253402300799.0||number!=std::floor(number))throw std::invalid_argument("Invalid notification expiry");return static_cast<std::int64_t>(number);
    }
    std::int64_t now()const{const auto value=clock_();if(value<0||value>253402214399LL)throw std::invalid_argument("Invalid notification clock");return value;}
    void load(){
        snapshot_=read(file());if(!snapshot_)return;
        const auto value=Object::Parse(winrt::to_hstring(*snapshot_));
        if(value.GetNamedNumber(L"version")!=1||value.GetNamedString(L"format")!=L"coincide.windows.notifications"||winrt::to_string(value.GetNamedString(L"scope"))!=scope_)throw std::runtime_error("Unsupported notification routing scope or format; metadata was preserved");
        const auto entries=value.GetNamedArray(L"routes");if(entries.Size()>maximum_routes)throw std::invalid_argument("Too many notification routes");
        std::map<std::string,Route> decoded;std::set<std::string> tokens;
        for(const auto& entry:entries){const auto object=entry.GetObject();Route route{identity(winrt::to_string(object.GetNamedString(L"thread"))),winrt::to_string(object.GetNamedString(L"token")),timestamp(object,L"created"),timestamp(object,L"expires"),object.GetNamedBoolean(L"delivered",false)};
            if(!hex(route.token,32)||route.expires<=route.created||route.expires-route.created>86400||!tokens.insert(route.token).second||!decoded.emplace(route.thread,route).second)throw std::invalid_argument("Invalid or duplicate notification route");}
        routes_.swap(decoded);original_=value;
    }
    void commit(std::map<std::string,Route> routes){
        auto document=original_?Object::Parse(original_.Stringify()):Object{};
        document.SetNamedValue(L"format",Value::CreateStringValue(L"coincide.windows.notifications"));document.SetNamedValue(L"version",Value::CreateNumberValue(1));document.SetNamedValue(L"scope",Value::CreateStringValue(winrt::to_hstring(scope_)));
        std::map<std::string,Object> originals;if(original_)for(const auto& raw:original_.GetNamedArray(L"routes")){const auto object=raw.GetObject();originals.emplace(identity(winrt::to_string(object.GetNamedString(L"thread"))),object);}
        winrt::Windows::Data::Json::JsonArray array;
        for(const auto& [id,route]:routes){auto value=originals.contains(id)?Object::Parse(originals.at(id).Stringify()):Object{};
            value.SetNamedValue(L"thread",Value::CreateStringValue(winrt::to_hstring(id)));value.SetNamedValue(L"token",Value::CreateStringValue(winrt::to_hstring(route.token)));value.SetNamedValue(L"created",Value::CreateNumberValue(static_cast<double>(route.created)));value.SetNamedValue(L"expires",Value::CreateNumberValue(static_cast<double>(route.expires)));value.SetNamedValue(L"delivered",Value::CreateBooleanValue(route.delivered));array.Append(value);}
        document.SetNamedValue(L"routes",array);auto bytes=winrt::to_string(document.Stringify());if(bytes.size()>maximum_file)throw std::runtime_error("Notification routing metadata exceeds its write bound");
        std::optional<std::string> next_snapshot(bytes);const auto temporary=directory_/winrt::to_hstring("notification-routes-"+random_token()+".tmp").c_str();
        const auto lock=CreateFileW((directory_/L"notification-routes.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);if(lock==INVALID_HANDLE_VALUE)winrt::throw_last_error();
        struct Close{HANDLE value;~Close(){CloseHandle(value);}} close{lock};
        try{
            if(read(file())!=snapshot_)throw std::runtime_error("Notification routing metadata changed; reopen before writing");
            const auto handle=CreateFileW(temporary.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(handle==INVALID_HANDLE_VALUE)winrt::throw_last_error();
            DWORD written{};const bool ok=WriteFile(handle,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)&&written==bytes.size()&&FlushFileBuffers(handle);const auto code=GetLastError();CloseHandle(handle);
            if(!ok)throw winrt::hresult_error(HRESULT_FROM_WIN32(code?code:ERROR_WRITE_FAULT));
            if(!MoveFileExW(temporary.c_str(),file().c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))winrt::throw_last_error();
            routes_.swap(routes);original_=std::move(document);snapshot_.swap(next_snapshot);
        }catch(...){DeleteFileW(temporary.c_str());throw;}
    }
    static std::wstring escaped(std::wstring_view text,std::size_t maximum){
        if(text.empty()||text.size()>maximum)throw std::invalid_argument("Notification text must be nonempty and bounded");std::wstring result;
        for(std::size_t i=0;i<text.size();++i){const auto ch=text[i];
            if(ch>=0xd800&&ch<=0xdbff){if(i+1==text.size()||text[i+1]<0xdc00||text[i+1]>0xdfff)throw std::invalid_argument("Invalid notification Unicode");result+=ch;result+=text[++i];continue;}
            if((ch>=0xdc00&&ch<=0xdfff)||(ch<32&&ch!=L'\t'&&ch!=L'\n'&&ch!=L'\r')||ch==0xfffe||ch==0xffff)throw std::invalid_argument("Unsupported notification XML character");
            switch(ch){case L'&':result+=L"&amp;";break;case L'<':result+=L"&lt;";break;case L'>':result+=L"&gt;";break;case L'\"':result+=L"&quot;";break;case L'\'':result+=L"&apos;";break;default:result+=ch;}
        }return result;
    }
    std::string tag(const std::string& thread)const{return "t"+AgentAccountScope::fingerprint("notification-thread",thread,scope_).substr(0,15);}
    void require_open()const{if(closed_)throw std::logic_error("The notification controller is closed");}
    WindowsNotifications(std::filesystem::path data,Post post,Activate activate,Eligible eligible,std::shared_ptr<WindowsNotificationTransport> transport,Clock clock,Error error):directory_(std::move(data)),post_(std::move(post)),activate_(std::move(activate)),eligible_(std::move(eligible)),clock_(std::move(clock)),error_(std::move(error)),transport_(std::move(transport)){
        if(!directory_.is_absolute()||!post_||!activate_||!eligible_)throw std::invalid_argument("Notifications require an absolute data root and explicit UI routing callbacks");
        if(!clock_)clock_=[](){return std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();};
        if(!transport_)transport_=std::make_shared<AppNotificationTransport>();
        std::filesystem::create_directories(directory_);
        directory_handle_=CreateFileW(directory_.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr);if(directory_handle_==INVALID_HANDLE_VALUE)winrt::throw_last_error();
        try{FILE_ID_INFO info{};std::array<wchar_t,32768> name{};const auto count=GetFinalPathNameByHandleW(directory_handle_,name.data(),static_cast<DWORD>(name.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
            if(!GetFileInformationByHandleEx(directory_handle_,FileIdInfo,&info,sizeof(info))||!count||count>=name.size())throw std::runtime_error("Could not bind notification storage to its physical data root");
            std::string id=std::to_string(info.VolumeSerialNumber)+":";constexpr char digits[]="0123456789abcdef";for(const auto byte:info.FileId.Identifier){id+=digits[byte>>4];id+=digits[byte&15];}
            directory_=std::filesystem::path(std::wstring(name.data(),count));scope_=AgentAccountScope::fingerprint("windows-notifications",user_sid(),id);group_="c"+scope_.substr(0,15);load();
        }catch(...){CloseHandle(directory_handle_);directory_handle_=INVALID_HANDLE_VALUE;throw;}
    }
public:
    static std::shared_ptr<WindowsNotifications> create(std::filesystem::path data,Post post,Activate activate,Eligible eligible,std::shared_ptr<WindowsNotificationTransport> transport={},Clock clock={},Error error={}){
        return std::shared_ptr<WindowsNotifications>(new WindowsNotifications(std::move(data),std::move(post),std::move(activate),std::move(eligible),std::move(transport),std::move(clock),std::move(error)));
    }
    bool enabled()const{return enabled_&&!closed_;}
    std::string group()const{return group_;}
    winrt::Windows::Foundation::IAsyncAction set_enabled(bool value){
        const auto lifetime=shared_from_this();require_open();if(changing_)throw std::runtime_error("A notification preference update is already pending");
        changing_=true;struct Reset{bool& value;~Reset(){value=false;}} reset{changing_};
        if(value){if(enabled_)co_return;if(disable_pending_){commit({});disable_pending_=false;}
            const auto current=now();auto valid=routes_;std::erase_if(valid,[&](const auto& item){return !item.second.delivered||item.second.expires<=current||item.second.created>current;});if(valid.size()!=routes_.size())commit(std::move(valid));
            const auto weak=weak_from_this();transport_->start([weak](std::string argument){if(const auto self=weak.lock()){
                try{self->post_([weak,argument=std::move(argument)]{if(const auto current=weak.lock())try{current->activate(argument);}catch(const std::exception& error){if(current->error_)current->error_(error.what());}catch(...){if(current->error_)current->error_("Notification activation failed");}});}catch(...){}}
            });try{if(!transport_->permitted())throw std::runtime_error("Windows has disabled notifications for this app or user; no notification was sent");}catch(...){transport_->stop();throw;}enabled_=true;co_return;
        }
        enabled_=false;disable_pending_=true;
        try{commit({});disable_pending_=false;co_await transport_->remove_group(group_);}catch(...){transport_->stop();throw;}
        transport_->stop();
    }
    bool notify(const std::string& thread,std::wstring_view title,std::wstring_view body){
        require_open();if(!enabled_||changing_)return false;const auto id=identity(thread);if(!eligible_(id)||removing_.contains(id))return false;
        if(!transport_->permitted())throw std::runtime_error("Windows has disabled notifications for this app or user; no notification was sent");
        const auto current=now();const auto nonce=random_token();const auto argument="coincide-notification-v1."+scope_+"."+nonce;
        const auto xml=L"<toast activationType=\"foreground\" launch=\""+std::wstring(winrt::to_hstring(argument).c_str())+L"\"><visual><binding template=\"ToastGeneric\"><text>"+escaped(title,256)+L"</text><text>"+escaped(body,1024)+L"</text></binding></visual><audio silent=\"true\"/></toast>";
        if(winrt::to_string(xml).size()>4096)throw std::invalid_argument("Notification payload exceeds its bounded size");
        auto values=routes_;std::erase_if(values,[&](const auto& item){return item.second.expires<=current;});
        values.insert_or_assign(id,Route{id,nonce,current,current+86400});if(values.size()>maximum_routes)throw std::runtime_error("Dismiss older notifications before adding more conversations");commit(std::move(values));
        try{transport_->show({id,tag(id),group_,argument,xml,current+86400});auto delivered=routes_;delivered.at(id).delivered=true;commit(std::move(delivered));}catch(...){auto rejected=routes_;rejected.erase(id);try{commit(std::move(rejected));}catch(...){enabled_=false;disable_pending_=true;transport_->stop();}throw;}
        return true;
    }
    winrt::Windows::Foundation::IAsyncAction dismiss(const std::string& thread){
        const auto lifetime=shared_from_this();require_open();const auto id=identity(thread);if(!removing_.insert(id).second)throw std::runtime_error("This conversation notification is already being dismissed");
        struct Removing{std::set<std::string>& values;std::string id;~Removing(){values.erase(id);}} removing{removing_,id};
        auto values=routes_;values.erase(id);commit(std::move(values));
        co_await transport_->remove(tag(id),group_);
    }
    bool activate(const std::string& argument){
        if(!enabled()||changing_||argument.size()!=122||!argument.starts_with("coincide-notification-v1."))return false;
        constexpr std::size_t prefix=25;if(argument.substr(prefix,64)!=scope_||argument[prefix+64]!='.'||!hex(std::string_view(argument).substr(prefix+65),32))return false;
        const auto token=argument.substr(prefix+65);const auto current=now();
        const auto found=std::find_if(routes_.begin(),routes_.end(),[&](const auto& item){return item.second.token==token;});
        if(found==routes_.end()||!found->second.delivered||found->second.expires<=current||found->second.created>current)return false;
        if(!eligible_(found->first)){auto values=routes_;values.erase(found->first);commit(std::move(values));return false;}
        const auto id=found->first;auto values=routes_;values.erase(id);commit(std::move(values));activate_(id);return true;
    }
    void close()noexcept{if(closed_)return;closed_=true;enabled_=false;transport_->stop();if(directory_handle_!=INVALID_HANDLE_VALUE){CloseHandle(directory_handle_);directory_handle_=INVALID_HANDLE_VALUE;}}
    ~WindowsNotifications(){close();}
    WindowsNotifications(const WindowsNotifications&)=delete;WindowsNotifications& operator=(const WindowsNotifications&)=delete;
};
} // namespace coincide
