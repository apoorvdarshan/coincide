#pragma once
#include "GitModels.h"
#include "WindowsProcess.h"
#include <exception>
#include <fstream>
#include <limits>
#include <map>
#include <set>

namespace coincide {
// These operations block on an owned subprocess; call them from a worker, never the WinUI dispatcher.
class GitService {
public:
    explicit GitService(std::filesystem::path executable, std::filesystem::path folder)
        : executable_(std::move(executable)), folder_(std::filesystem::canonical(folder)) {
        if (!std::filesystem::is_regular_file(executable_) || !std::filesystem::is_directory(folder_)) {
            throw std::invalid_argument("Git needs an installed executable and an existing project folder");
        }
    }

    static std::filesystem::path discover_git() {
        for (const auto variable : {L"ProgramFiles", L"ProgramFiles(x86)", L"LOCALAPPDATA"}) {
            const auto base = environment_value(variable);
            if (base.empty()) continue;
            const auto path = std::filesystem::path(base) / (std::wstring_view(variable) == L"LOCALAPPDATA"
                ? L"Programs/Git/cmd/git.exe" : L"Git/cmd/git.exe");
            if (std::filesystem::is_regular_file(path)) return path;
        }
        // Search only explicit absolute PATH entries. SearchPath would also search an untrusted current directory.
        const auto path = environment_value(L"PATH");
        const auto encoded_path = utf8(path);
        for (const auto part : git_parse::split(encoded_path, ';')) {
            auto entry = wide(part);
            if (entry.size() > 1 && entry.front() == L'"' && entry.back() == L'"') entry = entry.substr(1, entry.size() - 2);
            if (entry.empty() || !std::filesystem::path(entry).is_absolute()) continue;
            const auto candidate = std::filesystem::path(entry) / L"git.exe";
            if (std::filesystem::is_regular_file(candidate)) return candidate;
        }
        throw std::runtime_error("Install Git for Windows before using source control");
    }

    GitStatus status() {
        if (!resolve_repository()) return {};
        auto result = git_parse::status(run({L"status", L"--porcelain=v2", L"--branch", L"-z", L"--untracked-files=all"}).output);
        result.root = utf8(folder_.wstring());
        return result;
    }

    GitPreview diff(const std::string& path, bool staged = false, std::size_t limit = 1024 * 1024) {
        require_repository(); validate_path(path);
        if (!limit || limit > maximum_output) throw std::invalid_argument("Invalid Git preview limit");
        const auto current = status();
        const auto file = std::find_if(current.files.begin(), current.files.end(), [&](const auto& value) {return value.path == path;});
        if (!staged && file != current.files.end() && file->untracked) return untracked_preview(path, limit);
        std::vector<std::wstring> args{L"diff", L"--no-ext-diff", L"--no-textconv", L"--patch"};
        if (staged) args.push_back(L"--cached");
        args.push_back(L"--"); args.push_back(wide(path));
        auto result = run(args, {}, limit, true);
        const bool binary = result.output.find("Binary files ") != std::string::npos || result.output.find("GIT binary patch") != std::string::npos;
        return text_preview(std::move(result.output), result.truncated, binary);
    }

    std::vector<GitBranch> branches() {
        require_repository();
        return git_parse::branches(run({L"for-each-ref", L"--sort=-committerdate",
            L"--format=%(refname)%00%(upstream:short)%00%(HEAD)%00%(worktreepath)%00%(symref)", L"refs/heads", L"refs/remotes"}).output);
    }

    void stage(const std::vector<std::string>& paths) {
        require_repository();
        run({L"add", L"--pathspec-from-file=-", L"--pathspec-file-nul"}, path_input(paths));
    }
    void unstage(const std::vector<std::string>& paths) {
        require_repository();
        const auto input = path_input(paths);
        const auto head = run({L"rev-parse", L"--verify", L"--quiet", L"HEAD"}, {}, 4096, false, {}, true);
        if (head.status == 0) run({L"restore", L"--staged", L"--pathspec-from-file=-", L"--pathspec-file-nul"}, input);
        else {
            // Before the first commit, remove only the selected entries from the index, retaining every disk file.
            // No --force: if the staged version differs from the disk file Git must explain that conflict.
            run({L"rm", L"--cached", L"-r", L"--ignore-unmatch", L"--pathspec-from-file=-", L"--pathspec-file-nul"}, input);
        }
    }
    std::string commit(const std::string& message) {
        require_repository();
        if (message.empty() || message.find('\0') != std::string::npos || message.size() > 16000) {
            throw std::invalid_argument("Enter a commit message within the Windows command limit");
        }
        run({L"commit", L"-m", wide(message)});
        return trim_line(run({L"rev-parse", L"--verify", L"HEAD"}).output);
    }
    std::string push(const std::string& remote = {}, const std::string& branch = {}) {
        require_repository();
        std::vector<std::wstring> args{L"push", L"--porcelain"};
        if (!remote.empty()) {
            if (remote.front() == '-' || remote.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-") != std::string::npos) {
                throw std::invalid_argument("Select an existing named Git remote");
            }
            const auto remote_output = run({L"remote"}).output;
            const auto remotes = git_parse::split(remote_output, '\n');
            if (std::find(remotes.begin(), remotes.end(), remote) == remotes.end()) throw std::invalid_argument("Unknown Git remote");
            args.push_back(wide(remote));
            if (!branch.empty()) {validate_branch(branch); args.push_back(wide(branch));}
        } else if (!branch.empty()) throw std::invalid_argument("Select a named remote with the branch");
        return run(args, {}, maximum_output, false, {}, false, std::chrono::seconds(120)).output;
    }

    void switch_branch(const std::string& branch, bool create = false) {
        require_repository(); validate_branch(branch);
        // Git refuses checkout that would overwrite local work; no reset/force or implicit stash is used.
        std::vector<std::wstring> args{L"switch"}; if (create) args.push_back(L"-c"); args.push_back(wide(branch)); run(args);
    }
    void track_branch(const std::string& remote_branch,const std::string& local_branch){
        require_repository();validate_branch(remote_branch);validate_branch(local_branch);const auto values=branches();
        if(std::none_of(values.begin(),values.end(),[&](const auto& branch){return branch.remote&&branch.name==remote_branch;}))throw std::invalid_argument("Select an existing remote branch");
        run({L"switch",L"--track",L"-c",wide(local_branch),L"refs/remotes/"+wide(remote_branch)});
    }
    void rename_branch(const std::string& branch,const std::string& destination){
        require_repository();validate_branch(branch);validate_branch(destination);const auto values=branches();const auto found=std::find_if(values.begin(),values.end(),[&](const auto& value){return !value.remote&&value.name==branch;});
        if(found==values.end()||(!found->current&&!found->worktree_path.empty()))throw std::invalid_argument("Select a local branch that is not checked out in another worktree");
        run({L"branch",L"--move",L"--",wide(branch),wide(destination)});
    }
    void delete_branch(const std::string& branch){
        require_repository();validate_branch(branch);const auto values=branches();const auto found=std::find_if(values.begin(),values.end(),[&](const auto& value){return !value.remote&&value.name==branch;});
        if(found==values.end()||found->current||!found->worktree_path.empty())throw std::invalid_argument("Select an unused local branch before deleting it");
        // Ordinary --delete refuses unmerged work. There is deliberately no force option.
        run({L"branch",L"--delete",L"--",wide(branch)});
    }
    std::vector<GitWorktree> worktrees() {
        require_repository(); return git_parse::worktrees(run({L"worktree", L"list", L"--porcelain", L"-z"}).output);
    }
    void add_worktree(const std::filesystem::path& destination, const std::string& branch, bool create = false) {
        require_repository();
        if (!destination.is_absolute() || std::filesystem::exists(destination)) throw std::invalid_argument("Choose a new absolute worktree folder");
        std::vector<std::wstring> args{L"worktree", L"add", L"--no-track"};
        if (!branch.empty()) validate_branch(branch);
        if (create) {
            if (branch.empty()) throw std::invalid_argument("Enter a new worktree branch");
            args.push_back(L"-b"); args.push_back(wide(branch));
        } else if (branch.empty()) args.push_back(L"--detach");
        args.push_back(L"--"); args.push_back(destination.wstring());
        if (!create && !branch.empty()) args.push_back(wide(branch));
        run(args);
    }
    void remove_worktree(const std::filesystem::path& path) {
        require_repository();
        if (!path.is_absolute()) throw std::invalid_argument("Select an absolute worktree folder");
        const auto normalized = std::filesystem::weakly_canonical(path);
        const auto trees = worktrees();
        const auto at = std::find_if(trees.begin(), trees.end(), [&](const auto& tree) {
            return std::filesystem::weakly_canonical(std::filesystem::path(wide(tree.path))) == normalized;
        });
        if (at == trees.end() || at->main || at->locked || CompareStringOrdinal(normalized.c_str(),-1,folder_.c_str(),-1,TRUE)==CSTR_EQUAL) {
            throw std::invalid_argument("The selected worktree cannot be removed");
        }
        GitService target(executable_,normalized);if(!target.status().files.empty()||!target.run({L"ls-files",L"--others",L"--ignored",L"--exclude-standard",L"-z"}).output.empty())throw std::runtime_error("The worktree contains changed, untracked or ignored files; preserve them before removing it");
        // Git itself verifies cleanliness and refuses uncommitted/untracked work. Never add --force.
        run({L"worktree", L"remove", L"--", normalized.wstring()});
    }

    GitCheckpoint checkpoint(const std::string& message = "Coincide working tree checkpoint") {
        require_repository();
        if (message.empty() || message.find('\0') != std::string::npos || message.size() > 16000) throw std::invalid_argument("Invalid checkpoint message");
        const auto temporary = std::filesystem::temp_directory_path() / (L"coincide-git-index-" + unique_suffix());
        if (!std::filesystem::create_directory(temporary)) throw std::runtime_error("The unique checkpoint index directory already exists");
        const auto index = temporary / L"index";
        struct RemoveIndex {
            std::filesystem::path path;
            ~RemoveIndex() {std::error_code ignored; std::filesystem::remove_all(path, ignored);}
        } cleanup{temporary};
        const WindowsProcess::Environment environment{{L"GIT_INDEX_FILE", index.wstring()}};
        const auto head = run({L"rev-parse", L"--verify", L"--quiet", L"HEAD"}, {}, 4096, false, {}, true);
        if (head.status == 0) run({L"read-tree", L"HEAD"}, {}, maximum_output, false, environment);
        else run({L"read-tree", L"--empty"}, {}, maximum_output, false, environment);
        run({L"add", L"-A", L"--", L"."}, {}, maximum_output, false, environment);
        const auto tree = trim_line(run({L"write-tree"}, {}, 4096, false, environment).output);
        std::vector<std::wstring> args{L"-c", L"user.name=Coincide Checkpoint", L"-c", L"user.email=checkpoint@localhost",
            L"-c", L"commit.gpgsign=false", L"commit-tree", wide(tree)};
        if (head.status == 0) {args.push_back(L"-p"); args.push_back(wide(trim_line(head.output)));}
        args.push_back(L"-m"); args.push_back(wide(message));
        const auto commit = trim_line(run(args, {}, 4096, false, environment).output);
        const auto reference = "refs/coincide/checkpoints/" + utf8(unique_suffix());
        run({L"update-ref",L"--no-deref",wide(reference),wide(commit),std::wstring(commit.size(),L'0')});
        return {reference, commit, true};
    }
    GitPreview checkpoint_diff(const std::string& before, const std::string& after, std::size_t limit = 1024 * 1024) {
        require_repository();
        if (!checkpoint_ref(before) || !checkpoint_ref(after) || !limit || limit > maximum_output) throw std::invalid_argument("Select valid Coincide checkpoints");
        auto result = run({L"diff", L"--no-ext-diff", L"--no-textconv", wide(before), wide(after), L"--"}, {}, limit, true);
        const bool binary = result.output.find("Binary files ") != std::string::npos;
        return text_preview(std::move(result.output), result.truncated, binary);
    }
    std::vector<GitCheckpoint> checkpoints(){
        require_repository();const auto output=run({L"for-each-ref",L"--count=200",L"--sort=-committerdate",L"--format=%(refname)%00%(objectname)%00%(committerdate:iso-strict)%00%(subject)%00%(symref)",L"refs/coincide/checkpoints/"}).output;
        std::vector<GitCheckpoint> result;for(auto record:git_parse::split(output,'\n')){if(!record.empty()&&record.back()=='\r')record.remove_suffix(1);if(record.empty())continue;const auto fields=git_parse::split(record,'\0');if(fields.size()!=5||!checkpoint_ref(fields[0])||!object_id(fields[1]))throw std::runtime_error("Git returned unsupported checkpoint metadata");if(!fields[4].empty())continue;
            std::string message(fields[3]);try{(void)wide(message);}catch(...){message="Checkpoint";}result.push_back({std::string(fields[0]),std::string(fields[1]),true,std::move(message),std::string(fields[2])});}return result;
    }
    GitPreview checkpoint_preview(const std::string& reference,const std::string& expected_commit,std::size_t limit=1024*1024){
        require_repository();verify_checkpoint(reference,expected_commit);if(!limit||limit>maximum_output)throw std::invalid_argument("Invalid checkpoint preview bound");
        auto result=run({L"show",L"--format=",L"--no-show-signature",L"--no-ext-diff",L"--no-textconv",L"--patch",wide(expected_commit),L"--"},{},limit,true);return text_preview(std::move(result.output),result.truncated);
    }
    void delete_checkpoint(const std::string& reference,const std::string& expected_commit){
        require_repository();verify_checkpoint(reference,expected_commit);run({L"update-ref",L"--no-deref",L"-d",wide(reference),wide(expected_commit)});
    }
    // Explicit confirmed action only. A scratch HEAD index lets Git perform its checked two-tree
    // update while leaving the user's real index, HEAD, branch and stash untouched. There is no
    // force/reset/clean path: changed/untracked content, ignored collisions and exotic index/tree
    // states are rejected before Git is allowed to update the worktree.
    void restore_checkpoint(const std::string& reference,const std::string& expected_commit,const std::string& expected_head){
        require_repository();verify_checkpoint(reference,expected_commit);const auto current=status();if(current.head!=expected_head)throw std::runtime_error("HEAD changed after the restore prompt; refresh and review the checkpoint again");
        if(!current.files.empty())throw std::runtime_error("Commit or preserve all staged, changed and untracked files before restoring a checkpoint");
        const auto sparse=run({L"config",L"--bool",L"core.sparseCheckout"},{},4096,false,{},true);if(sparse.status==0&&trim_line(sparse.output)=="true")throw std::runtime_error("Checkpoint restore is unavailable in a sparse checkout");
        const auto flags=run({L"ls-files",L"-v",L"-z"}).output;for(const auto entry:git_parse::split(flags,'\0'))if(!entry.empty()&&(entry.front()=='S'||(entry.front()>='a'&&entry.front()<='z')))throw std::runtime_error("Remove skip-worktree or assume-unchanged flags before restoring a checkpoint");
        const auto before=current.head.empty()?trim_line(run({L"mktree"},{},4096).output):current.head;const auto original=tree_files(before),target=tree_files(expected_commit);
        for(const auto& [key,path]:target){
            if(const auto found=original.find(key);found!=original.end()&&found->second!=path)throw std::runtime_error("Case-only checkpoint path changes require manual review on Windows");
            const auto file=folder_/std::filesystem::path(wide(path));if(std::filesystem::exists(file)&&!original.contains(key))throw std::runtime_error("A checkpoint would overwrite an untracked or ignored path; preserve it first");
        }
        auto touched=original;touched.insert(target.begin(),target.end());std::vector<NativeHandle> directory_pins;std::set<std::wstring,PathOrder> pinned;
        const auto pin=[&](const std::filesystem::path& directory){if(!pinned.insert(directory.wstring()).second)return;NativeHandle handle(CreateFileW(directory.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};
            if(handle.get()==INVALID_HANDLE_VALUE||!GetFileInformationByHandle(handle.get(),&info)||!(info.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||(info.dwFileAttributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE)))throw std::runtime_error("A restore directory changed or is linked; no files were restored");directory_pins.push_back(std::move(handle));};pin(folder_);
        // Deletions need the same ancestry protection as writes. Pin ordinary directory
        // ancestors until Git finishes so a junction/rename cannot redirect an inspected path.
        for(const auto& [key,path]:touched){(void)key;
            std::filesystem::path prefix=folder_;for(const auto& part:std::filesystem::path(wide(path))){prefix/=part;const auto attributes=GetFileAttributesW(prefix.c_str());if(attributes==INVALID_FILE_ATTRIBUTES)continue;
                if(attributes&(FILE_ATTRIBUTE_REPARSE_POINT|FILE_ATTRIBUTE_OFFLINE))throw std::runtime_error("A checkpoint path is linked or unavailable; no files were restored");
                if(prefix!=folder_/std::filesystem::path(wide(path))&&!(attributes&FILE_ATTRIBUTE_DIRECTORY))throw std::runtime_error("A checkpoint directory would overwrite an existing file");
                if(attributes&FILE_ATTRIBUTE_DIRECTORY)pin(prefix);
            }
            const auto file=folder_/std::filesystem::path(wide(path));
            if(std::filesystem::exists(file)){NativeHandle handle(CreateFileW(file.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,nullptr,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT,nullptr));BY_HANDLE_FILE_INFORMATION info{};if(handle.get()==INVALID_HANDLE_VALUE||!GetFileInformationByHandle(handle.get(),&info)||info.nNumberOfLinks!=1)throw std::runtime_error("Linked checkpoint targets require manual review");}
        }
        const auto temporary=std::filesystem::temp_directory_path()/(L"coincide-git-restore-"+unique_suffix());if(!std::filesystem::create_directory(temporary))throw std::runtime_error("Could not create the isolated restore index");
        struct Remove{std::filesystem::path path;~Remove(){std::error_code error;std::filesystem::remove_all(path,error);}} cleanup{temporary};const WindowsProcess::Environment environment{{L"GIT_INDEX_FILE",(temporary/L"index").wstring()}};
        run({L"read-tree",wide(before)},{},maximum_output,false,environment);
        run({L"update-index",L"--refresh"},{},maximum_output,false,environment);
        const auto verified=status();if(verified.head!=expected_head||!verified.files.empty())throw std::runtime_error("The repository changed while the restore was prepared; refresh and preserve that work first");
        // Two-tree merging checks the live filesystem again instead of relying only on preflight.
        try{run({L"read-tree",L"-m",L"-u",wide(before),wide(expected_commit)},{},maximum_output,false,environment);}catch(const std::exception& error){throw std::runtime_error("Checkpoint restoration did not finish. Some worktree paths may have changed; HEAD and the real index were retained. Refresh to inspect the files. "+std::string(error.what()));}
    }

private:
    struct Result {DWORD status{}; std::string output; bool truncated{};};
    static constexpr std::size_t maximum_output = 16 * 1024 * 1024;
    std::filesystem::path executable_, folder_;
    bool resolved_{};

    static std::wstring environment_value(const wchar_t* name) {
        const auto count = GetEnvironmentVariableW(name, nullptr, 0);
        if (!count) return {};
        std::wstring result(count, L'\0');
        const auto used = GetEnvironmentVariableW(name, result.data(), count);
        if (!used || used >= count) throw std::runtime_error("A Windows environment value changed while being read");
        result.resize(used); return result;
    }
    static std::wstring wide(std::string_view value) {
        if (value.empty()) return {};
        if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) throw std::length_error("Git argument is too long");
        const auto count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
        if (!count) throw std::runtime_error("A Git path or argument is not valid UTF-8");
        std::wstring result(count, L'\0');
        if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), count)) throw std::runtime_error("Cannot decode a Git argument");
        return result;
    }
    static std::string utf8(std::wstring_view value) {
        if (value.empty()) return {};
        if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) throw std::length_error("Git path is too long");
        const auto count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
        if (!count) throw std::runtime_error("Cannot encode a Windows Git path");
        std::string result(count, '\0');
        if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), count, nullptr, nullptr)) throw std::runtime_error("Cannot encode a Git path");
        return result;
    }
    static std::string trim_line(std::string value) {while (!value.empty() && (value.back() == '\n' || value.back() == '\r')) value.pop_back(); return value;}
    static GitPreview text_preview(std::string value, bool truncated, bool binary = false) {
        if (!binary) {
            bool valid{};
            const auto attempts = truncated ? std::min<std::size_t>(3, value.size()) : 0;
            for (std::size_t removed = 0; removed <= attempts; ++removed) {
                try {(void)wide(std::string_view(value).substr(0, value.size() - removed)); value.resize(value.size() - removed); valid = true; break;}
                catch (const std::runtime_error&) { }
            }
            if (!valid) return {"This preview contains non-UTF-8 data. Open the file in its editor.", truncated, true};
        }
        return {std::move(value), truncated, binary};
    }
    static std::wstring unique_suffix() {
        static std::atomic<unsigned long long> sequence{};
        return std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()) + L"-" + std::to_wstring(++sequence);
    }
    static bool checkpoint_ref(std::string_view value) {
        return value.starts_with("refs/coincide/checkpoints/") && value.size() > 25
            && value.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-") == std::string_view::npos;
    }
    static bool object_id(std::string_view value){return(value.size()==40||value.size()==64)&&value.find_first_not_of("0123456789abcdef")==std::string_view::npos;}
    void verify_checkpoint(const std::string& reference,const std::string& expected){
        if(!checkpoint_ref(reference)||!object_id(expected))throw std::invalid_argument("Select a saved Coincide checkpoint with an exact object identity");
        if(run({L"symbolic-ref",L"--quiet",wide(reference)},{},4096,false,{},true).status==0)throw std::runtime_error("Symbolic checkpoint references require manual review");
        if(trim_line(run({L"rev-parse",L"--verify",L"--end-of-options",wide(reference+"^{commit}")},{},4096).output)!=expected)throw std::runtime_error("This checkpoint changed after selection; refresh before continuing");
    }
    struct PathOrder{bool operator()(const std::wstring& a,const std::wstring& b)const{return CompareStringOrdinal(a.c_str(),static_cast<int>(a.size()),b.c_str(),static_cast<int>(b.size()),TRUE)==CSTR_LESS_THAN;}};
    std::map<std::wstring,std::string,PathOrder> tree_files(const std::string& tree){
        if(!object_id(tree))throw std::invalid_argument("Unsupported checkpoint tree identity");std::map<std::wstring,std::string,PathOrder> result;
        const auto output=run({L"ls-tree",L"-r",L"--full-tree",L"-z",wide(tree)}).output;for(const auto record:git_parse::split(output,'\0'))if(!record.empty()){
            const auto tab=record.find('\t');if(tab==std::string_view::npos||(!record.starts_with("100644 blob ")&&!record.starts_with("100755 blob ")))throw std::runtime_error("Checkpoint restore does not overwrite submodules, symlinks or unsupported tree entries");
            const auto path=std::string(record.substr(tab+1));validate_path(path);if(path.find_first_of("<>:\"\\|?*")!=std::string::npos||folder_.wstring().size()+1+wide(path).size()>32760)throw std::runtime_error("The checkpoint contains a path Windows cannot safely restore");
            for(const auto component:git_parse::split(path,'/')){if(wide(component).size()>255)throw std::runtime_error("A checkpoint filename exceeds the Windows component limit");auto name=std::string(component.substr(0,component.find('.')));for(auto& ch:name)if(ch>='a'&&ch<='z')ch=static_cast<char>(ch-32);if(name=="CON"||name=="PRN"||name=="AUX"||name=="NUL"||name=="CONIN$"||name=="CONOUT$"||name=="CLOCK$"||name=="COM¹"||name=="COM²"||name=="COM³"||name=="LPT¹"||name=="LPT²"||name=="LPT³"||(name.size()==4&&(name.starts_with("COM")||name.starts_with("LPT"))&&name[3]>='1'&&name[3]<='9'))throw std::runtime_error("The checkpoint contains a reserved Windows device path");}
            if(result.size()>=100000||!result.emplace(wide(path),path).second)throw std::runtime_error("Checkpoint paths exceed their bound or collide on Windows");
        }return result;
    }
    static void validate_path(std::string_view value) {
        if (value.empty() || value.size() > 32767 || value.find('\0') != std::string_view::npos || value.front() == '/' || value.front() == '\\'
                || (value.size() > 1 && value[1] == ':')) throw std::invalid_argument("Select a repository-relative Git path");
        std::string normalized(value); std::replace(normalized.begin(), normalized.end(), '\\', '/');
        for (const auto component : git_parse::split(normalized, '/')) {
            if (component.empty() || component == "." || component == ".." || component.back() == '.' || component.back() == ' '
                    || std::any_of(component.begin(), component.end(), [](unsigned char ch) {return ch < 32;})) {
                throw std::invalid_argument("A Git path must name an explicit file inside the project");
            }
            std::string lower(component);
            for (auto& ch : lower) if (ch >= 'A' && ch <= 'Z') ch = static_cast<char>(ch + ('a' - 'A'));
            if (lower == ".git") throw std::invalid_argument("Git metadata cannot be selected as a project file");
        }
        (void)wide(value);
    }
    static std::string path_input(const std::vector<std::string>& paths) {
        if (paths.empty()) throw std::invalid_argument("Select at least one Git path");
        std::string input;
        for (const auto& path : paths) {
            validate_path(path);
            if (path.size() + 1 > maximum_output - input.size()) throw std::length_error("Too many selected Git paths");
            input += path; input += '\0';
        }
        return input;
    }
    void validate_branch(const std::string& branch) {
        if (branch.empty() || branch.front() == '-' || branch.find('\0') != std::string::npos||branch.find("@{")!=std::string::npos) throw std::invalid_argument("Enter a valid branch name");
        run({L"check-ref-format", L"--branch", wide(branch)});
    }
    bool resolve_repository() {
        if (resolved_) return true;
        const auto inside = run({L"rev-parse", L"--is-inside-work-tree"}, {}, 4096, false, {}, true);
        if (inside.status != 0 || trim_line(inside.output) != "true") return false;
        folder_ = std::filesystem::canonical(std::filesystem::path(wide(trim_line(run({L"rev-parse", L"--show-toplevel"}).output))));
        resolved_ = true; return true;
    }
    void require_repository() {if (!resolve_repository()) throw std::runtime_error("The selected project is not a Git working tree");}

    static std::string safe_error(std::string value) {
        // Git errors may repeat an authenticated remote URL. Keep credential-bearing URL components out of UI/logs.
        std::size_t at{};
        while ((at = value.find("://", at)) != std::string::npos) {
            const auto start = at + 3; auto end = value.find_first_of(" \t\r\n'\"<>", start);
            if (end == std::string::npos) end = value.size();
            auto url = value.substr(start, end - start);
            if (const auto credential = url.find('@'); credential != std::string::npos) url.erase(0, credential + 1);
            if (const auto query = url.find('?'); query != std::string::npos) url.replace(query, std::string::npos, "?[redacted]");
            value.replace(start, end - start, url); at = start + url.size();
        }
        return value;
    }
    Result run(const std::vector<std::wstring>& arguments, const std::string& input = {}, std::size_t limit = maximum_output,
            bool allow_truncation = false, const WindowsProcess::Environment& environment = {}, bool allow_failure = false,
            std::chrono::milliseconds timeout = std::chrono::seconds(30)) {
        std::vector<std::wstring> args{L"--no-pager", L"--literal-pathspecs", L"-c", L"color.ui=false", L"-c", L"core.fsmonitor=false",
            L"-c", L"status.relativePaths=false", L"-c",L"core.protectNTFS=true",L"-c", L"credential.interactive=false", L"-c", L"core.askPass="};
        args.insert(args.end(), arguments.begin(), arguments.end());
        Result result;
        WindowsProcess::Environment child{{L"GIT_DIR", std::nullopt}, {L"GIT_WORK_TREE", std::nullopt}, {L"GIT_INDEX_FILE", std::nullopt},
            {L"GIT_COMMON_DIR", std::nullopt}, {L"GIT_OBJECT_DIRECTORY", std::nullopt}, {L"GIT_ALTERNATE_OBJECT_DIRECTORIES", std::nullopt},
            {L"GIT_NAMESPACE", std::nullopt}, {L"GIT_PREFIX", std::nullopt}, {L"GIT_GLOB_PATHSPECS", std::nullopt},
            {L"GIT_NOGLOB_PATHSPECS", std::nullopt}, {L"GIT_ICASE_PATHSPECS", std::nullopt}, {L"GIT_LITERAL_PATHSPECS", L"1"},
            {L"GIT_TERMINAL_PROMPT", L"0"},{L"GIT_OPTIONAL_LOCKS",L"0"}};
        child.insert(child.end(), environment.begin(), environment.end());
        auto process = WindowsProcess::start_bytes(executable_, args, folder_, [&](std::string_view bytes) {result.output.append(bytes);}, limit, child);
        std::thread writer;
        std::exception_ptr input_error;
        if (!input.empty()) writer = std::thread([&] {try {process->write_bytes(input); process->close_input();} catch (...) {input_error = std::current_exception();}});
        else process->close_input();
        try {
            const auto exit = process->wait(timeout);
            if (!exit) {process->stop(); if (writer.joinable()) writer.join(); throw std::runtime_error("The Git operation timed out; its owned processes were stopped");}
            if (writer.joinable()) writer.join();
            result.status = exit->status; result.truncated = exit->stdout_truncated;
            if (!exit->channel_error.empty()) throw std::runtime_error(safe_error(exit->channel_error));
            if (result.truncated) {
                if (!allow_truncation) throw std::runtime_error("Git output exceeded the read limit; refresh or select fewer files");
            } else if (result.status != 0 && !allow_failure) {
                throw std::runtime_error(safe_error(exit->stderr_tail.empty() ? "The Git operation failed" : trim_line(exit->stderr_tail)));
            } else if (result.status == 0 && input_error) std::rethrow_exception(input_error);
            return result;
        } catch (...) {process->stop(); if (writer.joinable()) writer.join(); throw;}
    }
    GitPreview untracked_preview(const std::string& path, std::size_t limit) {
        const auto candidate = folder_ / std::filesystem::path(wide(path));
        const auto attributes = GetFileAttributesW(candidate.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) throw std::runtime_error("The untracked file is no longer available");
        if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) return {"Symbolic link or reparse point: " + path, false, true};
        const auto canonical = std::filesystem::canonical(candidate);
        const auto relative = canonical.lexically_relative(folder_);
        if (relative.empty() || relative.is_absolute() || *relative.begin() == L"..") throw std::runtime_error("The untracked file resolves outside this project");
        std::ifstream stream(canonical, std::ios::binary);
        if (!stream) throw std::runtime_error("Cannot read the selected untracked file");
        std::string bytes(limit + 1, '\0'); stream.read(bytes.data(), static_cast<std::streamsize>(bytes.size())); bytes.resize(static_cast<std::size_t>(stream.gcount()));
        const bool truncated = bytes.size() > limit; if (truncated) bytes.resize(limit);
        const bool binary = bytes.find('\0') != std::string::npos;
        if (binary) return {"Binary untracked file: " + path, truncated, true};
        return text_preview(std::move(bytes), truncated);
    }
};
} // namespace coincide
