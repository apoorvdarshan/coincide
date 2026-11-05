#pragma once
#include "../Core/ComposerFileMention.h"
#include "GitRepositoryIdentity.h"
#include <functional>
#include <unordered_map>

namespace coincide {
// Metadata only: all handles request attributes/listing, never file contents.
// Pinned ancestors and no-share-delete handles keep every inspected path literal.
class ProjectFileIndex {
public:
    static constexpr std::size_t maximum_visited=20000,maximum_files=5000,maximum_path_bytes=2*1024*1024,maximum_depth=32;
    struct Cancelled {};
    using Cancel=std::function<bool()>;
    struct Scope {std::filesystem::path root;git_identity::DirectoryID id;std::shared_ptr<git_identity::detail::Pins> pins;};
    struct Entry {std::string path;git_identity::DirectoryID id;};
    struct Result {std::shared_ptr<Scope> scope;std::vector<Entry> files;bool limited{};std::size_t skipped{};};
    struct Verified {git_identity::detail::Pins parents;NativeHandle file;};
    static Result scan(const std::filesystem::path& requested,Cancel cancel={}){
        if(cancel&&cancel())throw Cancelled{};
        Result result;auto pins=std::make_shared<git_identity::detail::Pins>();const auto chain=pins->directories(requested);const auto& root=chain.back();
        result.scope=std::make_shared<Scope>(Scope{root.path,root.id,std::move(pins)});
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(2);std::size_t visited{},bytes{};
        const auto stopped=[&]{if(cancel&&cancel())throw Cancelled{};if(visited>=maximum_visited||result.files.size()>=maximum_files||std::chrono::steady_clock::now()>=deadline){result.limited=true;return true;}return false;};
        std::function<void(const std::filesystem::path&,const std::string&,std::size_t)> walk;
        walk=[&](const auto& folder,const auto& prefix,std::size_t depth){
            if(stopped())return;git_identity::detail::Pins current;const auto actual=current.directory(folder);if(!git_identity::detail::equal_path(actual.path.wstring(),folder.wstring()))throw std::runtime_error("The project directory changed while listing files");
            WIN32_FIND_DATAW data{};const auto first=FindFirstFileExW(git_identity::detail::extended(folder/L"*").c_str(),FindExInfoBasic,&data,FindExSearchNameMatch,nullptr,FIND_FIRST_EX_LARGE_FETCH);
            if(first==INVALID_HANDLE_VALUE){if(GetLastError()==ERROR_FILE_NOT_FOUND)return;throw std::runtime_error("The project directory cannot be listed");}
            struct Find {HANDLE value;~Find(){FindClose(value);}} find{first};
            do{
                if(stopped())return;const std::wstring name(data.cFileName);if(name==L"."||name==L"..")continue;++visited;
                if(name.starts_with(L'.')||(data.dwFileAttributes&(git_identity::detail::unsafe_attributes|FILE_ATTRIBUTE_HIDDEN|FILE_ATTRIBUTE_SYSTEM))){++result.skipped;continue;}
                try{
                    git_identity::detail::component(name);const auto component=winrt::to_string(name);const auto relative=prefix.empty()?component:prefix+"/"+component;
                    if(!ComposerFileMention::relative(relative)){++result.skipped;continue;}
                    const auto child=folder/name;
                    if(data.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY){const auto lower=workspace_text::fold(component);if(skipped_folder(lower)){++result.skipped;continue;}if(depth>=maximum_depth){result.limited=true;continue;}walk(child,relative,depth+1);}
                    else{
                        auto leaf=open_file(child);const auto id=git_identity::detail::identity(leaf.get());
                        if(relative.size()>maximum_path_bytes-bytes){result.limited=true;return;}bytes+=relative.size();result.files.push_back({relative,id});
                    }
                }catch(const Cancelled&){throw;}catch(...){++result.skipped;}
            }while(FindNextFileW(find.value,&data));
            if(GetLastError()!=ERROR_NO_MORE_FILES)throw std::runtime_error("The project file listing did not finish");
        };
        walk(root.path,"",0);if(cancel&&cancel())throw Cancelled{};return result;
    }
    static std::shared_ptr<Verified> verify(const std::shared_ptr<Scope>& scope,const Entry& entry){
        if(!scope||!ComposerFileMention::relative(entry.path))throw std::runtime_error("The selected project file is unavailable");
        git_identity::detail::Pins roots;const auto current=roots.directories(scope->root);if(current.back().id!=scope->id)throw std::runtime_error("The project folder changed; refresh file suggestions");
        auto relative=std::filesystem::path(winrt::to_hstring(entry.path).c_str());relative.make_preferred();const auto path=scope->root/relative;auto result=std::make_shared<Verified>();
        const auto parents=result->parents.directories(path.parent_path());if(!git_identity::detail::equal_path(parents.back().path.wstring(),path.parent_path().wstring()))throw std::runtime_error("The selected project folder changed; refresh file suggestions");
        result->file=open_file(path);if(git_identity::detail::identity(result->file.get())!=entry.id)throw std::runtime_error("The selected project file changed; refresh file suggestions");
        // Keep root and all descendants pinned through the caller's insertion.
        for(auto& handle:roots.handles)result->parents.hold(std::move(handle));return result;
    }
private:
    static bool skipped_folder(const std::string& name){constexpr std::string_view names[]{"node_modules","build","dist","target","vendor","packages","bin","obj","__pycache__"};return std::find(std::begin(names),std::end(names),name)!=std::end(names);}
    static NativeHandle open_file(const std::filesystem::path& path){
        NativeHandle file(CreateFileW(git_identity::detail::extended(path).c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};
        if(file.get()==INVALID_HANDLE_VALUE||GetFileType(file.get())!=FILE_TYPE_DISK||!GetFileInformationByHandle(file.get(),&info)||(info.dwFileAttributes&(git_identity::detail::unsafe_attributes|FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_HIDDEN|FILE_ATTRIBUTE_SYSTEM))||info.nNumberOfLinks!=1)throw std::runtime_error("The selected project file is linked or unavailable");
        if(!git_identity::detail::equal_path(git_identity::detail::physical_name(file.get()).wstring(),path.wstring()))throw std::runtime_error("The project file changed its physical location");return file;
    }
};
} // namespace coincide
