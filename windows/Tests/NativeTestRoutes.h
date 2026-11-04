#pragma once
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>

namespace winrt::Microsoft::UI::Xaml {struct XamlRoot;}
namespace coincide::tests {
// Shallow declarations only. Implementations retain the existing test/fixture flags and run in
// the same executable so native subprocess ownership and fixture-only account gates stay intact.
// argv remains owned by the entrypoint and must stay alive until this synchronous call returns.
std::optional<int> run_contract_test(int argc,wchar_t** argv);
std::optional<std::string> ui_test_suite(std::wstring_view flag);
int run_ui_test(std::string_view suite,const std::filesystem::path& report,const winrt::Microsoft::UI::Xaml::XamlRoot& root);
} // namespace coincide::tests
