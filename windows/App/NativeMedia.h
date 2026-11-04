#pragma once
#include "../Core/Workspace.h"
#include "NativeStrings.h"
#include <shlobj.h>
#include <shlwapi.h>
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif
#include <filesystem>
#include <algorithm>
#include <cwctype>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.Core.h>

namespace coincide {
inline winrt::Windows::Foundation::Uri local_media_uri(const std::filesystem::path& path) {
    if(!path.is_absolute()||path.root_name().wstring().size()!=2)throw std::invalid_argument("Media preview needs an absolute local file");
    if(path.native().size()>32768)throw std::invalid_argument("The media path exceeds its size limit");
    // Preserve UTF-16 filename characters. Windows' file-URI parser interprets UTF-8
    // percent escapes as ANSI bytes, corrupting Unicode before media loading even starts.
    // The native path converter escapes reserved ASCII (#, %, spaces) without that loss.
    std::wstring encoded(path.native().size()*3+16,L'\0');DWORD length=static_cast<DWORD>(encoded.size());
    winrt::check_hresult(UrlCreateFromPathW(path.c_str(),encoded.data(),&length,0));encoded.resize(length);
    while(!encoded.empty()&&encoded.back()==L'\0')encoded.pop_back();
    return winrt::Windows::Foundation::Uri(encoded);
}
inline bool previewable_local_file(const std::filesystem::path& path) {
    const auto root=path.root_name().wstring();
    if(!path.is_absolute()||root.size()!=2||root[1]!=L':'||GetDriveTypeW(path.root_path().c_str())==DRIVE_REMOTE)return false;
    std::error_code error;
    return std::filesystem::is_regular_file(path,error)&&std::filesystem::file_size(path,error)<=20ULL*1024*1024&&!error;
}
inline void append_media(const winrt::Microsoft::UI::Xaml::Controls::StackPanel& content,const std::vector<MessageAttachment>& attachments) {
    namespace xaml=winrt::Microsoft::UI::Xaml;namespace ui=xaml::Controls;
    for(const auto& attachment:attachments){
        ui::StackPanel card;card.Spacing(6);xaml::Automation::AutomationProperties::SetAutomationId(card,L"MessageAttachment");
        ui::TextBlock name;name.Text(winrt::to_hstring(attachment.name));name.TextWrapping(xaml::TextWrapping::Wrap);card.Children().Append(name);
        const std::filesystem::path path(winrt::to_hstring(attachment.path).c_str());
        auto extension=path.extension().wstring();std::transform(extension.begin(),extension.end(),extension.begin(),[](wchar_t c){return static_cast<wchar_t>(std::towlower(c));});
        if(previewable_local_file(path)){
            const auto uri=local_media_uri(path);
            if(extension==L".png"||extension==L".jpg"||extension==L".jpeg"||extension==L".gif"||extension==L".webp"||extension==L".bmp"){
                xaml::Media::Imaging::BitmapImage bitmap;bitmap.DecodePixelWidth(720);bitmap.UriSource(uri);
                ui::Image image;image.Source(bitmap);image.MaxHeight(320);image.MaxWidth(720);image.Stretch(xaml::Media::Stretch::Uniform);
                xaml::Automation::AutomationProperties::SetName(image,winrt::to_hstring(attachment.name));xaml::Automation::AutomationProperties::SetAutomationId(image,L"AttachmentImage");
                ui::Button expand;expand.Content(image);xaml::Automation::AutomationProperties::SetAutomationId(expand,L"OpenAttachmentImage");
                ui::Flyout preview;winrt::weak_ref<ui::Flyout> weak_preview(preview);preview.Opening([weak_preview,uri](const auto&,const auto&){
                    const auto preview=weak_preview.get();if(!preview)return;
                    xaml::Media::Imaging::BitmapImage full;full.DecodePixelWidth(1600);full.UriSource(uri);ui::Image picture;picture.Source(full);picture.Stretch(xaml::Media::Stretch::Uniform);picture.MaxWidth(1000);picture.MaxHeight(720);
                    ui::ScrollViewer scroll;scroll.Content(picture);preview.Content(scroll);
                });expand.Flyout(preview);card.Children().Append(expand);
            }else if(extension==L".mp4"||extension==L".mov"||extension==L".webm"||extension==L".mp3"||extension==L".m4a"||extension==L".wav"||extension==L".ogg"){
                ui::MediaPlayerElement player;player.AutoPlay(false);player.AreTransportControlsEnabled(true);player.MaxHeight(360);player.MinHeight(80);
                player.Source(winrt::Windows::Media::Core::MediaSource::CreateFromUri(uri));xaml::Automation::AutomationProperties::SetAutomationId(player,L"AttachmentPlayer");card.Children().Append(player);
            }
        }
        ui::Button reveal;reveal.Content(winrt::box_value(ui_text(L"Show in File Explorer")));xaml::Automation::AutomationProperties::SetAutomationId(reveal,L"RevealAttachment");
        reveal.Click([path](const auto&,const auto&){
            PIDLIST_ABSOLUTE item{};
            if(SUCCEEDED(SHParseDisplayName(path.c_str(),nullptr,&item,0,nullptr))){SHOpenFolderAndSelectItems(item,0,nullptr,0);CoTaskMemFree(item);}
        });card.Children().Append(reveal);content.Children().Append(card);
    }
}
} // namespace coincide
