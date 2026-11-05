#pragma once
#include "GitService.h"
#include "ACPFileSystem.h"
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <charconv>
#include <cmath>
#include <cctype>
#include <set>

namespace coincide::code_hosting {
using Object=winrt::Windows::Data::Json::JsonObject;
using Array=winrt::Windows::Data::Json::JsonArray;
using Cancel=std::function<bool()>;
enum class Tool { git,gh };
struct Command {Tool tool{};std::filesystem::path cwd;std::vector<std::wstring> arguments;std::string input;std::size_t limit{2*1024*1024};bool mutation{};};
struct Result {DWORD status{};std::string output;};
using Runner=std::function<Result(const Command&,const Cancel&)>;
inline std::wstring wide(std::string_view text){return std::wstring(winrt::to_hstring(text));}
inline std::string narrow(const std::filesystem::path& path){return winrt::to_string(path.wstring());}
inline std::string trim(std::string text){while(!text.empty()&&(text.back()=='\r'||text.back()=='\n'))text.pop_back();return text;}
inline bool same_path(const std::filesystem::path& a,const std::filesystem::path& b){return CompareStringOrdinal(a.lexically_normal().c_str(),-1,b.lexically_normal().c_str(),-1,TRUE)==CSTR_EQUAL;}
inline bool token(std::string_view value,std::size_t maximum=100){return !value.empty()&&value.size()<=maximum&&value.front()!='-'&&value!="."&&value!=".."&&value.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")==std::string_view::npos;}
inline bool oid(std::string_view value){return (value.size()==40||value.size()==64)&&value.find_first_not_of("0123456789abcdef")==std::string_view::npos;}
inline std::vector<NativeHandle> pin_directories(const std::filesystem::path& physical){
    std::vector<NativeHandle> result;auto path=physical.root_path();std::vector<std::filesystem::path> paths{path};for(const auto& part:physical.relative_path()){path/=part;paths.push_back(path);}if(paths.size()>96)throw std::invalid_argument("The code hosting folder nesting exceeds its bound");
    for(const auto& value:paths){NativeHandle handle(CreateFileW(value.c_str(),FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};if(handle.get()==INVALID_HANDLE_VALUE||!GetFileInformationByHandle(handle.get(),&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE)))throw std::runtime_error("Could not pin a regular local code hosting directory");result.push_back(std::move(handle));}return result;
}
inline std::string text(const Object& object,const wchar_t* key,std::size_t maximum=65536){const auto value=object.GetNamedValue(key,nullptr);if(!value||value.ValueType()==winrt::Windows::Data::Json::JsonValueType::Null)return {};if(value.ValueType()!=winrt::Windows::Data::Json::JsonValueType::String)throw std::runtime_error("Unexpected code hosting text field");auto result=winrt::to_string(value.GetString());if(result.size()>maximum||result.find('\0')!=std::string::npos)throw std::runtime_error("Code hosting text exceeds its preview limit");return result;}
inline bool boolean(const Object& object,const wchar_t* key){const auto value=object.GetNamedValue(key,nullptr);if(!value||value.ValueType()!=winrt::Windows::Data::Json::JsonValueType::Boolean)throw std::runtime_error("Missing code hosting boolean field");return value.GetBoolean();}
inline std::uint32_t integer(const Object& object,const wchar_t* key,std::uint32_t maximum=1000000000){const auto value=object.GetNamedValue(key,nullptr);if(!value||value.ValueType()!=winrt::Windows::Data::Json::JsonValueType::Number)throw std::runtime_error("Missing code hosting count");const auto number=value.GetNumber();if(!std::isfinite(number)||number<0||number>maximum||std::floor(number)!=number)throw std::runtime_error("Invalid code hosting count");return static_cast<std::uint32_t>(number);}
inline void cancelled(const Cancel& cancel){if(cancel&&cancel())throw std::runtime_error("Cancelled");}
struct Repository {
    std::string host,owner,name;
    std::string full_name()const{return host+"/"+owner+"/"+name;}
    std::string endpoint()const{return "repos/"+owner+"/"+name;}
    bool operator==(const Repository&)const=default;
    static Repository parse(std::string remote){
        if(remote.size()>2048||remote.find_first_of("\r\n\t?#\\")!=std::string::npos)throw std::invalid_argument("Select a GitHub remote without credentials or query parameters");
        std::string authority,path;
        if(remote.starts_with("https://")||remote.starts_with("ssh://")){const bool ssh=remote.starts_with("ssh://");const auto start=ssh?6u:8u;const auto slash=remote.find('/',start);if(slash==std::string::npos)throw std::invalid_argument("The selected remote has no repository");authority=remote.substr(start,slash-start);path=remote.substr(slash+1);if(ssh&&authority.starts_with("git@"))authority.erase(0,4);}
        else if(remote.starts_with("git@")){const auto colon=remote.find(':',4);if(colon==std::string::npos)throw std::invalid_argument("Invalid SSH GitHub remote");authority=remote.substr(4,colon-4);path=remote.substr(colon+1);}else throw std::invalid_argument("Use an HTTPS or git SSH GitHub remote");
        std::transform(authority.begin(),authority.end(),authority.begin(),[](unsigned char ch){return static_cast<char>(std::tolower(ch));});
        if(authority.size()>253||authority.find('.')==std::string::npos||!token(authority,253)||authority.find('@')!=std::string::npos)throw std::invalid_argument("Invalid GitHub hostname");
        if(path.ends_with(".git"))path.resize(path.size()-4);const auto slash=path.find('/');if(slash==std::string::npos||path.find('/',slash+1)!=std::string::npos)throw std::invalid_argument("Invalid GitHub repository path");
        Repository result{authority,path.substr(0,slash),path.substr(slash+1)};if(!token(result.owner)||!token(result.name))throw std::invalid_argument("Invalid GitHub repository name");return result;
    }
};
enum class Filter {open,mine,review_requested};
enum class Action {review,merge,checkout,ready};
enum class Review {comment,approve,request_changes};
enum class Merge {merge,squash,rebase};
inline std::string review_name(Review value){switch(value){case Review::comment:return "COMMENT";case Review::approve:return "APPROVE";case Review::request_changes:return "REQUEST_CHANGES";}throw std::invalid_argument("Invalid review event");}
inline std::string merge_name(Merge value){switch(value){case Merge::merge:return "merge";case Merge::squash:return "squash";case Merge::rebase:return "rebase";}throw std::invalid_argument("Invalid merge method");}
struct Scope {Repository repository;std::filesystem::path root,common;std::string remote,remote_url,viewer;bool allow_merge{},allow_squash{},allow_rebase{};std::vector<std::shared_ptr<ACPFileSystem>> pins;std::vector<NativeHandle> root_pins,common_pins;};
struct Summary {std::uint32_t number{};std::string title,author,head_branch,base_branch,state;bool draft{};};
struct Check {std::string name,status,conclusion;bool blocking{true};};
struct ReviewRecord {std::string author,state,commit,body;};
struct Detail {std::shared_ptr<const Scope> scope;Summary summary;std::string head,base,body,mergeability;std::uint32_t additions{},deletions{},files{};std::vector<Check> checks;std::vector<ReviewRecord> reviews;bool complete{};
    bool can_merge()const{return complete&&summary.state=="open"&&!summary.draft&&mergeability=="clean"&&std::none_of(checks.begin(),checks.end(),[](const auto& value){return value.blocking;})&&std::none_of(reviews.begin(),reviews.end(),[](const auto& value){return value.state=="CHANGES_REQUESTED";});}
};
struct Listing {std::shared_ptr<const Scope> scope;std::vector<Summary> values;bool limited{};};
struct Plan {std::shared_ptr<const Detail> reviewed;Action action{};Review review{};Merge merge{};std::string body;std::filesystem::path target;};
struct Outcome {std::string message;std::filesystem::path worktree;};

// All process work blocks on a bounded, owned job. Invoke from a worker. Construction is inert.
class Service {
public:
    explicit Service(std::filesystem::path folder,Runner runner={}):folder_(std::move(folder)),runner_(runner?std::move(runner):native_runner()){}
    static WindowsProcess::Environment child_environment(const Command& command){
        WindowsProcess::Environment environment{{L"GIT_DIR",std::nullopt},{L"GIT_WORK_TREE",std::nullopt},{L"GIT_COMMON_DIR",std::nullopt},{L"GIT_INDEX_FILE",std::nullopt},{L"GIT_OBJECT_DIRECTORY",std::nullopt},{L"GIT_ALTERNATE_OBJECT_DIRECTORIES",std::nullopt},{L"GIT_CONFIG_COUNT",std::nullopt},{L"GIT_CONFIG_PARAMETERS",std::nullopt},{L"GH_REPO",std::nullopt},{L"GH_HOST",std::nullopt},{L"GH_ENTERPRISE_TOKEN",std::nullopt},{L"GITHUB_ENTERPRISE_TOKEN",std::nullopt},{L"GH_PROMPT_DISABLED",L"1"},{L"GH_PAGER",L""},{L"PAGER",L""},{L"GH_NO_UPDATE_NOTIFIER",L"1"},{L"GIT_TERMINAL_PROMPT",L"0"},{L"GCM_INTERACTIVE",L"Never"},{L"GIT_ASKPASS",L""},{L"SSH_ASKPASS",L""}};
        std::string host;if(command.tool==Tool::gh){for(std::size_t i=0;i+1<command.arguments.size();++i){if(command.arguments[i]==L"--hostname")host=winrt::to_string(command.arguments[i+1]);else if(command.arguments[i]==L"--repo"){const auto repo=winrt::to_string(command.arguments[i+1]);host=repo.substr(0,repo.find('/'));}}if(!token(host,253)||host.find('.')==std::string::npos)throw std::invalid_argument("Code hosting CLI requests require an explicit verified hostname");}
        // Generic enterprise tokens are not bound to a host and must never follow an untrusted remote.
        // Host-specific credentials already stored by gh remain available. Public generic tokens
        // are retained only for exact github.com, never an arbitrary GHES or cloud tenant hostname.
        if(command.tool!=Tool::gh||host!="github.com"){environment.emplace_back(L"GH_TOKEN",std::nullopt);environment.emplace_back(L"GITHUB_TOKEN",std::nullopt);}return environment;
    }
    static Runner native_runner(){return [](const Command& command,const Cancel& cancel){
        cancelled(cancel);const auto environment=child_environment(command);const auto executable=command.tool==Tool::git?GitService::discover_git():discover_gh();
        std::vector<std::wstring> arguments;if(command.tool==Tool::git)arguments={L"--no-pager",L"--literal-pathspecs",L"-c",L"color.ui=false",L"-c",L"core.fsmonitor=false",L"-c",L"core.hooksPath=NUL",L"-c",L"credential.interactive=false",L"-c",L"core.askPass="};arguments.insert(arguments.end(),command.arguments.begin(),command.arguments.end());
        Result result;auto process=WindowsProcess::start_bytes(executable,arguments,command.cwd,[&](std::string_view bytes){result.output.append(bytes);},command.limit,environment);
        std::exception_ptr write_error;std::thread writer([&]{try{if(!command.input.empty())process->write_bytes(command.input);process->close_input();}catch(...){write_error=std::current_exception();}});
        const auto join=[&]{if(writer.joinable())writer.join();};try{const auto deadline=std::chrono::steady_clock::now()+std::chrono::seconds(command.mutation?120:45);std::optional<WindowsProcess::Exit> exit;
            while(!(exit=process->wait(std::chrono::milliseconds(25)))){if((cancel&&cancel())||std::chrono::steady_clock::now()>deadline){process->stop();join();throw std::runtime_error(command.mutation?"Code hosting action interrupted; its result is unknown. Refresh before retrying.":"Code hosting request cancelled or timed out");}}
            join();result.status=exit->status;if(write_error||exit->stdout_truncated||!exit->channel_error.empty())throw std::runtime_error(command.mutation?"Code hosting action result is unknown. Refresh before retrying.":"Code hosting response exceeded its bound or could not be read");cancelled(cancel);return result;
        }catch(...){process->stop();join();throw;}
    };}
    Listing refresh(Filter filter=Filter::open,const std::string& remote="origin",const Cancel& cancel={}){
        if(!token(remote))throw std::invalid_argument("Select an existing named remote");auto scope=discover(remote,cancel);
        const auto metadata=api(*scope,scope->repository.endpoint(),cancel);if(text(metadata,L"full_name",300)!=scope->repository.owner+"/"+scope->repository.name)throw std::runtime_error("The server repository does not match the selected remote");
        scope->allow_merge=boolean(metadata,L"allow_merge_commit");scope->allow_squash=boolean(metadata,L"allow_squash_merge");scope->allow_rebase=boolean(metadata,L"allow_rebase_merge");
        scope->viewer=text(api(*scope,"user",cancel),L"login",100);if(!token(scope->viewer))throw std::runtime_error("The authenticated GitHub identity is unavailable");
        std::vector<std::wstring> arguments{L"pr",L"list",L"--repo",wide(scope->repository.full_name()),L"--state",L"open",L"--limit",L"100",L"--json",L"number,title,author,headRefName,baseRefName,state,isDraft"};
        if(filter==Filter::mine){arguments.insert(arguments.end(),{L"--author",L"@me"});}else if(filter==Filter::review_requested)arguments.insert(arguments.end(),{L"--search",L"review-requested:@me"});
        const auto rows=parse_array(run(Tool::gh,scope->root,arguments,cancel).output);if(rows.Size()>100)throw std::runtime_error("Too many pull request records");Listing result;result.scope=scope;result.limited=rows.Size()==100;
        for(const auto& value:rows){const auto raw=value.GetObject();Summary row;row.number=integer(raw,L"number");if(!row.number)throw std::runtime_error("Invalid pull request number");row.title=text(raw,L"title",4096);row.author=text(raw.GetNamedObject(L"author"),L"login",100);row.head_branch=text(raw,L"headRefName",1024);row.base_branch=text(raw,L"baseRefName",1024);row.state=text(raw,L"state",20);std::transform(row.state.begin(),row.state.end(),row.state.begin(),[](unsigned char ch){return static_cast<char>(std::tolower(ch));});row.draft=boolean(raw,L"isDraft");result.values.push_back(std::move(row));}
        cancelled(cancel);scope_=std::move(scope);return result;
    }
    std::shared_ptr<const Detail> detail(std::uint32_t number,const Cancel& cancel={}){
        const auto scope=require_scope();verify_scope(*scope,cancel);auto result=load_detail(scope,number,cancel);cancelled(cancel);return result;
    }
    std::string diff(const Detail& reviewed,const Cancel& cancel={}){
        verify(reviewed,cancel);const auto endpoint=reviewed.scope->repository.endpoint()+"/compare/"+reviewed.base+"..."+reviewed.head;
        auto result=run(Tool::gh,reviewed.scope->root,{L"api",L"--hostname",wide(reviewed.scope->repository.host),wide(endpoint),L"-H",L"Accept: application/vnd.github.diff"},cancel,{},false,1024*1024).output;
        if(result.find('\0')!=std::string::npos)throw std::runtime_error("Binary pull request preview is unavailable");cancelled(cancel);return result;
    }
    Plan plan(std::shared_ptr<const Detail> reviewed,Action action,Review review=Review::comment,std::string body={},Merge merge=Merge::squash,std::filesystem::path target={})const{
        if(!reviewed||reviewed->scope!=scope_||!oid(reviewed->head)||!oid(reviewed->base))throw std::invalid_argument("Refresh and select a pull request first");if(reviewed->summary.state!="open")throw std::invalid_argument("This pull request is no longer open");
        if(body.size()>16000||body.find('\0')!=std::string::npos)throw std::invalid_argument("Review messages are limited to 16000 UTF-8 bytes");
        if(action==Action::review){review_name(review);if(review!=Review::approve&&body.find_first_not_of(" \t\r\n")==std::string::npos)throw std::invalid_argument("Enter a review message");}
        if(action==Action::merge){merge_name(merge);if(!reviewed->can_merge()||!method_allowed(*reviewed->scope,merge))throw std::invalid_argument("This pull request is not ready for the selected merge method");}
        if(action==Action::ready&&!reviewed->summary.draft)throw std::invalid_argument("This pull request is already ready for review");
        if(action==Action::checkout)validate_target(target,reviewed->scope->root);
        return {std::move(reviewed),action,review,merge,std::move(body),std::move(target)};
    }
    // The caller must obtain direct native confirmation of this immutable plan and hold its runtime/repository lease.
    Outcome execute(const Plan& plan,const Cancel& cancel={}){
        if(!plan.reviewed)throw std::invalid_argument("Missing reviewed pull request");const auto& reviewed=*plan.reviewed;verify(reviewed,cancel);auto fresh=load_detail(reviewed.scope,reviewed.summary.number,cancel);
        if(fresh->head!=reviewed.head||fresh->base!=reviewed.base||fresh->summary.state!="open")throw std::runtime_error("The pull request changed after review. Refresh and review its new head.");
        const auto scope=reviewed.scope;const auto endpoint=scope->repository.endpoint()+"/pulls/"+std::to_string(reviewed.summary.number);cancelled(cancel);
        if(plan.action==Action::review){const auto checked=this->plan(plan.reviewed,plan.action,plan.review,plan.body,plan.merge,plan.target);static_cast<void>(checked);Object body;body.SetNamedValue(L"event",winrt::Windows::Data::Json::JsonValue::CreateStringValue(wide(review_name(plan.review))));body.SetNamedValue(L"body",winrt::Windows::Data::Json::JsonValue::CreateStringValue(wide(plan.body)));body.SetNamedValue(L"commit_id",winrt::Windows::Data::Json::JsonValue::CreateStringValue(wide(reviewed.head)));
            const auto response=api(*scope,endpoint+"/reviews",cancel,"POST",winrt::to_string(body.Stringify()),true);const auto state=text(response,L"state",40);const auto expected=plan.review==Review::comment?"COMMENTED":plan.review==Review::approve?"APPROVED":"CHANGES_REQUESTED";if(text(response,L"commit_id",64)!=reviewed.head||state!=expected||text(response.GetNamedObject(L"user"),L"login",100)!=scope->viewer)throw std::runtime_error("Review submission returned an unexpected identity; refresh before retrying");return {"Review submitted for "+reviewed.head,{}};
        }
        if(plan.action==Action::merge){if(!fresh->can_merge())throw std::runtime_error("Checks, reviews or mergeability changed. Refresh before merging.");const auto metadata=api(*scope,scope->repository.endpoint(),cancel);const auto method=merge_name(plan.merge);const bool enabled=boolean(metadata,plan.merge==Merge::merge?L"allow_merge_commit":plan.merge==Merge::squash?L"allow_squash_merge":L"allow_rebase_merge");if(!enabled)throw std::runtime_error("The selected merge method is unavailable");
            run(Tool::gh,scope->root,{L"pr",L"merge",wide(std::to_string(reviewed.summary.number)),L"--repo",wide(scope->repository.full_name()),L"--"+wide(method),L"--match-head-commit",wide(reviewed.head)},cancel,{},true);
            const auto after=api(*scope,endpoint,cancel);if(!boolean(after,L"merged"))return {"Merge was requested but is not confirmed merged. Refresh to see its current state.",{}};return {"Pull request merged.",{}};
        }
        if(plan.action==Action::ready){
            if(!fresh->summary.draft)throw std::runtime_error("The pull request is already ready for review. Refresh its state.");
            // GitHub exposes no expected-head precondition for this metadata-only transition.
            // Confirm the observed head before dispatch and disclose any subsequent change.
            run(Tool::gh,scope->root,{L"pr",L"ready",wide(std::to_string(reviewed.summary.number)),L"--repo",wide(scope->repository.full_name())},cancel,{},true);
            const auto after=api(*scope,endpoint,cancel);if(text(after.GetNamedObject(L"head"),L"sha",64)!=reviewed.head||text(after.GetNamedObject(L"base"),L"sha",64)!=reviewed.base)return {"Mark Ready was requested, but the head or base changed during the action. Refresh and review the new commit.",{}};
            if(boolean(after,L"draft"))return {"Mark Ready was requested but is not confirmed. Refresh before retrying.",{}};return {"Pull request marked ready for review. This metadata action does not atomically pin its head.",{}};
        }
        if(plan.action!=Action::checkout)throw std::invalid_argument("Unsupported code hosting action");validate_target(plan.target,scope->root);ACPFileSystem parent(plan.target.parent_path());auto parent_pins=pin_directories(parent.root());const auto target=parent.root()/plan.target.filename();
        // Fetch a literal immutable object from the verified remote; do not check out a moving PR ref.
        run(Tool::git,scope->root,{L"fetch",L"--no-tags",L"--no-write-fetch-head",L"--",wide(scope->remote_url),wide(reviewed.head)},cancel,{},true);
        const auto object=trim(run(Tool::git,scope->root,{L"rev-parse",L"--verify",wide(reviewed.head+"^{commit}")},cancel).output);if(object!=reviewed.head)throw std::runtime_error("The fetched object is not the reviewed head");cancelled(cancel);validate_target(target,scope->root);
        if(!CreateDirectoryW(target.c_str(),nullptr))throw std::runtime_error("The review worktree destination was created by another operation. Choose a new folder.");auto target_pins=pin_directories(target);
        run(Tool::git,scope->root,{L"worktree",L"add",L"--detach",L"--",target.wstring(),wide(reviewed.head)},cancel,{},true);
        const auto actual=trim(run(Tool::git,target,{L"rev-parse",L"--verify",L"HEAD"},cancel).output);if(actual!=reviewed.head)throw std::runtime_error("The new worktree head could not be confirmed. Its files were retained for review.");return {"Created a detached review worktree at "+reviewed.head,target};
    }
private:
    std::filesystem::path folder_;Runner runner_;std::shared_ptr<const Scope> scope_;
    static std::filesystem::path discover_gh(){
        for(const auto variable:{L"ProgramFiles",L"ProgramFiles(x86)",L"LOCALAPPDATA"}){wchar_t buffer[32768]{};const auto count=GetEnvironmentVariableW(variable,buffer,32768);if(count&&count<32768){const auto candidate=std::filesystem::path(buffer)/(std::wstring_view(variable)==L"LOCALAPPDATA"?L"Programs/GitHub CLI/gh.exe":L"GitHub CLI/gh.exe");if(std::filesystem::is_regular_file(candidate))return candidate;}}
        wchar_t path[32768]{};const auto size=GetEnvironmentVariableW(L"PATH",path,32768);if(size&&size<32768){for(const auto entry:git_parse::split(winrt::to_string(std::wstring_view(path,size)),';')){auto value=wide(entry);if(value.size()>1&&value.front()==L'"'&&value.back()==L'"')value=value.substr(1,value.size()-2);const auto candidate=std::filesystem::path(value)/L"gh.exe";if(std::filesystem::path(value).is_absolute()&&std::filesystem::is_regular_file(candidate))return candidate;}}
        throw std::runtime_error("Install GitHub CLI before refreshing pull requests");
    }
    static Object parse_object(const std::string& value){if(value.size()>2*1024*1024||value.find('\0')!=std::string::npos)throw std::runtime_error("Invalid bounded code hosting response");return Object::Parse(wide(value));}
    static Array parse_array(const std::string& value){if(value.size()>2*1024*1024||value.find('\0')!=std::string::npos)throw std::runtime_error("Invalid bounded code hosting response");return Array::Parse(wide(value));}
    Result run(Tool tool,const std::filesystem::path& cwd,std::vector<std::wstring> arguments,const Cancel& cancel,std::string input={},bool mutation=false,std::size_t limit=2*1024*1024){cancelled(cancel);Command command{tool,cwd,std::move(arguments),std::move(input),limit,mutation};Result result;try{result=runner_(command,cancel);cancelled(cancel);}catch(...){if(mutation)throw std::runtime_error("The code hosting action was interrupted or its outcome is unknown. Refresh before retrying.");throw;}if(result.output.size()>limit)throw std::runtime_error(mutation?"The code hosting action response exceeded its bound; its outcome is unknown. Refresh before retrying.":"Code hosting response exceeded its preview bound");if(result.status)throw std::runtime_error(mutation?"The code hosting action failed or its outcome is unknown. Refresh before retrying.":"Code hosting request failed. Check the selected remote and GitHub CLI sign-in.");return result;}
    Object api(const Scope& scope,const std::string& endpoint,const Cancel& cancel,const std::string& method={},const std::string& input={},bool mutation=false){std::vector<std::wstring> args{L"api",L"--hostname",wide(scope.repository.host),wide(endpoint)};if(!method.empty())args.insert(args.end(),{L"--method",wide(method),L"--input",L"-"});return parse_object(run(Tool::gh,scope.root,std::move(args),cancel,input,mutation).output);}
    std::shared_ptr<Scope> discover(const std::string& remote,const Cancel& cancel){
        auto selected=std::make_shared<ACPFileSystem>(folder_);auto result=std::make_shared<Scope>();result->remote=remote;result->pins.push_back(std::move(selected));const auto selected_root=result->pins.front()->root();
        if(trim(run(Tool::git,selected_root,{L"rev-parse",L"--is-inside-work-tree"},cancel,{},false,4096).output)!="true")throw std::runtime_error("Select a Git working tree");
        result->root=std::filesystem::canonical(std::filesystem::path(wide(trim(run(Tool::git,selected_root,{L"rev-parse",L"--show-toplevel"},cancel,{},false,32768).output))));auto root=std::make_shared<ACPFileSystem>(result->root);result->root=root->root();result->pins.push_back(std::move(root));
        result->common=std::filesystem::canonical(std::filesystem::path(wide(trim(run(Tool::git,result->root,{L"rev-parse",L"--path-format=absolute",L"--git-common-dir"},cancel,{},false,32768).output))));auto common=std::make_shared<ACPFileSystem>(result->common);result->common=common->root();result->pins.push_back(std::move(common));
        result->root_pins=pin_directories(result->root);result->common_pins=pin_directories(result->common);result->remote_url=trim(run(Tool::git,result->root,{L"remote",L"get-url",L"--",wide(remote)},cancel,{},false,4096).output);result->repository=Repository::parse(result->remote_url);return result;
    }
    std::shared_ptr<const Scope> require_scope()const{if(!scope_)throw std::runtime_error("Refresh pull requests before selecting an action");return scope_;}
    void verify_scope(const Scope& scope,const Cancel& cancel){const auto fresh=discover(scope.remote,cancel);if(!same_path(fresh->root,scope.root)||!same_path(fresh->common,scope.common)||fresh->remote_url!=scope.remote_url||fresh->repository!=scope.repository)throw std::runtime_error("The selected repository or remote changed. Refresh before continuing.");}
    void verify(const Detail& detail,const Cancel& cancel){if(!scope_||detail.scope!=scope_||!detail.summary.number||!oid(detail.head)||!oid(detail.base))throw std::runtime_error("This pull request preview is stale. Refresh before continuing.");verify_scope(*detail.scope,cancel);if(text(api(*detail.scope,"user",cancel),L"login",100)!=detail.scope->viewer)throw std::runtime_error("The GitHub identity changed after review. Refresh before continuing.");}
    static bool method_allowed(const Scope& scope,Merge method){return method==Merge::merge?scope.allow_merge:method==Merge::squash?scope.allow_squash:scope.allow_rebase;}
    static void validate_target(const std::filesystem::path& path,const std::filesystem::path& root){
        if(!path.is_absolute()||path.filename().empty()||path.lexically_normal()!=path||std::filesystem::exists(path)||!std::filesystem::is_directory(path.parent_path()))throw std::invalid_argument("Choose a new absolute review-worktree folder in an existing local parent");
        // ACP literal validation rejects ADS/device aliases and pins the destination parent.
        ACPFileSystem parent(path.parent_path());parent.literal(narrow(parent.root()/path.filename()));const auto candidate=parent.root()/path.filename();if(same_path(candidate,root))throw std::invalid_argument("A review worktree cannot replace the selected repository");
    }
    std::shared_ptr<Detail> load_detail(std::shared_ptr<const Scope> scope,std::uint32_t number,const Cancel& cancel){
        if(!number||number>1000000000)throw std::invalid_argument("Invalid pull request number");const auto endpoint=scope->repository.endpoint()+"/pulls/"+std::to_string(number);const auto raw=api(*scope,endpoint,cancel);if(integer(raw,L"number")!=number)throw std::runtime_error("Pull request response identity mismatch");
        const auto base=raw.GetNamedObject(L"base"),head=raw.GetNamedObject(L"head");if(text(base.GetNamedObject(L"repo"),L"full_name",300)!=scope->repository.owner+"/"+scope->repository.name)throw std::runtime_error("Pull request belongs to a different repository");
        auto result=std::make_shared<Detail>();result->scope=std::move(scope);result->head=text(head,L"sha",64);result->base=text(base,L"sha",64);if(!oid(result->head)||!oid(result->base))throw std::runtime_error("Pull request commit identity is unavailable");
        auto& row=result->summary;row.number=number;row.title=text(raw,L"title",4096);row.author=text(raw.GetNamedObject(L"user"),L"login",100);row.head_branch=text(head,L"ref",1024);row.base_branch=text(base,L"ref",1024);row.state=text(raw,L"state",20);row.draft=boolean(raw,L"draft");result->body=text(raw,L"body");result->mergeability=text(raw,L"mergeable_state",40);result->additions=integer(raw,L"additions");result->deletions=integer(raw,L"deletions");result->files=integer(raw,L"changed_files");
        const auto prefix=result->scope->repository.endpoint()+"/commits/"+result->head;const auto statuses=api(*result->scope,prefix+"/status?per_page=100",cancel),runs=api(*result->scope,prefix+"/check-runs?per_page=100",cancel);
        if(text(statuses,L"sha",64)!=result->head)throw std::runtime_error("Commit status response changed identity");const auto status_rows=statuses.GetNamedArray(L"statuses"),run_rows=runs.GetNamedArray(L"check_runs");if(status_rows.Size()>100||run_rows.Size()>100)throw std::runtime_error("Check preview exceeds its bound");result->complete=integer(statuses,L"total_count")==status_rows.Size()&&integer(runs,L"total_count")==run_rows.Size();
        for(const auto& value:status_rows){const auto check=value.GetObject();const auto state=text(check,L"state",40);result->checks.push_back({text(check,L"context",4096),state,state,state!="success"});}
        for(const auto& value:run_rows){const auto check=value.GetObject();if(text(check,L"head_sha",64)!=result->head)throw std::runtime_error("Check run response changed head identity");const auto state=text(check,L"status",40),conclusion=text(check,L"conclusion",40);result->checks.push_back({text(check,L"name",4096),state,conclusion,state!="completed"||(conclusion!="success"&&conclusion!="skipped"&&conclusion!="neutral")});}
        const auto reviews=parse_array(run(Tool::gh,result->scope->root,{L"api",L"--hostname",wide(result->scope->repository.host),wide(endpoint+"/reviews?per_page=100")},cancel).output);if(reviews.Size()>100)throw std::runtime_error("Review preview exceeds its bound");if(reviews.Size()==100)result->complete=false;
        std::map<std::string,ReviewRecord> latest;for(const auto& value:reviews){const auto raw_review=value.GetObject();ReviewRecord review{text(raw_review.GetNamedObject(L"user"),L"login",100),text(raw_review,L"state",40),text(raw_review,L"commit_id",64),text(raw_review,L"body",16000)};if(!oid(review.commit)||!token(review.author))throw std::runtime_error("Review response has an invalid identity");if(review.state!="COMMENTED"&&review.state!="PENDING")latest[review.author]=std::move(review);else result->reviews.push_back(std::move(review));}for(auto& [author,review]:latest){static_cast<void>(author);result->reviews.push_back(std::move(review));}
        // Re-read moving PR metadata after the pinned check/review requests to detect head/base changes.
        const auto after=api(*result->scope,endpoint,cancel);if(text(after.GetNamedObject(L"head"),L"sha",64)!=result->head||text(after.GetNamedObject(L"base"),L"sha",64)!=result->base||text(after,L"state",20)!=row.state)throw std::runtime_error("The pull request changed while loading. Refresh its preview.");return result;
    }
};
} // namespace coincide::code_hosting
