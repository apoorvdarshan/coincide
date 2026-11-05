#pragma once
#include "BrowserCredentials.h"
#include "CredentialTotp.h"
#include "WindowsCredentials.h"
#include "AgentAccountScope.h"
#include <winrt/Windows.Data.Json.h>
#include <mutex>

namespace coincide::credentials {
// Windows Credential Manager, scoped to this local DataRoot. Construction is inert. These
// methods are only wired to explicit native review/fill actions, never settings construction.
class SavedLoginVault {
public:
    struct Storage {virtual ~Storage()=default;virtual std::vector<std::wstring> names()const=0;virtual std::optional<WindowsCredential> load(std::wstring_view)const=0;virtual void save(std::wstring_view,std::wstring_view,std::span<const std::uint8_t>)const=0;virtual bool erase(std::wstring_view)const=0;};
private:
    struct NativeStorage final:Storage {WindowsCredentials store;explicit NativeStorage(std::wstring scope):store(std::move(scope)){}std::vector<std::wstring> names()const override{return store.names();}std::optional<WindowsCredential> load(std::wstring_view name)const override{return store.load(name);}void save(std::wstring_view name,std::wstring_view username,std::span<const std::uint8_t> secret)const override{store.save(name,username,secret);}bool erase(std::wstring_view name)const override{return store.erase(name);}};
    std::shared_ptr<Storage> store_;mutable std::mutex gate_;using Object=winrt::Windows::Data::Json::JsonObject;using Value=winrt::Windows::Data::Json::JsonValue;
    static std::wstring scope(const std::filesystem::path& directory){if(!local_file::local_path(directory)||local_file::has_reparse(directory))throw std::invalid_argument("Saved logins require a regular local app profile");return L"BrowserLogins-"+std::wstring(winrt::to_hstring(AgentAccountScope::fingerprint("browser-logins","local",winrt::to_string(local_file::lower(directory.lexically_normal().wstring())))));}
    static Object decode(const WindowsCredential& entry){const auto bytes=entry.secret.bytes();try{return Object::Parse(winrt::to_hstring(std::string_view(reinterpret_cast<const char*>(bytes.data()),bytes.size())));}catch(...){throw std::runtime_error("A saved login could not be decoded");}}
    static std::string field(const Object& item,const wchar_t* key){return winrt::to_string(item.GetNamedString(key,L""));}
    static LoginItem metadata(const std::wstring& id,const Object& value){if(value.GetNamedNumber(L"version",0)!=1)throw std::runtime_error("Unsupported saved-login record");LoginItem item{Manager::saved,winrt::to_string(id),field(value,L"title"),field(value,L"username"),{field(value,L"url")},value.GetNamedBoolean(L"hasTotp",false)};validate(item);(void)origin(item.urls.front());return item;}
public:
    explicit SavedLoginVault(const std::filesystem::path& directory):store_(std::make_shared<NativeStorage>(scope(directory))){}
    explicit SavedLoginVault(std::shared_ptr<Storage> storage):store_(std::move(storage)){if(!store_)throw std::invalid_argument("Saved logins require a storage backend");}
    std::vector<LoginItem> list()const{std::lock_guard lock(gate_);std::vector<LoginItem> result;for(const auto& id:store_->names()){const auto entry=store_->load(id);if(entry)result.push_back(metadata(id,decode(*entry)));}return result;}
    // New unique IDs only; never overwrites an original. A failed batch removes only entries
    // this call created. OS failure during rollback is surfaced as recovery required.
    void import(const std::vector<const CsvLogin*>& logins)const{std::lock_guard lock(gate_);if(logins.empty()||logins.size()>10000)throw std::invalid_argument("Invalid saved-login review selection");std::set<std::string> ids;for(const auto* login:logins){if(!login)throw std::invalid_argument("Invalid saved-login selection");validate(login->item);if(login->item.source!=Manager::saved||login->item.urls.size()!=1||login->password.empty()||!ids.insert(login->item.id).second)throw std::invalid_argument("Invalid saved-login review entry");if(!login->totp_seed.empty())(void)Totp(login->totp_seed.view());}
        struct Prepared{std::wstring name,username;SecretText encoded;};std::vector<Prepared> prepared;prepared.reserve(logins.size());std::set<std::wstring> canonical_names;
        for(const auto* login:logins){auto id=thread_id(login->item.id);id.erase(std::remove_if(id.begin(),id.end(),[](char c){return c=='{'||c=='}';}),id.end());const auto name=std::wstring(winrt::to_hstring(id));if(!canonical_names.insert(name).second||store_->load(name))throw std::runtime_error("A reviewed login is already saved");Object value;value.SetNamedValue(L"version",Value::CreateNumberValue(1));const auto put=[&](const wchar_t* key,std::string_view text){value.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(text)));};put(L"title",login->item.title);put(L"username",login->item.username);put(L"url",login->item.urls.front());put(L"password",login->password.view());put(L"totpSeed",login->totp_seed.view());value.SetNamedValue(L"hasTotp",Value::CreateBooleanValue(!login->totp_seed.empty()));auto encoded=winrt::to_string(value.Stringify());struct Wipe{std::string& value;~Wipe(){if(!value.empty())SecureZeroMemory(value.data(),value.size());}}wipe{encoded};if(encoded.size()>CRED_MAX_CREDENTIAL_BLOB_SIZE)throw std::invalid_argument("A reviewed login exceeds Windows Credential Manager storage bounds");prepared.push_back({name,std::wstring(winrt::to_hstring(login->item.username)),SecretText(encoded)});}
        std::size_t created{};try{for(const auto& entry:prepared){const auto bytes=entry.encoded.view();store_->save(entry.name,entry.username,{reinterpret_cast<const std::uint8_t*>(bytes.data()),bytes.size()});++created;}}
        catch(...){const auto failure=std::current_exception();bool recovery{};for(std::size_t i=0;i<created;++i)try{(void)store_->erase(prepared[i].name);}catch(...){recovery=true;}if(recovery)throw std::runtime_error("The import did not finish and its new entries need review; existing logins were preserved");std::rethrow_exception(failure);}}

    LoginSecret resolve(const LoginItem& item,std::uint64_t epoch_seconds)const{std::lock_guard lock(gate_);validate(item);if(item.source!=Manager::saved)throw std::invalid_argument("The selected login belongs to another manager");const auto entry=store_->load(winrt::to_hstring(item.id));if(!entry)throw std::runtime_error("The saved login is unavailable");const auto value=decode(*entry);const auto actual=metadata(winrt::to_hstring(item.id).c_str(),value);if(actual.urls!=item.urls||actual.username!=item.username)throw std::runtime_error("The saved login changed before filling");auto password=field(value,L"password"),seed=field(value,L"totpSeed");struct Wipe{std::string& a;std::string& b;~Wipe(){if(!a.empty())SecureZeroMemory(a.data(),a.size());if(!b.empty())SecureZeroMemory(b.data(),b.size());}}wipe{password,seed};LoginSecret result{actual.username,SecretText(password),{}};if(!seed.empty())result.totp=Totp(seed).code(epoch_seconds);return result;}
    bool erase(const LoginItem& item)const{std::lock_guard lock(gate_);validate(item);if(item.source!=Manager::saved)throw std::invalid_argument("The selected login belongs to another manager");return store_->erase(winrt::to_hstring(item.id));}
};
} // namespace coincide::credentials
