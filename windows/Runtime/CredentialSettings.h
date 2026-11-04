#pragma once
#include "BrowserCredentials.h"
#include <winrt/Windows.Data.Json.h>
#include <cmath>
#include "LocalFileRead.h"
#include <filesystem>
#include <fstream>
#include <optional>

namespace coincide::credentials {
using Object=winrt::Windows::Data::Json::JsonObject;using Value=winrt::Windows::Data::Json::JsonValue;using Type=winrt::Windows::Data::Json::JsonValueType;
inline void put(const Object& target,const wchar_t* key,const std::string& value){target.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(value)));}
struct Settings {bool saved{},bitwarden{},one_password{};bool enabled(Manager value)const{switch(value){case Manager::saved:return saved;case Manager::bitwarden:return bitwarden;case Manager::one_password:return one_password;}return false;}void set(Manager value,bool on){switch(value){case Manager::saved:saved=on;break;case Manager::bitwarden:bitwarden=on;break;case Manager::one_password:one_password=on;break;}}};
// Only manager opt-ins are saved. No vault/session tokens, passwords or fill approvals enter
// this file. Loading settings neither reads a vault nor invokes a manager executable.
class SettingsStore {
    std::filesystem::path directory_;Object original_{nullptr};std::optional<std::string> snapshot_;bool opened_{};
    std::unique_ptr<local_file::Handle> directory_pin_;std::optional<std::string> directory_id_;
    static constexpr std::size_t maximum=64*1024;
    std::filesystem::path file()const{return directory_/L"browser-credentials.json";}
    static std::string directory_id(HANDLE handle){FILE_ID_INFO info{};if(!GetFileInformationByHandleEx(handle,FileIdInfo,&info,sizeof(info)))throw std::runtime_error("Could not identify the Password manager settings folder");std::string result=std::to_string(info.VolumeSerialNumber)+":";constexpr char digits[]="0123456789abcdef";for(const auto byte:info.FileId.Identifier){result+=digits[byte>>4];result+=digits[byte&15];}return result;}
    void bind(){
        if(local_file::has_reparse(directory_))throw std::runtime_error("Password manager settings cannot use a linked folder");
        auto pin=std::make_unique<local_file::Handle>(CreateFileW(directory_.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr));if(pin->value==INVALID_HANDLE_VALUE)throw std::runtime_error("The Password manager settings folder is unavailable");
        const auto current=directory_id(pin->value);if(directory_id_&&*directory_id_!=current)throw std::runtime_error("The Password manager data folder changed; reopen settings");directory_id_=current;directory_pin_=std::move(pin);
    }
    void check_scope(){if(directory_id_){if(!std::filesystem::exists(directory_))throw std::runtime_error("The Password manager data folder moved; reopen settings");bind();}}
    std::optional<std::string> read()const{if(!std::filesystem::exists(file()))return{};return local_file::read(file(),maximum).bytes;}
    static void validate_unknown(const winrt::Windows::Data::Json::IJsonValue& value,unsigned depth=0,std::size_t* count=nullptr){
        std::size_t local{};if(!count)count=&local;if(depth>8||++*count>512)throw std::invalid_argument("Password manager settings exceed their structural bound");
        if(value.ValueType()==Type::Object){for(const auto& item:value.GetObject()){auto key=winrt::to_string(item.Key());if(key.size()>128)throw std::invalid_argument("Password manager settings field exceeds its bound");std::transform(key.begin(),key.end(),key.begin(),[](unsigned char ch){return ch>='A'&&ch<='Z'?static_cast<char>(ch+32):static_cast<char>(ch);});
            static const std::set<std::string> forbidden{"token","access_token","refresh_token","authorization","password","private_key","api_key","client_secret","secret","cookies","credentials","grants","threads","capabilities","permissions","session","bw_session","op_service_account_token","master_password","totp","totpseed"};
            if(forbidden.contains(key))throw std::invalid_argument("Password manager settings must not contain credentials or saved thread grants");validate_unknown(item.Value(),depth+1,count);}}
        else if(value.ValueType()==Type::Array){if(value.GetArray().Size()>128)throw std::invalid_argument("Password manager settings array exceeds its bound");for(const auto& item:value.GetArray())validate_unknown(item,depth+1,count);}
        else if(value.ValueType()==Type::String){const auto text=winrt::to_string(value.GetString());if(text.size()>4096||text.find('\0')!=std::string::npos)throw std::invalid_argument("Password manager settings string exceeds its bound");}
        else if(value.ValueType()==Type::Number&&!std::isfinite(value.GetNumber()))throw std::invalid_argument("Invalid Password manager settings number");
    }
public:
    explicit SettingsStore(std::filesystem::path directory):directory_(std::move(directory)){
        if(!local_file::local_path(directory_)||directory_.wstring().find(L'\0')!=std::wstring::npos||local_file::has_reparse(directory_))throw std::invalid_argument("Password manager settings need an absolute local app data folder");
        directory_=directory_.lexically_normal();
    }
    Settings open(){
        opened_=false;original_=nullptr;snapshot_.reset();if(std::filesystem::exists(directory_))bind();else if(directory_id_)throw std::runtime_error("The Password manager data folder moved; reopen its workspace");
        const auto bytes=read();Settings settings;Object document{nullptr};
        if(bytes){document=Object::Parse(winrt::to_hstring(*bytes));validate_unknown(document);if(document.GetNamedNumber(L"version",0)!=1||document.GetNamedString(L"format",L"")!=L"coincide.windows.browser-credentials")throw std::runtime_error("Unsupported Password manager settings; the original file was preserved");settings.saved=document.GetNamedBoolean(L"saved",false);settings.bitwarden=document.GetNamedBoolean(L"bitwarden",false);settings.one_password=document.GetNamedBoolean(L"onePassword",false);}
        original_=document;snapshot_=bytes;opened_=true;return settings;
    }
    void save(Settings settings){
        if(!opened_)throw std::logic_error("Password manager settings must load successfully before saving");check_scope();std::filesystem::create_directories(directory_);bind();
        if(local_file::has_reparse(directory_/L"browser-credentials.lock"))throw std::runtime_error("The Password manager settings lock is linked");
        local_file::Handle lock(CreateFileW((directory_/L"browser-credentials.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,nullptr));if(lock.value==INVALID_HANDLE_VALUE)throw std::runtime_error("Password manager settings are being saved by another window");
        if(read()!=snapshot_)throw std::runtime_error("Password manager settings changed in another window; reopen before editing");
        auto document=original_?Object::Parse(original_.Stringify()):Object{};put(document,L"format","coincide.windows.browser-credentials");document.SetNamedValue(L"version",Value::CreateNumberValue(1));document.SetNamedValue(L"saved",Value::CreateBooleanValue(settings.saved));document.SetNamedValue(L"bitwarden",Value::CreateBooleanValue(settings.bitwarden));document.SetNamedValue(L"onePassword",Value::CreateBooleanValue(settings.one_password));validate_unknown(document);auto bytes=winrt::to_string(document.Stringify());if(bytes.size()>maximum)throw std::runtime_error("Password manager settings exceed their file size bound");
        std::optional<std::string> next(bytes);const auto temporary=directory_/winrt::to_hstring("browser-credentials-"+random_id()+".tmp").c_str();const auto handle=CreateFileW(temporary.c_str(),GENERIC_WRITE|DELETE,FILE_SHARE_READ|FILE_SHARE_DELETE,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);if(handle==INVALID_HANDLE_VALUE)throw std::runtime_error("Could not create temporary Password manager settings");
        struct Pending{HANDLE value;bool keep{};~Pending(){if(!keep){FILE_DISPOSITION_INFO remove{TRUE};SetFileInformationByHandle(value,FileDispositionInfo,&remove,sizeof(remove));}CloseHandle(value);}}pending{handle};DWORD written{};
        if(!WriteFile(handle,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)||written!=bytes.size()||!FlushFileBuffers(handle)||!MoveFileExW(temporary.c_str(),file().c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("Could not publish Password manager settings; the previous file was preserved");
        pending.keep=true;original_=std::move(document);snapshot_.swap(next);
    }
};
} // namespace coincide::credentials
