#pragma once
#include "ComputerUsePolicy.h"
#include "ComputerUseDesktopLease.h"
#include <UIAutomation.h>
#include <wincodec.h>
#include <wincrypt.h>
#include <sstream>
#include <iomanip>
#include <iostream>
#include <filesystem>
#include <TlHelp32.h>
#include <thread>
#pragma comment(lib,"uiautomationcore.lib")
#pragma comment(lib,"windowscodecs.lib")
#pragma comment(lib,"crypt32.lib")
#pragma comment(lib,"gdi32.lib")
#pragma comment(lib,"user32.lib")
#pragma comment(lib,"oleaut32.lib")

namespace coincide::computer_use {
// Native code belongs in the owned helper, never on XAML's dispatcher. Construction is inert.
// UIA provider calls and PrintWindow can hang in other applications; the parent process backend
// imposes the deadline and terminates only its helper job. No UIAccess/elevation is requested.
class NativeBackend final:public Backend {
    struct Window {HWND handle{};DWORD pid{};std::uint64_t created{};};
    struct Element {Window window;winrt::com_ptr<IUIAutomationElement> value;std::vector<int> runtime,root_runtime;};
    struct Shot {Window window;RECT bounds{};std::vector<int> root_runtime;};
    struct Session {std::map<std::string,Element> elements;std::map<std::string,Shot> shots;};
    winrt::com_ptr<IUIAutomation> automation_;std::map<std::string,Session> sessions_;std::map<std::wstring,std::unique_ptr<DesktopLease>> leases_;DWORD app_pid_{};std::uint64_t epoch_{1};
    DesktopLease::Guard input_lease(const Window& window,const std::string& thread){const auto scope=DesktopLease::Scope::for_window(window.handle);auto& lease=leases_[scope.name()];if(!lease)lease=std::make_unique<DesktopLease>(scope);auto guard=lease->try_acquire(thread);if(!guard)throw std::runtime_error("Another conversation or Coincide instance owns this Windows desktop; wait or release its control");return std::move(*guard);}
    static std::string window_id(HWND window){std::ostringstream output;output<<std::hex<<reinterpret_cast<std::uintptr_t>(window);return output.str();}
    static HWND window_handle(const std::string& value){std::uintptr_t number{};std::istringstream input(value);input>>std::hex>>number;if(!input||!input.eof()||!number)throw std::invalid_argument("Invalid native window identity");return reinterpret_cast<HWND>(number);}
    static std::wstring lower(std::wstring value){for(auto& ch:value)if(ch>=L'A'&&ch<=L'Z')ch=static_cast<wchar_t>(ch+32);return value;}
    static bool blocked_program(const std::wstring& path){const auto base=lower(std::filesystem::path(path).filename().wstring());
        static const std::set<std::wstring> denied{L"chrome.exe",L"msedge.exe",L"firefox.exe",L"brave.exe",L"opera.exe",L"vivaldi.exe",L"iexplore.exe",L"arc.exe",L"browser.exe",L"chromium.exe",L"tor.exe",L"keepass.exe",L"keepassxc.exe",L"1password.exe",L"bitwarden.exe",L"credentialuibroker.exe",L"consent.exe",L"logonui.exe",L"cmd.exe",L"powershell.exe",L"pwsh.exe",L"windowsterminal.exe",L"wt.exe",L"conhost.exe",L"openconsole.exe"};return denied.contains(base);}
    static DWORD integrity(HANDLE process){HANDLE raw{};if(!OpenProcessToken(process,TOKEN_QUERY,&raw))winrt::throw_last_error();struct Close{HANDLE value;~Close(){CloseHandle(value);}}close{raw};DWORD bytes{};GetTokenInformation(raw,TokenIntegrityLevel,nullptr,0,&bytes);std::vector<BYTE> buffer(bytes);if(!bytes||!GetTokenInformation(raw,TokenIntegrityLevel,buffer.data(),bytes,&bytes))winrt::throw_last_error();const auto label=reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buffer.data());const auto count=*GetSidSubAuthorityCount(label->Label.Sid);if(!count)throw std::runtime_error("Cannot validate the target integrity level");return *GetSidSubAuthority(label->Label.Sid,count-1);}
    static void normal_desktop(){const auto desktop=OpenInputDesktop(0,FALSE,DESKTOP_READOBJECTS);if(!desktop)throw std::runtime_error("Computer Use cannot access the current input desktop");struct Close{HDESK value;~Close(){CloseDesktop(value);}}close{desktop};std::array<wchar_t,256> name{};DWORD size{};if(!GetUserObjectInformationW(desktop,UOI_NAME,name.data(),static_cast<DWORD>(sizeof(name)),&size)||lower(name.data())!=L"default")throw std::runtime_error("Computer Use does not operate on a secure desktop");}
    Window checked(HWND handle,DWORD expected=0)const{
        normal_desktop();DWORD pid{},session{};if(!IsWindow(handle)||!IsWindowVisible(handle)||!GetWindowThreadProcessId(handle,&pid)||(expected&&pid!=expected)||pid==app_pid_||pid==GetCurrentProcessId()||!ProcessIdToSessionId(pid,&session))throw std::runtime_error("The native window is stale or protected");
        DWORD current{};if(!ProcessIdToSessionId(GetCurrentProcessId(),&current)||session!=current)throw std::runtime_error("The native window is in another user session");
        const auto process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);if(!process)throw std::runtime_error("The target process is unavailable");struct Close{HANDLE value;~Close(){CloseHandle(value);}}close{process};std::array<wchar_t,32768> path{};DWORD size=static_cast<DWORD>(path.size());
        FILETIME created{},exited{},kernel{},user{};if(!QueryFullProcessImageNameW(process,0,path.data(),&size)||blocked_program(std::wstring(path.data(),size))||!GetProcessTimes(process,&created,&exited,&kernel,&user)||integrity(process)>integrity(GetCurrentProcess()))throw std::runtime_error("Browser, credential, shell and elevated applications are unavailable through this native service");
        return{handle,pid,(static_cast<std::uint64_t>(created.dwHighDateTime)<<32)|created.dwLowDateTime};
    }
    void current(const Window& value)const{const auto found=checked(value.handle,value.pid);if(found.created!=value.created)throw std::runtime_error("The native process identity changed; observe it again");}
    static void cancelled(const std::function<bool()>& predicate){if(predicate())throw std::runtime_error("Computer Use was revoked or cancelled");}
    void initialize(){if(automation_)return;winrt::check_hresult(CoCreateInstance(CLSID_CUIAutomation8,nullptr,CLSCTX_INPROC_SERVER,__uuidof(IUIAutomation),automation_.put_void()));if(const auto timed=automation_.try_as<IUIAutomation2>()){timed->put_ConnectionTimeout(1000);timed->put_TransactionTimeout(1500);}}
    static std::wstring string_property(IUIAutomationElement* element,PROPERTYID property){VARIANT value{};VariantInit(&value);winrt::check_hresult(element->GetCurrentPropertyValue(property,&value));struct Clear{VARIANT* value;~Clear(){VariantClear(value);}}clear{&value};if(value.vt!=VT_BSTR||!value.bstrVal)return{};const auto count=SysStringLen(value.bstrVal);if(count>8192)throw std::runtime_error("A native accessibility label exceeds its bound");return std::wstring(value.bstrVal,count);}
    static bool restricted(IUIAutomationElement* element){BOOL password{};winrt::check_hresult(element->get_CurrentIsPassword(&password));if(password)return true;const auto framework=lower(string_property(element,UIA_FrameworkIdPropertyId));const auto klass=lower(string_property(element,UIA_ClassNamePropertyId));return framework==L"chrome"||framework==L"mozilla"||framework==L"internetexplorer"||klass.find(L"chrome_render")!=std::wstring::npos||klass.find(L"mozilla")!=std::wstring::npos||klass.find(L"webview")!=std::wstring::npos;}
    static std::vector<int> runtime(IUIAutomationElement* element){SAFEARRAY* raw{};winrt::check_hresult(element->GetRuntimeId(&raw));if(!raw)throw std::runtime_error("The native control has no stable runtime identity");struct Destroy{SAFEARRAY* value;~Destroy(){SafeArrayDestroy(value);}}destroy{raw};LONG low{},high{};winrt::check_hresult(SafeArrayGetLBound(raw,1,&low));winrt::check_hresult(SafeArrayGetUBound(raw,1,&high));if(high<low||high-low>64)throw std::runtime_error("The native control identity exceeds its bound");std::vector<int> result;for(LONG index=low;index<=high;++index){int value{};winrt::check_hresult(SafeArrayGetElement(raw,&index,&value));result.push_back(value);}return result;}
    static Object bounds(RECT rectangle){Object value;value.SetNamedValue(L"x",Value::CreateNumberValue(rectangle.left));value.SetNamedValue(L"y",Value::CreateNumberValue(rectangle.top));value.SetNamedValue(L"width",Value::CreateNumberValue(rectangle.right-rectangle.left));value.SetNamedValue(L"height",Value::CreateNumberValue(rectangle.bottom-rectangle.top));return value;}
    static RECT rectangle(HWND window){RECT result{};if(!GetWindowRect(window,&result)||result.right<=result.left||result.bottom<=result.top)throw std::runtime_error("The target has no capturable window bounds");return result;}
    Object windows(bool apps,const std::function<bool()>& cancel){
        struct List{const NativeBackend* self;Array values;std::set<DWORD> pids;bool apps;std::function<bool()> cancel;};List state{this,Array{}, {},apps,cancel};
        EnumWindows([](HWND window,LPARAM context)->BOOL{auto& list=*reinterpret_cast<List*>(context);if(list.cancel()||list.values.Size()>=256)return FALSE;
            try{const auto value=list.self->checked(window);if(list.apps&&!list.pids.insert(value.pid).second)return TRUE;std::array<wchar_t,1025> title{};const auto size=GetWindowTextW(window,title.data(),static_cast<int>(title.size()));if(size<=0)return TRUE;Object entry;entry.SetNamedValue(L"pid",Value::CreateNumberValue(value.pid));put(entry,L"window_id",window_id(window));put(entry,L"title",winrt::to_string(std::wstring_view(title.data(),size)));entry.SetNamedValue(L"bounds",bounds(rectangle(window)));list.values.Append(entry);}catch(...){ }return TRUE;
        },reinterpret_cast<LPARAM>(&state));cancelled(cancel);Object result;result.SetNamedValue(apps?L"apps":L"windows",state.values);return result;
    }
    static std::string base64(const BYTE* bytes,DWORD size){DWORD length{};if(!CryptBinaryToStringA(bytes,size,CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,nullptr,&length))winrt::throw_last_error();std::string result(length,'\0');if(!CryptBinaryToStringA(bytes,size,CRYPT_STRING_BASE64|CRYPT_STRING_NOCRLF,result.data(),&length))winrt::throw_last_error();result.resize(length);if(!result.empty()&&result.back()=='\0')result.pop_back();return result;}
    Object capture(const Window& window,RECT area,const std::function<bool()>& cancel){
        current(window);cancelled(cancel);DWORD affinity{};if(IsIconic(window.handle)||(GetWindowDisplayAffinity(window.handle,&affinity)&&affinity!=WDA_NONE))throw std::runtime_error("The target window is minimized or excludes capture");
        const LONG width=area.right-area.left,height=area.bottom-area.top;if(width<=0||height<=0||width>4096||height>4096||static_cast<std::uint64_t>(width)*height>12*1024*1024)throw std::runtime_error("The target window exceeds the screenshot dimensions");
        const auto dc=CreateCompatibleDC(nullptr);if(!dc)winrt::throw_last_error();struct DC{HDC value;~DC(){DeleteDC(value);}}close{dc};BITMAPINFO info{};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=width;info.bmiHeader.biHeight=-height;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
        void* pixels{};const auto bitmap=CreateDIBSection(dc,&info,DIB_RGB_COLORS,&pixels,nullptr,0);if(!bitmap)winrt::throw_last_error();struct Bitmap{HBITMAP value;~Bitmap(){DeleteObject(value);}}image{bitmap};const auto previous=SelectObject(dc,bitmap);const bool rendered=PrintWindow(window.handle,dc,2)!=FALSE;SelectObject(dc,previous);cancelled(cancel);current(window);if(!rendered)throw std::runtime_error("The native app did not provide its window image");
        winrt::com_ptr<IWICImagingFactory> factory;winrt::check_hresult(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,__uuidof(IWICImagingFactory),factory.put_void()));winrt::com_ptr<IStream> stream;winrt::check_hresult(CreateStreamOnHGlobal(nullptr,TRUE,stream.put()));winrt::com_ptr<IWICBitmapEncoder> encoder;winrt::check_hresult(factory->CreateEncoder(GUID_ContainerFormatPng,nullptr,encoder.put()));winrt::check_hresult(encoder->Initialize(stream.get(),WICBitmapEncoderNoCache));winrt::com_ptr<IWICBitmapFrameEncode> frame;winrt::com_ptr<IPropertyBag2> properties;winrt::check_hresult(encoder->CreateNewFrame(frame.put(),properties.put()));winrt::check_hresult(frame->Initialize(properties.get()));winrt::check_hresult(frame->SetSize(static_cast<UINT>(width),static_cast<UINT>(height)));WICPixelFormatGUID format=GUID_WICPixelFormat32bppBGR;winrt::check_hresult(frame->SetPixelFormat(&format));if(format!=GUID_WICPixelFormat32bppBGR)throw std::runtime_error("The PNG encoder requires an unsupported pixel format");winrt::check_hresult(frame->WritePixels(static_cast<UINT>(height),static_cast<UINT>(width*4),static_cast<UINT>(width*height*4),static_cast<BYTE*>(pixels)));winrt::check_hresult(frame->Commit());winrt::check_hresult(encoder->Commit());STATSTG stat{};winrt::check_hresult(stream->Stat(&stat,STATFLAG_NONAME));if(stat.cbSize.QuadPart>2*1024*1024)throw std::runtime_error("The PNG exceeds its bounded image size");HGLOBAL global{};winrt::check_hresult(GetHGlobalFromStream(stream.get(),&global));const auto bytes=static_cast<BYTE*>(GlobalLock(global));if(!bytes)winrt::throw_last_error();std::string encoded;try{encoded=base64(bytes,stat.cbSize.LowPart);}catch(...){GlobalUnlock(global);throw;}GlobalUnlock(global);Object result;put(result,L"mimeType","image/png");put(result,L"data",encoded);result.SetNamedValue(L"width",Value::CreateNumberValue(width));result.SetNamedValue(L"height",Value::CreateNumberValue(height));return result;
    }
    Object observe(const std::string& thread,const Object& arguments,const std::function<bool()>& cancel){
        initialize();const auto window=checked(window_handle(text(arguments,L"window_id")),static_cast<DWORD>(integer(arguments,L"pid",1,MAXDWORD)));winrt::com_ptr<IUIAutomationElement> root;winrt::check_hresult(automation_->ElementFromHandle(window.handle,root.put()));
        const auto root_runtime=runtime(root.get());const auto maximum=arguments.HasKey(L"max_elements")?integer(arguments,L"max_elements",1,512):128;const auto depth_limit=arguments.HasKey(L"max_depth")?integer(arguments,L"max_depth",1,12):8;
        const auto query=arguments.HasKey(L"query")?lower(winrt::to_hstring(text(arguments,L"query")).c_str()):std::wstring{};auto& session=sessions_[thread];session.elements.clear();session.shots.clear();Array elements;bool protected_tree{},truncated{};std::size_t visited{};const auto deadline=GetTickCount64()+4000;
        winrt::com_ptr<IUIAutomationTreeWalker> walker;winrt::check_hresult(automation_->get_ControlViewWalker(walker.put()));
        std::function<void(IUIAutomationElement*,std::int64_t)> walk=[&](IUIAutomationElement* element,std::int64_t depth){
            cancelled(cancel);if(visited>=512||GetTickCount64()>deadline){truncated=true;return;}++visited;int pid{};if(FAILED(element->get_CurrentProcessId(&pid))||pid!=static_cast<int>(window.pid)){protected_tree=true;return;}
            try{if(restricted(element)){protected_tree=true;return;}const auto name=string_property(element,UIA_NamePropertyId);CONTROLTYPEID role{};BOOL enabled{},offscreen{};RECT area{};winrt::check_hresult(element->get_CurrentControlType(&role));winrt::check_hresult(element->get_CurrentIsEnabled(&enabled));winrt::check_hresult(element->get_CurrentIsOffscreen(&offscreen));winrt::check_hresult(element->get_CurrentBoundingRectangle(&area));
                if(query.empty()||lower(name).find(query)!=std::wstring::npos){if(elements.Size()>=maximum){truncated=true;return;}Object item;put(item,L"name",winrt::to_string(name));item.SetNamedValue(L"role",Value::CreateNumberValue(role));item.SetNamedValue(L"bounds",bounds(area));item.SetNamedValue(L"enabled",Value::CreateBooleanValue(enabled!=FALSE));item.SetNamedValue(L"offscreen",Value::CreateBooleanValue(offscreen!=FALSE));
                    if(enabled&&!offscreen){const auto token=random_id();winrt::com_ptr<IUIAutomationElement> saved;saved.copy_from(element);session.elements.emplace(token,Element{window,std::move(saved),runtime(element),root_runtime});put(item,L"native_token",token);}elements.Append(item);}
                winrt::com_ptr<IUIAutomationElement> child;winrt::check_hresult(walker->GetFirstChildElement(element,child.put()));if(child&&depth>=depth_limit){truncated=true;return;}
                while(child){walk(child.get(),depth+1);if(truncated)break;winrt::com_ptr<IUIAutomationElement> next;winrt::check_hresult(walker->GetNextSiblingElement(child.get(),next.put()));child=std::move(next);}
            }catch(...){protected_tree=true;}
        };walk(root.get(),0);current(window);Object result;result.SetNamedValue(L"elements",elements);result.SetNamedValue(L"truncated",Value::CreateBooleanValue(truncated));result.SetNamedValue(L"protected_content",Value::CreateBooleanValue(protected_tree));
        if(arguments.GetNamedBoolean(L"include_screenshot",false)){
            if(protected_tree||truncated)put(result,L"screenshot_error","No capture: the bounded native tree contains protected/unsupported or uninspected content");
            else{const auto area=rectangle(window.handle);result.SetNamedValue(L"image",capture(window,area,cancel));const auto token=random_id();session.shots.emplace(token,Shot{window,area,root_runtime});put(result,L"native_screenshot_token",token);}
        }return result;
    }
    void under_window(const Element& target){
        current(target.window);winrt::com_ptr<IUIAutomationElement> root;winrt::check_hresult(automation_->ElementFromHandle(target.window.handle,root.put()));if(runtime(root.get())!=target.root_runtime||restricted(target.value.get())||runtime(target.value.get())!=target.runtime)throw std::runtime_error("The native element is stale or protected");
        winrt::com_ptr<IUIAutomationTreeWalker> walker;winrt::check_hresult(automation_->get_ControlViewWalker(walker.put()));auto element=target.value;
        for(unsigned depth=0;element&&depth<32;++depth){int pid{};winrt::check_hresult(element->get_CurrentProcessId(&pid));if(pid!=static_cast<int>(target.window.pid)||restricted(element.get()))throw std::runtime_error("The native control moved under protected, foreign or browser content");UIA_HWND handle{};winrt::check_hresult(element->get_CurrentNativeWindowHandle(&handle));if(reinterpret_cast<HWND>(handle)==target.window.handle)return;winrt::com_ptr<IUIAutomationElement> parent;winrt::check_hresult(walker->GetParentElement(element.get(),parent.put()));element=std::move(parent);}throw std::runtime_error("The native element moved outside its observed window");
    }
    Object act(const std::string& thread,const std::string& name,const Object& request,const std::function<bool()>& cancel){
        initialize();auto found=sessions_.find(thread);if(found==sessions_.end())throw std::runtime_error("Observe the exact window before acting");const auto& args=request.GetNamedObject(L"arguments");const auto token=text(request,L"native_token");cancelled(cancel);
        if(text(request,L"token_kind")=="screenshot"){
            const auto at=found->second.shots.find(token);if(at==found->second.shots.end()||name!="click")throw std::runtime_error("The native screenshot token is stale");const auto shot=at->second;found->second.shots.erase(at);current(shot.window);const auto area=rectangle(shot.window.handle);
            winrt::com_ptr<IUIAutomationElement> root;winrt::check_hresult(automation_->ElementFromHandle(shot.window.handle,root.put()));if(runtime(root.get())!=shot.root_runtime||memcmp(&area,&shot.bounds,sizeof(area)))throw std::runtime_error("The window moved or was recreated since its screenshot");const POINT point{static_cast<LONG>(integer(args,L"x",-32768,32767)),static_cast<LONG>(integer(args,L"y",-32768,32767))};if(!PtInRect(&area,point))throw std::runtime_error("The pixel lies outside the observed window");
            const auto guard=input_lease(shot.window,thread);for(const auto key:{VK_SHIFT,VK_CONTROL,VK_MENU,VK_LWIN,VK_RWIN})if(GetAsyncKeyState(key)&0x8000)throw std::runtime_error("A user modifier is held; no Computer Use input was sent");
            SetForegroundWindow(shot.window.handle);if(GetForegroundWindow()!=shot.window.handle)throw std::runtime_error("The exact target did not become foreground; no input was sent");
            const auto hit=WindowFromPoint(point);if(hit!=shot.window.handle&&!IsChild(shot.window.handle,hit))throw std::runtime_error("A different window covers this point");winrt::com_ptr<IUIAutomationElement> leaf;winrt::check_hresult(automation_->ElementFromPoint(point,leaf.put()));const auto leaf_runtime=runtime(leaf.get());under_window(Element{shot.window,std::move(leaf),leaf_runtime,shot.root_runtime});cancelled(cancel);
            if(!SetCursorPos(point.x,point.y))winrt::throw_last_error();std::array<INPUT,2> input{};input[0].type=input[1].type=INPUT_MOUSE;input[0].mi.dwFlags=MOUSEEVENTF_LEFTDOWN;input[1].mi.dwFlags=MOUSEEVENTF_LEFTUP;if(SendInput(static_cast<UINT>(input.size()),input.data(),sizeof(INPUT))!=input.size()){INPUT release{};release.type=INPUT_MOUSE;release.mi.dwFlags=MOUSEEVENTF_LEFTUP;SendInput(1,&release,sizeof(INPUT));throw std::runtime_error("Native input was not confirmed; observe before retrying");}
        }else{
            const auto at=found->second.elements.find(token);if(at==found->second.elements.end())throw std::runtime_error("The native element token is stale");const auto element=at->second;found->second.elements.erase(at);under_window(element);cancelled(cancel);const auto guard=input_lease(element.window,thread);
            if(name=="set_value"){winrt::com_ptr<IUIAutomationValuePattern> pattern;winrt::check_hresult(element.value->GetCurrentPatternAs(UIA_ValuePatternId,__uuidof(IUIAutomationValuePattern),pattern.put_void()));BOOL readonly{};winrt::check_hresult(pattern->get_CurrentIsReadOnly(&readonly));if(readonly)throw std::runtime_error("The native field is read-only");const auto value=winrt::to_hstring(text(args,L"text"));const auto raw=SysAllocStringLen(value.c_str(),value.size());if(!raw)throw std::bad_alloc();struct String{BSTR value;~String(){SysFreeString(value);}}string{raw};winrt::check_hresult(pattern->SetValue(raw));}
            else if(name=="scroll"){winrt::com_ptr<IUIAutomationScrollPattern> pattern;winrt::check_hresult(element.value->GetCurrentPatternAs(UIA_ScrollPatternId,__uuidof(IUIAutomationScrollPattern),pattern.put_void()));const auto direction=text(args,L"direction");const auto amount=integer(args,L"amount",1,5);for(std::int64_t index=0;index<amount;++index){cancelled(cancel);const auto horizontal=direction=="left"?ScrollAmount_SmallDecrement:direction=="right"?ScrollAmount_SmallIncrement:ScrollAmount_NoAmount;const auto vertical=direction=="up"?ScrollAmount_SmallDecrement:direction=="down"?ScrollAmount_SmallIncrement:ScrollAmount_NoAmount;winrt::check_hresult(pattern->Scroll(horizontal,vertical));}}
            else{winrt::com_ptr<IUIAutomationInvokePattern> invoke;if(SUCCEEDED(element.value->GetCurrentPatternAs(UIA_InvokePatternId,__uuidof(IUIAutomationInvokePattern),invoke.put_void())))winrt::check_hresult(invoke->Invoke());else{winrt::com_ptr<IUIAutomationTogglePattern> toggle;if(SUCCEEDED(element.value->GetCurrentPatternAs(UIA_TogglePatternId,__uuidof(IUIAutomationTogglePattern),toggle.put_void())))winrt::check_hresult(toggle->Toggle());else{winrt::com_ptr<IUIAutomationSelectionItemPattern> select;winrt::check_hresult(element.value->GetCurrentPatternAs(UIA_SelectionItemPatternId,__uuidof(IUIAutomationSelectionItemPattern),select.put_void()));winrt::check_hresult(select->Select());}}}
        }Object result;result.SetNamedValue(L"dispatched",Value::CreateBooleanValue(true));put(result,L"verification","Observe the target again to verify the result");return result;
    }
public:
    explicit NativeBackend(DWORD owning_app_pid):app_pid_(owning_app_pid){}
    std::uint64_t generation()const override{return epoch_;}
    void release_controls(const std::string& thread)override{for(auto& [name,lease]:leases_){(void)name;(void)lease->release(thread);}}
    void stop()noexcept override{sessions_.clear();leases_.clear();automation_=nullptr;++epoch_;}
    Object request(const Object& value,const std::function<bool()>& cancel)override{
        keys(value,{L"thread",L"operation",L"arguments",L"native_token",L"token_kind",L"request_id"});const auto thread=identifier(text(value,L"thread"));const auto operation=text(value,L"operation");cancelled(cancel);
        if(sessions_.size()>=32&&!sessions_.contains(thread))throw std::runtime_error("Too many native Computer Use sessions");
        if(operation=="release_controls"){release_controls(thread);Object result;result.SetNamedValue(L"released",Value::CreateBooleanValue(true));return result;}
        if(operation=="list_windows"||operation=="list_apps")return windows(operation=="list_apps",cancel);
        if(operation=="get_window_state")return observe(thread,value.GetNamedObject(L"arguments"),cancel);
        if(operation=="click"||operation=="set_value"||operation=="scroll")return act(thread,operation,value,cancel);throw std::invalid_argument("Unsupported native Computer Use operation");
    }
};

// Parent invokes this only with its private inherited stdin/stdout pipes. There is no listener,
// HTTP endpoint, user script, installation, browser transport or externally chosen output path.
inline bool owned_helper_context(DWORD owning_app_pid){
    if(!owning_app_pid||GetFileType(GetStdHandle(STD_INPUT_HANDLE))!=FILE_TYPE_PIPE||GetFileType(GetStdHandle(STD_OUTPUT_HANDLE))!=FILE_TYPE_PIPE)return false;
    const auto snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);if(snapshot==INVALID_HANDLE_VALUE)return false;PROCESSENTRY32W entry{};entry.dwSize=sizeof(entry);DWORD parent{};
    if(Process32FirstW(snapshot,&entry))do{if(entry.th32ProcessID==GetCurrentProcessId()){parent=entry.th32ParentProcessID;break;}}while(Process32NextW(snapshot,&entry));CloseHandle(snapshot);if(parent!=owning_app_pid)return false;
    const auto process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,parent);if(!process)return false;std::array<wchar_t,32768> owner{},module{};DWORD length=static_cast<DWORD>(owner.size());const bool queried=QueryFullProcessImageNameW(process,0,owner.data(),&length)!=FALSE;CloseHandle(process);const auto count=GetModuleFileNameW(nullptr,module.data(),static_cast<DWORD>(module.size()));
    return queried&&count&&count<module.size()&&length==count&&CompareStringOrdinal(owner.data(),static_cast<int>(length),module.data(),static_cast<int>(count),TRUE)==CSTR_EQUAL;
}
inline int computer_use_helper_worker(DWORD owning_app_pid){
    winrt::init_apartment(winrt::apartment_type::multi_threaded);NativeBackend backend(owning_app_pid);std::string line;line.reserve(4096);
    for(;;){line.clear();char ch{};while(std::cin.get(ch)&&ch!='\n'){if(line.size()>=262144)return 2;line+=ch;}if(!std::cin&&line.empty())break;
        Object response;try{if(!line.empty()&&line.back()=='\r')line.pop_back();const auto request=Object::Parse(winrt::to_hstring(line));const auto id=text(request,L"request_id");if(id.size()!=32||id.find_first_not_of("0123456789abcdef")!=std::string::npos)throw std::invalid_argument("Invalid private request identity");put(response,L"request_id",id);const auto result=backend.request(request,[]{return false;});response.SetNamedValue(L"result",result);}catch(const winrt::hresult_error&){put(response,L"error","The native target is unavailable or does not support this operation");}catch(const std::exception& error){put(response,L"error",error.what());}
        const auto bytes=winrt::to_string(response.Stringify());if(bytes.size()>4*1024*1024)return 3;std::cout<<bytes<<'\n'<<std::flush;if(!std::cout)return 4;
    }return 0;
}
inline int computer_use_helper_main(DWORD owning_app_pid){
    if(!owned_helper_context(owning_app_pid))return 5;
    int result=1;std::thread worker([&]{try{result=computer_use_helper_worker(owning_app_pid);}catch(...){result=6;}});worker.join();return result;
}
} // namespace coincide::computer_use
