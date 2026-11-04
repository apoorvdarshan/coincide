#pragma once
#include <windows.h>
#include <bcrypt.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include "../Core/Workspace.h"
#include <array>
#include <charconv>
#include <cmath>
#include <map>
#include <mutex>
#include <set>
#include <span>
#pragma comment(lib,"bcrypt.lib")

namespace coincide {
// Credential continuity is deliberately not AgentAccountScope or a verified account identity.
// There is no native reader/CLI call here. Root's trusted collector supplies owned-server data
// only after version/protocol review; an absent collector/version never falls back to auth files.
class OpenCodeAccountScope {
public:
    static constexpr std::string_view kind="opencode-credential-continuity-v1";
    static constexpr std::string_view capability_contract="credential-active/integration-connections/config-entries-v1";
    static constexpr std::string_view reference_source="d356b9b24928cfebde9179e791501fff583eec7c";
    class Sensitive {
        std::vector<char> bytes_;
    public:
        Sensitive()=default;explicit Sensitive(std::string_view value):bytes_(value.begin(),value.end()){}
        Sensitive(const Sensitive&)=delete;Sensitive& operator=(const Sensitive&)=delete;
        Sensitive(Sensitive&&)=default;Sensitive& operator=(Sensitive&& other)noexcept{if(this!=&other){clear();bytes_=std::move(other.bytes_);}return*this;}
        ~Sensitive(){clear();}void clear()noexcept{if(!bytes_.empty())SecureZeroMemory(bytes_.data(),bytes_.size());bytes_.clear();}
        std::string_view view()const noexcept{return{bytes_.data(),bytes_.size()};}
    };
    struct Binding {
        std::string type{kind},digest,profile_id,model,integration_id,credential_id,version;
    };
    struct Policy {
        bool enabled{},reviewed_protocol{},resuming{};
        std::string expected_version,contract{capability_contract},profile_id{"default"},profile_identity,cwd_identity,binary_identity,model,integration_id;
        std::optional<Binding> saved;
    };
    struct Snapshot {
        std::string version,profile_id,profile_identity,cwd_identity,binary_identity,model;
        std::uint64_t observed_now_ms{};
        // Normalized private JSON arrays from the owned server's credential.list,
        // integration.list and config.get responses. Raw values never enter Binding/result.
        Sensitive credentials,integrations,config;
    };
    enum class Stage {delivery,resume,server_restart};
    enum class Status {bound,unchanged,unsupported,review};
    enum class Reason {none,disabled,protocol_unverified,version_mismatch,invalid_context,invalid_snapshot,credential_missing,ambiguous_selection,external_source,environment_source,config_override,credential_expiring,changed,resume_unbound};
    enum class Change {credentials,selection,config,integration};
    struct Result {Status status{Status::unsupported};Reason reason{Reason::none};bool must_pause{};std::optional<Binding> binding;};
    struct ProbePermission {bool allowed{};Reason reason{Reason::none};};
    // The local HMAC seal is injected, not generated/read/persisted by this module. Production
    // must keep it in the scoped secret store; fixtures use a synthetic seal. It is NOT a
    // provider credential. Losing/changing the seal requires review, never silent rebinding.
    OpenCodeAccountScope(Policy policy,Sensitive seal={}):policy_(std::move(policy)),seal_(std::move(seal)){}
    bool enabled()const noexcept{return policy_.enabled;}
    ProbePermission probe_permission(Stage stage)const{
        if(!policy_.enabled)return{false,Reason::disabled};
        if(!policy_.reviewed_protocol||policy_.expected_version.empty()||policy_.contract!=capability_contract||seal_.view().size()<32||seal_.view().size()>64)return{false,Reason::protocol_unverified};
        std::lock_guard lock(gate_);if(invalidated_)return{false,Reason::changed};if((policy_.resuming||stage==Stage::resume||(stage==Stage::server_restart&&!bound_))&&!policy_.saved)return{false,Reason::resume_unbound};return{true,Reason::none};
    }
    std::optional<Binding> binding()const{std::lock_guard lock(gate_);return bound_;}
    void invalidate(Change)noexcept{std::lock_guard lock(gate_);invalidated_=true;}
    Result verify(Snapshot before,Snapshot after,Stage stage){
        const auto permission=probe_permission(stage);if(!permission.allowed)return{permission.reason==Reason::disabled||permission.reason==Reason::protocol_unverified?Status::unsupported:Status::review,permission.reason,permission.reason!=Reason::disabled,{}};
        try{
            const auto first=evaluate(before),second=evaluate(after);auto candidate=std::optional<Binding>(second);std::lock_guard lock(gate_);
            if(invalidated_||!equal(first.digest,second.digest))return review(Reason::changed);
            if((policy_.resuming||stage==Stage::resume||(stage==Stage::server_restart&&!bound_))&&!policy_.saved)return review(Reason::resume_unbound);
            if(policy_.saved){const auto& saved=*policy_.saved;if(saved.type!=kind||saved.digest.size()!=64||saved.digest.find_first_not_of("0123456789abcdef")!=std::string::npos||!equal(saved.digest,second.digest)||saved.profile_id!=second.profile_id||saved.model!=second.model||saved.integration_id!=second.integration_id||saved.credential_id!=second.credential_id||saved.version!=second.version)return review(Reason::changed);}
            if(bound_&&!equal(bound_->digest,second.digest))return review(Reason::changed);
            const bool existing=bound_.has_value()||policy_.saved.has_value();Result result{existing?Status::unchanged:Status::bound,Reason::none,false,second};bound_.swap(candidate);return result;
        }catch(const Refusal& refusal){std::lock_guard lock(gate_);if(bound_||policy_.resuming)return review(refusal.reason);return{Status::unsupported,refusal.reason,true,{}};}
        catch(...){std::lock_guard lock(gate_);if(bound_||policy_.resuming)return review(Reason::invalid_snapshot);return{Status::unsupported,Reason::invalid_snapshot,true,{}};}
    }
private:
    using Object=winrt::Windows::Data::Json::JsonObject;using Array=winrt::Windows::Data::Json::JsonArray;using Value=winrt::Windows::Data::Json::IJsonValue;using Type=winrt::Windows::Data::Json::JsonValueType;
    struct Refusal {Reason reason;};
    const Policy policy_;Sensitive seal_;mutable std::mutex gate_;std::optional<Binding> bound_;bool invalidated_{};
    static void require(bool value,Reason reason){if(!value)throw Refusal{reason};}
    Result review(Reason reason){invalidated_=true;return{Status::review,reason,true,{}};}
    static bool equal(std::string_view a,std::string_view b)noexcept{if(a.size()!=b.size())return false;unsigned difference{};for(std::size_t i=0;i<a.size();++i)difference|=static_cast<unsigned char>(a[i])^static_cast<unsigned char>(b[i]);return difference==0;}
    static void text(std::string_view value,std::size_t bound,bool empty=false){require((empty||!value.empty())&&value.size()<=bound&&value.find('\0')==std::string_view::npos,Reason::invalid_snapshot);for(std::size_t at=0;at<value.size();){const auto code=workspace_text::next(value,at);require(code>=32&&code!=127,Reason::invalid_snapshot);}}
    static std::string field(const Object& value,const wchar_t* key,std::size_t bound=512,bool empty=false){auto result=winrt::to_string(value.GetNamedString(key,L""));try{text(result,bound,empty);}catch(...){if(!result.empty())SecureZeroMemory(result.data(),result.size());throw;}return result;}
#pragma push_macro("GetObject")
#ifdef GetObject
#undef GetObject
#endif
    template<class T>static Object object(const T& value){if constexpr(requires{value.GetObject();})return value.GetObject();else return value.GetObjectW();}
#pragma pop_macro("GetObject")
    struct Wipe {std::string& value;~Wipe(){if(!value.empty())SecureZeroMemory(value.data(),value.size());}};
    class Hmac {
        BCRYPT_ALG_HANDLE algorithm_{};BCRYPT_HASH_HANDLE hash_{};std::vector<UCHAR> storage_;
    public:
        explicit Hmac(std::string_view seal){if(BCryptOpenAlgorithmProvider(&algorithm_,BCRYPT_SHA256_ALGORITHM,nullptr,BCRYPT_ALG_HANDLE_HMAC_FLAG)<0)throw Refusal{Reason::invalid_context};DWORD length{},copied{};if(BCryptGetProperty(algorithm_,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&length),sizeof(length),&copied,0)<0){BCryptCloseAlgorithmProvider(algorithm_,0);algorithm_=nullptr;throw Refusal{Reason::invalid_context};}try{storage_.resize(length);}catch(...){BCryptCloseAlgorithmProvider(algorithm_,0);algorithm_=nullptr;throw;}if(BCryptCreateHash(algorithm_,&hash_,storage_.data(),length,reinterpret_cast<PUCHAR>(const_cast<char*>(seal.data())),static_cast<ULONG>(seal.size()),0)<0){if(!storage_.empty())SecureZeroMemory(storage_.data(),storage_.size());BCryptCloseAlgorithmProvider(algorithm_,0);algorithm_=nullptr;throw Refusal{Reason::invalid_context};}}
        ~Hmac(){if(hash_)BCryptDestroyHash(hash_);if(!storage_.empty())SecureZeroMemory(storage_.data(),storage_.size());if(algorithm_)BCryptCloseAlgorithmProvider(algorithm_,0);}
        void add(std::string_view value){require(value.size()<=4*1024*1024,Reason::invalid_snapshot);const auto prefix=std::to_string(value.size())+":";bytes(prefix);bytes(value);}
        void bytes(std::string_view value){if(!value.empty()&&BCryptHashData(hash_,reinterpret_cast<PUCHAR>(const_cast<char*>(value.data())),static_cast<ULONG>(value.size()),0)<0)throw Refusal{Reason::invalid_context};}
        std::string finish(){std::array<UCHAR,32> digest{};if(BCryptFinishHash(hash_,digest.data(),static_cast<ULONG>(digest.size()),0)<0)throw Refusal{Reason::invalid_context};constexpr char hex[]="0123456789abcdef";std::string result;result.reserve(64);for(const auto byte:digest){result+=hex[byte>>4];result+=hex[byte&15];}SecureZeroMemory(digest.data(),digest.size());return result;}
    };
    static void canonical(Hmac& hash,const Value& value,unsigned depth=0,std::size_t* total=nullptr){
        std::size_t local{};if(!total)total=&local;require(depth<=20&&++*total<=50000,Reason::invalid_snapshot);
        switch(value.ValueType()){
        case Type::Null:hash.add("null");break;
        case Type::Boolean:hash.add(value.GetBoolean()?"true":"false");break;
        case Type::Number:{const auto number=value.GetNumber();require(std::isfinite(number),Reason::invalid_snapshot);std::array<char,64> output{};const auto end=std::to_chars(output.data(),output.data()+output.size(),number,std::chars_format::general,std::numeric_limits<double>::max_digits10);require(end.ec==std::errc{},Reason::invalid_snapshot);hash.add("number");hash.add({output.data(),static_cast<std::size_t>(end.ptr-output.data())});break;}
        case Type::String:{auto bytes=winrt::to_string(value.GetString());Wipe wipe{bytes};require(bytes.size()<=256*1024&&bytes.find('\0')==std::string::npos,Reason::invalid_snapshot);hash.add("string");hash.add(bytes);break;}
        case Type::Array:{const auto values=value.GetArray();require(values.Size()<=4096,Reason::invalid_snapshot);hash.add("array");hash.add(std::to_string(values.Size()));for(const auto& item:values)canonical(hash,item,depth+1,total);break;}
        case Type::Object:{const auto values=object(value);require(values.Size()<=1024,Reason::invalid_snapshot);std::map<std::wstring,Value> fields;for(const auto& item:values){require(item.Key().size()<=512,Reason::invalid_snapshot);fields.emplace(std::wstring(item.Key()),item.Value());}hash.add("object");hash.add(std::to_string(fields.size()));for(const auto& [key,item]:fields){auto bytes=winrt::to_string(key);Wipe wipe{bytes};hash.add(bytes);canonical(hash,item,depth+1,total);}break;}
        default:throw Refusal{Reason::invalid_snapshot};
        }
    }
    static Array array(const Sensitive& value){const auto bytes=value.view();require(!bytes.empty()&&bytes.size()<=4*1024*1024&&bytes.find('\0')==std::string_view::npos,Reason::invalid_snapshot);for(std::size_t at=0;at<bytes.size();)(void)workspace_text::next(bytes,at);const auto result=Array::Parse(winrt::to_hstring(bytes));require(result.Size()<=4096,Reason::invalid_snapshot);return result;}
    static bool nonempty(const Value& value){if(value.ValueType()==Type::Null)return false;if(value.ValueType()==Type::Array)return value.GetArray().Size()!=0;if(value.ValueType()==Type::Object)return object(value).Size()!=0;if(value.ValueType()==Type::String)return!value.GetString().empty();return true;}
    static void config(const Array& entries){
        require(entries.Size()<=256,Reason::invalid_snapshot);for(const auto& raw:entries){require(raw.ValueType()==Type::Object,Reason::invalid_snapshot);const auto entry=object(raw);const auto type=field(entry,L"type",32);require(type=="document"||type=="directory",Reason::config_override);require(type!="directory",Reason::config_override);const auto info=entry.GetNamedObject(L"info");
            // This first conservative contract supports built-in stored credentials only.
            // Custom provider/inline auth/env/plugin sources are not guessed or silently ignored.
            for(const auto* name:{L"providers",L"plugins",L"plugin",L"provider",L"auth",L"credentials"})if(info.HasKey(name)&&nonempty(info.GetNamedValue(name)))throw Refusal{Reason::config_override};
        }
    }
    Binding evaluate(const Snapshot& snapshot)const{
        require(snapshot.version==policy_.expected_version,Reason::version_mismatch);text(snapshot.version,128);text(policy_.profile_id,80);require(valid_session_binding({"opencode","pending",0,policy_.profile_id,{}}),Reason::invalid_context);
        for(const auto* value:{&policy_.profile_identity,&policy_.cwd_identity,&policy_.binary_identity,&policy_.model,&policy_.integration_id})text(*value,1024);
        require(snapshot.profile_id==policy_.profile_id&&snapshot.profile_identity==policy_.profile_identity&&snapshot.cwd_identity==policy_.cwd_identity&&snapshot.binary_identity==policy_.binary_identity&&snapshot.model==policy_.model,Reason::invalid_context);
        const auto slash=policy_.model.find('/');require(slash!=std::string::npos&&slash>0&&slash+1<policy_.model.size()&&policy_.model.substr(0,slash)==policy_.integration_id,Reason::invalid_context);
        const auto credentials=array(snapshot.credentials),integrations=array(snapshot.integrations),configuration=array(snapshot.config);config(configuration);Object selected{nullptr};std::set<std::string> ids;unsigned active{};
        for(const auto& raw:credentials){require(raw.ValueType()==Type::Object,Reason::invalid_snapshot);const auto entry=object(raw);const auto id=field(entry,L"id",256);require(ids.insert(id).second,Reason::invalid_snapshot);const auto integration=field(entry,L"integrationID");const auto flag=entry.GetNamedValue(L"active");require(flag.ValueType()==Type::Boolean,Reason::invalid_snapshot);if(integration==policy_.integration_id&&flag.GetBoolean()){++active;selected=entry;}}
        require(active==1,active?Reason::ambiguous_selection:Reason::credential_missing);const auto credential=selected.GetNamedObject(L"value");const auto method=field(credential,L"type",32);require(method=="key"||method=="oauth",Reason::external_source);
        if(method=="key"){auto key=field(credential,L"key",65536);Wipe wipe{key};}
        else{auto access=field(credential,L"access",65536);Wipe wipe_access{access};auto refresh=field(credential,L"refresh",65536);Wipe wipe_refresh{refresh};require(credential.GetNamedValue(L"expires").ValueType()==Type::Number,Reason::invalid_snapshot);const auto expiry=credential.GetNamedNumber(L"expires");require(std::isfinite(expiry)&&expiry>=0&&expiry<=9007199254740991.0&&std::floor(expiry)==expiry,Reason::invalid_snapshot);require(snapshot.observed_now_ms>0&&snapshot.observed_now_ms<=9007199254000000ULL&&expiry>static_cast<double>(snapshot.observed_now_ms+301000),Reason::credential_expiring);}
        Object current{nullptr};unsigned matching{};for(const auto& raw:integrations){require(raw.ValueType()==Type::Object,Reason::invalid_snapshot);const auto entry=object(raw);if(field(entry,L"id")==policy_.integration_id){current=entry;++matching;}}require(matching==1,Reason::ambiguous_selection);const auto connections=current.GetNamedArray(L"connections");require(connections.Size()>0&&connections.Size()<=64,Reason::credential_missing);const auto choice=object(connections.GetAt(0));const auto source=field(choice,L"type",32);require(source=="credential",source=="env"?Reason::environment_source:Reason::external_source);const auto selected_id=field(selected,L"id",256);require(field(choice,L"id",256)==selected_id&&field(choice,L"method",32)==method,Reason::ambiguous_selection);if(choice.HasKey(L"status")&&nonempty(choice.GetNamedValue(L"status")))throw Refusal{Reason::credential_missing};
        Hmac hash(seal_.view());for(const auto part:{kind,capability_contract,std::string_view(snapshot.version),std::string_view(policy_.profile_id),std::string_view(policy_.profile_identity),std::string_view(policy_.cwd_identity),std::string_view(policy_.binary_identity),std::string_view(policy_.model),std::string_view(policy_.integration_id)})hash.add(part);canonical(hash,selected);canonical(hash,current);canonical(hash,configuration);
        return{std::string(kind),hash.finish(),policy_.profile_id,policy_.model,policy_.integration_id,selected_id,snapshot.version};
    }
};
} // namespace coincide
