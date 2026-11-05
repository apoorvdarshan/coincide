#pragma once
#include <string>
#include <utility>
#include <winrt/Windows.Foundation.h>
#include <winrt/Microsoft.UI.Xaml.Data.h>
#include <winrt/Windows.UI.Xaml.Interop.h>
#include "NativeMarkdown.h"
#include "NativeMedia.h"

namespace coincide {
using winrt::hstring;
// ListView needs an identity for each row. Equal boxed strings otherwise identify two different messages
// as the same item, which can make UI Automation sibling traversal cycle indefinitely.
using Inspectable = winrt::Windows::Foundation::IInspectable;
using XamlType = winrt::Windows::UI::Xaml::Interop::TypeName;
using TypeKind = winrt::Windows::UI::Xaml::Interop::TypeKind;
Inspectable display_content(const Inspectable& target);
struct DisplayProperty : winrt::implements<DisplayProperty, winrt::Microsoft::UI::Xaml::Data::ICustomProperty> {
    explicit DisplayProperty(bool content = false) : content_(content) {}
    XamlType Type() const { return {content_ ? L"Object" : L"String", TypeKind::Primitive}; }
    hstring Name() const { return content_ ? L"Content" : L"Text"; }
    // XAML may cache this property descriptor across items; always read the target supplied by the binding.
    Inspectable GetValue(const Inspectable& target) const {
        return content_ ? display_content(target) : winrt::box_value(target.as<winrt::Microsoft::UI::Xaml::Data::ICustomPropertyProvider>().GetStringRepresentation());
    }
    bool CanRead() const { return true; }
    bool CanWrite() const { return false; }
    void SetValue(const Inspectable&, const Inspectable&) const { throw winrt::hresult_access_denied(); }
    Inspectable GetIndexedValue(const Inspectable&, const Inspectable&) const { throw winrt::hresult_not_implemented(); }
    void SetIndexedValue(const Inspectable&, const Inspectable&, const Inspectable&) const { throw winrt::hresult_not_implemented(); }
private:
    bool content_{};
};
struct DisplayItem : winrt::implements<DisplayItem, winrt::Microsoft::UI::Xaml::Data::ICustomPropertyProvider> {
    explicit DisplayItem(hstring text,std::vector<MessageAttachment> attachments={},native_markdown::Navigator navigate={},native_markdown::Preview preview={},double font_size=14,hstring font=L"Segoe UI")
        : text_(std::move(text)),attachments_(std::move(attachments)),navigate_(std::move(navigate)),preview_(std::move(preview)),font_size_(font_size),font_(std::move(font)) {}
    winrt::Microsoft::UI::Xaml::Data::ICustomProperty GetCustomProperty(const hstring& name) const {
        if (name == L"Text") return winrt::make<DisplayProperty>();
        if (name == L"Content") return winrt::make<DisplayProperty>(true);
        return nullptr;
    }
    winrt::Microsoft::UI::Xaml::Data::ICustomProperty GetIndexedProperty(const hstring&, const XamlType&) const { return nullptr; }
    hstring GetStringRepresentation() const { return text_; }
    XamlType Type() const { return {L"Coincide.DisplayItem", TypeKind::Custom}; }
    Inspectable content() {
        // Let WinUI own the current visual. Keeping it in this view model would retain every row ever scrolled past.
        auto content=native_markdown::render(winrt::to_string(text_),ui_text(L"Copy Code"),navigate_,preview_,font_size_,font_);
        content.DataContext(winrt::box_value(false));append_media(content,attachments_);return content;
    }
private:
    hstring text_;
    std::vector<MessageAttachment> attachments_;
    native_markdown::Navigator navigate_;native_markdown::Preview preview_;double font_size_;hstring font_;
};
inline Inspectable display_content(const Inspectable& target) {
    return winrt::get_self<DisplayItem>(target.as<winrt::Microsoft::UI::Xaml::Data::ICustomPropertyProvider>())->content();
}
inline winrt::Windows::Foundation::IInspectable display_item(const std::string& text) {
    return winrt::make<DisplayItem>(winrt::to_hstring(text));
}
inline winrt::Windows::Foundation::IInspectable display_message(const Message& message,const std::string& speaker,native_markdown::Navigator navigate={},native_markdown::Preview preview={},double font_size=14,hstring font=L"Segoe UI"){
    return winrt::make<DisplayItem>(winrt::to_hstring(speaker+"\n"+message.text),message.attachments,std::move(navigate),std::move(preview),font_size,std::move(font));
}

} // namespace coincide
