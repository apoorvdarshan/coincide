#pragma once
#include <winrt/Microsoft.Windows.ApplicationModel.Resources.h>
#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string_view>

namespace coincide {
// Stable resource keys let Windows-only views reuse the existing catalog without translating keys.
inline std::wstring ui_resource_key(std::wstring_view source) {
    const auto bytes=winrt::to_string(source);std::uint64_t hash=14695981039346656037ULL;
    for(const auto c:bytes){hash^=static_cast<unsigned char>(c);hash*=1099511628211ULL;}
    std::wostringstream key;key<<L"Text_"<<std::hex<<std::setfill(L'0')<<std::setw(16)<<hash;return key.str();
}
inline winrt::hstring ui_text(std::wstring_view source) {
    try {
        winrt::Microsoft::Windows::ApplicationModel::Resources::ResourceLoader resources;
        const auto value=resources.GetString(ui_resource_key(source));if(!value.empty())return value;
    }catch(const winrt::hresult_error&){}
    return winrt::hstring(source);
}
} // namespace coincide
