#pragma once
#include "ComputerUsePolicy.h"
#include <filesystem>
#include <initializer_list>
#include <optional>

namespace coincide::app_tools {
using Object=winrt::Windows::Data::Json::JsonObject;
using Value=winrt::Windows::Data::Json::JsonValue;
using Type=winrt::Windows::Data::Json::JsonValueType;
enum class Channel {browser,terminal,schedule,computer_use};
inline std::string channel_name(Channel channel){switch(channel){case Channel::browser:return "preview";case Channel::terminal:return "terminal";case Channel::schedule:return "schedule";case Channel::computer_use:return "computer-use";}throw std::invalid_argument("Unknown app tool");}
inline std::string thread_key(const std::string& value){if(value.size()!=36&&value.size()!=38)throw std::invalid_argument("Invalid app-tool thread");const winrt::guid id(winrt::to_hstring(value));if(id==winrt::guid{})throw std::invalid_argument("Invalid app-tool thread");auto result=winrt::to_string(winrt::to_hstring(id));if(result.front()=='{')result=result.substr(1,result.size()-2);std::transform(result.begin(),result.end(),result.begin(),[](unsigned char ch){return static_cast<char>(std::tolower(ch));});return result;}
inline bool utf8(std::string_view value){return value.empty()||(value.size()<=INT_MAX&&MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,value.data(),static_cast<int>(value.size()),nullptr,0)>0);}
inline void invalid(){throw std::invalid_argument("Invalid or unsupported app-tool request");}

// Reject duplicate (including escaped) JSON keys before WinRT's last-value-wins object parser.
// Depth/nodes/string bounds also apply to controller replies, which remain untrusted data.
class StrictJSON {
    std::string_view input_;std::size_t at_{},nodes_{},string_limit_{};
    void whitespace(){while(at_<input_.size()&&(input_[at_]==' '||input_[at_]=='\t'||input_[at_]=='\r'||input_[at_]=='\n'))++at_;}
    bool take(char value){whitespace();if(at_<input_.size()&&input_[at_]==value){++at_;return true;}return false;}
    std::wstring string(){
        whitespace();const auto begin=at_;if(at_>=input_.size()||input_[at_++]!='"')invalid();bool escaped{};
        while(at_<input_.size()) {const auto ch=static_cast<unsigned char>(input_[at_++]);if(ch<32)invalid();if(ch=='"'&&!escaped){const auto size=at_-begin;if(size>string_limit_)invalid();const auto text=Value::Parse(winrt::to_hstring(input_.substr(begin,size))).GetString();
                for(std::uint32_t i=0;i<text.size();++i){const auto unit=text[i];if(unit>=0xd800&&unit<=0xdbff){if(++i>=text.size()||text[i]<0xdc00||text[i]>0xdfff)invalid();}else if(unit>=0xdc00&&unit<=0xdfff)invalid();}return std::wstring(text);}
            if(ch=='\\'&&!escaped)escaped=true;else escaped=false;}
        invalid();return{};
    }
    void value(unsigned depth){
        if(depth>12||++nodes_>8192)invalid();whitespace();if(at_>=input_.size())invalid();
        if(input_[at_]=='{'){++at_;std::set<std::wstring> names;if(take('}'))return;do{auto key=string();if(key.empty()||key.size()>128||names.size()>=64||!names.insert(std::move(key)).second)invalid();if(!take(':'))invalid();value(depth+1);}while(take(','));if(!take('}'))invalid();}
        else if(input_[at_]=='['){++at_;std::size_t count{};if(take(']'))return;do{if(++count>2048)invalid();value(depth+1);}while(take(','));if(!take(']'))invalid();}
        else if(input_[at_]=='"'){static_cast<void>(string());}
        else{const auto begin=at_;while(at_<input_.size()&&std::string_view(" \t\r\n,]}").find(input_[at_])==std::string_view::npos)++at_;if(at_==begin||at_-begin>1024)invalid();const auto parsed=Value::Parse(winrt::to_hstring(input_.substr(begin,at_-begin)));if(parsed.ValueType()==Type::Number&&!std::isfinite(parsed.GetNumber()))invalid();}
    }
public:
    explicit StrictJSON(std::string_view value):input_(value),string_limit_(value.size()){}
    static void validate(std::string_view value,std::size_t maximum=1048576){if(value.empty()||value.size()>maximum||!utf8(value)||value.find('\0')!=std::string_view::npos)invalid();StrictJSON parser(value);parser.value(0);parser.whitespace();if(parser.at_!=value.size())invalid();static_cast<void>(Value::Parse(winrt::to_hstring(value)));}
};

inline std::string text(const Object& object,const wchar_t* key,std::size_t limit,bool required=true,bool empty=false){
    if(!object.HasKey(key)){if(required)invalid();return{};}const auto raw=object.GetNamedValue(key);if(raw.ValueType()!=Type::String)invalid();const auto value=winrt::to_string(raw.GetString());if(value.size()>limit||(!empty&&value.empty())||value.find('\0')!=std::string::npos)invalid();return value;
}
inline void fields(const Object& object,std::initializer_list<std::wstring_view> allowed){for(const auto& item:object)if(std::find(allowed.begin(),allowed.end(),item.Key())==allowed.end())invalid();}
inline double number(const Object& object,const wchar_t* key,double low,double high,std::optional<double> fallback={},bool whole=false){
    if(!object.HasKey(key)){if(!fallback)invalid();return *fallback;}const auto raw=object.GetNamedValue(key);if(raw.ValueType()!=Type::Number)invalid();const auto value=raw.GetNumber();if(!std::isfinite(value)||value<low||value>high||(whole&&std::floor(value)!=value))invalid();return value;
}
inline bool boolean(const Object& object,const wchar_t* key,bool fallback=false){if(!object.HasKey(key))return fallback;const auto raw=object.GetNamedValue(key);if(raw.ValueType()!=Type::Boolean)invalid();return raw.GetBoolean();}
inline void object_value(const Object& object,const wchar_t* key){if(!object.HasKey(key)||object.GetNamedValue(key).ValueType()!=Type::Object)invalid();}
inline bool nonblank(const std::string& value){return std::any_of(value.begin(),value.end(),[](unsigned char ch){return ch!=' '&&ch!='\t'&&ch!='\r'&&ch!='\n';});}
inline void identifier(const Object& object,const wchar_t* key,bool required=false){const auto value=text(object,key,128,required);if(!value.empty()&&std::any_of(value.begin(),value.end(),[](unsigned char ch){return !((ch>='A'&&ch<='Z')||(ch>='a'&&ch<='z')||(ch>='0'&&ch<='9')||ch=='-'||ch=='_'||ch=='{'||ch=='}');}))invalid();}
inline void web_url(const Object& object,const wchar_t* key,bool required=true){const auto value=text(object,key,8192,required);if(value.empty())return;if(std::any_of(value.begin(),value.end(),[](unsigned char ch){return ch<=32||ch==127;}))invalid();try{winrt::Windows::Foundation::Uri uri(winrt::to_hstring(value));if((uri.SchemeName()!=L"http"&&uri.SchemeName()!=L"https")||uri.Host().empty()||!uri.UserName().empty()||!uri.Password().empty())invalid();}catch(...){invalid();}}

struct Request {
    Channel channel;std::string thread_id,action,json;std::filesystem::path artifact_directory;
    std::chrono::milliseconds timeout{std::chrono::seconds(30)};
    static std::set<std::string> actions(Channel channel){
        if(channel==Channel::browser)return {"read","navigate","search","click","input","type","press","dialog","back","forward","reload","scroll","wait-for","upload","screenshot","downloads","frames","console","viewport","show","hide","ask-user","fill-login","tabs","new-tab","select-tab","close-tab"};
        if(channel==Channel::terminal)return {"status","read","show","hide","interrupt"};
        if(channel==Channel::schedule)return {"list","create","update","pause","resume","delete","run-now"};
        return {"status","tools","release","call"};
    }
    static Request parse(Channel channel,const std::string& bytes){
        StrictJSON::validate(bytes);const auto object=Object::Parse(winrt::to_hstring(bytes));Request result{channel,{},text(object,L"action",40),winrt::to_string(object.Stringify()),{}};
        if(!actions(channel).contains(result.action))invalid();
        if(channel==Channel::computer_use){static_cast<void>(computer_use::Request::parse(bytes));result.timeout=std::chrono::seconds(result.action=="call"?120:20);return result;}
        if(channel==Channel::terminal){if(result.action=="read"){fields(object,{L"action",L"limit",L"page"});number(object,L"limit",1,2000,200,true);number(object,L"page",1,1000,1,true);}else fields(object,{L"action"});return result;}
        if(channel==Channel::schedule){schedule(object,result.action);return result;}
        browser(object,result);return result;
    }
private:
    static void selector(const Object& object,bool required=true){static_cast<void>(text(object,L"selector",4096,required));}
    static void schedule_spec(const Object& spec){
        const auto kind=text(spec,L"kind",20);static_cast<void>(text(spec,L"timeZone",128,false));
        const auto time=[&]{const auto value=text(spec,L"time",5);if(value.size()!=5||value[2]!=':'||!std::isdigit(static_cast<unsigned char>(value[0]))||!std::isdigit(static_cast<unsigned char>(value[1]))||!std::isdigit(static_cast<unsigned char>(value[3]))||!std::isdigit(static_cast<unsigned char>(value[4]))||(value[0]-'0')*10+value[1]-'0'>23||(value[3]-'0')*10+value[4]-'0'>59)invalid();};
        const auto day=[](const std::string& value){static const std::set<std::string> days{"mon","monday","tue","tuesday","wed","wednesday","thu","thursday","fri","friday","sat","saturday","sun","sunday"};if(!days.contains(value))invalid();};
        if(kind=="once"){fields(spec,{L"kind",L"timeZone",L"at",L"inMinutes"});if(spec.HasKey(L"at")==spec.HasKey(L"inMinutes"))invalid();if(spec.HasKey(L"at"))static_cast<void>(text(spec,L"at",80));else number(spec,L"inMinutes",1,525600,{},true);}
        else if(kind=="daily"||kind=="weekdays"){fields(spec,{L"kind",L"timeZone",L"time"});time();}
        else if(kind=="weekly"){fields(spec,{L"kind",L"timeZone",L"time",L"day"});time();day(text(spec,L"day",12));}
        else if(kind=="days"){fields(spec,{L"kind",L"timeZone",L"time",L"days"});time();const auto values=spec.GetNamedArray(L"days");if(values.Size()<1||values.Size()>7)invalid();for(const auto& raw:values)day(winrt::to_string(raw.GetString()));}
        else if(kind=="interval"){fields(spec,{L"kind",L"timeZone",L"minutes",L"hours"});if(spec.HasKey(L"minutes")==spec.HasKey(L"hours"))invalid();if(spec.HasKey(L"minutes"))number(spec,L"minutes",5,44640,{},true);else number(spec,L"hours",1,744,{},true);}
        else if(kind=="cron"){fields(spec,{L"kind",L"timeZone",L"expression"});static_cast<void>(text(spec,L"expression",256));}
        else invalid();
    }
    static void schedule(const Object& object,const std::string& action){
        if(action=="list"){fields(object,{L"action"});return;}
        if(action=="create"||action=="update"){
            fields(object,{L"action",L"id",L"name",L"prompt",L"schedule"});if(action=="create"&&object.HasKey(L"id"))invalid();
            const auto name=text(object,L"name",200,action=="create"),prompt=text(object,L"prompt",20000,action=="create");if((object.HasKey(L"name")&&!nonblank(name))||(object.HasKey(L"prompt")&&!nonblank(prompt)))invalid();
            if(action=="update"){static_cast<void>(thread_key(text(object,L"id",38)));if(!object.HasKey(L"name")&&!object.HasKey(L"prompt")&&!object.HasKey(L"schedule"))invalid();}
            if(object.HasKey(L"schedule")){object_value(object,L"schedule");schedule_spec(object.GetNamedObject(L"schedule"));}else if(action=="create")invalid();
        }else{fields(object,{L"action",L"id"});static_cast<void>(thread_key(text(object,L"id",38)));}
    }
    static void browser(const Object& object,Request& result){
        const auto& action=result.action;const bool frame=object.HasKey(L"frame"),tab=object.HasKey(L"tab");
        if(frame){if(!std::set<std::string>{"read","click","input","type","press","scroll","wait-for","upload"}.contains(action))invalid();identifier(object,L"frame",true);}if(tab){if(action=="show"||action=="hide"||action=="tabs"||action=="new-tab"||action=="ask-user")invalid();identifier(object,L"tab",true);}
        if(action=="read"){fields(object,{L"action",L"selector",L"page",L"tab",L"frame"});selector(object,false);number(object,L"page",1,1000,1,true);}
        else if(action=="navigate"||action=="new-tab"){fields(object,{L"action",L"url",L"tab"});web_url(object,L"url",action=="navigate");}
        else if(action=="search"){fields(object,{L"action",L"query",L"tab"});if(!nonblank(text(object,L"query",2048)))invalid();}
        else if(action=="click"){fields(object,{L"action",L"selector",L"tab",L"frame"});selector(object);}
        else if(action=="input"||action=="type"){if(action=="input")fields(object,{L"action",L"selector",L"text",L"tab",L"frame"});else fields(object,{L"action",L"selector",L"text",L"clear",L"tab",L"frame"});selector(object);static_cast<void>(text(object,L"text",65536,true,true));if(action=="type")boolean(object,L"clear");}
        else if(action=="press"){fields(object,{L"action",L"selector",L"key",L"tab",L"frame"});selector(object,false);static_cast<void>(text(object,L"key",64));}
        else if(action=="dialog"){fields(object,{L"action",L"accept",L"text",L"tab"});if(!object.HasKey(L"accept"))invalid();boolean(object,L"accept");static_cast<void>(text(object,L"text",65536,false,true));}
        else if(action=="scroll"){fields(object,{L"action",L"selector",L"to",L"by",L"tab",L"frame"});if(static_cast<int>(object.HasKey(L"selector"))+static_cast<int>(object.HasKey(L"to"))+static_cast<int>(object.HasKey(L"by"))>1)invalid();selector(object,false);if(object.HasKey(L"to")){const auto to=text(object,L"to",6);if(to!="top"&&to!="bottom")invalid();}if(object.HasKey(L"by"))number(object,L"by",-1000000,1000000);}
        else if(action=="wait-for"){fields(object,{L"action",L"selector",L"text",L"timeout",L"tab",L"frame"});if(!object.HasKey(L"selector")&&!object.HasKey(L"text"))invalid();selector(object,false);static_cast<void>(text(object,L"text",4096,false));result.timeout=std::chrono::milliseconds(static_cast<long long>((number(object,L"timeout",0.5,60,10)+5)*1000));}
        else if(action=="upload"){fields(object,{L"action",L"selector",L"files",L"tab",L"frame"});selector(object);const auto paths=object.GetNamedArray(L"files");if(paths.Size()<1||paths.Size()>20)invalid();for(const auto& raw:paths){const auto path=winrt::to_string(raw.GetString());if(path.empty()||path.size()>4096||path.find('\0')!=std::string::npos)invalid();const std::filesystem::path file(raw.GetString().c_str());if(!file.is_absolute()||path.starts_with("\\\\")||path.find(':',2)!=std::string::npos)invalid();}}
        else if(action=="screenshot"){fields(object,{L"action",L"fullPage",L"tab"});boolean(object,L"fullPage");}
        else if(action=="console"){fields(object,{L"action",L"clear",L"tab"});boolean(object,L"clear");}
        else if(action=="viewport"){fields(object,{L"action",L"width",L"height",L"preset",L"reset",L"tab"});if(boolean(object,L"reset")){if(object.HasKey(L"width")||object.HasKey(L"height")||object.HasKey(L"preset"))invalid();}else if(object.HasKey(L"preset")){if(object.HasKey(L"width")||object.HasKey(L"height"))invalid();const auto preset=text(object,L"preset",10);if(preset!="mobile"&&preset!="tablet"&&preset!="desktop")invalid();}else{number(object,L"width",320,2560,{},true);number(object,L"height",240,2560,{},true);}}
        else if(action=="ask-user"){fields(object,{L"action",L"message",L"timeout"});static_cast<void>(text(object,L"message",4096));result.timeout=std::chrono::milliseconds(static_cast<long long>((number(object,L"timeout",1,900,300)+5)*1000));}
        else if(action=="fill-login"){fields(object,{L"action",L"item",L"tab"});static_cast<void>(text(object,L"item",200,false,true));result.timeout=std::chrono::seconds(390);}
        else if(action=="select-tab"||action=="close-tab"){fields(object,{L"action",L"tab"});identifier(object,L"tab",true);}
        else if(action=="show"||action=="hide"||action=="tabs")fields(object,{L"action"});
        else fields(object,{L"action",L"tab"});
    }
};

struct HTTPRequest {
    static constexpr std::size_t maximum_headers=16384,maximum_body=1048576;
    std::string path,host,authorization,body,request_id;
    static std::optional<HTTPRequest> parse(const std::string& bytes){
        const auto boundary=bytes.find("\r\n\r\n");if(boundary==std::string::npos){if(bytes.size()>maximum_headers)invalid();return{};}if(boundary>maximum_headers)invalid();
        const auto first_end=bytes.find("\r\n");if(first_end==std::string::npos||first_end>boundary)invalid();const auto first=bytes.substr(0,first_end);
        if(!first.starts_with("POST ")||!first.ends_with(" HTTP/1.1"))invalid();const auto path=first.substr(5,first.size()-14);if(path.empty()||path.front()!='/'||path.find_first_of(" ?#\r\n\t%")!=std::string::npos)invalid();
        std::map<std::string,std::string> headers;std::size_t at=first_end+2;
        static const std::set<std::string> allowed{"host","authorization","content-type","content-length","connection","user-agent","accept","accept-encoding","x-coincide-request-id"};
        while(at<boundary){const auto end=bytes.find("\r\n",at),colon=bytes.find(':',at);if(end==std::string::npos||colon==std::string::npos||colon>=end)invalid();auto name=bytes.substr(at,colon-at);if(name.empty()||std::any_of(name.begin(),name.end(),[](unsigned char ch){return !((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||(ch>='0'&&ch<='9')||ch=='-');}))invalid();std::transform(name.begin(),name.end(),name.begin(),[](unsigned char ch){return static_cast<char>(std::tolower(ch));});if(!allowed.contains(name)||headers.contains(name))invalid();auto value=bytes.substr(colon+1,end-colon-1);if(std::any_of(value.begin(),value.end(),[](unsigned char ch){return (ch<32&&ch!='\t')||ch==127;}))invalid();const auto begin=value.find_first_not_of(" \t"),last=value.find_last_not_of(" \t");value=begin==std::string::npos?"":value.substr(begin,last-begin+1);headers.emplace(std::move(name),std::move(value));at=end+2;}
        if(!headers.contains("host")||!headers.contains("authorization")||!headers.contains("content-length")||!headers.contains("content-type"))invalid();
        const auto type=headers.at("content-type");if(type!="application/json"&&type!="application/json; charset=utf-8")invalid();const auto length=headers.at("content-length");if(length.empty()||length.size()>7||length.find_first_not_of("0123456789")!=std::string::npos)invalid();std::size_t size{};for(const auto ch:length){size=size*10+static_cast<unsigned>(ch-'0');if(size>maximum_body)invalid();}
        const auto body_size=bytes.size()-boundary-4;if(body_size>size)invalid();if(body_size<size)return{};
        const auto id=headers.contains("x-coincide-request-id")?headers.at("x-coincide-request-id"):"";if(!id.empty()&&(id.size()>128||id.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")!=std::string::npos))invalid();
        return HTTPRequest{path,headers.at("host"),headers.at("authorization"),bytes.substr(boundary+4),id};
    }
};
} // namespace coincide::app_tools
