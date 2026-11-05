#pragma once
#include "../App/DisplayItem.h"
#include <filesystem>
#include <fstream>
#include <stdexcept>

namespace coincide {
inline int display_tests(const std::filesystem::path& report) {
    try {
        int checks{};auto check=[&](bool valid,const char* failure){++checks;if(!valid)throw std::runtime_error(failure);};
        const auto partial = display_item("partial");
        const auto complete = display_item("complete — 你好");
        // XAML caches property metadata when a virtualized container is rebound to another item.
        const auto property = partial.as<winrt::Microsoft::UI::Xaml::Data::ICustomPropertyProvider>().GetCustomProperty(L"Text");
        if (winrt::unbox_value<winrt::hstring>(property.GetValue(partial)) != L"partial"
            || winrt::unbox_value<winrt::hstring>(property.GetValue(complete)) != L"complete — 你好") {
            throw std::runtime_error("A cached property descriptor displayed an earlier stream value");
        }
        ++checks;
        const auto folder=std::filesystem::temp_directory_path()/(L"Coincide media tests "+std::to_wstring(GetCurrentProcessId())+L"-"+std::to_wstring(GetTickCount64()));
        if(!std::filesystem::create_directory(folder))throw std::runtime_error("The unique media test folder exists");
        struct Cleanup{std::filesystem::path path;~Cleanup(){std::error_code ignored;std::filesystem::remove_all(path,ignored);}} cleanup{folder};
        const auto media=folder/L"会話 # 100%23.png";{std::ofstream stream(media,std::ios::binary);stream<<"fixture";}
        const auto uri=local_media_uri(media);
        const auto absolute=uri.AbsoluteUri();
        check(uri.SchemeName()==L"file"&&uri.Fragment().empty(),"Local media names must not become URI fragments");
        std::wstring decoded(32768,L'\0');DWORD decoded_length=static_cast<DWORD>(decoded.size());
        winrt::check_hresult(PathCreateFromUrlW(absolute.c_str(),decoded.data(),&decoded_length,0));decoded.resize(decoded_length);while(!decoded.empty()&&decoded.back()==L'\0')decoded.pop_back();
        check(std::filesystem::equivalent(media,std::filesystem::path(decoded)),"Local media URI must round-trip Unicode, hash and percent filename characters");
        for(const auto filename:{L"你好🙂 # %E4%BC%9A.png",L"literal %2523 and %23.png"}){
            const auto fixture=folder/filename;{std::ofstream stream(fixture,std::ios::binary);stream<<"fixture";}
            const auto encoded=local_media_uri(fixture);decoded.assign(32768,L'\0');decoded_length=static_cast<DWORD>(decoded.size());
            winrt::check_hresult(PathCreateFromUrlW(encoded.AbsoluteUri().c_str(),decoded.data(),&decoded_length,0));decoded.resize(decoded_length);while(!decoded.empty()&&decoded.back()==L'\0')decoded.pop_back();
            check(encoded.Fragment().empty()&&std::filesystem::equivalent(fixture,std::filesystem::path(decoded)),"File URIs must preserve surrogate pairs and literal escape-looking filename text without double decoding");
        }
        check(previewable_local_file(media),"An explicit small local attachment can be previewed");
        check(!previewable_local_file(std::filesystem::path(L"\\\\untrusted.invalid\\share\\image.png")),"Transcript rendering must not fetch an untrusted UNC image");
        std::filesystem::resize_file(media,20ULL*1024*1024+1);
        check(!previewable_local_file(media),"Oversized attachments must not be decoded automatically");
        std::ofstream output(report);
        output << "PASS: "<<checks<<" Windows display and media checks\n";
        return output ? 0 : 2;
    } catch (const std::exception& error) {
        std::ofstream(report) << "FAIL: " << error.what() << '\n';
    } catch (const winrt::hresult_error& error) {
        std::ofstream(report) << "FAIL: " << winrt::to_string(error.message()) << '\n';
    }
    return 1;
}
} // namespace coincide
