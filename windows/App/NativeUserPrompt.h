#pragma once
#include <windows.h>
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif
#include "NativeStrings.h"
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <chrono>
#include <cstdint>
#include <functional>

namespace coincide {
// Only the owner window calls this. No page script, JSON field or timer can accept the dialog.
// The caller reserves its dialog slot and restores only the panel it opened for this handoff.
inline winrt::Windows::Foundation::IAsyncOperation<winrt::hstring> native_user_prompt(
        winrt::Microsoft::UI::Xaml::XamlRoot root,winrt::hstring title,winrt::hstring message,
        winrt::hstring affirmative,std::uint64_t deadline,std::function<bool()> cancelled={}){
    namespace ui=winrt::Microsoft::UI::Xaml::Controls;namespace xaml=winrt::Microsoft::UI::Xaml;
    if(!root)throw std::runtime_error("The owner window is unavailable");
    if(cancelled&&cancelled())co_return L"cancelled";
    ui::ContentDialog dialog;dialog.XamlRoot(root);dialog.Title(winrt::box_value(title));
    xaml::Automation::AutomationProperties::SetAutomationId(dialog,L"NativeUserHandoff");
    ui::TextBlock text;text.Text(message);text.TextWrapping(xaml::TextWrapping::Wrap);
    ui::ScrollViewer scroll;scroll.Content(text);scroll.MaxHeight(320);dialog.Content(scroll);
    dialog.PrimaryButtonText(affirmative);dialog.CloseButtonText(ui_text(L"Decline"));
    dialog.DefaultButton(ui::ContentDialogButton::Close);
    auto timer=root.Content().DispatcherQueue().CreateTimer();timer.Interval(std::chrono::milliseconds(100));
    bool expired{},revoked{};auto tick=timer.Tick(winrt::auto_revoke,[&](const auto&,const auto&){
        revoked=cancelled&&cancelled();expired=GetTickCount64()>=deadline;if(revoked||expired){timer.Stop();dialog.Hide();}
    });
    const auto show=dialog.ShowAsync();timer.Start();
    struct Stop {winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer timer;~Stop(){timer.Stop();}}stop{timer};
    const auto decision=co_await show;timer.Stop();
    if(revoked||(cancelled&&cancelled()))co_return L"cancelled";
    if(expired||GetTickCount64()>=deadline)co_return L"timeout";
    co_return decision==ui::ContentDialogResult::Primary?L"done":L"declined";
}
} // namespace coincide
