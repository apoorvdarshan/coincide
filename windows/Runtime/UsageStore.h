#pragma once
#include "UsageProtocol.h"
#include <mutex>
#include <deque>
#include <chrono>

namespace coincide {
struct UsageFilter {
    std::string provider,project_id,thread_id,profile_id,account_scope;
    std::int64_t since_ms{},until_ms{253402300799999LL};
    bool matches(const UsageRecord& value)const{return value.finished_ms>=since_ms&&value.finished_ms<=until_ms&&(provider.empty()||provider==value.owner.provider)&&(project_id.empty()||usage_guid(project_id)==value.owner.project_id)&&(thread_id.empty()||usage_guid(thread_id)==value.owner.thread_id)&&(profile_id.empty()||profile_id==value.owner.profile_id)&&(account_scope.empty()||account_scope==value.owner.account_scope);}
};
struct UsageTotals {
    UsageTokens tokens;double reported_cost_usd{};
    std::size_t records{},token_records{},cost_records{},snapshot_records{};
    void add(const UsageRecord& value){++records;if(value.tokens){tokens+=*value.tokens;++token_records;}if(value.cost_usd){reported_cost_usd+=*value.cost_usd;++cost_records;}if(!value.tokens&&(value.context_tokens||value.context_window||value.session_cost_usd))++snapshot_records;}
};
struct UsageRow {std::string id;UsageTotals totals;};
enum class UsageDimension {provider,project,thread,account,model};

// Passive local metric history only: no prompts, replies, paths, credentials or pricing guesses.
// Root decides when to record a completed UsageTurn. The store never starts provider operations.
class UsageStore {
public:
    static constexpr std::size_t maximum_records=10000;
    explicit UsageStore(std::filesystem::path root,std::size_t limit=maximum_records):root_(std::move(root)),limit_(limit){if(!limit||limit>maximum_records)throw std::invalid_argument("Invalid bounded usage history limit");}
    void open(){
        std::lock_guard lock(mutex_);opened_=false;records_.clear();snapshot_.reset();
        if(!std::filesystem::exists(root_)){opened_=true;return;}ACPFileSystem files(root_);root_=files.root();const auto path=root_/L"usage-history.json";
        if(!std::filesystem::exists(path)){opened_=true;return;}
        const auto bytes=files.read(winrt::to_string(path.wstring()));const auto object=UsageProtocol::Object::Parse(winrt::to_hstring(bytes));fields(object,{L"schema",L"records"});if(object.GetNamedNumber(L"schema",0)!=1)throw std::runtime_error("This usage history format is unsupported; its file was preserved");
        const auto array=object.GetNamedArray(L"records");if(array.Size()>maximum_records)throw std::runtime_error("The usage history exceeds its record bound; its file was preserved");std::set<std::string> identities;std::vector<UsageRecord> loaded;
        for(const auto& raw:array){auto value=decode(raw.GetObject());if(!identities.insert(value.owner.key()).second)throw std::runtime_error("Duplicate usage turn identity; the original history was preserved");loaded.push_back(std::move(value));}
        records_=std::move(loaded);snapshot_=bytes;opened_=true;
    }
    bool record(UsageRecord value){
        value.validate();std::lock_guard lock(mutex_);if(!opened_)throw std::logic_error("Open a valid usage history before recording it");
        if(std::any_of(records_.begin(),records_.end(),[&](const auto& item){return item.owner.key()==value.owner.key();}))return false;
        auto candidate=records_;candidate.push_back(std::move(value));std::stable_sort(candidate.begin(),candidate.end(),[](const auto& a,const auto& b){return a.finished_ms==b.finished_ms?a.owner.key()<b.owner.key():a.finished_ms<b.finished_ms;});if(candidate.size()>limit_)candidate.erase(candidate.begin(),candidate.begin()+static_cast<std::ptrdiff_t>(candidate.size()-limit_));
        usage_json::JsonArray array;for(const auto& item:candidate)array.Append(encode(item));UsageProtocol::Object object;object.SetNamedValue(L"schema",UsageProtocol::Value::CreateNumberValue(1));object.SetNamedValue(L"records",array);const auto bytes=winrt::to_string(object.Stringify());if(bytes.size()>ACPFileSystem::max_bytes)throw std::runtime_error("Usage history exceeds its bounded local size; the original file was preserved");
        std::filesystem::create_directories(root_);ACPFileSystem files(root_);root_=files.root();
        NativeHandle lease(CreateFileW((root_/L"usage-history.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};
        if(lease.get()==INVALID_HANDLE_VALUE||!GetFileInformationByHandle(lease.get(),&info)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_OFFLINE))||info.nNumberOfLinks!=1)throw std::runtime_error("Usage history is busy or unsafe; reload before recording");
        const auto path=root_/L"usage-history.json";const auto current=std::filesystem::exists(path)?std::optional(files.read(winrt::to_string(path.wstring()))):std::nullopt;
        if(current!=snapshot_)throw std::runtime_error("Usage history changed in another window; reload before recording");files.write(winrt::to_string(path.wstring()),bytes);snapshot_=bytes;records_=std::move(candidate);return true;
    }
    std::vector<UsageRecord> records(const UsageFilter& filter={})const{std::lock_guard lock(mutex_);std::vector<UsageRecord> result;for(const auto& record:records_)if(filter.matches(record))result.push_back(record);return result;}
    UsageTotals totals(const UsageFilter& filter={})const{UsageTotals result;for(const auto& record:records(filter))result.add(record);return result;}
    std::vector<UsageRow> rows(UsageDimension dimension,const UsageFilter& filter={})const{
        std::map<std::string,UsageTotals> values;for(const auto& record:records(filter)){std::string id;switch(dimension){case UsageDimension::provider:id=record.owner.provider;break;case UsageDimension::project:id=record.owner.project_id;break;case UsageDimension::thread:id=record.owner.thread_id;break;case UsageDimension::account:id=record.owner.provider+"/"+record.owner.profile_id+"/"+record.owner.account_scope;break;case UsageDimension::model:id=record.owner.provider+"/"+record.owner.model;break;}values[id].add(record);}
        std::vector<UsageRow> result;for(auto& entry:values)result.push_back({entry.first,std::move(entry.second)});std::sort(result.begin(),result.end(),[](const auto& a,const auto& b){return a.totals.tokens.total()==b.totals.tokens.total()?a.id<b.id:a.totals.tokens.total()>b.totals.tokens.total();});return result;
    }
    static std::int64_t now_ms(){return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();}
private:
    std::filesystem::path root_;std::size_t limit_;mutable std::mutex mutex_;bool opened_{};std::optional<std::string> snapshot_;std::vector<UsageRecord> records_;
    static void fields(const UsageProtocol::Object& object,std::initializer_list<std::wstring_view> permitted){for(const auto& field:object)if(std::find(permitted.begin(),permitted.end(),field.Key())==permitted.end())throw std::invalid_argument("Unknown usage history field; the original file was preserved");}
    static UsageProtocol::Object encode(const UsageRecord& value){
        UsageProtocol::Object out;const auto& owner=value.owner;const std::pair<const wchar_t*,const std::string*> strings[]={{L"provider",&owner.provider},{L"project",&owner.project_id},{L"thread",&owner.thread_id},{L"profile",&owner.profile_id},{L"accountScope",&owner.account_scope},{L"session",&owner.native_session},{L"turn",&owner.turn_id},{L"model",&owner.model},{L"delivery",&owner.delivery_id},{L"outcome",&value.outcome}};for(const auto& field:strings)UsageProtocol::put(out,field.first,*field.second);
        out.SetNamedValue(L"startedMS",UsageProtocol::Value::CreateNumberValue(static_cast<double>(value.started_ms)));out.SetNamedValue(L"finishedMS",UsageProtocol::Value::CreateNumberValue(static_cast<double>(value.finished_ms)));
        UsageObservation observation;observation.scope=UsageObservation::Scope::turn;observation.tokens=value.tokens;observation.cost_usd=value.cost_usd;observation.context_tokens=value.context_tokens;observation.context_window=value.context_window;out.SetNamedValue(L"usage",UsageProtocol::encode(observation));if(value.session_cost_usd)out.SetNamedValue(L"sessionCostUSD",UsageProtocol::Value::CreateNumberValue(*value.session_cost_usd));return out;
    }
    static std::int64_t timestamp(const UsageProtocol::Object& value,const wchar_t* key){const auto raw=value.GetNamedValue(key);if(raw.ValueType()!=usage_json::JsonValueType::Number)throw std::invalid_argument("Invalid usage timestamp");const auto number=raw.GetNumber();if(!std::isfinite(number)||number<0||number>253402300799999.0||number!=std::floor(number))throw std::invalid_argument("Invalid usage timestamp");return static_cast<std::int64_t>(number);}
    static UsageRecord decode(const UsageProtocol::Object& value){
        fields(value,{L"provider",L"project",L"thread",L"profile",L"accountScope",L"session",L"turn",L"model",L"delivery",L"outcome",L"startedMS",L"finishedMS",L"usage",L"sessionCostUSD"});
        UsageRecord result;auto& owner=result.owner;owner.provider=UsageProtocol::string(value,L"provider");owner.project_id=UsageProtocol::string(value,L"project");owner.thread_id=UsageProtocol::string(value,L"thread");owner.profile_id=UsageProtocol::string(value,L"profile");owner.account_scope=UsageProtocol::string(value,L"accountScope");owner.native_session=UsageProtocol::string(value,L"session");owner.turn_id=UsageProtocol::string(value,L"turn");owner.model=UsageProtocol::string(value,L"model");owner.delivery_id=UsageProtocol::string(value,L"delivery");result.outcome=UsageProtocol::string(value,L"outcome");result.started_ms=timestamp(value,L"startedMS");result.finished_ms=timestamp(value,L"finishedMS");const auto usage=UsageProtocol::decode(value.GetNamedObject(L"usage"));result.tokens=usage.tokens;result.cost_usd=usage.cost_usd;result.context_tokens=usage.context_tokens;result.context_window=usage.context_window;result.session_cost_usd=UsageProtocol::cost(value,L"sessionCostUSD");result.validate();return result;
    }
};
} // namespace coincide
