#pragma once
#include "../Runtime/GitService.h"
#include <fstream>
#include <functional>

namespace coincide {
inline int git_tests(const std::filesystem::path& report) {
    int checks{};
    auto check = [&](bool value, const char* message) {++checks; if (!value) throw std::runtime_error(message);};
    auto rejects = [&](auto operation, const char* message) {
        bool failed{}; try {operation();} catch (const std::exception&) {failed = true;} check(failed, message);
    };
    auto directory = std::filesystem::temp_directory_path() / (L"Coincide Git tests 会話 " + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring(GetTickCount64()));
    struct Cleanup {
        std::filesystem::path path;
        bool owned{};
        ~Cleanup() {
            if (!owned) return;
            // Git object files may be read-only on Windows. These paths belong only to the unique test fixture.
            std::error_code ignored;
            for (std::filesystem::recursive_directory_iterator at(path, std::filesystem::directory_options::skip_permission_denied, ignored), end;
                    at != end; at.increment(ignored)) {
                if (!at->is_directory(ignored)) SetFileAttributesW(at->path().c_str(), FILE_ATTRIBUTE_NORMAL);
            }
            std::filesystem::remove_all(path, ignored);
        }
    } cleanup{directory};
    try {
        // Protocol parsing preserves raw paths and refuses incomplete records instead of staging an inferred path.
        std::string data = "# branch.oid (initial)"; data += '\0'; data += "# branch.head main"; data += '\0';
        data += "# branch.upstream origin/main"; data += '\0'; data += "# branch.ab +12 -3"; data += '\0';
        data += "1 M. N... 100644 100644 100644 abc def path with spaces.txt"; data += '\0';
        data += "2 R. N... 100644 100644 100644 abc def R100 new 会話.txt"; data += '\0'; data += "old name.txt"; data += '\0';
        data += "u UU N... 100644 100644 100644 100644 a b c conflict.txt"; data += '\0';
        data += "? :(literal)not a wildcard.txt"; data += '\0';
        const auto parsed = git_parse::status(data);
        check(parsed.branch == "main" && parsed.head.empty() && parsed.upstream == "origin/main" && parsed.ahead == 12 && parsed.behind == 3,
            "Git branch metadata and unborn HEAD must parse correctly");
        check(parsed.files.size() == 4 && parsed.files[0].path == "path with spaces.txt" && parsed.files[0].staged(), "ordinary paths must preserve spaces and index state");
        check(parsed.files[1].path == "new 会話.txt" && parsed.files[1].original_path == "old name.txt", "rename paths must retain Unicode and their NUL-separated original");
        check(parsed.files[2].conflicted && parsed.files[2].index_status == 'U', "unmerged entries must be identified explicitly");
        check(parsed.files[3].path == ":(literal)not a wildcard.txt" && parsed.files[3].untracked, "pathspec-looking names must remain literal data");
        rejects([&]{(void)git_parse::status("? incomplete");}, "incomplete status data must fail closed");
        std::string missing_original = "2 R. N... 1 1 1 a b R100 name"; missing_original += '\0';
        rejects([&]{(void)git_parse::status(missing_original);}, "a rename without its original path must fail closed");
        std::string trees = "worktree C:/a folder"; trees += '\0'; trees += "HEAD abc"; trees += '\0'; trees += "branch refs/heads/main"; trees += '\0'; trees += '\0';
        trees += "worktree C:/other"; trees += '\0'; trees += "HEAD def"; trees += '\0'; trees += "locked test reason"; trees += '\0'; trees += '\0';
        const auto parsed_trees = git_parse::worktrees(trees);
        check(parsed_trees.size() == 2 && parsed_trees[0].main && parsed_trees[0].path == "C:/a folder" && parsed_trees[1].locked,
            "worktree paths, main worktree identity and lock state must parse correctly");

        if (!std::filesystem::create_directory(directory)) throw std::runtime_error("The unique Git test directory already exists");
        cleanup.owned = true;
        const auto executable = GitService::discover_git();
        const auto repository = directory / L"repository नमस्ते";
        std::filesystem::create_directory(repository);
        auto command = [&](const std::filesystem::path& cwd, const std::vector<std::wstring>& arguments, bool allow_failure = false) {
            std::string output;
            auto process = WindowsProcess::start_bytes(executable, arguments, cwd, [&](std::string_view bytes){output.append(bytes);}, 4 * 1024 * 1024,
                {{L"GIT_DIR", std::nullopt}, {L"GIT_WORK_TREE", std::nullopt}, {L"GIT_INDEX_FILE", std::nullopt},
                 {L"GIT_COMMON_DIR", std::nullopt}, {L"GIT_OBJECT_DIRECTORY", std::nullopt}, {L"GIT_ALTERNATE_OBJECT_DIRECTORIES", std::nullopt},
                 {L"GIT_NAMESPACE", std::nullopt}, {L"GIT_TERMINAL_PROMPT", L"0"}});
            process->close_input();
            const auto exit = process->wait(std::chrono::seconds(15));
            if (!exit || exit->stdout_truncated || !exit->channel_error.empty() || (!allow_failure && exit->status != 0)) {
                throw std::runtime_error("An isolated Git test command failed: " + (exit ? exit->stderr_tail : "timeout"));
            }
            return std::pair{exit->status, std::move(output)};
        };
        auto write = [&](const std::filesystem::path& path, const std::string& value) {std::ofstream stream(path, std::ios::binary); stream << value; if (!stream) throw std::runtime_error("Cannot write an isolated Git fixture");};
        auto read = [&](const std::filesystem::path& path) {std::ifstream stream(path, std::ios::binary); return std::string(std::istreambuf_iterator<char>(stream), std::istreambuf_iterator<char>{});};
        GitService service(executable, repository);
        check(!service.status().is_repository, "a project outside Git must report that state without inventing a repository");
        command(repository, {L"init", L"-b", L"main"});
        command(repository, {L"config", L"user.name", L"Coincide Git Test"});
        command(repository, {L"config", L"user.email", L"git-test@localhost"});
        command(repository, {L"config", L"commit.gpgsign", L"false"});
        command(repository, {L"config", L"core.autocrlf", L"false"});
        const auto hooks = repository / L".git" / L"coincide-empty-test-hooks";
        std::filesystem::create_directory(hooks);
        command(repository, {L"config", L"core.hooksPath", hooks.wstring()});
        auto status = service.status();
        check(status.is_repository && status.branch == "main" && status.head.empty() && status.files.empty(), "an empty repository must retain its unborn branch");
        write(repository / L"base.txt", "first\n");
        service.stage({"base.txt"});
        check(service.status().files.front().staged(), "staging must update the real isolated Git index");
        service.unstage({"base.txt"});
        check(service.status().files.front().untracked && read(repository / L"base.txt") == "first\n", "unstaging an unborn repository must keep the disk file");
        service.stage({"base.txt"});
        const auto initial = service.commit("Initial isolated Windows Git fixture");
        check(initial.size() >= 40 && service.status().files.empty(), "a normal commit must use the repository identity and leave a clean index");
        const auto branches = service.branches();
        check(branches.size() == 1 && branches[0].name == "main" && branches[0].current, "native branch metadata must identify the checked-out branch");
        {
            struct ScopedEnvironment {
                const wchar_t* name; std::optional<std::wstring> previous;
                ScopedEnvironment(const wchar_t* key, const std::wstring& value) : name(key) {
                    SetLastError(ERROR_SUCCESS);
                    const auto count = GetEnvironmentVariableW(name, nullptr, 0);
                    if (count) {std::wstring old(count, L'\0'); const auto used = GetEnvironmentVariableW(name, old.data(), count); old.resize(used); previous = std::move(old);}
                    else if (GetLastError() != ERROR_ENVVAR_NOT_FOUND) previous = L"";
                    if (!SetEnvironmentVariableW(name, value.c_str())) throw std::runtime_error("Cannot set isolated test environment probe");
                }
                ~ScopedEnvironment(){SetEnvironmentVariableW(name, previous ? previous->c_str() : nullptr);}
            };
            const auto foreign_index = directory / L"parent-index-probe";
            write(foreign_index, "keep this non-index fixture unchanged\n");
            ScopedEnvironment index_probe(L"GIT_INDEX_FILE", foreign_index.wstring());
            ScopedEnvironment directory_probe(L"GIT_DIR", (directory / L"not-the-selected-repository").wstring());
            GitService isolated(executable, repository);
            check(isolated.status().branch == "main", "selected-project Git operations must ignore inherited repository/index context");
            isolated.stage({"base.txt"});
            check(read(foreign_index) == "keep this non-index fixture unchanged\n", "selected-project operations must not overwrite an inherited foreign index");
            wchar_t inherited_index[32768]{};
            const auto length = GetEnvironmentVariableW(L"GIT_INDEX_FILE", inherited_index, 32768);
            check(length && std::wstring_view(inherited_index, length) == foreign_index.wstring(), "Git context isolation must not change the caller's environment");
        }

        write(repository / L"base.txt", "changed\n");
        write(repository / L"file[1].txt", "literal file\n"); write(repository / L"file1.txt", "other file\n");
        write(repository / L"-dash नमस्ते.txt", "Unicode argument\n");
        service.stage({"file[1].txt", "-dash नमस्ते.txt"});
        status = service.status();
        auto find = [](const GitStatus& value, const std::string& path) -> const GitFile& {
            const auto at = std::find_if(value.files.begin(), value.files.end(), [&](const auto& file){return file.path == path;});
            if (at == value.files.end()) throw std::runtime_error("An expected fixture path was not present in Git status");
            return *at;
        };
        check(find(status, "file[1].txt").staged() && find(status, "file1.txt").untracked, "literal staging must not expand bracket patterns into another file");
        check(find(status, "-dash नमस्ते.txt").staged(), "leading-dash Unicode paths must not become Git options");
        const auto staged_before_rejection = command(repository, {L"ls-files", L"--stage", L"-z"}).second;
        rejects([&]{service.stage({":(glob)*"});}, "pathspec syntax must not silently stage every file");
        rejects([&]{service.stage({"base.txt", "../outside.txt"});}, "path traversal in a batch must fail before any index mutation");
        rejects([&]{service.stage({".GIT/config"});}, "Git metadata protection must respect Windows case-insensitive paths");
        rejects([&]{service.stage({".. /outside.txt"});}, "Windows trailing-space aliases must not bypass path traversal checks");
        rejects([&]{service.stage({});}, "an empty selection must not stage the entire repository");
        check(command(repository, {L"ls-files", L"--stage", L"-z"}).second == staged_before_rejection, "invalid selections must leave the user's index unchanged");
        service.unstage({"file[1].txt"});
        check(find(service.status(), "file[1].txt").untracked && find(service.status(), "-dash नमस्ते.txt").staged(), "unstaging must affect only the selected literal path");
        check(service.diff("base.txt").text.find("+changed") != std::string::npos, "unstaged diff must contain the actual working tree change");
        service.stage({"base.txt"});
        check(service.diff("base.txt", true).text.find("+changed") != std::string::npos, "staged diff must read the index instead of the working tree");
        write(repository / L"base.txt", "later\n");
        status = service.status();
        check(find(status, "base.txt").staged() && find(status, "base.txt").unstaged(), "a file with staged and later unstaged changes must expose both states");
        check(service.diff("file1.txt").text == "other file\n", "an untracked file needs its own content preview");
        write(repository / L"large.txt", std::string(8192, 'x'));
        const auto limited = service.diff("large.txt", false, 100);
        check(limited.truncated && limited.text.size() == 100, "untracked previews must be explicitly bounded");
        write(repository / L"unicode.txt", "你好");
        const auto unicode_limit = service.diff("unicode.txt", false, 4);
        check(unicode_limit.truncated && unicode_limit.text == "你", "a truncated UTF-8 preview must end at a complete code point");
        write(repository / L"non-utf8.txt", std::string("\xff\xfe", 2));
        check(service.diff("non-utf8.txt").binary, "non-UTF-8 file data must not crash the native text renderer");
        write(repository / L"base.txt", std::string(8192, 'x') + "\n");
        const auto tracked_limit = service.diff("base.txt", false, 128);
        check(tracked_limit.truncated && tracked_limit.text.size() <= 128, "a tracked diff cap must stop and join its owned Git producer without hanging");
        write(repository / L"base.txt", "later\n");
        write(repository / L"binary.bin", std::string("binary\0bytes", 12));
        check(service.diff("binary.bin").binary, "binary untracked data must not be fed to the text renderer");

        write(repository / L"checkpoint-only.txt", "captured untracked content\n");
        write(repository / L".gitignore", "ignored.txt\n"); write(repository / L"ignored.txt", "ignored fixture content\n");
        const auto index_before = command(repository, {L"ls-files", L"--stage", L"-z"}).second;
        const auto status_before = command(repository, {L"status", L"--porcelain=v2", L"-z", L"--untracked-files=all"}).second;
        const auto stash_before = command(repository, {L"stash", L"list"}).second;
        const auto checkpoint = service.checkpoint();
        check(checkpoint.reference.starts_with("refs/coincide/checkpoints/") && checkpoint.includes_untracked, "a checkpoint must be retained by an owned hidden ref");
        check(command(repository, {L"show", std::wstring(checkpoint.reference.begin(), checkpoint.reference.end()) + L":checkpoint-only.txt"}).second == "captured untracked content\n",
            "checkpoints must include untracked files without staging them in the user's index");
        check(command(repository, {L"cat-file", L"-e", std::wstring(checkpoint.reference.begin(), checkpoint.reference.end()) + L":ignored.txt"}, true).first != 0,
            "ignored files must remain outside checkpoints");
        check(command(repository, {L"ls-files", L"--stage", L"-z"}).second == index_before, "checkpoint capture must preserve the user's staged blob identities exactly");
        check(command(repository, {L"status", L"--porcelain=v2", L"-z", L"--untracked-files=all"}).second == status_before,
            "checkpoint capture must leave tracked, staged and untracked working tree state unchanged");
        check(command(repository, {L"stash", L"list"}).second == stash_before && read(repository / L"base.txt") == "later\n", "checkpoint capture must not touch the user's stash or disk content");
        write(repository / L"base.txt", "checkpoint change\n");
        const auto after = service.checkpoint("Second isolated checkpoint");
        check(service.checkpoint_diff(checkpoint.reference, after.reference).text.find("+checkpoint change") != std::string::npos,
            "checkpoint diff must compare the captured trees rather than current index state");

        const auto other = directory / L"other worktree 会話";
        service.add_worktree(other, "native-git-test", true);
        check(service.worktrees().size() == 2 && std::filesystem::is_directory(other), "a new worktree must be created on its requested branch");
        rejects([&]{service.switch_branch("native-git-test");}, "branch switching must respect another worktree's checked-out branch");
        write(other / L"keep-untracked.txt", "owned test content\n");
        rejects([&]{service.remove_worktree(other);}, "worktree removal must refuse untracked or uncommitted work");
        check(std::filesystem::exists(other / L"keep-untracked.txt"), "a rejected worktree removal must preserve its disk content");
        std::filesystem::remove(other / L"keep-untracked.txt"); // Only this test's explicitly created file.
        service.remove_worktree(other);
        check(!std::filesystem::exists(other) && service.worktrees().size() == 1, "a clean secondary worktree may be removed without force");
        service.switch_branch("native-git-test");
        check(service.status().branch == "native-git-test" && read(repository / L"base.txt") == "checkpoint change\n", "switching compatible branches must preserve the existing working tree");
        service.switch_branch("main");
        check(service.status().branch == "main", "switching back must restore the selected branch without resetting files");
        rejects([&]{service.remove_worktree(repository);}, "the main/current worktree must never be removed by this action");
        rejects([&]{service.switch_branch("--orphan");}, "a branch name must not become a checkout option");
        rejects([&]{service.push("https://invalid.example/repository");}, "push accepts only a selected existing remote name, never an injected URL or transport");
        rejects([&]{service.push("--all");}, "push must not reinterpret a remote as a force or all-refs option");

        const auto unborn = directory / L"unborn checkpoint";
        std::filesystem::create_directory(unborn); command(unborn, {L"init", L"-b", L"main"});
        write(unborn / L"new.txt", "unborn snapshot\n");
        GitService fresh(executable, unborn);
        const auto first_checkpoint = fresh.checkpoint();
        check(!first_checkpoint.commit.empty() && fresh.status().head.empty(), "checkpoint capture before the first commit must not create or advance HEAD");
        check(!std::filesystem::exists(unborn / L".git" / L"index") && fresh.status().files.front().untracked, "an unborn checkpoint must not create the user's index");

        std::ofstream output(report); output << "PASS: " << checks << " Windows Git checks\n"; return output ? 0 : 2;
    } catch (const std::exception& error) {std::ofstream(report) << "FAIL: " << error.what() << '\n';}
    return 1;
}
} // namespace coincide
