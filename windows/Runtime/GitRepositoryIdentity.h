#pragma once
#include "WindowsProcess.h"
#include <cstring>
#include <climits>

namespace coincide::git_identity {
// Metadata-only identity for short, synchronous lease decisions. No CLI is discovered or started.
inline constexpr std::size_t maximum_metadata_bytes=4096,maximum_depth=64,maximum_pins=512;
enum class State {ready,not_repository,unavailable};
struct DirectoryID {
    std::uint64_t volume{};std::array<unsigned char,16> file{};
    bool operator==(const DirectoryID&)const=default;
};
namespace detail {
inline bool equal_path(std::wstring_view a,std::wstring_view b){return a.size()<=INT_MAX&&b.size()<=INT_MAX&&CompareStringOrdinal(a.data(),static_cast<int>(a.size()),b.data(),static_cast<int>(b.size()),TRUE)==CSTR_EQUAL;}
inline std::filesystem::path literal(std::filesystem::path value){
    auto name=value.wstring();std::replace(name.begin(),name.end(),L'/',L'\\');if(name.starts_with(L"\\\\?\\")&&name.size()>6&&name[5]==L':')name.erase(0,4);value=name;
    const auto drive=value.root_name().wstring();if(!value.is_absolute()||drive.size()!=2||drive[1]!=L':'||!((drive[0]>=L'A'&&drive[0]<=L'Z')||(drive[0]>=L'a'&&drive[0]<=L'z'))||name.size()>32760||name.find_first_of(L"\0*?<>|\"",0,7)!=std::wstring::npos||name.find(L':',2)!=std::wstring::npos)throw std::runtime_error("Repository identity requires an absolute local DOS directory");
    const auto type=GetDriveTypeW(value.root_path().c_str());if(type!=DRIVE_FIXED&&type!=DRIVE_RAMDISK)throw std::runtime_error("Repository identity refuses remote or removable storage");while(value!=value.root_path()&&!value.has_filename())value=value.parent_path();return value;
}
inline void component(std::wstring value){
    if(value.empty()||value.back()==L'.'||value.back()==L' '||std::any_of(value.begin(),value.end(),[](wchar_t ch){return ch<32;}))throw std::runtime_error("Repository identity refuses ambiguous path components");
    value=value.substr(0,value.find(L'.'));std::transform(value.begin(),value.end(),value.begin(),[](wchar_t ch){return ch>=L'a'&&ch<=L'z'?static_cast<wchar_t>(ch-(L'a'-L'A')):ch;});
    if(value==L"CON"||value==L"PRN"||value==L"AUX"||value==L"NUL"||value==L"CLOCK$"||((value.starts_with(L"COM")||value.starts_with(L"LPT"))&&value.size()==4&&value[3]>=L'0'&&value[3]<=L'9'))throw std::runtime_error("Repository identity refuses Windows device aliases");
}
inline std::wstring extended(const std::filesystem::path& path){return L"\\\\?\\"+path.wstring();}
inline bool missing(DWORD error){return error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND;}
inline DWORD attributes(const std::filesystem::path& path){const auto result=GetFileAttributesW(extended(path).c_str());if(result==INVALID_FILE_ATTRIBUTES&&!missing(GetLastError()))throw std::runtime_error("Repository metadata is unavailable or unreadable");return result;}
inline constexpr DWORD unsafe_attributes=FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE|0x00400000|0x00040000;
inline DirectoryID identity(HANDLE handle){FILE_ID_INFO info{};if(!GetFileInformationByHandleEx(handle,FileIdInfo,&info,sizeof(info)))throw std::runtime_error("The local filesystem cannot provide a stable directory identity");DirectoryID result;result.volume=info.VolumeSerialNumber;std::memcpy(result.file.data(),info.FileId.Identifier,result.file.size());return result;}
inline std::filesystem::path physical_name(HANDLE handle){std::array<wchar_t,32768> name{};const auto count=GetFinalPathNameByHandleW(handle,name.data(),static_cast<DWORD>(name.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);if(!count||count>=name.size())throw std::runtime_error("Could not resolve a physical repository directory");return literal(std::filesystem::path(std::wstring(name.data(),count)));}
struct Directory {std::filesystem::path path;DirectoryID id;};
struct Pins {
    std::vector<NativeHandle> handles;std::vector<std::filesystem::path> absent;
    void hold(NativeHandle handle){if(handles.size()>=maximum_pins)throw std::runtime_error("Repository metadata exceeded its handle bound");handles.push_back(std::move(handle));}
    Directory directory(const std::filesystem::path& path){
        NativeHandle handle(CreateFileW(extended(path).c_str(),FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,nullptr));BY_HANDLE_FILE_INFORMATION info{};
        if(handle.get()==INVALID_HANDLE_VALUE||GetFileType(handle.get())!=FILE_TYPE_DISK||!GetFileInformationByHandle(handle.get(),&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.dwFileAttributes&unsafe_attributes))throw std::runtime_error("Repository identity refuses unavailable, linked or placeholder directories");
        Directory result{physical_name(handle.get()),identity(handle.get())};hold(std::move(handle));return result;
    }
    std::vector<Directory> directories(const std::filesystem::path& requested,bool allow_parents=false){
        const auto value=literal(requested);auto current=value.root_path();std::vector<Directory> result;result.push_back(directory(current));current=result.back().path;std::size_t depth{};
        for(const auto& part:value.relative_path()){
            const auto name=part.wstring();if(++depth>maximum_depth)throw std::runtime_error("Repository identity exceeded its ancestor bound");
            if(name==L"."||name==L".."){if(!allow_parents)throw std::runtime_error("Repository identity requires an unambiguous current directory");if(name==L".."){if(current==current.root_path())throw std::runtime_error("Repository metadata traverses above its drive root");current=current.parent_path();result.push_back(directory(current));current=result.back().path;}continue;}
            component(name);current/=part;result.push_back(directory(current));current=result.back().path;
        }return result;
    }
    std::string file(const std::filesystem::path& path){
        NativeHandle handle(CreateFileW(extended(path).c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_SEQUENTIAL_SCAN,nullptr));BY_HANDLE_FILE_INFORMATION info{};LARGE_INTEGER size{};
        if(handle.get()==INVALID_HANDLE_VALUE||GetFileType(handle.get())!=FILE_TYPE_DISK||!GetFileInformationByHandle(handle.get(),&info)||(info.dwFileAttributes&(unsafe_attributes|FILE_ATTRIBUTE_DIRECTORY))||info.nNumberOfLinks!=1||!GetFileSizeEx(handle.get(),&size)||size.QuadPart<0||size.QuadPart>static_cast<LONGLONG>(maximum_metadata_bytes))throw std::runtime_error("Repository metadata must be a readable bounded regular file without links");
        const auto actual=physical_name(handle.get());if(!equal_path(actual.wstring(),path.wstring()))throw std::runtime_error("Repository metadata changed its physical target");std::string bytes(static_cast<std::size_t>(size.QuadPart),'\0');std::size_t offset{};
        while(offset<bytes.size()){DWORD count{};if(!ReadFile(handle.get(),bytes.data()+offset,static_cast<DWORD>(bytes.size()-offset),&count,nullptr)||!count)throw std::runtime_error("Repository metadata could not be read completely");offset+=count;}
        BY_HANDLE_FILE_INFORMATION after{};if(!GetFileInformationByHandle(handle.get(),&after)||after.nFileSizeHigh!=info.nFileSizeHigh||after.nFileSizeLow!=info.nFileSizeLow||CompareFileTime(&after.ftLastWriteTime,&info.ftLastWriteTime)!=0)throw std::runtime_error("Repository metadata changed while it was being read");hold(std::move(handle));return bytes;
    }
    void missing_file(const std::filesystem::path& path){absent.push_back(path);}
    void verify_absent()const{for(const auto& path:absent)if(attributes(path)!=INVALID_FILE_ATTRIBUTES)throw std::runtime_error("Repository metadata appeared while resolving its identity");}
};
inline std::filesystem::path metadata_path(std::string bytes,const std::filesystem::path& base,bool gitfile){
    if(gitfile){if(!bytes.starts_with("gitdir: "))throw std::runtime_error("The selected .git file has an unsupported format");bytes.erase(0,8);}
    if(bytes.ends_with("\n")){bytes.pop_back();if(bytes.ends_with("\r"))bytes.pop_back();}
    if(bytes.empty()||bytes.find_first_of("\0\r\n",0,3)!=std::string::npos||bytes.size()>maximum_metadata_bytes)throw std::runtime_error("Repository metadata must contain one bounded directory path");
    const auto length=MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,bytes.data(),static_cast<int>(bytes.size()),nullptr,0);if(!length)throw std::runtime_error("Repository metadata must use valid UTF-8");std::wstring text(static_cast<std::size_t>(length),L'\0');if(MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,bytes.data(),static_cast<int>(bytes.size()),text.data(),length)!=length)throw std::runtime_error("Could not decode repository metadata");
    std::filesystem::path path(text);if(path.is_absolute())return literal(path);if(path.has_root_name()||path.has_root_directory())throw std::runtime_error("Repository metadata contains a drive-relative path");return literal(base/path);
}
}
struct Result;
struct Identity {
    std::filesystem::path root,git_directory,common_directory;
    DirectoryID root_id,git_id,common_id;
private:
    std::shared_ptr<detail::Pins> pins_;
    friend Result lookup(const std::filesystem::path&,const std::filesystem::path&);
};
struct Result {State state{State::unavailable};std::shared_ptr<const Identity> value;std::string error;};
inline bool same_repository(const Identity& a,const Identity& b){return a.common_id==b.common_id;}

// ceiling is an optional trusted ancestor boundary (also keeps fixtures wholly inside their owned tree).
// Result pins are intentionally short-lived: keep them through the lease decision, then release.
// Bounds limit calls/bytes, not kernel filesystem-driver latency; this is restricted to local storage.
inline Result lookup(const std::filesystem::path& cwd,const std::filesystem::path& ceiling={}){
    try{
        auto pins=std::make_shared<detail::Pins>();auto ancestors=pins->directories(cwd);std::optional<DirectoryID> stop;
        if(!ceiling.empty()){const auto boundary=pins->directories(ceiling).back();const auto found=std::find_if(ancestors.begin(),ancestors.end(),[&](const auto& value){return value.id==boundary.id;});if(found==ancestors.end())throw std::runtime_error("The repository lookup boundary is not an ancestor of its current directory");stop=boundary.id;}
        for(auto at=ancestors.rbegin();at!=ancestors.rend();++at){
            const auto metadata=at->path/L".git";const auto attributes=detail::attributes(metadata);
            if(attributes==INVALID_FILE_ATTRIBUTES){pins->missing_file(metadata);if(stop&&at->id==*stop)break;continue;}
            if(attributes&detail::unsafe_attributes)throw std::runtime_error("Repository identity refuses linked or placeholder .git metadata");
            const auto git=(attributes&FILE_ATTRIBUTE_DIRECTORY)?pins->directory(metadata):pins->directories(detail::metadata_path(pins->file(metadata),at->path,true),true).back();
            const auto common_file=git.path/L"commondir";const auto common_attributes=detail::attributes(common_file);detail::Directory common=git;
            if(common_attributes==INVALID_FILE_ATTRIBUTES)pins->missing_file(common_file);else{if(common_attributes&(detail::unsafe_attributes|FILE_ATTRIBUTE_DIRECTORY))throw std::runtime_error("Repository commondir is not regular readable metadata");common=pins->directories(detail::metadata_path(pins->file(common_file),git.path,false),true).back();}
            pins->verify_absent();auto identity=std::make_shared<Identity>();identity->root=at->path;identity->git_directory=git.path;identity->common_directory=common.path;identity->root_id=at->id;identity->git_id=git.id;identity->common_id=common.id;identity->pins_=std::move(pins);return {State::ready,std::move(identity),{}};
        }
        pins->verify_absent();return {State::not_repository,nullptr,{}};
    }catch(const std::exception& error){return {State::unavailable,nullptr,error.what()};}catch(...){return {State::unavailable,nullptr,"Repository identity could not be resolved safely"};}
}
} // namespace coincide::git_identity
