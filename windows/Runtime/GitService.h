#pragma once
#include "GitModels.h"
#include "WindowsProcess.h"
#include <exception>
#include <fstream>
#include <limits>

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
        if (at == trees.end() || at->main || at->locked || normalized == folder_) {
            throw std::invalid_argument("The selected worktree cannot be removed");
        }
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
        run({L"update-ref", wide(reference), wide(commit)});
        return {reference, commit, true};
    }
    GitPreview checkpoint_diff(const std::string& before, const std::string& after, std::size_t limit = 1024 * 1024) {
        require_repository();
        if (!checkpoint_ref(before) || !checkpoint_ref(after) || !limit || limit > maximum_output) throw std::invalid_argument("Select valid Coincide checkpoints");
        auto result = run({L"diff", L"--no-ext-diff", L"--no-textconv", wide(before), wide(after), L"--"}, {}, limit, true);
        const bool binary = result.output.find("Binary files ") != std::string::npos;
        return text_preview(std::move(result.output), result.truncated, binary);
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
        if (branch.empty() || branch.front() == '-' || branch.find('\0') != std::string::npos) throw std::invalid_argument("Enter a valid branch name");
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
            L"-c", L"status.relativePaths=false", L"-c", L"credential.interactive=false", L"-c", L"core.askPass="};
        args.insert(args.end(), arguments.begin(), arguments.end());
        Result result;
        WindowsProcess::Environment child{{L"GIT_DIR", std::nullopt}, {L"GIT_WORK_TREE", std::nullopt}, {L"GIT_INDEX_FILE", std::nullopt},
            {L"GIT_COMMON_DIR", std::nullopt}, {L"GIT_OBJECT_DIRECTORY", std::nullopt}, {L"GIT_ALTERNATE_OBJECT_DIRECTORIES", std::nullopt},
            {L"GIT_NAMESPACE", std::nullopt}, {L"GIT_PREFIX", std::nullopt}, {L"GIT_GLOB_PATHSPECS", std::nullopt},
            {L"GIT_NOGLOB_PATHSPECS", std::nullopt}, {L"GIT_ICASE_PATHSPECS", std::nullopt}, {L"GIT_LITERAL_PATHSPECS", L"1"},
            {L"GIT_TERMINAL_PROMPT", L"0"}};
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
