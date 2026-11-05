#pragma once
#include "OfflineVoice.h"
#include "../Core/VoiceShortcutState.h"
#include <winrt/Windows.Data.Json.h>
#include <optional>

namespace coincide {
struct VoiceLanguage {const char* code;const wchar_t* label;};
inline constexpr VoiceLanguage voice_languages[]{{"auto",L"Detect language"},{"en",L"English"},{"es",L"Spanish"},{"fr",L"French"},{"de",L"German"},{"hi",L"Hindi"},{"pt",L"Portuguese"},{"ja",L"Japanese"},{"zh",L"Chinese"},{"ko",L"Korean"},{"ar",L"Arabic"},{"ru",L"Russian"},{"it",L"Italian"},{"nl",L"Dutch"},{"pl",L"Polish"},{"tr",L"Turkish"},{"uk",L"Ukrainian"},{"vi",L"Vietnamese"},{"id",L"Indonesian"}};
struct OfflineVoiceSettings {
    bool enabled{},shortcut_enabled{};VoiceShortcutMode shortcut_mode=VoiceShortcutMode::hold;std::string executable,model,language="auto";unsigned threads=4;
};
class OfflineVoiceSettingsStore {
    using Object=winrt::Windows::Data::Json::JsonObject;using Value=winrt::Windows::Data::Json::JsonValue;
    std::filesystem::path directory_;Object original_{nullptr};std::optional<std::string> snapshot_;bool opened_{};
    std::optional<std::string> read()const{const auto path=directory_/L"voice.json";return std::filesystem::exists(path)?std::optional<std::string>{local_file::read(path,64*1024).bytes}:std::nullopt;}
public:
    explicit OfflineVoiceSettingsStore(std::filesystem::path app_voice_directory):directory_(std::move(app_voice_directory)){
        if(!local_file::local_path(directory_)||local_file::has_reparse(directory_))throw std::invalid_argument("Voice settings need an absolute local app folder");
    }
    std::filesystem::path directory()const{return directory_;}
    std::filesystem::path models_root()const{return directory_/L"models";}
    static void validate(const OfflineVoiceSettings& settings){
        if(!VoiceShortcutState::valid(settings.shortcut_mode))throw std::invalid_argument("Choose a supported dictation shortcut behavior");
        if(settings.executable.size()>32760||settings.executable.find('\0')!=std::string::npos||(!settings.executable.empty()&&(!local_file::local_path(std::filesystem::path(winrt::to_hstring(settings.executable).c_str()))||local_file::lower(std::filesystem::path(winrt::to_hstring(settings.executable).c_str()).extension().wstring())!=L".exe")))throw std::invalid_argument("Choose an absolute local native speech engine executable");
        if(settings.model.size()>256||settings.model.find_first_of("/\\:\0",0,4)!=std::string::npos||(!settings.model.empty()&&local_file::lower(std::filesystem::path(winrt::to_hstring(settings.model).c_str()).extension().wstring())!=L".bin"))throw std::invalid_argument("Choose a model filename in the app's model folder");
        if(settings.threads<1||settings.threads>16||std::none_of(std::begin(voice_languages),std::end(voice_languages),[&](const auto& value){return value.code==settings.language;}))throw std::invalid_argument("Choose a supported voice language and bounded CPU thread count");
        if(settings.enabled&&(settings.executable.empty()||settings.model.empty()))throw std::invalid_argument("Choose a speech engine and model before enabling Voice");
    }
    OfflineVoiceSettings open(){
        opened_=false;original_=nullptr;snapshot_.reset();OfflineVoiceSettings settings;const auto bytes=read();
        if(bytes){const auto value=Object::Parse(winrt::to_hstring(*bytes));if(value.GetNamedNumber(L"version",0)!=1||value.GetNamedString(L"format",L"")!=L"coincide.windows.offline-voice")throw std::runtime_error("Unsupported voice settings; the original file was preserved");
            settings.enabled=value.GetNamedBoolean(L"enabled",false);settings.executable=winrt::to_string(value.GetNamedString(L"executable",L""));settings.model=winrt::to_string(value.GetNamedString(L"model",L""));settings.language=winrt::to_string(value.GetNamedString(L"language",L"auto"));const auto threads=value.GetNamedNumber(L"threads",4);
            if((value.HasKey(L"shortcutEnabled")&&value.GetNamedValue(L"shortcutEnabled").ValueType()!=winrt::Windows::Data::Json::JsonValueType::Boolean)||(value.HasKey(L"shortcutMode")&&value.GetNamedValue(L"shortcutMode").ValueType()!=winrt::Windows::Data::Json::JsonValueType::String))throw std::invalid_argument("Invalid dictation shortcut settings");settings.shortcut_enabled=value.GetNamedBoolean(L"shortcutEnabled",false);const auto mode=value.GetNamedString(L"shortcutMode",L"hold");if(mode!=L"hold"&&mode!=L"toggle")throw std::invalid_argument("Unsupported dictation shortcut behavior");settings.shortcut_mode=mode==L"hold"?VoiceShortcutMode::hold:VoiceShortcutMode::toggle;
            if(!std::isfinite(threads)||threads!=std::floor(threads)||threads<1||threads>16)throw std::invalid_argument("Invalid voice CPU thread count");settings.threads=static_cast<unsigned>(threads);validate(settings);original_=value;
        }snapshot_=bytes;opened_=true;return settings;
    }
    OfflineVoiceOptions options(const OfflineVoiceSettings& settings)const{
        validate(settings);if(!settings.enabled)throw std::runtime_error("Enable Voice before recording");return{std::filesystem::path(winrt::to_hstring(settings.executable).c_str()),models_root(),models_root()/winrt::to_hstring(settings.model).c_str(),directory_/L"working",settings.language,settings.threads,std::chrono::minutes(10)};
    }
    void save(const OfflineVoiceSettings& settings){
        if(!opened_)throw std::runtime_error("Voice settings cannot be changed after a failed load");validate(settings);if(local_file::has_reparse(directory_))throw std::runtime_error("The voice settings folder changed");std::filesystem::create_directories(directory_);
        local_file::Handle lock(CreateFileW((directory_/L"voice.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr));if(lock.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Voice settings are being saved in another window");
        if(read()!=snapshot_)throw std::runtime_error("Voice settings changed in another window; reopen before saving");
        auto value=original_?Object::Parse(original_.Stringify()):Object{};value.SetNamedValue(L"version",Value::CreateNumberValue(1));value.SetNamedValue(L"format",Value::CreateStringValue(L"coincide.windows.offline-voice"));value.SetNamedValue(L"enabled",Value::CreateBooleanValue(settings.enabled));
        value.SetNamedValue(L"shortcutEnabled",Value::CreateBooleanValue(settings.shortcut_enabled));value.SetNamedValue(L"shortcutMode",Value::CreateStringValue(settings.shortcut_mode==VoiceShortcutMode::hold?L"hold":L"toggle"));
        for(const auto& [key,text]:std::vector<std::pair<const wchar_t*,std::string>>{{L"executable",settings.executable},{L"model",settings.model},{L"language",settings.language}})value.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(text)));value.SetNamedValue(L"threads",Value::CreateNumberValue(settings.threads));
        const auto bytes=winrt::to_string(value.Stringify());if(bytes.size()>64*1024)throw std::runtime_error("Voice settings exceed their file size limit");winrt::guid id;winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&id)));const auto temporary=directory_/(L"voice-"+std::wstring(winrt::to_hstring(id))+L".tmp");
        const auto file=CreateFileW(temporary.c_str(),GENERIC_WRITE|DELETE,FILE_SHARE_READ|FILE_SHARE_DELETE,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(file==INVALID_HANDLE_VALUE)throw std::runtime_error("Could not save voice settings");
        struct Pending{HANDLE value;bool keep{};~Pending(){if(!keep){FILE_DISPOSITION_INFO remove{TRUE};SetFileInformationByHandle(value,FileDispositionInfo,&remove,sizeof(remove));}CloseHandle(value);}} pending{file};DWORD count{};
        if(!WriteFile(file,bytes.data(),static_cast<DWORD>(bytes.size()),&count,nullptr)||count!=bytes.size()||!FlushFileBuffers(file)||!MoveFileExW(temporary.c_str(),(directory_/L"voice.json").c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("Could not publish voice settings; the previous file was preserved");
        pending.keep=true;original_=value;snapshot_=bytes;
    }
    std::vector<std::string> models()const{
        std::vector<std::string> result;const auto root=models_root();if(local_file::has_reparse(root))throw std::runtime_error("The app's model folder is linked; review it before using Voice");std::error_code error;if(!std::filesystem::exists(root,error))return result;std::size_t visited{};
        for(std::filesystem::directory_iterator it(root,std::filesystem::directory_options::skip_permission_denied,error),end;!error&&it!=end;it.increment(error)){
            if(++visited>2000)throw std::runtime_error("The app's model folder exceeds its discovery limit");if(local_file::reparse(it->path())||!it->is_regular_file(error)||local_file::lower(it->path().extension().wstring())!=L".bin")continue;
            const auto bytes=it->file_size(error);if(error)break;if(bytes>=16&&bytes<=4ULL*1024*1024*1024)result.push_back(winrt::to_string(it->path().filename().wstring()));
        }if(error)throw std::runtime_error("The app's model folder could not be read completely");std::sort(result.begin(),result.end());return result;
    }
};
} // namespace coincide
