#pragma once
#include <windows.h>
#include <bcrypt.h>
#include <shlobj.h>
#include <winrt/Windows.Foundation.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "shell32.lib")

namespace coincide::local_file {
struct Handle {HANDLE value{INVALID_HANDLE_VALUE};~Handle(){if(value!=INVALID_HANDLE_VALUE&&value)CloseHandle(value);}Handle(const Handle&)=delete;Handle& operator=(const Handle&)=delete;explicit Handle(HANDLE v):value(v){}};
inline std::wstring lower(std::wstring value){for(auto& ch:value)if(ch>=L'A'&&ch<=L'Z')ch=static_cast<wchar_t>(ch+(L'a'-L'A'));return value;}
inline bool equal_path(std::wstring_view a,std::wstring_view b){return a.size()<=INT_MAX&&b.size()<=INT_MAX&&CompareStringOrdinal(a.data(),static_cast<int>(a.size()),b.data(),static_cast<int>(b.size()),TRUE)==CSTR_EQUAL;}
inline bool within(const std::filesystem::path& root,const std::filesystem::path& file){
    const auto base=std::filesystem::weakly_canonical(root).wstring(),target=std::filesystem::weakly_canonical(file).wstring();
    return equal_path(target,base)||(target.size()>base.size()&&equal_path(std::wstring_view(target).substr(0,base.size()),base)&&(base.ends_with(L"\\")||base.ends_with(L"/")||target[base.size()]==L'\\'||target[base.size()]==L'/'));
}
inline bool local_path(const std::filesystem::path& path){
    const auto root=path.root_name().wstring();if(!path.is_absolute()||root.size()!=2||root[1]!=L':'||path.wstring().size()>32760)return false;
    const auto type=GetDriveTypeW(path.root_path().c_str());return type==DRIVE_FIXED||type==DRIVE_REMOVABLE||type==DRIVE_RAMDISK;
}
inline bool reparse(const std::filesystem::path& path){const auto attr=GetFileAttributesW(path.c_str());return attr!=INVALID_FILE_ATTRIBUTES&&(attr&FILE_ATTRIBUTE_REPARSE_POINT);}
inline bool has_reparse(const std::filesystem::path& path){std::filesystem::path prefix;for(const auto& part:path){prefix/=part;if(reparse(prefix))return true;}return false;}
inline std::filesystem::path home(){PWSTR value{};winrt::check_hresult(SHGetKnownFolderPath(FOLDERID_Profile,KF_FLAG_DEFAULT,nullptr,&value));const std::filesystem::path result(value);CoTaskMemFree(value);return result;}
inline std::filesystem::path environment_path(const wchar_t* name,const std::filesystem::path& fallback){
    std::array<wchar_t,32768> value{};const auto count=GetEnvironmentVariableW(name,value.data(),static_cast<DWORD>(value.size()));
    if(!count)return fallback;if(count>=value.size())throw std::runtime_error("A configured history/instruction path is too long");
    const std::filesystem::path path(value.data());if(!local_path(path))throw std::runtime_error("Configured history/instruction folders must be absolute local paths");return path.lexically_normal();
}
inline std::string sha256(std::string_view bytes){
    BCRYPT_ALG_HANDLE algorithm{};if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)throw std::runtime_error("Could not initialize the source fingerprint");
    struct Algorithm{BCRYPT_ALG_HANDLE value;~Algorithm(){BCryptCloseAlgorithmProvider(value,0);}} release{algorithm};
    DWORD length{},received{};if(BCryptGetProperty(algorithm,BCRYPT_OBJECT_LENGTH,reinterpret_cast<PUCHAR>(&length),sizeof(length),&received,0)<0)throw std::runtime_error("Could not initialize the source fingerprint");
    std::vector<UCHAR> object(length);BCRYPT_HASH_HANDLE hash{};if(BCryptCreateHash(algorithm,&hash,object.data(),length,nullptr,0,0)<0)throw std::runtime_error("Could not initialize the source fingerprint");
    struct Hash{BCRYPT_HASH_HANDLE value;~Hash(){BCryptDestroyHash(value);}} release_hash{hash};
    std::array<UCHAR,32> digest{};if(bytes.size()>MAXDWORD||BCryptHashData(hash,reinterpret_cast<PUCHAR>(const_cast<char*>(bytes.data())),static_cast<ULONG>(bytes.size()),0)<0||BCryptFinishHash(hash,digest.data(),static_cast<ULONG>(digest.size()),0)<0)throw std::runtime_error("Could not fingerprint the source file");
    constexpr char hex[]="0123456789abcdef";std::string result;for(const auto ch:digest){result+=hex[ch>>4];result+=hex[ch&15];}return result;
}
struct Snapshot{std::filesystem::path resolved;std::string bytes,digest;std::uint64_t size{},modified{};};
inline Snapshot read(const std::filesystem::path& path,std::size_t maximum,bool allow_reparse=false,bool prefix_only=false,const std::filesystem::path& expected_resolved={}){
    if(!local_path(path)||(!allow_reparse&&has_reparse(path)))throw std::runtime_error("Choose a regular local file without symbolic links or junctions");
    const auto expected=expected_resolved.empty()?std::filesystem::weakly_canonical(path):expected_resolved;
    Handle file(CreateFileW(path.c_str(),GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,nullptr));
    if(file.value==INVALID_HANDLE_VALUE)throw std::runtime_error("The selected local file cannot be read");
    BY_HANDLE_FILE_INFORMATION before{},after{};if(!GetFileInformationByHandle(file.value,&before)||(before.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_OFFLINE)))throw std::runtime_error("The selected source is not an available regular local file");
    const auto size=(static_cast<std::uint64_t>(before.nFileSizeHigh)<<32)|before.nFileSizeLow;if(!prefix_only&&size>maximum)throw std::runtime_error("The selected source exceeds its file size limit");
    std::vector<wchar_t> resolved(32768);const auto count=GetFinalPathNameByHandleW(file.value,resolved.data(),static_cast<DWORD>(resolved.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
    if(!count||count>=resolved.size())throw std::runtime_error("Could not resolve the local source path");
    std::wstring final_path(resolved.data(),count);if(final_path.starts_with(L"\\\\?\\"))final_path.erase(0,4);
    Snapshot result;result.resolved=final_path;if(!local_path(result.resolved))throw std::runtime_error("The selected source resolves outside local storage");
    if(!equal_path(result.resolved.wstring(),expected.wstring()))throw std::runtime_error("The selected source path changed before it could be read");
    std::array<char,65536> buffer{};DWORD read{};
    while(result.bytes.size()<maximum+(prefix_only?0:1)){
        const auto amount=static_cast<DWORD>(std::min<std::size_t>(buffer.size(),maximum+(prefix_only?0:1)-result.bytes.size()));
        if(!ReadFile(file.value,buffer.data(),amount,&read,nullptr))throw std::runtime_error("The selected source could not be read completely");if(!read)break;result.bytes.append(buffer.data(),read);
    }
    if(!prefix_only&&result.bytes.size()>maximum)throw std::runtime_error("The selected source grew beyond its size limit");
    if(!GetFileInformationByHandle(file.value,&after))throw std::runtime_error("Could not verify the selected source");
    const auto stamp=[](FILETIME time){return(static_cast<std::uint64_t>(time.dwHighDateTime)<<32)|time.dwLowDateTime;};
    if(!prefix_only&&(before.nFileSizeHigh!=after.nFileSizeHigh||before.nFileSizeLow!=after.nFileSizeLow||stamp(before.ftLastWriteTime)!=stamp(after.ftLastWriteTime)))throw std::runtime_error("The source changed while it was being read; refresh its preview");
    result.size=size;result.modified=stamp(before.ftLastWriteTime);result.digest=sha256(result.bytes);return result;
}
inline bool utf8(std::string_view bytes){return bytes.empty()||(bytes.size()<=INT_MAX&&MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,bytes.data(),static_cast<int>(bytes.size()),nullptr,0)>0);}
} // namespace coincide::local_file
