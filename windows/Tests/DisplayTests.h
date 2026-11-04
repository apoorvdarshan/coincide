#pragma once
#include "../App/DisplayItem.h"
#include <filesystem>
#include <fstream>
#include <stdexcept>

namespace coincide {
inline int display_tests(const std::filesystem::path& report) {
    try {
        const auto partial = display_item("partial");
        const auto complete = display_item("complete — 你好");
        // XAML caches property metadata when a virtualized container is rebound to another item.
        const auto property = partial.as<winrt::Microsoft::UI::Xaml::Data::ICustomPropertyProvider>().GetCustomProperty(L"Text");
        if (winrt::unbox_value<winrt::hstring>(property.GetValue(partial)) != L"partial"
            || winrt::unbox_value<winrt::hstring>(property.GetValue(complete)) != L"complete — 你好") {
            throw std::runtime_error("A cached property descriptor displayed an earlier stream value");
        }
        std::ofstream output(report);
        output << "PASS: 1 Windows binding regression check\n";
        return output ? 0 : 2;
    } catch (const std::exception& error) {
        std::ofstream(report) << "FAIL: " << error.what() << '\n';
    } catch (const winrt::hresult_error& error) {
        std::ofstream(report) << "FAIL: " << winrt::to_string(error.message()) << '\n';
    }
    return 1;
}
} // namespace coincide
