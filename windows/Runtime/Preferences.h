#pragma once
#include <windows.h>
#include "../Core/Workspace.h"
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <filesystem>
#include <fstream>
#include <map>
#include <cmath>
#include <cctype>
#include <set>

namespace coincide {
struct WindowsProviderPreferences {
    bool enabled{true};
    std::string executable,profile_id;
    std::vector<std::string> favorites,hidden,custom_models;
    ProviderModelPreference defaults;
};
struct ProjectPreferences {std::string provider;std::map<std::string,ProviderModelPreference> models;};
struct Preferences {
    std::string appearance{"system"},language,reply_font{"system"},default_provider{"codex"};
    int font_size{14};bool send_on_return{},background{true},notifications{},keep_awake{},awake_on_battery{},keep_display{},antigravity_ack{};
    std::map<std::string,WindowsProviderPreferences> providers;
    std::map<std::string,ProjectPreferences> projects;
    std::map<std::string,std::string> shortcuts{{"new","Ctrl+N"},{"search","Ctrl+K"},{"settings","Ctrl+,"},{"archive","Ctrl+W"},{"terminal","Ctrl+Shift+T"},{"browser","Ctrl+Shift+B"},{"undo","Ctrl+Z"},{"redo","Ctrl+Shift+Z"},{"quit","Ctrl+Q"}};
    Preferences(){for(const auto provider:provider_ids){WindowsProviderPreferences value;value.defaults.provider=provider;if(provider=="antigravity")value.enabled=false;providers.emplace(std::string(provider),std::move(value));}}
    ProviderModelPreference model_defaults(const std::optional<std::string>& project,const std::string& provider)const{
        if(project)if(const auto found=projects.find(*project);found!=projects.end())if(const auto value=found->second.models.find(provider);value!=found->second.models.end())return value->second;
        if(const auto found=providers.find(provider);found!=providers.end())return found->second.defaults;
        throw std::invalid_argument("Unknown provider preferences");
    }
    std::string provider_default(const std::optional<std::string>& project)const{
        if(project)if(const auto found=projects.find(*project);found!=projects.end())if(known_provider(found->second.provider)&&providers.at(found->second.provider).enabled)return found->second.provider;
        return default_provider;
    }
};
struct Shortcut {unsigned key{};bool control{},shift{},alt{};};
inline Shortcut parse_shortcut(const std::string& text){
    if(text.empty())return{};if(text.size()>64)throw std::invalid_argument("The shortcut is too long");Shortcut result;std::size_t offset{};
    for(;;){const auto delimiter=text.find('+',offset);auto part=text.substr(offset,delimiter==std::string::npos?text.size()-offset:delimiter-offset);
        if(delimiter==std::string::npos){
            if(part.size()==1){const unsigned char character=static_cast<unsigned char>(part[0]);if((character>='a'&&character<='z')||(character>='A'&&character<='Z')||(character>='0'&&character<='9'))result.key=static_cast<unsigned>(std::toupper(character));else if(character==',')result.key=VK_OEM_COMMA;}
            else if(part.size()>=2&&part.front()=='F'){if(part.size()>3)throw std::invalid_argument("Invalid function key");int number{};for(std::size_t i=1;i<part.size();++i){if(part[i]<'0'||part[i]>'9')throw std::invalid_argument("Invalid function key");number=number*10+part[i]-'0';}if(number>=1&&number<=12)result.key=VK_F1+static_cast<unsigned>(number-1);}
            if(!result.key||(!result.control&&!result.alt&&result.key<VK_F1))throw std::invalid_argument("Use Ctrl or Alt with a letter, number or function key");break;
        }
        if(part=="Ctrl"&&!result.control)result.control=true;else if(part=="Shift"&&!result.shift)result.shift=true;else if(part=="Alt"&&!result.alt)result.alt=true;else throw std::invalid_argument("Invalid or repeated shortcut modifier");offset=delimiter+1;
    }
    if((result.alt&&!result.control&&result.key==VK_F4)||(result.alt&&result.control&&result.key<VK_F1))throw std::invalid_argument("This shortcut is reserved by Windows or keyboard input");
    return result;
}
inline void validate_preferences(const Preferences& prefs){
    if(prefs.appearance!="system"&&prefs.appearance!="light"&&prefs.appearance!="dark")throw std::invalid_argument("Invalid appearance");
    if(prefs.reply_font!="system"&&prefs.reply_font!="serif"&&prefs.reply_font!="mono")throw std::invalid_argument("Invalid reply typeface");
    if(prefs.font_size<11||prefs.font_size>28)throw std::invalid_argument("Reply font size must be between 11 and 28");
    constexpr std::string_view languages[]{"","en-US","de","es","es-419","fr","hi","id","it","ja","ko","nl","pl","pt-BR","ru","tr","uk","vi","zh-Hans","zh-Hant"};
    if(std::find(std::begin(languages),std::end(languages),prefs.language)==std::end(languages))throw std::invalid_argument("Unsupported interface language");
    if(!known_provider(prefs.default_provider)||!prefs.providers.at(prefs.default_provider).enabled)throw std::invalid_argument("Enable the default provider before saving");
    auto model=[](const ProviderModelPreference& value,const std::string& provider){
        if(value.provider!=provider)throw std::invalid_argument("Mismatched provider default");
        for(const auto& item:{value.model,value.effort,value.service_tier})if(item.size()>256||item.find_first_of(" \t\r\n\0",0,5)!=std::string::npos)throw std::invalid_argument("Model settings must be bounded identifiers without spaces");
    };
    for(const auto& [id,value]:prefs.providers){
        if(!known_provider(id))throw std::invalid_argument("Unknown provider preferences");model(value.defaults,id);
        if(!value.profile_id.empty()&&!valid_session_binding({id,"pending",0,value.profile_id,{}}))throw std::invalid_argument("Choose an existing provider profile ID");
        if(!value.executable.empty()){
            const std::filesystem::path path(winrt::to_hstring(value.executable).c_str());
            if(!path.is_absolute()||value.executable.size()>32760||value.executable.find('\0')!=std::string::npos||value.executable.starts_with("\\\\"))throw std::invalid_argument("Use an absolute local native executable path");
        }
        std::set<std::string> favorites;
        for(const auto* list:{&value.favorites,&value.hidden,&value.custom_models}){
            if(list->size()>100)throw std::invalid_argument("Keep at most 100 model IDs per list");std::set<std::string> unique;
            for(const auto& entry:*list){if(entry.empty()||entry.size()>256||entry.find_first_of(" \t\r\n\0",0,5)!=std::string::npos||!unique.insert(entry).second)throw std::invalid_argument("Model lists need unique nonempty IDs without spaces");}
        }
        favorites.insert(value.favorites.begin(),value.favorites.end());for(const auto& hidden:value.hidden)if(favorites.contains(hidden))throw std::invalid_argument("A model cannot be both hidden and a favorite");
    }
    if(prefs.providers.size()!=provider_ids.size()||prefs.projects.size()>2000)throw std::invalid_argument("Invalid preferences collection size");
    for(const auto& [id,project]:prefs.projects){if(winrt::guid(winrt::to_hstring(id))==winrt::guid{}||(!project.provider.empty()&&!known_provider(project.provider)))throw std::invalid_argument("Invalid project defaults");for(const auto& [provider,value]:project.models){if(!known_provider(provider))throw std::invalid_argument("Unknown project provider");model(value,provider);}}
    if(prefs.providers.at("antigravity").enabled&&!prefs.antigravity_ack)throw std::invalid_argument("Acknowledge the documented Antigravity account risk before enabling it");
    const Preferences defaults;std::set<std::string> keys;
    for(const auto& [action,text]:prefs.shortcuts){if(!defaults.shortcuts.contains(action))throw std::invalid_argument("Unknown keyboard action");const auto value=parse_shortcut(text);if(!value.key)continue;const auto key=std::to_string(value.key)+":"+std::to_string(value.control)+std::to_string(value.shift)+std::to_string(value.alt);if(!keys.insert(key).second)throw std::invalid_argument("Two actions use the same keyboard shortcut");}
    if(prefs.shortcuts.size()!=defaults.shortcuts.size())throw std::invalid_argument("Missing keyboard action");
}
class PreferencesStore {
    using Object=winrt::Windows::Data::Json::JsonObject;using Value=winrt::Windows::Data::Json::JsonValue;using Array=winrt::Windows::Data::Json::JsonArray;using Type=winrt::Windows::Data::Json::JsonValueType;
    std::filesystem::path directory_;Object original_{nullptr};std::optional<std::string> snapshot_;bool opened_{};
    std::filesystem::path path()const{return directory_/L"settings.json";}
    static std::optional<std::string> read(const std::filesystem::path& path){if(!std::filesystem::exists(path))return{};if(std::filesystem::file_size(path)>1024*1024)throw std::runtime_error("The settings file exceeds 1 MB");std::ifstream input(path,std::ios::binary);if(!input)throw std::runtime_error("Could not read preferences");std::string bytes((std::istreambuf_iterator<char>(input)),{});if(input.bad())throw std::runtime_error("Could not read preferences");return bytes;}
    static std::string text(const Object& value,const wchar_t* name,std::string fallback={}){return winrt::to_string(value.GetNamedString(name,winrt::to_hstring(fallback)));}
    static Object clone(const Object& value){return value?Object::Parse(value.Stringify()):Object{};}
    static void put(const Object& value,const wchar_t* key,const std::string& text){value.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(text)));}
    static std::vector<std::string> list(const Object& value,const wchar_t* key){std::vector<std::string> result;for(const auto& item:value.GetNamedArray(key,Array{}))result.push_back(winrt::to_string(item.GetString()));return result;}
    static void put_list(const Object& value,const wchar_t* key,const std::vector<std::string>& entries){Array result;for(const auto& text:entries)result.Append(Value::CreateStringValue(winrt::to_hstring(text)));value.SetNamedValue(key,result);}
    static ProviderModelPreference model(const Object& value,const std::string& provider){return {provider,text(value,L"model"),text(value,L"effort"),text(value,L"serviceTier"),value.GetNamedBoolean(L"plan",false),value.GetNamedBoolean(L"fullAccess",false)};}
    static Object encode_model(const ProviderModelPreference& value,const Object& original){auto result=clone(original);put(result,L"model",value.model);put(result,L"effort",value.effort);put(result,L"serviceTier",value.service_tier);result.SetNamedValue(L"plan",Value::CreateBooleanValue(value.plan));result.SetNamedValue(L"fullAccess",Value::CreateBooleanValue(value.full_access));return result;}
public:
    explicit PreferencesStore(std::filesystem::path directory):directory_(std::move(directory)){if(!directory_.is_absolute())throw std::invalid_argument("Preferences need an absolute app data directory");}
    Preferences open(){
        opened_=false;original_=nullptr;snapshot_.reset();Preferences result;const auto bytes=read(path());
        if(bytes){auto value=Object::Parse(winrt::to_hstring(*bytes));if(value.GetNamedNumber(L"version")!=1||text(value,L"format")!="coincide.windows.settings")throw std::runtime_error("Unsupported preferences; the original file was preserved");
            result.appearance=text(value,L"appearance","system");result.language=text(value,L"language");result.reply_font=text(value,L"replyFont","system");result.default_provider=text(value,L"defaultProvider","codex");const auto size=value.GetNamedNumber(L"fontSize",14);if(size!=std::floor(size)||size<11||size>28)throw std::invalid_argument("Invalid font size");result.font_size=static_cast<int>(size);
            result.send_on_return=value.GetNamedBoolean(L"sendOnReturn",false);result.background=value.GetNamedBoolean(L"background",true);result.notifications=value.GetNamedBoolean(L"notifications",false);result.keep_awake=value.GetNamedBoolean(L"keepAwake",false);result.awake_on_battery=value.GetNamedBoolean(L"awakeOnBattery",false);result.keep_display=value.GetNamedBoolean(L"keepDisplay",false);result.antigravity_ack=value.GetNamedBoolean(L"antigravityAcknowledged",false);
            auto providers=value.GetNamedObject(L"providers",Object{});for(auto& [id,provider]:result.providers){auto entry=providers.GetNamedObject(winrt::to_hstring(id),Object{});provider.enabled=entry.GetNamedBoolean(L"enabled",true);provider.executable=text(entry,L"executable");provider.profile_id=winrt::to_string(entry.GetNamedString(L"profileID",L""));provider.favorites=list(entry,L"favorites");provider.hidden=list(entry,L"hidden");provider.custom_models=list(entry,L"customModels");provider.defaults=model(entry.GetNamedObject(L"defaults",Object{}),id);}
            for(const auto& entry:value.GetNamedObject(L"shortcuts",Object{}))if(result.shortcuts.contains(winrt::to_string(entry.Key())))result.shortcuts[winrt::to_string(entry.Key())]=winrt::to_string(entry.Value().GetString());
            for(const auto& item:value.GetNamedObject(L"projects",Object{})){auto entry=item.Value().GetObject();ProjectPreferences project;project.provider=text(entry,L"provider");for(const auto& option:entry.GetNamedObject(L"models",Object{})){auto id=winrt::to_string(option.Key());project.models[id]=model(option.Value().GetObject(),id);}result.projects.emplace(winrt::to_string(item.Key()),std::move(project));}
            validate_preferences(result);original_=value;}
        snapshot_=bytes;opened_=true;return result;
    }
    void save(const Preferences& prefs){
        if(!opened_)throw std::runtime_error("Preferences are read-only after a failed load");validate_preferences(prefs);std::filesystem::create_directories(directory_);
        HANDLE lock=CreateFileW((directory_/L"settings.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr);if(lock==INVALID_HANDLE_VALUE)throw std::runtime_error("Preferences are being saved by another process");struct Unlock{HANDLE value;~Unlock(){CloseHandle(value);}} unlock{lock};
        if(read(path())!=snapshot_)throw std::runtime_error("Preferences changed in another window; reopen before saving");auto value=clone(original_);put(value,L"format","coincide.windows.settings");value.SetNamedValue(L"version",Value::CreateNumberValue(1));put(value,L"appearance",prefs.appearance);put(value,L"language",prefs.language);put(value,L"replyFont",prefs.reply_font);put(value,L"defaultProvider",prefs.default_provider);value.SetNamedValue(L"fontSize",Value::CreateNumberValue(prefs.font_size));
        for(const auto& entry:{std::pair{L"sendOnReturn",prefs.send_on_return},{L"background",prefs.background},{L"notifications",prefs.notifications},{L"keepAwake",prefs.keep_awake},{L"awakeOnBattery",prefs.awake_on_battery},{L"keepDisplay",prefs.keep_display},{L"antigravityAcknowledged",prefs.antigravity_ack}})value.SetNamedValue(entry.first,Value::CreateBooleanValue(entry.second));
        auto providers=clone(value.GetNamedObject(L"providers",Object{}));for(const auto& [id,provider]:prefs.providers){auto entry=clone(providers.GetNamedObject(winrt::to_hstring(id),Object{}));entry.SetNamedValue(L"enabled",Value::CreateBooleanValue(provider.enabled));put(entry,L"executable",provider.executable);put(entry,L"profileID",provider.profile_id);put_list(entry,L"favorites",provider.favorites);put_list(entry,L"hidden",provider.hidden);put_list(entry,L"customModels",provider.custom_models);entry.SetNamedValue(L"defaults",encode_model(provider.defaults,entry.GetNamedObject(L"defaults",Object{})));providers.SetNamedValue(winrt::to_hstring(id),entry);}value.SetNamedValue(L"providers",providers);
        auto shortcuts=clone(value.GetNamedObject(L"shortcuts",Object{}));for(const auto& [id,text]:prefs.shortcuts)put(shortcuts,winrt::to_hstring(id).c_str(),text);value.SetNamedValue(L"shortcuts",shortcuts);
        auto previous=value.GetNamedObject(L"projects",Object{});Object projects;for(const auto& [id,project]:prefs.projects){auto entry=clone(previous.GetNamedObject(winrt::to_hstring(id),Object{}));put(entry,L"provider",project.provider);auto models=clone(entry.GetNamedObject(L"models",Object{}));for(const auto provider:provider_ids)if(!project.models.contains(std::string(provider))&&models.HasKey(winrt::to_hstring(provider)))models.Remove(winrt::to_hstring(provider));for(const auto& [provider,selection]:project.models)models.SetNamedValue(winrt::to_hstring(provider),encode_model(selection,models.GetNamedObject(winrt::to_hstring(provider),Object{})));entry.SetNamedValue(L"models",models);projects.SetNamedValue(winrt::to_hstring(id),entry);}value.SetNamedValue(L"projects",projects);
        const auto bytes=winrt::to_string(value.Stringify());if(bytes.size()>1024*1024)throw std::runtime_error("Preferences exceed their size limit");const auto temp=directory_/(L"settings-"+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64())+L".tmp");
        struct Cleanup{std::filesystem::path value;~Cleanup(){DeleteFileW(value.c_str());}} cleanup{temp};HANDLE output=CreateFileW(temp.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(output==INVALID_HANDLE_VALUE)throw std::runtime_error("Could not prepare preferences");
        DWORD count{};const bool written=WriteFile(output,bytes.data(),static_cast<DWORD>(bytes.size()),&count,nullptr)&&count==bytes.size()&&FlushFileBuffers(output);CloseHandle(output);if(!written||!MoveFileExW(temp.c_str(),path().c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("Could not atomically save preferences");original_=value;snapshot_=bytes;
    }
};
} // namespace coincide
