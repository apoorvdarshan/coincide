#pragma once
#include <winrt/Windows.Data.Json.h>
#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace coincide::browser_tool {
// Only lengths and rolling fingerprints survive a private fill, never its plaintext. A
// matching echo is redacted conservatively; a hash collision can only redact extra text.
class PrivateText {
    struct Fingerprint{std::size_t size;std::uint64_t hash,power;};std::vector<Fingerprint> values_;
    static constexpr std::uint64_t base=257;
public:
    void add(std::string_view value){if(value.empty())return;if(value.size()>16384)throw std::invalid_argument("Private browser text exceeds its bound");std::uint64_t hash{},power=1;for(const auto ch:value){hash=hash*base+static_cast<unsigned char>(ch)+1;power*=base;}for(const auto& item:values_)if(item.size==value.size()&&item.hash==hash)return;if(values_.size()>=32)throw std::runtime_error("Open a new tab before approving additional saved logins");values_.push_back({value.size(),hash,power});}
    bool empty()const noexcept{return values_.empty();}
    std::string text(const std::string& value)const{
        if(values_.empty()||value.empty())return value;if(value.size()>1048576)throw std::runtime_error("Browser text exceeds its private-output bound");std::vector<std::uint64_t> prefix(value.size()+1);for(std::size_t i=0;i<value.size();++i)prefix[i+1]=prefix[i]*base+static_cast<unsigned char>(value[i])+1;std::vector<std::int32_t> changes(value.size()+1);bool found{};
        for(const auto& item:values_)if(item.size<=value.size())for(std::size_t i=0;i<=value.size()-item.size;++i)if(prefix[i+item.size]-prefix[i]*item.power==item.hash){++changes[i];--changes[i+item.size];found=true;}
        if(!found)return value;std::string result;std::int32_t active{};bool redacting{};for(std::size_t i=0;i<value.size();++i){active+=changes[i];if(active){if(!redacting)result+="[redacted]";redacting=true;}else{redacting=false;result+=value[i];}if(result.size()>1048576)throw std::runtime_error("Redacted browser text exceeds its output bound");}return result;
    }
    void redact(const winrt::Windows::Data::Json::JsonObject& object)const{if(values_.empty())return;std::size_t nodes{};static_cast<void>(visit(object,0,nodes));}
private:
    winrt::Windows::Data::Json::IJsonValue visit(const winrt::Windows::Data::Json::IJsonValue& value,unsigned depth,std::size_t& nodes)const{
        using namespace winrt::Windows::Data::Json;if(depth>12||++nodes>8192)throw std::runtime_error("Browser output exceeds its redaction structure bound");if(value.ValueType()==JsonValueType::String)return JsonValue::CreateStringValue(winrt::to_hstring(text(winrt::to_string(value.GetString()))));
        if(value.ValueType()==JsonValueType::Object){const auto object=value.GetObject();std::vector<winrt::hstring> keys;for(const auto& item:object)keys.push_back(item.Key());for(const auto& key:keys)object.SetNamedValue(key,visit(object.GetNamedValue(key),depth+1,nodes));}
        else if(value.ValueType()==JsonValueType::Array){const auto array=value.GetArray();for(std::uint32_t i=0;i<array.Size();++i)array.SetAt(i,visit(array.GetAt(i),depth+1,nodes));}return value;
    }
};
} // namespace coincide::browser_tool
