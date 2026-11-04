#pragma once
#include <windows.h>
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Json.h>
#include <bcrypt.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>
#pragma comment(lib,"bcrypt.lib")

namespace coincide::computer_use {
using Object=winrt::Windows::Data::Json::JsonObject;
using Array=winrt::Windows::Data::Json::JsonArray;
using Value=winrt::Windows::Data::Json::JsonValue;
using Type=winrt::Windows::Data::Json::JsonValueType;
inline void put(const Object& object,const wchar_t* key,const std::string& value){object.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(value)));}
inline std::string text(const Object& object,const wchar_t* key){return winrt::to_string(object.GetNamedString(key));}
inline std::string identifier(const std::string& value){if(value.size()!=36&&value.size()!=38)throw std::invalid_argument("Invalid Computer Use thread identity");const winrt::guid id(winrt::to_hstring(value));if(id==winrt::guid{})throw std::invalid_argument("Invalid Computer Use thread identity");return winrt::to_string(winrt::to_hstring(id));}
inline std::string random_id(){std::array<unsigned char,16> bytes{};if(BCryptGenRandom(nullptr,bytes.data(),static_cast<ULONG>(bytes.size()),BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0)throw std::runtime_error("Could not create a Computer Use observation token");constexpr char hex[]="0123456789abcdef";std::string result;for(const auto byte:bytes){result+=hex[byte>>4];result+=hex[byte&15];}return result;}
inline std::int64_t integer(const Object& value,const wchar_t* key,std::int64_t low,std::int64_t high){const auto n=value.GetNamedNumber(key);if(!std::isfinite(n)||n<static_cast<double>(low)||n>static_cast<double>(high)||n!=std::floor(n))throw std::invalid_argument("Computer Use needs a bounded integer");return static_cast<std::int64_t>(n);}
inline void keys(const Object& value,std::initializer_list<std::wstring_view> allowed){for(const auto& pair:value)if(std::find(allowed.begin(),allowed.end(),pair.Key())==allowed.end())throw std::invalid_argument("Unsupported or reserved Computer Use option");}
inline void bounded(const winrt::Windows::Data::Json::IJsonValue& value,unsigned depth,std::size_t& nodes){
    if(depth>10||++nodes>4096)throw std::invalid_argument("Computer Use JSON exceeds its structural bound");
    if(value.ValueType()==Type::Object){const auto object=value.GetObject();if(object.Size()>64)throw std::invalid_argument("Too many Computer Use options");for(const auto& item:object){auto key=winrt::to_string(item.Key());std::transform(key.begin(),key.end(),key.begin(),[](unsigned char ch){return ch>='A'&&ch<='Z'?static_cast<char>(ch+32):static_cast<char>(ch);});
        static const std::set<std::string> reserved{"session","session_id","permission_mode","permission_profile","capability_manifest","grant","profile","socket","host","port","config","environment","env","script","source","code","url","screenshot_out_file","debug_image_out","output_file","output_path","output_directory","output_dir"};
        if(key.empty()||key.size()>128||key.front()=='_'||reserved.contains(key))throw std::invalid_argument("Reserved Computer Use option");bounded(item.Value(),depth+1,nodes);}}
    else if(value.ValueType()==Type::Array){if(value.GetArray().Size()>1024)throw std::invalid_argument("Computer Use array exceeds its bound");for(const auto& item:value.GetArray())bounded(item,depth+1,nodes);}
    else if(value.ValueType()==Type::String){const auto string=winrt::to_string(value.GetString());if(string.size()>65536||string.find('\0')!=std::string::npos)throw std::invalid_argument("Computer Use text exceeds its bound");}
    else if(value.ValueType()==Type::Number&&!std::isfinite(value.GetNumber()))throw std::invalid_argument("Invalid Computer Use number");
}
struct Request {
    std::string action,name;Object arguments;
    static Request parse(const std::string& bytes){
        if(bytes.size()>262144||bytes.find('\0')!=std::string::npos)throw std::invalid_argument("Computer Use request exceeds its bound");
        const auto object=Object::Parse(winrt::to_hstring(bytes));std::size_t nodes{};bounded(object,0,nodes);Request result{text(object,L"action"),{},Object{}};
        if(result.action=="status"||result.action=="tools"||result.action=="release"){keys(object,{L"action"});return result;}
        if(result.action!="call")throw std::invalid_argument("Unsupported Computer Use action");keys(object,{L"action",L"name",L"arguments"});result.name=text(object,L"name");result.arguments=object.GetNamedObject(L"arguments");
        if(result.name=="list_apps"||result.name=="list_windows")keys(result.arguments,{});
        else if(result.name=="get_window_state"){
            keys(result.arguments,{L"pid",L"window_id",L"query",L"max_elements",L"max_depth",L"include_screenshot"});target(result.arguments);
            if(result.arguments.HasKey(L"query")&&text(result.arguments,L"query").size()>256)throw std::invalid_argument("Narrow the Computer Use query");
            if(result.arguments.HasKey(L"max_elements"))(void)integer(result.arguments,L"max_elements",1,512);if(result.arguments.HasKey(L"max_depth"))(void)integer(result.arguments,L"max_depth",1,12);
            if(result.arguments.HasKey(L"include_screenshot"))(void)result.arguments.GetNamedBoolean(L"include_screenshot");
        }else if(result.name=="click"||result.name=="set_value"||result.name=="scroll"){
            keys(result.arguments,{L"pid",L"window_id",L"element_token",L"screenshot_token",L"x",L"y",L"text",L"direction",L"amount"});target(result.arguments);
            const bool element=result.arguments.HasKey(L"element_token"),pixel=result.arguments.HasKey(L"screenshot_token");
            if(element==pixel||(!element&&result.name!="click"))throw std::invalid_argument("Use one fresh element token, or a screenshot token for a pixel click");
            if(element){if(text(result.arguments,L"element_token").size()!=32||result.arguments.HasKey(L"x")||result.arguments.HasKey(L"y"))throw std::invalid_argument("Invalid Computer Use element action");}
            else{if(text(result.arguments,L"screenshot_token").size()!=32)throw std::invalid_argument("Invalid Computer Use screenshot token");(void)integer(result.arguments,L"x",-32768,32767);(void)integer(result.arguments,L"y",-32768,32767);}
            if(result.name=="set_value"){(void)text(result.arguments,L"text");if(result.arguments.HasKey(L"direction")||result.arguments.HasKey(L"amount"))throw std::invalid_argument("Unexpected set-value option");}
            else if(result.arguments.HasKey(L"text"))throw std::invalid_argument("Text belongs only to set_value");
            if(result.name=="scroll"){const auto direction=text(result.arguments,L"direction");if(direction!="up"&&direction!="down"&&direction!="left"&&direction!="right")throw std::invalid_argument("Invalid native scroll direction");(void)integer(result.arguments,L"amount",1,5);}
            else if(result.arguments.HasKey(L"direction")||result.arguments.HasKey(L"amount"))throw std::invalid_argument("Unexpected scroll option");
        }else throw std::invalid_argument("This Computer Use tool is not implemented on Windows");return result;
    }
    static void target(const Object& value){(void)integer(value,L"pid",1,MAXDWORD);const auto window=text(value,L"window_id");if(window.empty()||window.size()>16||window.find_first_not_of("0123456789abcdef")!=std::string::npos)throw std::invalid_argument("Use a window identity from list_windows");}
};
struct Permission {bool read_windows{},capture_windows{},input{};};
struct Snapshot {bool enabled{},granted{};Permission permission;std::string desktop="free";};
// Backend requests are private typed JSON produced below, never the public agent object.
// A backend must check cancellation before side effects and reject stale native identities.
struct Backend {
    virtual ~Backend()=default;
    virtual Object request(const Object&,const std::function<bool()>& cancelled)=0;
    virtual std::uint64_t generation()const=0;
    virtual void release_controls(const std::string&){}
    virtual void stop()noexcept=0;
};

class Controller {
    struct Token {std::string native,window;DWORD pid{};std::uint64_t generation{},at{};bool screenshot{};};
    struct Grant {Permission permission;std::atomic_bool valid{true};std::map<std::string,Token> tokens;};
    std::shared_ptr<Backend> backend_;std::function<std::uint64_t()> clock_;std::mutex state_,operation_;
    std::map<std::string,std::shared_ptr<Grant>> grants_;std::set<std::string> released_pending_;bool enabled_{};std::string owner_;std::uint64_t lease_{},last_use_{};
    void drain_releases()noexcept{std::set<std::string> pending;{std::lock_guard lock(state_);pending.swap(released_pending_);}for(const auto& id:pending)try{backend_->release_controls(id);}catch(...){backend_->stop();}}
    void release_backend(const std::string& id){{std::lock_guard lock(state_);released_pending_.insert(id);}std::unique_lock command(operation_,std::try_to_lock);if(command.owns_lock())drain_releases();}
    std::shared_ptr<Grant> require(const std::string& thread){std::lock_guard lock(state_);if(!enabled_)throw std::runtime_error("Computer Use is off");const auto found=grants_.find(thread);if(found==grants_.end()||!found->second->valid)throw std::runtime_error("Computer Use is not explicitly permitted for this thread");return found->second;}
    static Array catalog(){
        Array result;for(const auto name:{"list_apps","list_windows","get_window_state","click","set_value","scroll"}){Object item;put(item,L"name",name);put(item,L"description",name==std::string_view("get_window_state")?"Read a bounded native window tree; optionally capture that window with separate permission":"Native Windows Computer Use; browser, script, password and shell access are unavailable");
            Object schema,properties;put(schema,L"type","object");schema.SetNamedValue(L"additionalProperties",Value::CreateBooleanValue(false));Array required;
            auto property=[&](const wchar_t* key,const char* type,bool needed=false){Object value;put(value,L"type",type);properties.SetNamedValue(key,value);if(needed)required.Append(Value::CreateStringValue(key));return value;};
            if(name!=std::string_view("list_apps")&&name!=std::string_view("list_windows")){auto pid=property(L"pid","integer",true);pid.SetNamedValue(L"minimum",Value::CreateNumberValue(1));pid.SetNamedValue(L"maximum",Value::CreateNumberValue(MAXDWORD));auto window=property(L"window_id","string",true);put(window,L"pattern","^[0-9a-f]{1,16}$");
                if(name==std::string_view("get_window_state")){auto query=property(L"query","string");query.SetNamedValue(L"maxLength",Value::CreateNumberValue(256));for(const auto key:{L"max_elements",L"max_depth"}){auto limit=property(key,"integer");limit.SetNamedValue(L"minimum",Value::CreateNumberValue(1));limit.SetNamedValue(L"maximum",Value::CreateNumberValue(std::wstring_view(key)==L"max_depth"?12:512));}property(L"include_screenshot","boolean");}
                else{auto token=property(L"element_token","string",name!=std::string_view("click"));put(token,L"pattern","^[0-9a-f]{32}$");
                    if(name==std::string_view("click")){auto image=property(L"screenshot_token","string");put(image,L"pattern","^[0-9a-f]{32}$");property(L"x","integer");property(L"y","integer");Array alternatives;for(const auto key:{L"element_token",L"screenshot_token"}){Object option;Array fields;fields.Append(Value::CreateStringValue(key));if(std::wstring_view(key)==L"screenshot_token"){fields.Append(Value::CreateStringValue(L"x"));fields.Append(Value::CreateStringValue(L"y"));}option.SetNamedValue(L"required",fields);alternatives.Append(option);}schema.SetNamedValue(L"oneOf",alternatives);}
                    if(name==std::string_view("set_value")){auto input=property(L"text","string",true);input.SetNamedValue(L"maxLength",Value::CreateNumberValue(65536));}
                    if(name==std::string_view("scroll")){auto direction=property(L"direction","string",true);Array directions;for(const auto value:{L"up",L"down",L"left",L"right"})directions.Append(Value::CreateStringValue(value));direction.SetNamedValue(L"enum",directions);auto amount=property(L"amount","integer",true);amount.SetNamedValue(L"minimum",Value::CreateNumberValue(1));amount.SetNamedValue(L"maximum",Value::CreateNumberValue(5));}
                }
            }schema.SetNamedValue(L"properties",properties);schema.SetNamedValue(L"required",required);item.SetNamedValue(L"inputSchema",schema);result.Append(item);
        }return result;
    }
    void alive(const std::shared_ptr<Grant>& grant)const{if(!grant->valid.load())throw std::runtime_error("Computer Use permission was revoked during this request");}
public:
    explicit Controller(std::shared_ptr<Backend> backend,std::function<std::uint64_t()> clock={}):backend_(std::move(backend)),clock_(std::move(clock)){if(!backend_)throw std::invalid_argument("Computer Use needs an owned backend");if(!clock_)clock_=[](){return GetTickCount64();};}
    Snapshot snapshot(const std::string& thread={}){const auto id=thread.empty()?std::string{}:identifier(thread);std::lock_guard lock(state_);Snapshot result;result.enabled=enabled_;if(const auto found=grants_.find(id);enabled_&&found!=grants_.end()&&found->second->valid){result.granted=true;result.permission=found->second->permission;}if(!owner_.empty()&&clock_()<lease_)result.desktop=owner_==id?"this thread":"another thread";return result;}
    void set_enabled(bool enabled){{std::lock_guard lock(state_);enabled_=enabled;if(!enabled){for(auto& [id,grant]:grants_){(void)id;grant->valid=false;}grants_.clear();owner_.clear();lease_=0;}}if(!enabled){std::unique_lock command(operation_,std::try_to_lock);if(command.owns_lock())backend_->stop();}}
    void grant(const std::string& thread,Permission permission){const auto id=identifier(thread);bool replaced{};{std::lock_guard lock(state_);if(!enabled_)throw std::runtime_error("Enable Computer Use before granting thread access");if((permission.capture_windows||permission.input)&&!permission.read_windows)throw std::invalid_argument("Window capture/input requires explicit window-read permission");if(!permission.read_windows)throw std::invalid_argument("Choose an explicit Computer Use permission");if(grants_.size()>=32&&!grants_.contains(id))throw std::runtime_error("Too many Computer Use grants");if(const auto found=grants_.find(id);found!=grants_.end()){found->second->valid=false;replaced=true;}auto value=std::make_shared<Grant>();value->permission=permission;grants_.insert_or_assign(id,std::move(value));if(owner_==id){owner_.clear();lease_=0;}}if(replaced)release_backend(id);}
    void revoke(const std::string& thread){const auto id=identifier(thread);bool known{};{std::lock_guard lock(state_);if(const auto found=grants_.find(id);found!=grants_.end()){known=true;found->second->valid=false;grants_.erase(found);}if(owner_==id){known=true;owner_.clear();lease_=0;}}if(known)release_backend(id);}
    void release(const std::string& thread){const auto id=identifier(thread);bool known{};{std::lock_guard lock(state_);if(const auto found=grants_.find(id);found!=grants_.end()){known=true;found->second->tokens.clear();}if(owner_==id){known=true;owner_.clear();lease_=0;}}if(known)release_backend(id);}
    void stop()noexcept{try{set_enabled(false);std::lock_guard lock(operation_);backend_->stop();}catch(...){}}
    void idle_tick(){std::unique_lock command(operation_,std::try_to_lock);if(!command.owns_lock())return;const auto now=clock_();std::lock_guard lock(state_);if(!owner_.empty()&&now>=lease_){owner_.clear();lease_=0;}if(last_use_&&now>=last_use_&&now-last_use_>=120000){backend_->stop();for(auto& [id,grant]:grants_){(void)id;grant->tokens.clear();}last_use_=0;}}
    Object perform(const std::string& thread,const std::string& json){
        const auto id=identifier(thread);const auto request=Request::parse(json);const auto grant=require(id);
        if(request.action=="release"){release(id);Object result;result.SetNamedValue(L"released",Value::CreateBooleanValue(true));return result;}
        if(request.action=="status"){Object result;result.SetNamedValue(L"enabled",Value::CreateBooleanValue(true));result.SetNamedValue(L"read_windows",Value::CreateBooleanValue(grant->permission.read_windows));result.SetNamedValue(L"capture_windows",Value::CreateBooleanValue(grant->permission.capture_windows));result.SetNamedValue(L"input",Value::CreateBooleanValue(grant->permission.input));std::lock_guard lock(state_);put(result,L"desktop",owner_.empty()||clock_()>=lease_?"free":owner_==id?"this thread":"another thread");return result;}
        if(request.action=="tools"){Object result;result.SetNamedValue(L"tools",catalog());return result;}
        std::unique_lock command(operation_,std::try_to_lock);if(!command.owns_lock())throw std::runtime_error("Another Computer Use command is still running; wait before retrying");struct Releases{Controller* self;~Releases(){self->drain_releases();}} releases{this};alive(grant);
        const bool action=request.name=="click"||request.name=="set_value"||request.name=="scroll";if(action&&!grant->permission.input)throw std::runtime_error("This thread has no explicit native-input permission");
        const bool capture=request.name=="get_window_state"&&request.arguments.GetNamedBoolean(L"include_screenshot",false);if(capture&&!grant->permission.capture_windows)throw std::runtime_error("This thread has no explicit window-capture permission");
        Object internal;put(internal,L"thread",id);put(internal,L"operation",request.name);internal.SetNamedValue(L"arguments",Object::Parse(request.arguments.Stringify()));const auto now=clock_();
        if(action){std::lock_guard lock(state_);const auto token=text(request.arguments,request.arguments.HasKey(L"element_token")?L"element_token":L"screenshot_token");const auto found=grant->tokens.find(token);
            if(found==grant->tokens.end()||found->second.pid!=integer(request.arguments,L"pid",1,MAXDWORD)||found->second.window!=text(request.arguments,L"window_id")||now<found->second.at||now-found->second.at>(found->second.screenshot?15000:30000)||found->second.generation!=backend_->generation())throw std::runtime_error("Computer Use token is stale; observe the exact target again");
            if(!owner_.empty()&&owner_!=id&&now<lease_)throw std::runtime_error("Another thread owns the shared desktop; wait for it to release control");owner_=id;lease_=now+60000;
            put(internal,L"native_token",found->second.native);put(internal,L"token_kind",found->second.screenshot?"screenshot":"element");grant->tokens.erase(found);
        }
        last_use_=now;const auto result=backend_->request(internal,[grant]{return !grant->valid.load();});alive(grant);
        if(winrt::to_string(result.Stringify()).size()>4*1024*1024)throw std::runtime_error("Computer Use result exceeds its bound; request a narrower observation");
        auto shown=Object::Parse(result.Stringify());
        if(request.name=="get_window_state"){
            if(shown.HasKey(L"image")&&(!capture||shown.GetNamedBoolean(L"protected_content",false)||shown.GetNamedBoolean(L"truncated",false)))throw std::runtime_error("An unrequested, protected or incomplete Computer Use screenshot was rejected");
            std::lock_guard lock(state_);alive(grant);std::erase_if(grant->tokens,[&](const auto& item){return item.second.window==text(request.arguments,L"window_id");});
            const auto elements=shown.GetNamedArray(L"elements",Array{});if(elements.Size()>512)throw std::runtime_error("Computer Use returned too many elements");
            Array safe;for(const auto& raw:elements){const auto element=raw.GetObject();if(element.GetNamedBoolean(L"protected",false)){Object redacted;redacted.SetNamedValue(L"protected",Value::CreateBooleanValue(true));safe.Append(redacted);continue;}
                keys(element,{L"name",L"role",L"bounds",L"enabled",L"offscreen",L"native_token"});
                if(element.HasKey(L"native_token")){const auto native=text(element,L"native_token");if(native.size()!=32||native.find_first_not_of("0123456789abcdef")!=std::string::npos)throw std::runtime_error("Invalid native accessibility token");element.Remove(L"native_token");const auto token=random_id();grant->tokens.emplace(token,Token{native,text(request.arguments,L"window_id"),static_cast<DWORD>(integer(request.arguments,L"pid",1,MAXDWORD)),backend_->generation(),now,false});put(element,L"element_token",token);}safe.Append(element);}shown.SetNamedValue(L"elements",safe);
            if(shown.HasKey(L"native_screenshot_token")){if(!capture)throw std::runtime_error("An unrequested Computer Use screenshot was rejected");const auto native=text(shown,L"native_screenshot_token");shown.Remove(L"native_screenshot_token");const auto token=random_id();grant->tokens.emplace(token,Token{native,text(request.arguments,L"window_id"),static_cast<DWORD>(integer(request.arguments,L"pid",1,MAXDWORD)),backend_->generation(),now,true});put(shown,L"screenshot_token",token);}
            if(grant->tokens.size()>1024)grant->tokens.clear();
        }
        return shown;
    }
    ~Controller(){stop();}
};
} // namespace coincide::computer_use
