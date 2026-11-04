#pragma once
#include <windows.h>
#include <winrt/base.h>
#include <stdexcept>
#include <cwctype>
#include <shellapi.h>
#include <sddl.h>
#include <powrprof.h>
#include "AgentAccountScope.h"
#include <filesystem>
#include <functional>
#include <string>
#include <vector>
#include <memory>
#pragma comment(lib,"powrprof.lib")
#pragma comment(lib,"shell32.lib")
#pragma comment(lib,"advapi32.lib")

namespace coincide {
struct PowerPolicy {bool enabled{},on_battery{},display{};};
struct PowerDemand {bool system{},display{};bool operator==(const PowerDemand&)const=default;};
inline PowerDemand power_demand(PowerPolicy policy,bool on_ac){const bool active=policy.enabled&&(on_ac||policy.on_battery);return{active,active&&policy.display};}
class PowerRequest {
    HANDLE handle_{INVALID_HANDLE_VALUE};PowerDemand current_{};
public:
    PowerRequest()=default;PowerRequest(const PowerRequest&)=delete;PowerRequest& operator=(const PowerRequest&)=delete;
    ~PowerRequest(){close();}
    PowerDemand current()const{return current_;}
    void update(PowerPolicy policy){
        SYSTEM_POWER_STATUS status{};const bool known=GetSystemPowerStatus(&status)!=FALSE;apply(power_demand(policy,known&&status.ACLineStatus==1));
    }
    void apply(PowerDemand demand){
        if(demand.display&&!demand.system)throw std::invalid_argument("Display activity requires an enabled system activity request");
        if(demand==current_)return;
        if(handle_==INVALID_HANDLE_VALUE&&(demand.system||demand.display)){
            REASON_CONTEXT context{};context.Version=POWER_REQUEST_CONTEXT_VERSION;context.Flags=POWER_REQUEST_CONTEXT_SIMPLE_STRING;
            context.Reason.SimpleReasonString=const_cast<PWSTR>(L"Coincide Keep Awake");handle_=PowerCreateRequest(&context);
            if(handle_==INVALID_HANDLE_VALUE)throw std::runtime_error("Windows could not create this app's sleep request");
        }
        if(demand.system!=current_.system){const bool success=demand.system?PowerSetRequest(handle_,PowerRequestSystemRequired)!=FALSE:PowerClearRequest(handle_,PowerRequestSystemRequired)!=FALSE;if(!success)throw std::runtime_error("Windows could not update this app's sleep request");current_.system=demand.system;}
        if(demand.display!=current_.display){const bool success=demand.display?PowerSetRequest(handle_,PowerRequestDisplayRequired)!=FALSE:PowerClearRequest(handle_,PowerRequestDisplayRequired)!=FALSE;if(!success)throw std::runtime_error("Windows could not update this app's display request");current_.display=demand.display;}
        if(!current_.system&&!current_.display&&handle_!=INVALID_HANDLE_VALUE){CloseHandle(handle_);handle_=INVALID_HANDLE_VALUE;}
    }
    void close()noexcept{if(handle_!=INVALID_HANDLE_VALUE){if(current_.display)PowerClearRequest(handle_,PowerRequestDisplayRequired);if(current_.system)PowerClearRequest(handle_,PowerRequestSystemRequired);CloseHandle(handle_);handle_=INVALID_HANDLE_VALUE;}current_={};}
};
// The controller owns only its mutex, message window, tray icon and process-scoped power request.
// It installs no service/startup entry and changes no machine-wide sleep, lid, sound or network setting.
class DesktopServices {
    struct CloseNative{void operator()(void* value)const noexcept{if(value&&value!=INVALID_HANDLE_VALUE)CloseHandle(value);}};
    std::unique_ptr<void,CloseNative> data_handle_;
    HANDLE mutex_{};HWND host_{},owner_{};HINSTANCE module_{};std::wstring class_name_;bool primary_{true},icon_{};
    std::function<void()> open_,quit_,resume_;std::function<void(std::string)> activate_;
    std::string notification_thread_;UINT taskbar_message_{};
    static constexpr UINT tray_message=WM_APP+0x270,activate_message=WM_APP+0x271;
    static std::wstring sid(){
        HANDLE raw{};if(!OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&raw))throw std::runtime_error("Could not identify the current Windows user");struct Close{HANDLE value;~Close(){CloseHandle(value);}} close{raw};
        DWORD needed{};GetTokenInformation(raw,TokenUser,nullptr,0,&needed);std::vector<unsigned char> bytes(needed);if(!needed||!GetTokenInformation(raw,TokenUser,bytes.data(),needed,&needed))throw std::runtime_error("Could not read the Windows user identity");
        PWSTR text{};if(!ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(bytes.data())->User.Sid,&text))throw std::runtime_error("Could not scope the Windows app instance");std::wstring result(text);LocalFree(text);return result;
    }
    static LRESULT CALLBACK procedure(HWND window,UINT message,WPARAM first,LPARAM second){
        auto self=reinterpret_cast<DesktopServices*>(GetWindowLongPtrW(window,GWLP_USERDATA));
        if(message==WM_NCCREATE){self=static_cast<DesktopServices*>(reinterpret_cast<CREATESTRUCTW*>(second)->lpCreateParams);SetWindowLongPtrW(window,GWLP_USERDATA,reinterpret_cast<LONG_PTR>(self));}
        if(self){try{
            if(message==activate_message){if(self->open_)self->open_();return 0;}
            if(message==self->taskbar_message_){self->icon_=false;self->add_icon();return 0;}
            if(message==tray_message){const auto event=LOWORD(second);
                if(event==WM_LBUTTONUP||event==NIN_SELECT||event==NIN_KEYSELECT){if(self->open_)self->open_();return 0;}
                if(event==NIN_BALLOONUSERCLICK){auto activate=self->activate_;auto thread=self->notification_thread_;if(activate)activate(std::move(thread));else if(self->open_)self->open_();return 0;}
                if(event==WM_CONTEXTMENU||event==WM_RBUTTONUP){self->menu();return 0;}
            }
            if((message==WM_POWERBROADCAST&&(first==PBT_APMRESUMEAUTOMATIC||first==PBT_APMRESUMESUSPEND))||message==WM_TIMECHANGE){if(self->resume_)self->resume_();return TRUE;}
            if(message==WM_QUERYENDSESSION){if(self->quit_)self->quit_();return TRUE;}
        }catch(...){return message==WM_QUERYENDSESSION?TRUE:0;}}
        return DefWindowProcW(window,message,first,second);
    }
    void add_icon(){
        if(!host_||!owner_)return;NOTIFYICONDATAW data{};data.cbSize=sizeof(data);data.hWnd=host_;data.uID=1;data.uFlags=NIF_MESSAGE|NIF_ICON|NIF_TIP;data.uCallbackMessage=tray_message;data.hIcon=LoadIconW(nullptr,IDI_APPLICATION);wcscpy_s(data.szTip,L"Coincide");
        if(Shell_NotifyIconW(NIM_ADD,&data)){icon_=true;data.uVersion=NOTIFYICON_VERSION_4;Shell_NotifyIconW(NIM_SETVERSION,&data);}
    }
    void menu(){
        HMENU menu=CreatePopupMenu();if(!menu)return;AppendMenuW(menu,MF_STRING,1,L"Open Coincide");AppendMenuW(menu,MF_SEPARATOR,0,nullptr);AppendMenuW(menu,MF_STRING,2,L"Quit Coincide");
        POINT point{};GetCursorPos(&point);SetForegroundWindow(owner_);const auto action=TrackPopupMenu(menu,TPM_RETURNCMD|TPM_NONOTIFY,point.x,point.y,0,owner_,nullptr);DestroyMenu(menu);PostMessageW(owner_,WM_NULL,0,0);
        if(action==1&&open_)open_();else if(action==2&&quit_)quit_();
    }
public:
    explicit DesktopServices(const std::filesystem::path& data){
        if(!data.is_absolute())throw std::invalid_argument("Desktop services need an absolute app data directory");
        std::filesystem::create_directories(data);
        const auto directory=CreateFileW(data.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr);
        if(directory==INVALID_HANDLE_VALUE)throw std::runtime_error("Could not pin the app data directory");data_handle_.reset(directory);
        FILE_ID_INFO info{};if(!GetFileInformationByHandleEx(directory,FileIdInfo,&info,sizeof(info)))throw std::runtime_error("Could not identify the app data directory");
        std::string identity=std::to_string(info.VolumeSerialNumber)+":";constexpr char digits[]="0123456789abcdef";for(const auto byte:info.FileId.Identifier){identity+=digits[byte>>4];identity+=digits[byte&15];}
        const auto user=sid();class_name_=L"Coincide.Desktop."+winrt::to_hstring(AgentAccountScope::fingerprint("windows-instance",winrt::to_string(user),identity));
        PSECURITY_DESCRIPTOR descriptor{};const auto sddl=L"D:P(A;;GA;;;SY)(A;;GA;;;"+user+L")";
        if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(),SDDL_REVISION_1,&descriptor,nullptr))throw std::runtime_error("Could not protect the app instance");
        SECURITY_ATTRIBUTES attributes{sizeof(attributes),descriptor,FALSE};mutex_=CreateMutexW(&attributes,FALSE,(L"Local\\"+class_name_).c_str());const auto error=GetLastError();LocalFree(descriptor);
        if(!mutex_)throw std::runtime_error("Could not reserve this app data folder");primary_=error!=ERROR_ALREADY_EXISTS;
        if(!primary_){if(const auto existing=FindWindowW(class_name_.c_str(),nullptr))PostMessageW(existing,activate_message,0,0);return;}
        module_=GetModuleHandleW(nullptr);WNDCLASSW type{};type.lpfnWndProc=procedure;type.hInstance=module_;type.lpszClassName=class_name_.c_str();if(!RegisterClassW(&type)&&GetLastError()!=ERROR_CLASS_ALREADY_EXISTS){CloseHandle(mutex_);mutex_=nullptr;throw std::runtime_error("Could not register the app message window");}
        taskbar_message_=RegisterWindowMessageW(L"TaskbarCreated");host_=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,class_name_.c_str(),L"Coincide",WS_POPUP,0,0,0,0,nullptr,nullptr,module_,this);
        if(!host_){CloseHandle(mutex_);mutex_=nullptr;throw std::runtime_error("Could not create the app message window");}
    }
    bool primary()const{return primary_;}
    void attach(HWND owner,std::function<void()> open,std::function<void()> quit,std::function<void(std::string)> activate={},std::function<void()> resume={}){owner_=owner;open_=std::move(open);quit_=std::move(quit);activate_=std::move(activate);resume_=std::move(resume);add_icon();}
    bool tray_available()const{return icon_;}
    void notify(std::string thread,const std::wstring& title,const std::wstring& body){
        if(!icon_)return;notification_thread_=std::move(thread);NOTIFYICONDATAW data{};data.cbSize=sizeof(data);data.hWnd=host_;data.uID=1;data.uFlags=NIF_INFO;data.dwInfoFlags=NIIF_INFO|NIIF_RESPECT_QUIET_TIME;
        wcsncpy_s(data.szInfoTitle,title.c_str(),_TRUNCATE);wcsncpy_s(data.szInfo,body.c_str(),_TRUNCATE);Shell_NotifyIconW(NIM_MODIFY,&data);
    }
    void dismiss_notification(const std::string& thread){if(thread!=notification_thread_||!icon_)return;NOTIFYICONDATAW data{};data.cbSize=sizeof(data);data.hWnd=host_;data.uID=1;data.uFlags=NIF_INFO;Shell_NotifyIconW(NIM_MODIFY,&data);notification_thread_.clear();}
    void close()noexcept{if(icon_&&host_){NOTIFYICONDATAW data{};data.cbSize=sizeof(data);data.hWnd=host_;data.uID=1;Shell_NotifyIconW(NIM_DELETE,&data);icon_=false;}if(host_){DestroyWindow(host_);host_=nullptr;}if(mutex_){CloseHandle(mutex_);mutex_=nullptr;}data_handle_.reset();}
    ~DesktopServices(){close();}
    DesktopServices(const DesktopServices&)=delete;DesktopServices& operator=(const DesktopServices&)=delete;
};
}
