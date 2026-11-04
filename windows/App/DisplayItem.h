#pragma once
#include <string>
#include <utility>
#include <winrt/Windows.Foundation.h>
#include <winrt/Microsoft.UI.Xaml.Data.h>
#include <winrt/Windows.UI.Xaml.Interop.h>

namespace coincide {
using winrt::hstring;
// ListView needs an identity for each row. Equal boxed strings otherwise identify two different messages
// as the same item, which can make UI Automation sibling traversal cycle indefinitely.
using Inspectable = winrt::Windows::Foundation::IInspectable;
using XamlType = winrt::Windows::UI::Xaml::Interop::TypeName;
using TypeKind = winrt::Windows::UI::Xaml::Interop::TypeKind;
struct DisplayProperty : winrt::implements<DisplayProperty, winrt::Microsoft::UI::Xaml::Data::ICustomProperty> {
    XamlType Type() const { return {L"String", TypeKind::Primitive}; }
    hstring Name() const { return L"Text"; }
    // XAML may cache this property descriptor across items; always read the target supplied by the binding.
    Inspectable GetValue(const Inspectable& target) const {
        return winrt::box_value(target.as<winrt::Microsoft::UI::Xaml::Data::ICustomPropertyProvider>().GetStringRepresentation());
    }
    bool CanRead() const { return true; }
    bool CanWrite() const { return false; }
    void SetValue(const Inspectable&, const Inspectable&) const { throw winrt::hresult_access_denied(); }
    Inspectable GetIndexedValue(const Inspectable&, const Inspectable&) const { throw winrt::hresult_not_implemented(); }
    void SetIndexedValue(const Inspectable&, const Inspectable&, const Inspectable&) const { throw winrt::hresult_not_implemented(); }
};
struct DisplayItem : winrt::implements<DisplayItem, winrt::Microsoft::UI::Xaml::Data::ICustomPropertyProvider> {
    explicit DisplayItem(hstring text) : text_(std::move(text)) {}
    winrt::Microsoft::UI::Xaml::Data::ICustomProperty GetCustomProperty(const hstring& name) const {
        return name == L"Text" ? winrt::make<DisplayProperty>() : nullptr;
    }
    winrt::Microsoft::UI::Xaml::Data::ICustomProperty GetIndexedProperty(const hstring&, const XamlType&) const { return nullptr; }
    hstring GetStringRepresentation() const { return text_; }
    XamlType Type() const { return {L"Coincide.DisplayItem", TypeKind::Custom}; }
private:
    hstring text_;
};
inline winrt::Windows::Foundation::IInspectable display_item(const std::string& text) {
    return winrt::make<DisplayItem>(winrt::to_hstring(text));
}

} // namespace coincide
