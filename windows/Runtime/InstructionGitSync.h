#pragma once
#include "InstructionService.h"
#include "CodeHosting.h"
#include "HostIPCScope.h"
#include "GitRepositoryIdentity.h"
#include <winrt/Windows.Data.Json.h>
#include <fstream>
#include <regex>

namespace coincide::instruction_git {
using Object=winrt::Windows::Data::Json::JsonObject;using Array=winrt::Windows::Data::Json::JsonArray;using Value=winrt::Windows::Data::Json::JsonValue;
using Cancel=code_hosting::Cancel;
inline std::string narrow(const std::filesystem::path& value){return winrt::to_string(value.wstring());}
inline std::wstring wide(std::string_view value){return std::wstring(winrt::to_hstring(value));}
inline std::string trim(std::string value){while(!value.empty()&&(value.back()=='\r'||value.back()=='\n'))value.pop_back();return value;}
inline bool oid(std::string_view value){return(value.size()==40||value.size()==64)&&value.find_first_not_of("0123456789abcdef")==std::string_view::npos;}
inline bool digest(std::string_view value){return value.empty()||(value.size()==64&&value.find_first_not_of("0123456789abcdef")==std::string_view::npos);}
inline bool token(std::string_view value){return code_hosting::token(value,128);}
inline bool copy_name(std::string_view value){if(!token(value)||!value.ends_with(".md")||value.front()=='.')return false;try{git_identity::detail::component(wide(value));return true;}catch(...){return false;}}
inline bool remote_address(std::string_view value){
    if(value.empty()||value.size()>4096||value.find_first_of("\r\n\t\0",0,4)!=std::string_view::npos)return false;
    try{const std::filesystem::path path(wide(value));if(local_file::local_path(path))return path==path.lexically_normal()&&!local_file::has_reparse(path)&&value.find(':',2)==std::string_view::npos;}catch(...){return false;}
    if(value.find_first_of(" ?#\\")!=std::string_view::npos)return false;
    if(value.starts_with("https://")){const auto slash=value.find('/',8);return slash!=std::string_view::npos&&slash>8&&value.find('@')==std::string_view::npos&&value.substr(8,slash-8).find(':')==std::string_view::npos;}
    if(value.starts_with("ssh://git@")){const auto slash=value.find('/',10);return slash!=std::string_view::npos&&slash>10&&value.find('@',10)==std::string_view::npos;}
    if(value.starts_with("git@")){const auto colon=value.find(':',4);return colon!=std::string_view::npos&&colon>4&&value.find('@',4)==std::string_view::npos;}
    // Local bare remotes are useful for offline work and deterministic fixtures.
    return false;
}
inline bool suspected_secret(std::string_view text){
    static const std::regex pattern(R"((sk-(proj-|ant-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{24,}|AKIA[0-9A-Z]{16}|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----))");
    return std::regex_search(text.begin(),text.end(),pattern);
}
enum class CopyStep {in_step,update_copy,update_source,conflict};
inline CopyStep copy_step(const std::optional<std::string>& source,const std::optional<std::string>& copy,const std::string& agreed){
    if(!source)return copy?CopyStep::update_source:CopyStep::in_step;if(!copy)return CopyStep::update_copy;
    if(*source==*copy)return CopyStep::in_step;if(!agreed.empty()&&local_file::sha256(*copy)==agreed)return CopyStep::update_copy;
    if(!agreed.empty()&&local_file::sha256(*source)==agreed)return CopyStep::update_source;return CopyStep::conflict;
}
struct Binding {
    std::string id{background_host::new_guid()},copy{"Global.md"},agreed,remote{"origin"};
    InstructionFile source;std::filesystem::path repository;
    bool automatic{},push_automatically{},paused{};std::string review;
};
inline void validate(const Binding& value){
    background_host::guid(value.id);if(!copy_name(value.copy)||!token(value.remote)||!digest(value.agreed)||value.review.size()>1024)
        throw std::invalid_argument("Invalid instruction synchronization settings");
    for(const auto& path:{value.repository,value.source.path,value.source.resolved,value.source.scope_root})
        if(!local_file::local_path(path)||path!=path.lexically_normal())throw std::invalid_argument("Instruction synchronization requires literal local paths");
    if(!value.source.global_master.empty()&&!local_file::local_path(value.source.global_master))throw std::invalid_argument("Invalid instruction master location");
    if(local_file::equal_path(value.source.resolved.wstring(),(value.repository/wide(value.copy)).wstring()))throw std::invalid_argument("Keep the local master and its Git copy as separate files");
}
namespace files {
using Handle=background_host::Handle;
struct Pins {std::vector<Handle> handles;explicit Pins(const std::filesystem::path& path,bool create=false){
    if(!local_file::local_path(path)||path!=path.lexically_normal())throw std::invalid_argument("Choose a literal local synchronization folder");
    auto part=path.root_path();const auto pin=[&](const auto& folder){Handle handle(CreateFileW(folder.c_str(),FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};if(!handle||!GetFileInformationByHandle(handle.value,&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE)))throw std::runtime_error("A synchronization folder is linked or unavailable");handles.push_back(std::move(handle));};pin(part);
    for(const auto& item:path.relative_path()){part/=item;if(create&&!CreateDirectoryW(part.c_str(),nullptr)&&GetLastError()!=ERROR_ALREADY_EXISTS)throw std::runtime_error("Could not prepare synchronization settings");pin(part);}
}};
struct Snapshot {bool exists{};std::filesystem::path resolved;std::string bytes,hash,identity;};
inline Snapshot read(const std::filesystem::path& path,bool allow_link=false,const std::filesystem::path& expected={},std::size_t maximum=1024*1024){
    Snapshot result;const auto attributes=GetFileAttributesW(path.c_str());if(attributes==INVALID_FILE_ATTRIBUTES){const auto error=GetLastError();if(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND){result.resolved=path;return result;}throw std::runtime_error("The synchronized instruction file is unavailable");}
    const auto snapshot=local_file::read(path,maximum,allow_link,false,expected);if(!local_file::utf8(snapshot.bytes)||snapshot.bytes.find('\0')!=std::string::npos)throw std::runtime_error("Synchronized instructions need bounded UTF-8 text");
    Handle handle(CreateFileW(snapshot.resolved.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};
    if(!handle||!GetFileInformationByHandle(handle.value,&info)||info.nNumberOfLinks!=1||(info.dwFileAttributes&FILE_ATTRIBUTE_REPARSE_POINT))throw std::runtime_error("Synchronized instructions cannot be hardlinked or replaced during review");
    result.exists=true;result.resolved=snapshot.resolved;result.bytes=snapshot.bytes;result.hash=snapshot.digest;
    result.identity=std::to_string(info.dwVolumeSerialNumber)+":"+std::to_string(info.nFileIndexHigh)+":"+std::to_string(info.nFileIndexLow);return result;
}
inline bool same(const Snapshot& a,const Snapshot& b){return a.exists==b.exists&&local_file::equal_path(a.resolved.wstring(),b.resolved.wstring())&&a.hash==b.hash&&a.identity==b.identity;}
inline void create(const std::filesystem::path& path,std::string_view bytes){
    Pins parent(path.parent_path());Handle output(CreateFileW(path.c_str(),GENERIC_WRITE,0,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr));if(!output)throw std::runtime_error("The new instruction file already exists or cannot be created");
    DWORD written{};if(bytes.size()>2*1024*1024||!WriteFile(output.value,bytes.data(),static_cast<DWORD>(bytes.size()),&written,nullptr)||written!=bytes.size()||!FlushFileBuffers(output.value))throw std::runtime_error("The instruction file could not be written completely; preserve it for review");
}
inline void replace_preserving_link(const std::filesystem::path& declared,const Snapshot& expected,std::string_view bytes,const std::filesystem::path& backups){
    if(bytes.size()>1024*1024||!local_file::utf8(bytes)||bytes.find('\0')!=std::string_view::npos)throw std::invalid_argument("Invalid synchronized instruction text");
    const auto current=read(declared,true,expected.resolved);if(!same(current,expected))throw std::runtime_error("Instructions changed after review; nothing was overwritten");
    if(!expected.exists){create(expected.resolved,bytes);return;}
    Pins parent(expected.resolved.parent_path());Handle target(CreateFileW(expected.resolved.c_str(),GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};
    if(!target||!GetFileInformationByHandle(target.value,&info)||info.nNumberOfLinks!=1||(info.dwFileAttributes&(FILE_ATTRIBUTE_DIRECTORY|FILE_ATTRIBUTE_REPARSE_POINT)))throw std::runtime_error("The reviewed instruction target cannot be exclusively opened");
    const auto identity=std::to_string(info.dwVolumeSerialNumber)+":"+std::to_string(info.nFileIndexHigh)+":"+std::to_string(info.nFileIndexLow);
    if(identity!=expected.identity)throw std::runtime_error("The reviewed instruction target was replaced");
    OVERLAPPED range{};if(!LockFileEx(target.value,LOCKFILE_EXCLUSIVE_LOCK|LOCKFILE_FAIL_IMMEDIATELY,0,MAXDWORD,MAXDWORD,&range))throw std::runtime_error("The instruction target is in use; no text was overwritten");
    struct Unlock{HANDLE handle;OVERLAPPED& range;~Unlock(){UnlockFileEx(handle,0,MAXDWORD,MAXDWORD,&range);}}unlock{target.value,range};
    std::string verified(expected.bytes.size()+1,'\0');DWORD copied{};if(!ReadFile(target.value,verified.data(),static_cast<DWORD>(verified.size()),&copied,nullptr))throw std::runtime_error("Could not recheck the reviewed instruction target");verified.resize(copied);
    if(local_file::sha256(verified)!=expected.hash)throw std::runtime_error("Instructions changed after review; nothing was overwritten");
    // Preserve the original leaf and every symlink to its file identity; hardlinks are refused.
    // Keep a durable application-data backup before writing. A failed write attempts full restoration;
    // if storage fails during restoration the backup remains for explicit owner recovery.
    Pins backup_folder(backups,true);const auto backup=backups/(expected.resolved.filename().wstring()+L".coincide-backup-"+wide(background_host::new_guid()));create(backup,expected.bytes);
    const auto write=[&](std::string_view text){DWORD count{};return SetFilePointerEx(target.value,{},nullptr,FILE_BEGIN)&&WriteFile(target.value,text.data(),static_cast<DWORD>(text.size()),&count,nullptr)&&count==text.size()&&SetEndOfFile(target.value)&&FlushFileBuffers(target.value);};
    if(!write(bytes)){const bool restored=write(expected.bytes);throw std::runtime_error(restored?"The instruction update failed; the original was restored and its backup retained":"The instruction update was interrupted; restore the retained application-data backup before continuing");}
}
}
class Store {
    std::filesystem::path directory_;Object original_{nullptr};std::optional<std::string> snapshot_;bool opened_{};
    std::filesystem::path path()const{return directory_/L"instruction-git-sync.json";}
    static std::optional<std::string> read(const std::filesystem::path& path){const auto attributes=GetFileAttributesW(path.c_str());if(attributes==INVALID_FILE_ATTRIBUTES){const auto error=GetLastError();if(error==ERROR_FILE_NOT_FOUND||error==ERROR_PATH_NOT_FOUND)return{};throw std::runtime_error("Instruction sync settings are unavailable");}return files::read(path,false,{},2*1024*1024).bytes;}
    static std::string text(const Object& object,const wchar_t* key,std::string fallback={}){return winrt::to_string(object.GetNamedString(key,winrt::to_hstring(fallback)));}
    static void put(const Object& object,const wchar_t* key,const std::string& value){object.SetNamedValue(key,Value::CreateStringValue(winrt::to_hstring(value)));}
public:
    explicit Store(std::filesystem::path directory):directory_(std::move(directory)){if(!local_file::local_path(directory_))throw std::invalid_argument("Instruction sync settings need a local application folder");}
    void verify_current()const{if(!opened_||read(path())!=snapshot_)throw std::runtime_error("Instruction sync approval/settings changed elsewhere; reopen before continuing");}
    std::vector<Binding> open(){opened_=false;const auto bytes=read(path());Object original;std::vector<Binding> result;std::set<std::string> ids;std::set<std::wstring> sources,copies;
        if(bytes){original=Object::Parse(winrt::to_hstring(*bytes));if(text(original,L"format")!="coincide.windows.instruction-git"||original.GetNamedNumber(L"version")!=1)throw std::runtime_error("Unsupported instruction sync settings; the original was preserved");
            const auto bindings=original.GetNamedArray(L"bindings");if(bindings.Size()>64)throw std::runtime_error("Too many instruction sync bindings");
            for(const auto& raw:bindings){const auto item=raw.GetObject();Binding binding;binding.id=text(item,L"id");binding.repository=wide(text(item,L"repository"));binding.copy=text(item,L"copy");binding.agreed=text(item,L"agreed");binding.remote=text(item,L"remote","origin");binding.source.path=wide(text(item,L"source"));binding.source.resolved=wide(text(item,L"resolved"));binding.source.scope_root=wide(text(item,L"scope"));binding.source.global_master=wide(text(item,L"master"));binding.source.readable=true;binding.source.exists=true;binding.source.linked=item.GetNamedBoolean(L"linked",false);binding.source.protected_master=item.GetNamedBoolean(L"protected",false);binding.automatic=item.GetNamedBoolean(L"automatic",false);binding.push_automatically=item.GetNamedBoolean(L"pushAutomatically",false);binding.paused=item.GetNamedBoolean(L"paused",false);binding.review=text(item,L"review");validate(binding);if(!ids.insert(binding.id).second||!sources.insert(local_file::lower(binding.source.resolved.wstring())).second||!copies.insert(local_file::lower((binding.repository/wide(binding.copy)).wstring())).second)throw std::runtime_error("Repeated instruction source, copy or sync binding");result.push_back(std::move(binding));}
        }original_=original;snapshot_=bytes;opened_=true;return result;
    }
    void save(const std::vector<Binding>& bindings){
        if(!opened_||bindings.size()>64)throw std::runtime_error("Open valid instruction sync settings before editing");files::Pins directory(directory_,true);
        background_host::Handle lock(CreateFileW((directory_/L"instruction-git-sync.lock").c_str(),GENERIC_READ|GENERIC_WRITE,0,nullptr,OPEN_ALWAYS,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));if(!lock)throw std::runtime_error("Instruction sync settings are being changed elsewhere");
        if(read(path())!=snapshot_)throw std::runtime_error("Instruction sync settings changed elsewhere; reopen before saving");auto result=Object::Parse(original_.Stringify());Array previous=result.GetNamedArray(L"bindings",Array{}),all;std::set<std::string> ids;std::set<std::wstring> sources,copies;
        for(const auto& binding:bindings){validate(binding);if(!ids.insert(binding.id).second||!sources.insert(local_file::lower(binding.source.resolved.wstring())).second||!copies.insert(local_file::lower((binding.repository/wide(binding.copy)).wstring())).second)throw std::invalid_argument("Repeated instruction source, copy or sync binding");Object item;
            for(const auto& raw:previous)if(text(raw.GetObject(),L"id")==binding.id){item=Object::Parse(raw.GetObject().Stringify());break;}
            for(const auto& field:{std::pair{L"id",binding.id},{L"repository",narrow(binding.repository)},{L"copy",binding.copy},{L"agreed",binding.agreed},{L"remote",binding.remote},{L"source",narrow(binding.source.path)},{L"resolved",narrow(binding.source.resolved)},{L"scope",narrow(binding.source.scope_root)},{L"master",narrow(binding.source.global_master)},{L"review",binding.review}})put(item,field.first,field.second);
            for(const auto& field:{std::pair{L"linked",binding.source.linked},{L"protected",binding.source.protected_master},{L"automatic",binding.automatic},{L"pushAutomatically",binding.push_automatically},{L"paused",binding.paused}})item.SetNamedValue(field.first,Value::CreateBooleanValue(field.second));all.Append(item);
        }
        put(result,L"format","coincide.windows.instruction-git");result.SetNamedValue(L"version",Value::CreateNumberValue(1));result.SetNamedValue(L"bindings",all);const auto bytes=winrt::to_string(result.Stringify());if(bytes.size()>2*1024*1024)throw std::runtime_error("Instruction sync settings exceed their bound");
        const auto temp=directory_/(L"instruction-git-"+wide(background_host::new_guid())+L".tmp");files::create(temp,bytes);struct Cleanup{std::filesystem::path path;~Cleanup(){DeleteFileW(path.c_str());}}cleanup{temp};
        if(!MoveFileExW(temp.c_str(),path().c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH))throw std::runtime_error("Could not atomically save instruction sync settings");original_=result;snapshot_=bytes;
    }
};
struct Command {code_hosting::Tool tool{code_hosting::Tool::git};std::filesystem::path cwd;std::vector<std::wstring> arguments;std::string input;bool mutation{};std::optional<std::filesystem::path> index;bool isolated_fixture{};};
enum class Failure {none,authentication,network,conflict,identity,unavailable,other};
struct Result {DWORD status{};std::string output;Failure failure{Failure::none};};using Runner=std::function<Result(const Command&,const Cancel&)>;
inline Failure classify_failure(std::string text){for(auto& ch:text)if(ch>='A'&&ch<='Z')ch=static_cast<char>(ch+('a'-'A'));
    for(const auto* item:{"authentication failed","permission denied","could not read username","terminal prompts disabled","access denied","http 401","http 403"})if(text.find(item)!=std::string::npos)return Failure::authentication;
    for(const auto* item:{"could not resolve host","could not resolve hostname","failed to connect","connection timed out","network is unreachable"})if(text.find(item)!=std::string::npos)return Failure::network;
    for(const auto* item:{"non-fast-forward","[rejected]","would be overwritten","unmerged"})if(text.find(item)!=std::string::npos)return Failure::conflict;
    for(const auto* item:{"unable to auto-detect email","please tell me who you are","empty ident"})if(text.find(item)!=std::string::npos)return Failure::identity;
    for(const auto* item:{"not a git repository","repository not found"})if(text.find(item)!=std::string::npos)return Failure::unavailable;return Failure::other;
}
inline std::filesystem::path discover_gh(){
    for(const auto variable:{L"ProgramFiles",L"ProgramFiles(x86)",L"LOCALAPPDATA"}){const auto root=local_file::environment_path(variable,std::filesystem::path{});if(root.empty())continue;const auto candidate=root/(std::wstring_view(variable)==L"LOCALAPPDATA"?L"Programs/GitHub CLI/gh.exe":L"GitHub CLI/gh.exe");if(std::filesystem::is_regular_file(candidate))return candidate;}
    wchar_t raw[32768]{};const auto count=GetEnvironmentVariableW(L"PATH",raw,32768);if(count&&count<32768)for(const auto part:git_parse::split(winrt::to_string(std::wstring_view(raw,count)),';')){auto entry=wide(part);if(entry.size()>1&&entry.front()==L'"'&&entry.back()==L'"')entry=entry.substr(1,entry.size()-2);const auto candidate=std::filesystem::path(entry)/L"gh.exe";if(local_file::local_path(candidate)&&std::filesystem::is_regular_file(candidate))return candidate;}
    throw std::runtime_error("Install GitHub CLI and sign in explicitly before creating a private instruction repository");
}
inline Runner native_runner(){return [](const Command& command,const Cancel& cancel){
    if(command.isolated_fixture){auto relative=command.cwd.lexically_relative(std::filesystem::temp_directory_path());if(command.tool!=code_hosting::Tool::git||relative.empty()||relative.is_absolute()||!relative.begin()->wstring().starts_with(L"Coincide-Instruction-Git-")||!local_file::within(std::filesystem::temp_directory_path(),command.cwd))throw std::runtime_error("Isolated Git configuration requires the exact owned synthetic fixture tree");}
    if(cancel&&cancel())throw std::runtime_error("Instruction sync was cancelled");const auto executable=command.tool==code_hosting::Tool::git?GitService::discover_git():discover_gh();
    std::vector<std::wstring> args;if(command.tool==code_hosting::Tool::git)args={L"--no-pager",L"--literal-pathspecs",L"-c",L"color.ui=false",L"-c",L"core.fsmonitor=false",L"-c",L"core.hooksPath=NUL",L"-c",L"core.autocrlf=false",L"-c",L"commit.gpgsign=false",L"-c",L"credential.interactive=false",L"-c",L"core.askPass="};args.insert(args.end(),command.arguments.begin(),command.arguments.end());
    auto environment=code_hosting::Service::child_environment({command.tool,command.cwd,command.tool==code_hosting::Tool::gh?std::vector<std::wstring>{L"--hostname",L"github.com"}:std::vector<std::wstring>{}, {},0,false});
    if(command.tool==code_hosting::Tool::gh)environment.emplace_back(L"GH_HOST",L"github.com");environment.emplace_back(L"GIT_OPTIONAL_LOCKS",L"0");if(command.index)environment.emplace_back(L"GIT_INDEX_FILE",command.index->wstring());
    if(command.isolated_fixture){environment.emplace_back(L"GIT_CONFIG_GLOBAL",L"NUL");environment.emplace_back(L"GIT_CONFIG_SYSTEM",L"NUL");environment.emplace_back(L"GIT_CONFIG_NOSYSTEM",L"1");for(const auto* key:{L"GIT_AUTHOR_NAME",L"GIT_AUTHOR_EMAIL",L"GIT_COMMITTER_NAME",L"GIT_COMMITTER_EMAIL"})environment.emplace_back(key,std::nullopt);}
    Result result;auto process=WindowsProcess::start_bytes(executable,args,command.cwd,[&](std::string_view bytes){result.output.append(bytes);},2*1024*1024,environment);std::exception_ptr writer_error;
    std::thread writer([&]{try{if(!command.input.empty())process->write_bytes(command.input);process->close_input();}catch(...){writer_error=std::current_exception();}});const auto join=[&]{if(writer.joinable())writer.join();};
    try{const auto end=std::chrono::steady_clock::now()+std::chrono::seconds(command.mutation?120:30);std::optional<WindowsProcess::Exit> exit;
        while(!(exit=process->wait(std::chrono::milliseconds(25))))if((cancel&&cancel())||std::chrono::steady_clock::now()>end){process->stop();join();throw std::runtime_error(command.mutation?"Instruction Git action was interrupted; refresh its actual state before retrying":"Instruction Git check was cancelled or timed out");}
        join();if(writer_error||exit->stdout_truncated||!exit->channel_error.empty())throw std::runtime_error("Instruction Git output could not be bounded or confirmed; refresh before retrying");result.status=exit->status;if(result.status)result.failure=classify_failure(exit->stderr_tail);return result;
    }catch(...){process->stop();join();throw;}
};}
struct Status {GitStatus git;files::Snapshot source,copy;CopyStep step{CopyStep::conflict};std::string upstream_oid,remote_fingerprint;std::vector<std::string> outgoing,remote_changes,remote_addresses,allowed_files;bool conflict{},can_push{},normalize_newlines{};std::shared_ptr<const git_identity::Identity> identity;};
enum class Action {attach,setup,use_source,use_copy,commit,fetch,pull,push,unlink,enable_automatic,disable_automatic};
enum class SetupKind {local,clone,private_github};
struct Review {std::string id,binding_id,title,detail,preview;Action action{};Status before;Binding binding;bool automatic_push{};SetupKind setup{SetupKind::local};std::string address;};
struct Outcome {bool changed{},review{};std::string message;};
class Service {
    Store store_;std::filesystem::path backups_;Runner runner_;std::vector<Binding> bindings_;bool loaded_{};std::map<std::string,std::shared_ptr<const Review>> reviews_;std::map<std::string,std::uint64_t> last_check_,last_fetch_;mutable std::recursive_mutex gate_;
    Result run(const Binding& binding,std::vector<std::wstring> args,bool mutation=false,const Cancel& cancel={},bool failure=false,std::string input={},std::optional<std::filesystem::path> index={})const{
        if(cancel&&cancel())throw std::runtime_error("Instruction synchronization was cancelled");const auto result=runner_({code_hosting::Tool::git,binding.repository,std::move(args),std::move(input),mutation,std::move(index)},cancel);
        if(result.output.size()>2*1024*1024)throw std::runtime_error("Instruction Git output exceeds its bound");if(result.status&&!failure){switch(result.failure){
            case Failure::authentication:throw std::runtime_error("Git authentication or repository access was denied. Sign in with the existing CLI outside this action; no credentials were requested.");
            case Failure::network:throw std::runtime_error("Git could not reach the configured remote. Existing instructions and local work were retained.");
            case Failure::conflict:throw std::runtime_error("Git refused a conflict or non-fast-forward update. Review the repository manually; no force, reset or rebase was performed.");
            case Failure::identity:throw std::runtime_error("Configure a Git author name and email before committing instructions. Existing work was retained.");
            case Failure::unavailable:throw std::runtime_error("The instruction repository is unavailable or inaccessible; verify its folder and remote access.");
            default:throw std::runtime_error("Git could not complete the instruction action. Check repository, identity, authentication, network and conflicts; no credentials were requested.");}}return result;
    }
    Binding& binding(const std::string& id){auto at=std::find_if(bindings_.begin(),bindings_.end(),[&](const auto& value){return value.id==id;});if(at==bindings_.end())throw std::runtime_error("This instruction Git link no longer exists");return*at;}
    void loaded(){if(!loaded_){bindings_=store_.open();loaded_=true;}}
    void persist(std::vector<Binding> next){store_.save(next);bindings_.swap(next);}
    static std::vector<std::string> zero_paths(std::string_view bytes){std::set<std::string> unique;for(const auto item:git_parse::split(bytes,'\0'))if(!item.empty())unique.emplace(item);if(unique.size()>10000)throw std::runtime_error("Too many outgoing instruction Git paths");return {unique.begin(),unique.end()};}
    static bool snapshot_equal(const Status& a,const Status& b){
        if(!a.identity||!b.identity||a.identity->root_id!=b.identity->root_id||a.identity->git_id!=b.identity->git_id||a.identity->common_id!=b.identity->common_id||a.normalize_newlines!=b.normalize_newlines||!files::same(a.source,b.source)||!files::same(a.copy,b.copy)||a.git.head!=b.git.head||a.git.branch!=b.git.branch||a.git.upstream!=b.git.upstream||a.upstream_oid!=b.upstream_oid||a.remote_fingerprint!=b.remote_fingerprint||a.git.files.size()!=b.git.files.size())return false;
        for(std::size_t i=0;i<a.git.files.size();++i){const auto& x=a.git.files[i];const auto& y=b.git.files[i];if(x.path!=y.path||x.index_status!=y.index_status||x.worktree_status!=y.worktree_status||x.original_path!=y.original_path)return false;}return a.outgoing==b.outgoing&&a.allowed_files==b.allowed_files;
    }
    std::shared_ptr<const Review> issue(Review value){reviews_.clear();value.id=background_host::new_guid();auto result=std::make_shared<const Review>(std::move(value));reviews_.emplace(result->id,result);return result;}
    std::string commit_copy(const Binding& selected,const Status& before,const Cancel& cancel){
        if(!before.copy.exists||suspected_secret(before.copy.bytes))throw std::runtime_error("Review instructions for credential material before committing or pushing");
        const auto temporary=selected.repository/(L".coincide-instruction-index-"+wide(background_host::new_guid()));struct Cleanup{std::filesystem::path value;~Cleanup(){DeleteFileW(value.c_str());DeleteFileW((value.wstring()+L".lock").c_str());}}cleanup{temporary};
        const auto git=[&](std::vector<std::wstring> args,std::string input={}){return run(selected,std::move(args),true,cancel,false,std::move(input),temporary);};
        git(before.git.head.empty()?std::vector<std::wstring>{L"read-tree",L"--empty"}:std::vector<std::wstring>{L"read-tree",wide(before.git.head)});
        auto bytes=before.copy.bytes;if(before.normalize_newlines){std::string normalized;normalized.reserve(bytes.size());for(std::size_t i=0;i<bytes.size();++i){if(bytes[i]=='\r'&&i+1<bytes.size()&&bytes[i+1]=='\n')continue;normalized+=bytes[i];}bytes.swap(normalized);}
        const auto blob=trim(git({L"hash-object",L"-w",L"--stdin",L"--no-filters"},std::move(bytes)).output);if(!oid(blob))throw std::runtime_error("Git returned an invalid instruction blob");
        git({L"update-index",L"--add",L"--cacheinfo",L"100644",wide(blob),wide(selected.copy)});const auto tree=trim(git({L"write-tree"}).output);if(!oid(tree))throw std::runtime_error("Git returned an invalid instruction tree");
        if(!before.git.head.empty()&&trim(run(selected,{L"rev-parse",L"--verify",wide(before.git.head+"^{tree}")}).output)==tree)return before.git.head;
        std::vector<std::wstring> args{L"commit-tree",wide(tree)};if(!before.git.head.empty())args.insert(args.end(),{L"-p",wide(before.git.head)});args.insert(args.end(),{L"-F",L"-"});
        const auto commit=trim(git(std::move(args),"Update "+selected.copy+"\n").output);if(!oid(commit))throw std::runtime_error("Git returned an invalid instruction commit");
        run(selected,{L"update-ref",L"--no-deref",wide("refs/heads/"+before.git.branch),wide(commit),wide(before.git.head.empty()?std::string(commit.size(),'0'):before.git.head)},true,cancel);
        // Preserve every unrelated staged entry. Only this already committed copy is moved
        // to its new blob in the real index. No clean filters, hooks, reset or rebase run.
        run(selected,{L"update-index",L"--add",L"--cacheinfo",L"100644",wide(blob),wide(selected.copy)},true,cancel);return commit;
    }
public:
    explicit Service(std::filesystem::path data_directory,Runner runner={}):store_(data_directory),backups_(std::move(data_directory)/L"instruction-backups"),runner_(runner?std::move(runner):native_runner()){}
    std::vector<Binding> bindings(){std::lock_guard lock(gate_);loaded();return bindings_;}
    void reload(){std::lock_guard lock(gate_);auto next=store_.open();bindings_.swap(next);loaded_=true;reviews_.clear();}
    void discard(const std::shared_ptr<const Review>& review){std::lock_guard lock(gate_);if(!review)return;const auto at=reviews_.find(review->id);if(at!=reviews_.end()&&at->second==review)reviews_.erase(at);}
    void discard_all(){std::lock_guard lock(gate_);reviews_.clear();}
    Status status(const Binding& selected,const Cancel& cancel={})const{
        std::lock_guard lock(gate_);validate(selected);files::Pins repo(selected.repository);Status result;const auto git=[&](std::vector<std::wstring> args,bool failure=false){return run(selected,std::move(args),false,cancel,failure);};const auto identity=git_identity::lookup(selected.repository);if(identity.state!=git_identity::State::ready||!identity.value||!local_file::equal_path(identity.value->root.wstring(),selected.repository.wstring()))throw std::runtime_error("Choose the top folder of an available instruction Git worktree");result.identity=identity.value;
        auto source=selected.source;source.exists=std::filesystem::is_regular_file(source.path);if(source.exists)static_cast<void>(InstructionService::read(source));
        result.source=files::read(source.path,true,source.resolved);result.copy=files::read(selected.repository/wide(selected.copy));
        if(!local_file::equal_path(result.source.resolved.wstring(),selected.source.resolved.wstring()))throw std::runtime_error("The instruction link target changed; relink it explicitly before syncing");
        if(result.copy.exists&&result.copy.resolved.filename().wstring()!=wide(selected.copy))throw std::runtime_error("Use the existing instruction Git copy's exact filename case before linking or syncing");
        const auto root=trim(git({L"rev-parse",L"--show-toplevel"}).output);
        if(!local_file::equal_path(std::filesystem::path(wide(root)).lexically_normal().wstring(),selected.repository.wstring()))throw std::runtime_error("Choose the top folder of an existing Git worktree");
        for(const auto& path:zero_paths(git({L"ls-files",L"-z"}).output))if(path!=selected.copy&&local_file::equal_path(wide(path),wide(selected.copy)))throw std::runtime_error("A tracked instruction path has another filename case; preserve that exact Git path before syncing");
        const auto attribute_bytes=git({L"check-attr",L"-z",L"filter",L"working-tree-encoding",L"text",L"eol",L"--",wide(selected.copy)}).output;const auto attrs=git_parse::split(attribute_bytes,'\0');
        constexpr std::string_view names[]{"filter","working-tree-encoding","text","eol"};if(attrs.size()!=13||!attrs.back().empty())throw std::runtime_error("Git instruction attributes could not be verified");
        std::string text_attribute,eol_attribute;for(std::size_t i=0;i<12;i+=3){if(attrs[i]!=selected.copy||attrs[i+1]!=names[i/3]||attrs[i+2].size()>1024)throw std::runtime_error("Git returned unexpected instruction attribute metadata");const auto name=attrs[i+1],value=attrs[i+2];
            if((name=="filter"||name=="working-tree-encoding")&&value!="unspecified"&&value!="unset")throw std::runtime_error("This instruction copy uses a custom Git filter or encoding. Preserve it through Git outside this synchronization workflow.");if(name=="text")text_attribute=value;if(name=="eol")eol_attribute=value;
        }result.normalize_newlines=text_attribute!="unset"&&(text_attribute=="set"||text_attribute=="auto"||eol_attribute=="lf"||eol_attribute=="crlf");
        result.git=git_parse::status(git({L"status",L"--porcelain=v2",L"--branch",L"-z",L"--untracked-files=all"}).output);result.git.root=root;
        if(result.git.head=="(initial)")result.git.head.clear();if(result.git.branch.empty()||result.git.branch=="(detached)"||(!result.git.head.empty()&&!oid(result.git.head)))throw std::runtime_error("Choose an attached instruction branch before syncing");
        if(git({L"check-ref-format",L"--branch",wide(result.git.branch)},true).status)throw std::runtime_error("The instruction branch is invalid");
        for(const auto& file:result.git.files)if(file.conflicted)result.conflict=true;
        for(const auto* marker:{L"MERGE_HEAD",L"CHERRY_PICK_HEAD",L"REVERT_HEAD",L"rebase-merge",L"rebase-apply"}){const auto path=trim(git({L"rev-parse",L"--git-path",marker}).output);if(std::filesystem::exists(std::filesystem::path(wide(path)).is_absolute()?std::filesystem::path(wide(path)):selected.repository/wide(path)))result.conflict=true;}
        const auto remotes=git({L"remote"}).output;bool found{};for(const auto remote:git_parse::split(remotes,'\n'))if(trim(std::string(remote))==selected.remote)found=true;
        if(found){std::string references;std::vector<std::string> fetch_urls,push_urls;
            for(const auto push:{false,true}){std::vector<std::wstring> args{L"remote",L"get-url",L"--all"};if(push)args.push_back(L"--push");args.push_back(wide(selected.remote));const auto urls=git(std::move(args)).output;
                for(const auto raw:git_parse::split(urls,'\n'))if(!trim(std::string(raw)).empty()){const auto url=trim(std::string(raw));if(!remote_address(url))throw std::runtime_error("Instruction remote contains credentials, an unsupported transport, or an unsafe address; edit it outside Coincide");result.remote_addresses.push_back(url);(push?push_urls:fetch_urls).push_back(url);}references+=urls;}
            if(fetch_urls.size()!=1||push_urls!=fetch_urls)throw std::runtime_error("Instruction sync requires one identical fetch and push destination; review multiple or separate push URLs outside Coincide");
            result.remote_fingerprint=local_file::sha256(references);
        }
        if(!result.git.upstream.empty()){
            if(!result.git.upstream.starts_with(selected.remote+"/"))throw std::runtime_error("The tracked upstream belongs to another remote; choose a matching instruction remote before syncing");
            result.upstream_oid=trim(git({L"rev-parse",L"--verify",L"--end-of-options",wide(result.git.upstream+"^{commit}")}).output);if(!oid(result.upstream_oid))throw std::runtime_error("The instruction upstream cannot be verified");
            result.remote_changes=zero_paths(git({L"diff",L"--name-only",L"-z",wide(result.git.head.empty()?result.upstream_oid:result.git.head),wide(result.upstream_oid),L"--"}).output);
        }
        if(!result.git.head.empty()){
            std::vector<std::wstring> history{L"log",L"--format=",L"--name-only",L"-z"};if(result.upstream_oid.empty())history.insert(history.end(),{L"HEAD",L"--not",L"--remotes"});else history.push_back(wide(result.upstream_oid+"..HEAD"));history.push_back(L"--");
            result.outgoing=zero_paths(git(std::move(history)).output);
        }
        std::set<std::string> allowed{selected.copy};for(const auto& linked:bindings_)if(local_file::equal_path(linked.repository.wstring(),selected.repository.wstring()))allowed.insert(linked.copy);result.allowed_files.assign(allowed.begin(),allowed.end());
        result.can_push=!result.remote_fingerprint.empty()&&!result.outgoing.empty()&&std::all_of(result.outgoing.begin(),result.outgoing.end(),[&](const auto& file){return allowed.contains(file);});
        result.step=copy_step(result.source.exists?std::optional{result.source.bytes}:std::nullopt,result.copy.exists?std::optional{result.copy.bytes}:std::nullopt,selected.agreed);return result;
    }
    Status status(const std::string& id,const Cancel& cancel={}){std::lock_guard lock(gate_);loaded();return status(binding(id),cancel);}
    std::shared_ptr<const Review> setup(InstructionFile source,const std::filesystem::path& destination,std::string copy,SetupKind kind,std::string address={}){
        std::lock_guard lock(gate_);loaded();static_cast<void>(InstructionService::read(source));Binding selected;selected.source=std::move(source);selected.repository=destination.lexically_normal();selected.copy=std::move(copy);validate(selected);
        if(bindings_.size()>=64)throw std::runtime_error("Keep at most 64 instruction Git links");for(const auto& value:bindings_)if(local_file::equal_path(value.source.resolved.wstring(),selected.source.resolved.wstring())||local_file::equal_path((value.repository/wide(value.copy)).wstring(),(selected.repository/wide(selected.copy)).wstring()))throw std::runtime_error("This instruction source or Git copy is already linked");
        files::Pins parent(destination.parent_path());if(std::filesystem::exists(destination)&&(!std::filesystem::is_directory(destination)||!std::filesystem::is_empty(destination)||local_file::has_reparse(destination)))throw std::runtime_error("Choose a new or empty local folder; existing work is never cleared");
        if(kind==SetupKind::clone&&!remote_address(address))throw std::invalid_argument("Use an existing HTTPS, git SSH, or local repository address without credentials");
        if(kind==SetupKind::private_github){const auto slash=address.find('/');if(slash==std::string::npos||!token(address.substr(0,slash))||!token(address.substr(slash+1)))throw std::invalid_argument("Enter the explicit GitHub owner/name without credentials; no default owner is selected");}
        Review review;review.action=Action::setup;review.binding_id=selected.id;review.binding=std::move(selected);review.setup=kind;review.address=std::move(address);review.before.source=files::read(review.binding.source.path,true,review.binding.source.resolved);review.preview=review.before.source.bytes;
        if(suspected_secret(review.preview))throw std::runtime_error("Review instructions for credential material before creating a Git copy");
        review.title=kind==SetupKind::clone?"Clone an instruction repository":kind==SetupKind::private_github?"Create a private GitHub instruction repository":"Create a local instruction repository";
        review.detail="Destination: "+narrow(destination)+"\nThe original instructions and their links remain in place. ";
        review.detail+=kind==SetupKind::clone?"Clones the reviewed repository and links its copy for a separate text review.":kind==SetupKind::private_github?"Creates a local instruction-only commit and a PRIVATE GitHub repository. Push is a separate explicit action.":"Creates a local repository and commits only the reviewed instruction copy. No remote is contacted.";
        if(!review.address.empty())review.detail+="\n"+review.address;return issue(std::move(review));
    }
    std::shared_ptr<const Review> attach(InstructionFile source,const std::filesystem::path& repository,std::string copy,const Cancel& cancel={}){
        std::lock_guard lock(gate_);loaded();static_cast<void>(InstructionService::read(source));Binding selected;selected.source=std::move(source);selected.repository=std::filesystem::canonical(repository);selected.copy=std::move(copy);validate(selected);
        if(bindings_.size()>=64)throw std::runtime_error("Keep at most 64 instruction Git links");for(const auto& value:bindings_)if(local_file::equal_path(value.source.resolved.wstring(),selected.source.resolved.wstring())||local_file::equal_path((value.repository/wide(value.copy)).wstring(),(selected.repository/wide(selected.copy)).wstring()))throw std::runtime_error("This instruction source or Git copy is already linked");
        auto snapshot=status(selected,cancel);return issue({{},selected.id,"Link instruction Git copy","Saves this explicit link only. Source, links and repository files stay in place.",snapshot.source.bytes,Action::attach,std::move(snapshot),std::move(selected),false});
    }
    std::shared_ptr<const Review> preview(const std::string& id,Action action,bool automatic_push=false,const Cancel& cancel={}){
        std::lock_guard lock(gate_);loaded();const auto selected=binding(id);Review result;result.binding_id=id;result.action=action;result.binding=selected;result.automatic_push=automatic_push;
        if(action==Action::unlink||action==Action::disable_automatic){result.title=action==Action::unlink?"Unlink instruction Git copy":"Pause automatic instruction-copy sync";result.detail="Changes synchronization settings only. All instruction files, links, backups and repositories are retained; unavailable folders do not prevent this action.";return issue(std::move(result));}
        result.before=status(selected,cancel);
        if(result.before.conflict&&action!=Action::unlink&&action!=Action::disable_automatic)throw std::runtime_error("Finish the repository conflict before instruction sync; no reset, stash or rebase is performed");
        switch(action){
            case Action::use_source:if(!result.before.source.exists)throw std::runtime_error("The instruction source is missing; review the Git copy instead");result.title="Replace Git copy with local instructions";result.preview=result.before.source.bytes;result.detail="Writes only "+selected.copy+". Existing copy text gets an application-data backup; the master and its links stay in place.\nBackup folder: "+narrow(backups_);break;
            case Action::use_copy:if(!result.before.copy.exists)throw std::runtime_error("The instruction Git copy is missing");result.title="Replace local instructions with Git copy";result.preview=result.before.copy.bytes;result.detail="Updates the resolved master in place and retains an application-data backup. This changes the instructions read by its linked agents.\nBackup folder: "+narrow(backups_);break;
            case Action::commit:if(!result.before.copy.exists)throw std::runtime_error("Create the instruction Git copy first");result.title="Commit instruction copy only";result.preview=result.before.copy.bytes;result.detail="Creates an isolated commit for "+selected.copy+". Other staged and unstaged files are excluded.";break;
            case Action::fetch:if(result.before.remote_fingerprint.empty())throw std::runtime_error("This instruction repository has no selected remote; commits remain local");result.title="Fetch instruction remote";result.detail="Contacts the configured "+selected.remote+" remote and updates remote references. No master or working file is overwritten.";break;
            case Action::pull:if(result.before.git.upstream.empty())throw std::runtime_error("Set an upstream branch before pulling instructions");if(result.before.git.ahead&&result.before.git.behind)throw std::runtime_error("Local and remote instruction history diverged; review it in Git without an automatic rebase");if(!result.before.git.files.empty())throw std::runtime_error("Commit or preserve working changes before a fast-forward pull");result.title="Fast-forward instruction repository";result.detail="Moves this branch to reviewed commit "+result.before.upstream_oid+". The local master remains unchanged until a separate explicit approval.";for(const auto& path:result.before.remote_changes)result.preview+=path+"\n";break;
            case Action::push:if(!result.before.can_push)throw std::runtime_error("Push requires a remote and outgoing commits touching only configured instruction copies; other history is never pushed");if(result.before.git.behind)throw std::runtime_error("Fetch and resolve the newer upstream before pushing instructions");result.title="Push instruction commits";result.detail="Pushes only reviewed instruction-copy commits to "+selected.remote+" without force or tags. Instructions leave this computer; keep credentials out.";result.preview=result.before.copy.bytes;for(const auto& address:result.before.remote_addresses)result.detail+="\n"+address;for(const auto& path:result.before.outgoing)result.detail+="\nInstruction copy: "+path;break;
            case Action::unlink:result.title="Unlink instruction Git copy";result.detail="Removes this sync setting. The master, links, repository, backups and Git copy remain on disk.";break;
            case Action::enable_automatic:result.title="Enable automatic instruction-copy sync";result.detail="Checks each minute; fetches at most every five minutes. Local changes may update and commit the Git copy"+std::string(automatic_push?" and push instruction-only history":"; pushes stay manual")+". Incoming changes pause for explicit approval before changing the local master. Conflicts pause synchronization.";break;
            case Action::disable_automatic:result.title="Pause automatic instruction-copy sync";result.detail="Keeps all files and commits in place; no pending work is replayed.";break;
            default:throw std::invalid_argument("Use explicit attach for a new instruction Git link");
        }return issue(std::move(result));
    }
    Outcome apply(const std::shared_ptr<const Review>& reviewed,const Cancel& cancel={}){
        std::lock_guard lock(gate_);loaded();if(!reviewed)throw std::runtime_error("Review an instruction action before approving it");const auto at=reviews_.find(reviewed->id);if(at==reviews_.end()||at->second!=reviewed)throw std::runtime_error("This instruction confirmation expired or was already used");auto plan=at->second;reviews_.erase(at);store_.verify_current();if(cancel&&cancel())throw std::runtime_error("Instruction synchronization was cancelled before dispatch");
        if(plan->action==Action::setup){
            const auto& selected=plan->binding;files::Pins parent(selected.repository.parent_path());const auto current=files::read(selected.source.path,true,selected.source.resolved);
            if(!files::same(current,plan->before.source)||suspected_secret(current.bytes))throw std::runtime_error("Instructions changed after setup review; preview again");
            if(std::filesystem::exists(selected.repository)){if(!std::filesystem::is_directory(selected.repository)||!std::filesystem::is_empty(selected.repository)||local_file::has_reparse(selected.repository))throw std::runtime_error("The setup destination changed; existing files were preserved");}
            else if(!CreateDirectoryW(selected.repository.c_str(),nullptr))throw std::runtime_error("Could not create the reviewed instruction repository folder");
            files::Pins destination(selected.repository);
            if(plan->setup==SetupKind::clone)run(selected,{L"clone",L"--no-hardlinks",L"--no-recurse-submodules",L"--template=",L"--",wide(plan->address),L"."},true,cancel);
            else{run(selected,{L"init",L"--initial-branch=main",L"--template=",L"--",L"."},true,cancel);files::create(selected.repository/wide(selected.copy),current.bytes);const auto before=status(selected,cancel);static_cast<void>(commit_copy(selected,before,cancel));}
            if(plan->setup==SetupKind::private_github){const auto auth=runner_({code_hosting::Tool::gh,selected.repository,{L"auth",L"status",L"--hostname",L"github.com"},{},false,{}},cancel);if(auth.status)throw std::runtime_error("GitHub CLI authentication is unavailable. Sign in explicitly with the existing CLI; the local instruction repository was retained and nothing was pushed.");
                const auto reply=runner_({code_hosting::Tool::gh,selected.repository,{L"repo",L"create",wide(plan->address),L"--private",L"--source",selected.repository.wstring(),L"--remote",L"origin"},{},true,{}},cancel);if(reply.status)throw std::runtime_error("Private GitHub creation was not confirmed. The local repository was retained; review GitHub and its remote before retrying.");
                const auto verify=runner_({code_hosting::Tool::gh,selected.repository,{L"repo",L"view",L"--json",L"isPrivate,nameWithOwner"},{},false,{}},cancel);Object metadata{nullptr};if(verify.status||verify.output.size()>65536||!Object::TryParse(winrt::to_hstring(verify.output),metadata)||!metadata.GetNamedBoolean(L"isPrivate",false))throw std::runtime_error("GitHub repository privacy could not be verified; no instructions were pushed. Review the retained repository before retrying.");
                const auto actual=winrt::to_string(metadata.GetNamedString(L"nameWithOwner",L""));if(!local_file::equal_path(wide(actual),wide(plan->address)))throw std::runtime_error("The created GitHub repository identity did not match the reviewed owner/name; nothing was pushed");}
            auto linked=selected;const auto after=status(linked,cancel);if(after.source.exists&&after.copy.exists&&after.source.bytes==after.copy.bytes)linked.agreed=after.source.hash;auto next=bindings_;next.push_back(std::move(linked));persist(std::move(next));return {true,false,"Instruction repository prepared and linked. Original instructions and links were preserved; review synchronization before pushing."};
        }
        if(plan->action==Action::unlink||plan->action==Action::disable_automatic){auto next=bindings_;if(plan->action==Action::unlink)next.erase(std::remove_if(next.begin(),next.end(),[&](const auto& value){return value.id==plan->binding_id;}),next.end());else for(auto& value:next)if(value.id==plan->binding_id){value.automatic=false;value.paused=true;value.review="Automatic synchronization was paused explicitly.";}persist(std::move(next));return {true,false,"Instruction synchronization settings changed. Existing source, links and Git files were retained."};}
        auto selected=plan->action==Action::attach?plan->binding:binding(plan->binding_id);const auto current=status(selected,cancel);if(!snapshot_equal(current,plan->before))throw std::runtime_error("Instruction source, Git copy, branch or remote changed after review; preview it again");
        auto next=bindings_;const auto replace=[&](const Binding& value){for(auto& old:next)if(old.id==value.id){old=value;return;}next.push_back(value);};bool changed{};
        switch(plan->action){
            case Action::setup:throw std::logic_error("Instruction setup must use its explicit reviewed path");
            case Action::attach:if(next.size()>=64)throw std::runtime_error("Keep at most 64 instruction Git links");if(current.source.exists&&current.copy.exists&&current.source.bytes==current.copy.bytes)selected.agreed=current.source.hash;replace(selected);persist(std::move(next));return {true,false,"Instruction Git copy linked. Review a copy or commit action to synchronize its contents."};
            case Action::use_source:if(suspected_secret(current.source.bytes))throw std::runtime_error("Review instructions for credential material before creating a Git copy");changed=!current.copy.exists||current.copy.bytes!=current.source.bytes;if(changed)files::replace_preserving_link(selected.repository/wide(selected.copy),current.copy,current.source.bytes,backups_);selected.agreed=current.source.hash;break;
            case Action::use_copy:changed=!current.source.exists||current.source.bytes!=current.copy.bytes;if(changed)files::replace_preserving_link(selected.source.path,current.source,current.copy.bytes,backups_);selected.agreed=current.copy.hash;break;
            case Action::commit:{const auto commit=commit_copy(selected,current,cancel);const bool created=commit!=current.git.head;return {created,false,created?"Instruction copy committed. Other staged files were preserved; pushing remains separate.":"No instruction-copy changes to commit. Other staged files were preserved."};}
            case Action::fetch:run(selected,{L"-c",L"fetch.prune=false",L"fetch",L"--no-tags",L"--no-recurse-submodules",L"--no-write-fetch-head",L"--",wide(selected.remote),wide("refs/heads/*:refs/remotes/"+selected.remote+"/*")},true,cancel);return {true,false,"Remote references fetched. Preview a fast-forward pull before changing working files."};
            case Action::pull:if(!current.git.behind)return {false,false,"Instruction repository is already up to date; the local master was unchanged."};run(selected,{L"merge",L"--ff-only",L"--no-edit",L"--no-stat",wide(current.upstream_oid)},true,cancel);return {true,false,"Instruction repository fast-forwarded. Review incoming instruction text before applying it to the local master."};
            case Action::push:{
                std::vector<std::wstring> args{L"log",L"--format=",L"--patch",L"--no-ext-diff",L"--no-textconv"};if(current.upstream_oid.empty())args.insert(args.end(),{L"HEAD",L"--not",L"--remotes"});else args.push_back(wide(current.upstream_oid+"..HEAD"));args.push_back(L"--");
                if(suspected_secret(run(selected,std::move(args)).output))throw std::runtime_error("Outgoing instruction history contains possible credential material; it was not pushed");
                run(selected,{L"push",L"--porcelain",L"--no-follow-tags",L"--recurse-submodules=no",L"--set-upstream",L"--",wide(selected.remote),wide("HEAD:refs/heads/"+current.git.branch)},true,cancel);return {true,false,"Instruction-only commits pushed without force or tags."};}
            case Action::unlink:next.erase(std::remove_if(next.begin(),next.end(),[&](const auto& value){return value.id==selected.id;}),next.end());persist(std::move(next));return {true,false,"Instruction Git link removed; all files and links were retained."};
            case Action::enable_automatic:selected.automatic=true;selected.push_automatically=plan->automatic_push;selected.paused=false;selected.review.clear();break;
            case Action::disable_automatic:selected.automatic=false;selected.paused=true;selected.review="Automatic synchronization was paused explicitly.";break;
        }
        if(!selected.automatic&&plan->action!=Action::disable_automatic){selected.paused=false;selected.review.clear();}replace(selected);persist(std::move(next));return {changed,false,"Instruction synchronization settings saved. Existing file identities and links were preserved."};
    }
    // Called by Root's app-level timer, not by a provider. Missing/disabled defaults do
    // nothing. This method never implicitly overwrites an incoming local master.
    std::vector<Outcome> tick(std::uint64_t now,const Cancel& cancel={},const std::function<bool(const Binding&)>& permitted={}){
        std::lock_guard lock(gate_);loaded();std::vector<Outcome> results;if(!reviews_.empty())return results;const auto snapshot=bindings_;
        for(const auto& item:snapshot){if(!item.automatic||item.paused||(permitted&&!permitted(item))||(last_check_.contains(item.id)&&(now<last_check_.at(item.id)||now-last_check_.at(item.id)<60000)))continue;last_check_[item.id]=now;
            try{
                auto current=status(item,cancel);if(current.conflict)throw std::runtime_error("Resolve the instruction repository conflict before resuming automatic sync");
                if(current.step==CopyStep::conflict||current.step==CopyStep::update_source)throw std::runtime_error("Incoming or conflicting instruction text requires explicit owner review before changing the local master");
                if(current.step==CopyStep::update_copy){results.push_back(apply(preview(item.id,Action::use_source),cancel));results.push_back(apply(preview(item.id,Action::commit),cancel));current=status(item.id,cancel);}
                else if(current.step==CopyStep::in_step&&std::any_of(current.git.files.begin(),current.git.files.end(),[&](const auto& file){return file.path==item.copy;})){results.push_back(apply(preview(item.id,Action::commit),cancel));current=status(item.id,cancel);}
                if(!current.remote_fingerprint.empty()&&(!last_fetch_.contains(item.id)||now-last_fetch_.at(item.id)>=300000)){
                    results.push_back(apply(preview(item.id,Action::fetch),cancel));last_fetch_[item.id]=now;current=status(item.id,cancel);
                    if(current.git.behind){results.push_back(apply(preview(item.id,Action::pull),cancel));current=status(item.id,cancel);if(current.step!=CopyStep::in_step)throw std::runtime_error("Fetched instruction text needs explicit approval before updating the local master");}
                }
                if(item.push_automatically&&current.can_push)results.push_back(apply(preview(item.id,Action::push),cancel));
            }catch(...){auto next=bindings_;for(auto& value:next)if(value.id==item.id){value.paused=true;value.review="Automatic instruction sync paused. Review changed files, conflicts, authentication, network or interrupted work before resuming.";}persist(std::move(next));results.push_back({false,true,"Automatic instruction sync paused for explicit review. No incoming master overwrite was performed."});}
        }return results;
    }
};
} // namespace coincide::instruction_git
