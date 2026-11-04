#pragma once
#include "ACPFileSystem.h"
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <optional>
#include <map>
#include <cmath>
#include <set>

namespace coincide {
namespace usage_json=winrt::Windows::Data::Json;
inline bool usage_provider(const std::string& value){return value=="codex"||value=="claude"||value=="opencode"||value=="cursor"||value=="grok"||value=="antigravity";}
inline std::string usage_text(const std::string& value,std::size_t bound,bool empty=false){if((!empty&&value.empty())||value.size()>bound||!ACPFileSystem::valid_utf8(value)||std::any_of(value.begin(),value.end(),[](unsigned char ch){return ch<32||ch==127;}))throw std::invalid_argument("Invalid bounded usage metadata");return value;}
inline std::string usage_guid(const std::string& value,bool empty=false){if(empty&&value.empty())return{};if(value.size()!=36&&value.size()!=38)throw std::invalid_argument("Invalid usage owner identity");const winrt::guid id(winrt::to_hstring(value));if(id==winrt::guid{})throw std::invalid_argument("Invalid usage owner identity");auto result=winrt::to_string(winrt::to_hstring(id));std::transform(result.begin(),result.end(),result.begin(),[](unsigned char ch){return static_cast<char>(std::tolower(ch));});return result;}
struct UsageTokens {
    static constexpr std::uint64_t maximum=1000000000000ULL;
    std::uint64_t input{},cache_read{},cache_write{},output{},reasoning{};
    std::uint64_t total()const{return input+cache_read+cache_write+output;}
    bool operator==(const UsageTokens&)const=default;
    void validate()const{if(input>maximum||cache_read>maximum||cache_write>maximum||output>maximum||reasoning>output)throw std::invalid_argument("Invalid provider token counts");}
    UsageTokens& operator+=(const UsageTokens& value){input+=value.input;cache_read+=value.cache_read;cache_write+=value.cache_write;output+=value.output;reasoning+=value.reasoning;return *this;}
    void merge(const UsageTokens& value){input=std::max(input,value.input);cache_read=std::max(cache_read,value.cache_read);cache_write=std::max(cache_write,value.cache_write);output=std::max(output,value.output);reasoning=std::max(reasoning,value.reasoning);}
};
struct UsageOwner {
    std::string provider,project_id,thread_id,profile_id{"default"},account_scope,native_session,turn_id,model,delivery_id;
    void validate(){if(!usage_provider(provider))throw std::invalid_argument("Unknown usage provider");project_id=usage_guid(project_id,true);thread_id=usage_guid(thread_id);if(profile_id!="default"){profile_id=usage_guid(profile_id);if(profile_id.front()=='{')profile_id=profile_id.substr(1,36);}if(!account_scope.empty()&&(account_scope.size()!=64||account_scope.find_first_not_of("0123456789abcdef")!=std::string::npos))throw std::invalid_argument("Invalid usage account scope");usage_text(delivery_id,256,true);usage_text(native_session,512,!delivery_id.empty());usage_text(turn_id,256,!delivery_id.empty());usage_text(model,256,true);}
    std::string key()const{std::string value;const auto append=[&](const std::string& part){value+=std::to_string(part.size())+":"+part;};for(const auto* part:{&provider,&thread_id,&profile_id})append(*part);if(!delivery_id.empty()){append("delivery");append(delivery_id);}else{append("native");for(const auto* part:{&account_scope,&native_session,&turn_id})append(*part);}return value;}
};
struct UsageObservation {
    // Context and session figures are snapshots. Only request/turn totals may enter additive reports.
    enum class Scope {context,request,turn,session};Scope scope{Scope::context};
    std::string id,native_session,turn_id;
    std::optional<UsageTokens> tokens;
    std::optional<std::uint64_t> context_tokens,context_window;
    std::optional<double> cost_usd;
    void validate()const{if(scope!=Scope::request&&scope!=Scope::turn&&scope!=Scope::context&&scope!=Scope::session)throw std::invalid_argument("Unknown usage scope");usage_text(id,512,scope!=Scope::request);usage_text(native_session,512,true);usage_text(turn_id,256,true);if(tokens)tokens->validate();for(const auto value:{context_tokens,context_window})if(value&&*value>UsageTokens::maximum)throw std::invalid_argument("Invalid usage context count");if(cost_usd&&(!std::isfinite(*cost_usd)||*cost_usd<0||*cost_usd>1000000000.0))throw std::invalid_argument("Invalid reported usage cost");}
};
struct UsageRecord {
    UsageOwner owner;std::int64_t started_ms{},finished_ms{};std::string outcome;
    std::optional<UsageTokens> tokens;
    std::optional<double> cost_usd,session_cost_usd;
    std::optional<std::uint64_t> context_tokens,context_window;
    void validate(){owner.validate();if(started_ms<0||finished_ms<started_ms||finished_ms>253402300799999LL||(outcome!="completed"&&outcome!="interrupted"&&outcome!="failed"))throw std::invalid_argument("Invalid usage turn lifecycle");UsageObservation observation;observation.tokens=tokens;observation.cost_usd=cost_usd;observation.context_tokens=context_tokens;observation.context_window=context_window;observation.validate();observation.cost_usd=session_cost_usd;observation.validate();}
};
class UsageTurn {
    UsageRecord record_;std::map<std::string,UsageObservation> requests_;std::optional<UsageTokens> turn_tokens_;std::optional<double> turn_cost_;bool finished_{},observed_{};
public:
    UsageTurn(UsageOwner owner,std::int64_t started):record_{std::move(owner),started,started,"completed"}{record_.validate();}
    const UsageOwner& owner()const{return record_.owner;}
    bool bind_session(const std::string& value){usage_text(value,512);if(finished_||(!record_.owner.native_session.empty()&&record_.owner.native_session!=value))return false;record_.owner.native_session=value;return true;}
    bool bind_native_turn(const std::string& value){usage_text(value,256);if(finished_||(!record_.owner.turn_id.empty()&&record_.owner.turn_id!=value))return false;record_.owner.turn_id=value;return true;}
    bool bind_account_scope(const std::string& value){if(value.size()!=64||value.find_first_not_of("0123456789abcdef")!=std::string::npos)throw std::invalid_argument("Invalid usage account bootstrap");if(finished_)return false;if(record_.owner.account_scope==value)return true;if(observed_||!record_.owner.account_scope.empty())return false;record_.owner.account_scope=value;return true;}
    bool observe(const UsageObservation& value){
        if(finished_)return false;value.validate();if((!value.native_session.empty()&&value.native_session!=record_.owner.native_session)||(!value.turn_id.empty()&&value.turn_id!=record_.owner.turn_id))return false;
        observed_=true;
        if(value.scope==UsageObservation::Scope::context||value.scope==UsageObservation::Scope::session){if(value.context_tokens)record_.context_tokens=value.context_tokens;if(value.context_window)record_.context_window=value.context_window;if(value.cost_usd)record_.session_cost_usd=value.cost_usd;return true;}
        if(value.scope==UsageObservation::Scope::turn){if(value.tokens){if(turn_tokens_)turn_tokens_->merge(*value.tokens);else turn_tokens_=value.tokens;}if(value.cost_usd)turn_cost_=std::max(turn_cost_.value_or(0),*value.cost_usd);return true;}
        auto found=requests_.find(value.id);if(found==requests_.end()){if(requests_.size()>=4096)throw std::invalid_argument("Too many usage requests in one turn");requests_.emplace(value.id,value);return true;}
        if(value.tokens){if(found->second.tokens)found->second.tokens->merge(*value.tokens);else found->second.tokens=value.tokens;}if(value.cost_usd)found->second.cost_usd=std::max(found->second.cost_usd.value_or(0),*value.cost_usd);return true;
    }
    UsageRecord finish(std::string outcome,std::int64_t finished){
        if(finished_)throw std::logic_error("This usage turn was already finalized");auto result=record_;result.outcome=std::move(outcome);result.finished_ms=std::max(result.started_ms,finished);
        if(turn_tokens_)result.tokens=turn_tokens_;else for(const auto& entry:requests_)if(entry.second.tokens){if(!result.tokens)result.tokens=UsageTokens{};*result.tokens+=*entry.second.tokens;}
        if(turn_cost_)result.cost_usd=turn_cost_;else for(const auto& entry:requests_)if(entry.second.cost_usd)result.cost_usd=result.cost_usd.value_or(0)+*entry.second.cost_usd;
        result.validate();finished_=true;return result;
    }
};

// Parses only recorded official provider frames. Never discovers credentials, reads CLI history,
// starts an executable or queries a network. Caller still checks the provider/thread/turn identity.
class UsageProtocol {
public:
    using Object=usage_json::JsonObject;using Value=usage_json::JsonValue;
    static std::optional<std::uint64_t> count(const Object& value,const wchar_t* key){if(!value.HasKey(key)||value.GetNamedValue(key).ValueType()==usage_json::JsonValueType::Null)return{};const auto raw=value.GetNamedValue(key);if(raw.ValueType()!=usage_json::JsonValueType::Number)throw std::invalid_argument("Provider usage must contain numeric counts");const auto number=raw.GetNumber();if(!std::isfinite(number)||number<0||number>UsageTokens::maximum||number!=std::floor(number))throw std::invalid_argument("Provider usage count is out of bounds");return static_cast<std::uint64_t>(number);}
    static std::optional<double> cost(const Object& value,const wchar_t* key){if(!value.HasKey(key)||value.GetNamedValue(key).ValueType()==usage_json::JsonValueType::Null)return{};const auto raw=value.GetNamedValue(key);if(raw.ValueType()!=usage_json::JsonValueType::Number)throw std::invalid_argument("Provider cost must be numeric");const auto number=raw.GetNumber();if(!std::isfinite(number)||number<0||number>1000000000.0)throw std::invalid_argument("Provider cost is out of bounds");return number;}
    static Object object(const Object& parent,const wchar_t* key){if(!parent.HasKey(key)||parent.GetNamedValue(key).ValueType()==usage_json::JsonValueType::Null)return Object{};return parent.GetNamedObject(key);}
    static std::string string(const Object& value,const wchar_t* key){if(!value.HasKey(key))return{};return usage_text(winrt::to_string(value.GetNamedString(key)),512,true);}
    static std::optional<UsageObservation> codex(const Object& params){const auto token=object(params,L"tokenUsage"),last=object(token,L"last");UsageObservation result;result.native_session=string(params,L"threadId");result.turn_id=string(params,L"turnId");result.context_tokens=count(last,L"totalTokens");result.context_window=count(token,L"modelContextWindow");if(!result.context_tokens&&!result.context_window)return{};result.validate();return result;}
    static std::optional<UsageObservation> claude(const Object& frame){
        const auto type=string(frame,L"type");UsageObservation result;result.native_session=string(frame,L"session_id");
        if(type=="result"){result.scope=UsageObservation::Scope::session;result.cost_usd=cost(frame,L"total_cost_usd");if(!result.cost_usd)return{};return result;}
        if(type!="assistant")return{};const auto message=object(frame,L"message"),used=object(message,L"usage");result.id=string(message,L"id");result.scope=UsageObservation::Scope::request;
        const auto input=count(used,L"input_tokens"),output=count(used,L"output_tokens"),read=count(used,L"cache_read_input_tokens"),write=count(used,L"cache_creation_input_tokens");if(!input&&!output&&!read&&!write)return{};
        result.tokens=UsageTokens{input.value_or(0),read.value_or(0),write.value_or(0),output.value_or(0),0};result.validate();return result;
    }
    static std::optional<UsageObservation> opencode(const std::string& type,const Object& data){
        UsageObservation result;result.native_session=string(data,L"sessionID");if(type=="session.usage.updated"){result.scope=UsageObservation::Scope::session;result.cost_usd=cost(data,L"cost");if(!result.cost_usd)return{};return result;}
        if(type!="session.step.ended"&&type!="session.step.failed")return{};result.id=string(data,L"assistantMessageID");result.scope=UsageObservation::Scope::request;const auto used=object(data,L"tokens"),cache=object(used,L"cache");
        const auto input=count(used,L"input"),output=count(used,L"output"),reasoning=count(used,L"reasoning"),read=count(cache,L"read"),write=count(cache,L"write");if(input||output||reasoning||read||write)result.tokens=UsageTokens{input.value_or(0),read.value_or(0),write.value_or(0),output.value_or(0)+reasoning.value_or(0),reasoning.value_or(0)};result.cost_usd=cost(data,L"cost");if(!result.tokens&&!result.cost_usd)return{};result.validate();return result;
    }
    static std::optional<UsageObservation> acp_snapshot(const Object& update){UsageObservation result;result.context_tokens=count(update,L"used");result.context_window=count(update,L"size");const auto amount=object(update,L"cost");if(string(amount,L"currency")=="USD")result.cost_usd=cost(amount,L"amount");if(!result.context_tokens&&!result.context_window&&!result.cost_usd)return{};result.validate();return result;}
    static std::optional<UsageObservation> acp_result(const Object& used,bool grok_ticks=false){
        const auto in=count(used,L"inputTokens"),out=count(used,L"outputTokens"),read=count(used,L"cachedReadTokens"),write=count(used,L"cachedWriteTokens"),thought=count(used,L"thoughtTokens"),total=count(used,L"totalTokens");
        UsageObservation result;result.scope=UsageObservation::Scope::turn;if(in||out||read||write||thought){UsageTokens tokens{in.value_or(0),read.value_or(0),write.value_or(0),out.value_or(0),0};const auto cache=tokens.cache_read+tokens.cache_write,reasoning=thought.value_or(0);
            if(total&&*total==tokens.input+cache+tokens.output+reasoning)tokens.output+=reasoning;
            else if(total&&cache>0&&tokens.input>=cache&&*total==tokens.input+tokens.output+reasoning){tokens.input-=cache;tokens.output+=reasoning;}
            else if(total&&cache>0&&tokens.input>=cache&&*total==tokens.input+tokens.output)tokens.input-=cache;
            tokens.reasoning=std::min(reasoning,tokens.output);result.tokens=tokens;}
        if(grok_ticks&&used.HasKey(L"costUsdTicks")&&used.GetNamedValue(L"costUsdTicks").ValueType()!=usage_json::JsonValueType::Null){const auto raw=used.GetNamedValue(L"costUsdTicks");if(raw.ValueType()!=usage_json::JsonValueType::Number)throw std::invalid_argument("Provider cost ticks must be numeric");const auto ticks=raw.GetNumber();if(!std::isfinite(ticks)||ticks<0||ticks>9007199254740991.0||ticks!=std::floor(ticks))throw std::invalid_argument("Provider cost ticks are out of bounds");result.cost_usd=ticks/10000000000.0;}if(!result.tokens&&!result.cost_usd)return{};result.validate();return result;
    }
    static Object encode(const UsageObservation& value){value.validate();Object out;out.SetNamedValue(L"scope",Value::CreateStringValue(value.scope==UsageObservation::Scope::request?L"request":value.scope==UsageObservation::Scope::turn?L"turn":value.scope==UsageObservation::Scope::session?L"session":L"context"));put(out,L"id",value.id);put(out,L"session",value.native_session);put(out,L"turn",value.turn_id);if(value.tokens)out.SetNamedValue(L"tokens",encode(*value.tokens));if(value.context_tokens)out.SetNamedValue(L"contextTokens",Value::CreateNumberValue(static_cast<double>(*value.context_tokens)));if(value.context_window)out.SetNamedValue(L"contextWindow",Value::CreateNumberValue(static_cast<double>(*value.context_window)));if(value.cost_usd)out.SetNamedValue(L"costUSD",Value::CreateNumberValue(*value.cost_usd));return out;}
    static Object encode(const UsageTokens& value){Object out;const std::pair<const wchar_t*,std::uint64_t> fields[]={{L"input",value.input},{L"cacheRead",value.cache_read},{L"cacheWrite",value.cache_write},{L"output",value.output},{L"reasoning",value.reasoning}};for(const auto& field:fields)out.SetNamedValue(field.first,Value::CreateNumberValue(static_cast<double>(field.second)));return out;}
    static UsageTokens tokens(const Object& value){UsageTokens result{count(value,L"input").value_or(0),count(value,L"cacheRead").value_or(0),count(value,L"cacheWrite").value_or(0),count(value,L"output").value_or(0),count(value,L"reasoning").value_or(0)};result.validate();return result;}
    static UsageObservation decode(const Object& value){UsageObservation result;const auto scope=string(value,L"scope");if(scope=="request")result.scope=UsageObservation::Scope::request;else if(scope=="turn")result.scope=UsageObservation::Scope::turn;else if(scope=="session")result.scope=UsageObservation::Scope::session;else if(scope!="context")throw std::invalid_argument("Unknown usage scope");result.id=string(value,L"id");result.native_session=string(value,L"session");result.turn_id=string(value,L"turn");if(value.HasKey(L"tokens"))result.tokens=tokens(value.GetNamedObject(L"tokens"));result.context_tokens=count(value,L"contextTokens");result.context_window=count(value,L"contextWindow");result.cost_usd=cost(value,L"costUSD");result.validate();return result;}
    static UsageObservation decode_text(const std::string& json){if(json.empty()||json.size()>65536||json.find('\0')!=std::string::npos||!ACPFileSystem::valid_utf8(json))throw std::invalid_argument("Usage observation exceeds its JSON bound");return decode(Object::Parse(winrt::to_hstring(json)));}
    template<class Parser>static std::optional<std::string> normalize(Parser&& parser,const std::string& session,const std::string& turn)noexcept{
        try{if(session.empty()||turn.empty())return{};auto value=parser();if(!value)return{};if((!value->native_session.empty()&&value->native_session!=session)||(!value->turn_id.empty()&&value->turn_id!=turn))return{};value->native_session=session;value->turn_id=turn;return winrt::to_string(encode(*value).Stringify());}catch(...){return{};}
    }
    static void put(Object value,const wchar_t* key,const std::string& text){value.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(text)));}
};
} // namespace coincide
