#pragma once
#include "LocalFileRead.h"
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <objbase.h>
#include <functional>
#include <atomic>
#include <memory>
#include <mutex>
#include <map>
#include <optional>
#include <set>
#include <span>

namespace coincide::credentials {
inline std::string lower(std::string value){for(auto& ch:value)if(ch>='A'&&ch<='Z')ch=static_cast<char>(ch+32);return value;}
inline std::string trim(std::string_view value){const auto a=value.find_first_not_of(" \t\r\n"),b=value.find_last_not_of(" \t\r\n");return a==std::string_view::npos?std::string{}:std::string(value.substr(a,b-a+1));}
inline void text_bound(std::string_view value,std::size_t maximum,bool multiline=false){if(value.size()>maximum||!local_file::utf8(value)||value.find('\0')!=std::string_view::npos||(!multiline&&std::any_of(value.begin(),value.end(),[](unsigned char ch){return ch<32||ch==127;})))throw std::invalid_argument("Credential text exceeds its safe bounds");}
inline std::string random_id(){GUID id{};winrt::check_hresult(CoCreateGuid(&id));wchar_t value[40]{};StringFromGUID2(id,value,40);return winrt::to_string(value);}
inline std::string thread_id(const std::string& value){text_bound(value,38);if(value.size()!=38)throw std::invalid_argument("A credential request needs its owning conversation");GUID id{};if(FAILED(CLSIDFromString(winrt::to_hstring(value).c_str(),&id)))throw std::invalid_argument("Invalid credential conversation");wchar_t canonical[40]{};StringFromGUID2(id,canonical,40);if(lower(value)!=lower(winrt::to_string(canonical)))throw std::invalid_argument("Invalid credential conversation");return lower(value);}
// Move-only transient bytes. Neither secrets nor TOTP seeds have a string/JSON/debug conversion.
class SecretText {
    std::vector<char> data_;
public:
    SecretText()=default;explicit SecretText(std::string_view value):data_(value.begin(),value.end()){}
    SecretText(const SecretText&)=delete;SecretText& operator=(const SecretText&)=delete;
    SecretText(SecretText&& other)noexcept:data_(std::move(other.data_)){}SecretText& operator=(SecretText&& other)noexcept{if(this!=&other){clear();data_=std::move(other.data_);}return*this;}
    ~SecretText(){clear();}void clear()noexcept{if(!data_.empty())SecureZeroMemory(data_.data(),data_.size());data_.clear();}
    std::string_view view()const noexcept{return{data_.data(),data_.size()};}bool empty()const noexcept{return data_.empty();}
};
enum class Manager{saved,bitwarden,one_password};
inline std::string manager_id(Manager value){switch(value){case Manager::saved:return"saved";case Manager::bitwarden:return"bitwarden";case Manager::one_password:return"onePassword";}throw std::invalid_argument("Invalid password manager");}
struct LoginItem {Manager source{Manager::saved};std::string id,title,username;std::vector<std::string> urls;bool has_totp{};};
inline void validate(const LoginItem& item){(void)manager_id(item.source);text_bound(item.id,256);if(item.id.empty())throw std::invalid_argument("The login identifier is empty");text_bound(item.title,512);text_bound(item.username,512);if(item.urls.size()>16)throw std::invalid_argument("The login has too many addresses");for(const auto& url:item.urls)text_bound(url,4096);}
struct LoginSecret {std::string username;SecretText password,totp;};
// Deliberately exact-origin matching. No public-suffix guess or origin supplied by an agent.
inline std::string origin(std::string_view address){
    text_bound(address,4096);if(address.empty())throw std::invalid_argument("Open a web sign-in page first");
    try{const winrt::Windows::Foundation::Uri uri(winrt::to_hstring(address));const auto scheme=lower(winrt::to_string(uri.SchemeName()));if((scheme!="https"&&scheme!="http")||uri.Host().empty()||!uri.UserName().empty()||!uri.Password().empty())throw std::invalid_argument("Invalid web origin");
        auto host=lower(winrt::to_string(uri.Host()));if(host.find_first_of(" /\\\t\r\n@")!=std::string::npos)throw std::invalid_argument("Invalid web origin");if(host.find(':')!=std::string::npos&&!host.starts_with("["))host="["+host+"]";const auto port=uri.Port();return scheme+"://"+host+((port==80&&scheme=="http")||(port==443&&scheme=="https")||port<0?"":":"+std::to_string(port));
    }catch(...){throw std::invalid_argument("Open an HTTP or HTTPS page without embedded credentials");}
}
inline bool matches(const LoginItem& item,const std::string& page){const auto actual=origin(page);for(const auto& saved:item.urls)try{if(origin(saved)==actual)return true;}catch(...){}return false;}
struct FrameContext {std::string thread,frame,navigation,origin;};
inline FrameContext context(FrameContext value){value.thread=thread_id(value.thread);for(const auto* id:{&value.frame,&value.navigation}){if(id->empty()||id->size()>128||!std::all_of(id->begin(),id->end(),[](unsigned char c){return(c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='{'||c=='}';}))throw std::invalid_argument("Invalid browser frame or navigation identity");}value.origin=origin(value.origin);return value;}
inline bool same(const FrameContext& a,const FrameContext& b){return a.thread==b.thread&&a.frame==b.frame&&a.navigation==b.navigation&&a.origin==b.origin;}
struct FillRequest {std::string ticket;FrameContext frame;LoginItem item;};
struct FillResult {bool filled{};std::string username;};
// The browser host resolves its actual current frame both before secret access and immediately
// before filling. The ticket is consumed before any callback, including failures/reentrancy.
inline std::string record_fingerprint(const LoginItem& item){validate(item);std::string bytes;const auto append=[&](const std::string& value){bytes+=std::to_string(value.size())+":"+value;};append(manager_id(item.source));append(item.id);append(item.title);append(item.username);std::set<std::string> origins;for(const auto& url:item.urls)origins.insert(origin(url));for(const auto& url:origins)append(url);append(item.has_totp?"totp":"password");return local_file::sha256(bytes);}
class FillCoordinator {
    struct Pending{FillRequest request;std::uint64_t expires{};std::atomic<bool> valid{true};bool consumed{},finished{};Pending(FillRequest value,std::uint64_t until):request(std::move(value)),expires(until){}};
    struct State {std::map<std::string,std::shared_ptr<Pending>> pending;std::function<std::uint64_t()> clock;std::set<Manager> enabled;mutable std::mutex gate;explicit State(std::function<std::uint64_t()> value):clock(std::move(value)){}};
    std::shared_ptr<State> state_;
    static bool permitted(const std::weak_ptr<State>& weak,const std::shared_ptr<Pending>& value){const auto state=weak.lock();if(!state||!value||!value->valid)return false;std::lock_guard lock(state->gate);return value->valid&&state->enabled.contains(value->request.item.source)&&state->clock()<value->expires;}
    static void release(const std::weak_ptr<State>& weak,const std::shared_ptr<Pending>& value)noexcept{if(!value)return;value->valid=false;try{if(const auto state=weak.lock()){std::lock_guard lock(state->gate);const auto at=state->pending.find(value->request.ticket);if(at!=state->pending.end()&&at->second==value)state->pending.erase(at);}}catch(...){} }
    template<class Match>void cancel(const Match& match){std::lock_guard lock(state_->gate);std::erase_if(state_->pending,[&](const auto& entry){if(!match(entry.second->request))return false;entry.second->valid=false;return true;});}
public:
    using Current=std::function<FrameContext()>;using Resolve=std::function<LoginSecret(const LoginItem&)>;using Sink=std::function<bool(const FrameContext&,const LoginSecret&)>;
    class Permit {
        friend class FillCoordinator;std::weak_ptr<State> state_;std::shared_ptr<Pending> value_;
        Permit(const std::shared_ptr<State>& state,std::shared_ptr<Pending> value):state_(state),value_(std::move(value)){}
    public:
        Permit()=default;Permit(const Permit&)=delete;Permit& operator=(const Permit&)=delete;Permit(Permit&&)=default;Permit& operator=(Permit&& other)noexcept{if(this!=&other){release(state_,value_);state_=std::move(other.state_);value_=std::move(other.value_);}return*this;}~Permit(){release(state_,value_);}
        explicit operator bool()const{return permitted(state_,value_);}const FillRequest& request()const{if(!value_)throw std::logic_error("No credential approval permit");return value_->request;}
    };
    // Keep this guard alive throughout the browser's async fill and pass cancellation() to
    // every awaited browser operation. The only secret transfer is one explicit native move.
    class ApprovedFill {
        friend class FillCoordinator;std::weak_ptr<State> state_;std::shared_ptr<Pending> value_;LoginSecret secret_;std::string username_;bool taken_{};
        ApprovedFill(const std::shared_ptr<State>& state,std::shared_ptr<Pending> value,LoginSecret secret):state_(state),value_(std::move(value)),secret_(std::move(secret)),username_(secret_.username){}
    public:
        ApprovedFill(const ApprovedFill&)=delete;ApprovedFill& operator=(const ApprovedFill&)=delete;ApprovedFill(ApprovedFill&&)=default;ApprovedFill& operator=(ApprovedFill&& other)noexcept{if(this!=&other){release(state_,value_);state_=std::move(other.state_);value_=std::move(other.value_);secret_=std::move(other.secret_);username_=std::move(other.username_);taken_=other.taken_;}return*this;}~ApprovedFill(){release(state_,value_);}
        bool valid()const{return permitted(state_,value_);}const FrameContext& frame()const{if(!value_)throw std::logic_error("No approved credential frame");return value_->request.frame;}const std::string& username()const{return username_;}
        LoginSecret take_secret(){if(taken_||!valid())throw std::runtime_error("The native fill approval is no longer available");taken_=true;return std::move(secret_);}
        std::function<bool()> cancellation()const{const auto state=state_;const auto value=value_;return[state,value]{try{return!permitted(state,value);}catch(...){return true;}};}
    };
    explicit FillCoordinator(std::function<std::uint64_t()> clock=[] {return GetTickCount64();}):state_(std::make_shared<State>(std::move(clock))){}
    FillCoordinator(const FillCoordinator&)=delete;FillCoordinator& operator=(const FillCoordinator&)=delete;~FillCoordinator(){clear();}
    void set_enabled(Manager manager,bool on){(void)manager_id(manager);std::lock_guard lock(state_->gate);if(on)state_->enabled.insert(manager);else{state_->enabled.erase(manager);std::erase_if(state_->pending,[manager](const auto& entry){if(entry.second->request.item.source!=manager)return false;entry.second->valid=false;return true;});}}
    FillRequest request(FrameContext frame,LoginItem item){frame=context(std::move(frame));validate(item);if(!matches(item,frame.origin))throw std::invalid_argument("The saved login does not match this exact origin");std::lock_guard lock(state_->gate);if(!state_->enabled.contains(item.source))throw std::runtime_error("Enable the password manager before requesting a fill");const auto now=state_->clock();std::erase_if(state_->pending,[now](const auto& entry){if(entry.second->valid&&entry.second->expires>now)return false;entry.second->valid=false;return true;});if(state_->pending.size()>=32)throw std::runtime_error("Too many pending sign-in approvals");auto ticket=random_id();FillRequest result{ticket,std::move(frame),std::move(item)};state_->pending.emplace(ticket,std::make_shared<Pending>(result,now+300000));return result;}
    Permit begin_approved(const std::string& ticket,FrameContext actual){std::shared_ptr<Pending> value;{std::lock_guard lock(state_->gate);const auto at=state_->pending.find(ticket);if(at==state_->pending.end()||at->second->consumed)return{};value=at->second;value->consumed=true;}Permit permit(state_,value);if(!permit||!same(value->request.frame,context(std::move(actual))))return{};return permit;}
    std::optional<ApprovedFill> finish(Permit permit,FrameContext fresh,Manager manager,const std::string& current_fingerprint,LoginSecret secret){if(permit.state_.lock()!=state_||!permit||!same(permit.request().frame,context(std::move(fresh)))||manager!=permit.request().item.source||record_fingerprint(permit.request().item)!=current_fingerprint||secret.username!=permit.request().item.username)return{};text_bound(secret.username,512);if(secret.password.empty()&&secret.totp.empty())return{};{std::lock_guard lock(state_->gate);if(!permit.value_->valid||permit.value_->finished||!state_->enabled.contains(manager)||state_->clock()>=permit.value_->expires)return{};permit.value_->finished=true;}auto value=std::move(permit.value_);return ApprovedFill(state_,std::move(value),std::move(secret));}
    FillResult approve(const std::string& ticket,const Current& current,const Resolve& resolve,const Sink& sink){if(!current||!resolve||!sink){deny(ticket);return{};}Permit permit;try{permit=begin_approved(ticket,current());}catch(...){deny(ticket);throw;}if(!permit)return{};const auto fingerprint=record_fingerprint(permit.request().item);const auto manager=permit.request().item.source;auto secret=resolve(permit.request().item);auto handoff=finish(std::move(permit),current(),manager,fingerprint,std::move(secret));if(!handoff||!handoff->valid())return{};auto values=handoff->take_secret();return sink(handoff->frame(),values)?FillResult{true,handoff->username()}:FillResult{};}
    void deny(const std::string& ticket){std::lock_guard lock(state_->gate);const auto at=state_->pending.find(ticket);if(at!=state_->pending.end()){at->second->valid=false;state_->pending.erase(at);}}
    void cancel_thread(const std::string& thread){const auto id=thread_id(thread);cancel([&](const FillRequest& value){return value.frame.thread==id;});}void cancel_navigation(const std::string& frame){cancel([&](const FillRequest& value){return value.frame.frame==frame;});}
    void clear(){cancel([](const FillRequest&){return true;});}std::size_t pending()const{std::lock_guard lock(state_->gate);return state_->pending.size();}
};
struct CsvLogin {LoginItem item;SecretText password,totp_seed;};
class CsvReview {
    std::vector<CsvLogin> logins_;std::size_t skipped_{};
    static std::vector<std::vector<SecretText>> records(std::string_view input){
        std::vector<std::vector<SecretText>> rows;std::vector<SecretText> row;std::vector<char> field;field.reserve(16385);bool quoted{},closed{},start=true;
        struct Wipe{std::vector<char>& value;~Wipe(){if(!value.empty())SecureZeroMemory(value.data(),value.size());}}wipe{field};
        const auto finish=[&]{if(field.size()>16384||row.size()>=64)throw std::invalid_argument("CSV fields exceed their bounds");row.emplace_back(std::string_view(field.data(),field.size()));if(!field.empty())SecureZeroMemory(field.data(),field.size());field.clear();start=true;closed=false;};
        const auto record=[&]{finish();if(rows.size()>=10001)throw std::invalid_argument("CSV exceeds the login count limit");rows.push_back(std::move(row));row.clear();};
        for(std::size_t i=0;i<input.size();++i){const char c=input[i];if(quoted){if(c=='"'){if(i+1<input.size()&&input[i+1]=='"'){field.push_back('"');++i;}else{quoted=false;closed=true;}}else field.push_back(c);}
            else if(c==',' )finish();else if(c=='\r'||c=='\n'){if(c=='\r'&&i+1<input.size()&&input[i+1]=='\n')++i;record();}else if(c=='"'&&start){quoted=true;start=false;}else{if(closed||c=='"')throw std::invalid_argument("The CSV has malformed quoting");field.push_back(c);start=false;}if(field.size()>16384)throw std::invalid_argument("CSV field exceeds its bound");}
        if(quoted)throw std::invalid_argument("The CSV has an unfinished quoted field");if(!field.empty()||!row.empty()||closed)record();return rows;
    }
public:
    CsvReview()=default;CsvReview(const CsvReview&)=delete;CsvReview& operator=(const CsvReview&)=delete;CsvReview(CsvReview&&)=default;CsvReview& operator=(CsvReview&&)=default;
    static CsvReview parse(std::string_view bytes){if(bytes.size()>8*1024*1024||!local_file::utf8(bytes)||bytes.find('\0')!=std::string_view::npos)throw std::invalid_argument("Choose a bounded UTF-8 password CSV");if(bytes.starts_with("\xef\xbb\xbf"))bytes.remove_prefix(3);auto rows=records(bytes);if(rows.empty())throw std::invalid_argument("The CSV is empty");
        std::map<std::string,std::size_t> columns;for(std::size_t i=0;i<rows[0].size();++i){const auto key=lower(trim(rows[0][i].view()));if(!columns.emplace(key,i).second)throw std::invalid_argument("The CSV contains duplicate column names");}
        const auto column=[&](std::initializer_list<const char*> names)->std::optional<std::size_t>{for(const auto* name:names)if(columns.contains(name))return columns.at(name);return{};};
        const auto url=column({"url","login_uri","website","web site","login url","uri"}),password=column({"password","login_password"}),username=column({"username","login_username","user name","login","email","user"}),title=column({"title","name"}),totp=column({"otpauth","login_totp","totp","otp"});if(!url||!password)throw std::invalid_argument("The CSV needs web-address and password columns");CsvReview result;std::set<std::pair<std::string,std::string>> seen;
        for(std::size_t i=1;i<rows.size();++i){auto& row=rows[i];if(row.size()==1&&row[0].empty())continue;const auto get=[&](std::optional<std::size_t> index)->std::string_view{return index&&*index<row.size()?row[*index].view():std::string_view{};};const auto address=trim(get(url));auto candidate=address.find("://")==std::string::npos?"https://"+address:address;std::string site;try{site=origin(candidate);}catch(...){++result.skipped_;continue;}if(get(password).empty()){++result.skipped_;continue;}
            auto user=trim(get(username)),name=trim(get(title));if(!seen.emplace(site,user).second){++result.skipped_;continue;}text_bound(user,512);text_bound(name,512);const auto seed=get(totp);CsvLogin login{{Manager::saved,random_id(),name.empty()?site:name,user,{candidate},!seed.empty()},SecretText(get(password)),SecretText(seed)};validate(login.item);result.logins_.push_back(std::move(login));}return result;
    }
    std::size_t size()const{return logins_.size();}std::size_t skipped()const{return skipped_;}const LoginItem& item(std::size_t index)const{return logins_.at(index).item;}
    // Only a native explicit review action calls commit. No automatic imports or file deletion.
    std::size_t commit(const std::vector<std::size_t>& selection,const std::function<void(const std::vector<const CsvLogin*>&)>& import){if(!import)throw std::invalid_argument("No saved-login store is connected");std::set<std::size_t> unique;std::vector<const CsvLogin*> chosen;for(const auto index:selection){if(index>=size()||!unique.insert(index).second)throw std::invalid_argument("Invalid CSV review selection");chosen.push_back(&logins_[index]);}if(chosen.empty())throw std::invalid_argument("Select logins to import");import(chosen);const auto count=chosen.size();logins_.clear();return count;}
};
} // namespace coincide::credentials
