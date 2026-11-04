#pragma once
#include <charconv>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace coincide {
struct GitFile {
    std::string path, original_path;
    char index_status{'.'}, worktree_status{'.'};
    bool untracked{}, conflicted{};
    bool staged() const {return !untracked && index_status != '.' && index_status != ' ';}
    bool unstaged() const {return untracked || (worktree_status != '.' && worktree_status != ' ');}
};
struct GitStatus {
    bool is_repository{};
    std::string root, branch, head, upstream;
    int ahead{}, behind{};
    std::vector<GitFile> files;
};
struct GitPreview {std::string text; bool truncated{}, binary{};};
struct GitBranch {
    std::string name, upstream, worktree_path;
    bool remote{}, current{};
};
struct GitWorktree {
    std::string path, branch, head;
    bool main{}, locked{}, prunable{};
};
struct GitCheckpoint {std::string reference, commit; bool includes_untracked{true};};

namespace git_parse {
inline std::vector<std::string_view> split(std::string_view input, char separator) {
    std::vector<std::string_view> result;
    for (;;) {
        const auto at = input.find(separator);
        if (at == std::string_view::npos) {result.push_back(input); break;}
        result.push_back(input.substr(0, at)); input.remove_prefix(at + 1);
    }
    return result;
}
inline int nonnegative(std::string_view value) {
    int result{};
    const auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
    if (value.empty() || parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size() || result < 0) {
        throw std::runtime_error("Git returned an invalid branch count");
    }
    return result;
}
// Paths are raw NUL-delimited bytes: spaces, UTF-8, quotes and pathspec-looking names are not unquoted or split.
inline GitStatus status(std::string_view output) {
    GitStatus result; result.is_repository = true;
    if (!output.empty() && output.back() != '\0') throw std::runtime_error("Git returned incomplete status output");
    const auto records = split(output, '\0');
    for (std::size_t i = 0; i < records.size(); ++i) {
        const auto record = records[i];
        if (record.empty()) continue;
        if (record.starts_with("# ")) {
            const auto space = record.find(' ', 2);
            if (space == std::string_view::npos) continue;
            const auto key = record.substr(2, space - 2), value = record.substr(space + 1);
            if (key == "branch.oid" && value != "(initial)") result.head = value;
            else if (key == "branch.head" && value != "(detached)") result.branch = value;
            else if (key == "branch.upstream") result.upstream = value;
            else if (key == "branch.ab") {
                const auto numbers = split(value, ' ');
                if (numbers.size() != 2 || !numbers[0].starts_with('+') || !numbers[1].starts_with('-')) {
                    throw std::runtime_error("Git returned invalid upstream counts");
                }
                result.ahead = nonnegative(numbers[0].substr(1)); result.behind = nonnegative(numbers[1].substr(1));
            }
            continue;
        }
        const char kind = record.front();
        if (kind == '!') continue;
        const std::size_t fields = kind == '1' ? 8 : kind == '2' ? 9 : kind == 'u' ? 10 : kind == '?' ? 1 : 0;
        if (!fields) throw std::runtime_error("Git returned an unsupported status record");
        std::size_t path_start{};
        std::string_view xy;
        for (std::size_t field = 0; field < fields; ++field) {
            const auto next = record.find(' ', path_start);
            if (next == std::string_view::npos) throw std::runtime_error("Git returned a malformed file status");
            if (field == 1) xy = record.substr(path_start, next - path_start);
            path_start = next + 1;
        }
        GitFile file;
        file.path = record.substr(path_start); file.untracked = kind == '?'; file.conflicted = kind == 'u';
        if (file.path.empty()) throw std::runtime_error("Git returned an empty file path");
        if (file.untracked) {file.index_status = '?'; file.worktree_status = '?';}
        else {
            if (xy.size() != 2) throw std::runtime_error("Git returned an invalid index/worktree status");
            file.index_status = xy[0]; file.worktree_status = xy[1];
        }
        if (kind == '2') {
            if (++i >= records.size() || records[i].empty()) throw std::runtime_error("Git omitted the original rename path");
            file.original_path = records[i];
        }
        result.files.push_back(std::move(file));
    }
    return result;
}
inline std::vector<GitWorktree> worktrees(std::string_view output) {
    if (!output.empty() && output.back() != '\0') throw std::runtime_error("Git returned incomplete worktree output");
    std::vector<GitWorktree> result;
    std::optional<GitWorktree> current;
    auto finish = [&] {if (current) {result.push_back(std::move(*current)); current.reset();}};
    for (const auto field : split(output, '\0')) {
        if (field.empty()) {finish(); continue;}
        if (field.starts_with("worktree ")) {finish(); current.emplace(); current->path = field.substr(9); current->main = result.empty();}
        else if (current && field.starts_with("HEAD ")) current->head = field.substr(5);
        else if (current && field.starts_with("branch ")) {
            const auto ref = field.substr(7); current->branch = ref.starts_with("refs/heads/") ? ref.substr(11) : ref;
        } else if (current && (field == "locked" || field.starts_with("locked "))) current->locked = true;
        else if (current && (field == "prunable" || field.starts_with("prunable "))) current->prunable = true;
    }
    finish(); return result;
}
inline std::vector<GitBranch> branches(std::string_view output) {
    std::vector<GitBranch> result;
    for (auto record : split(output, '\n')) {
        if (!record.empty() && record.back() == '\r') record.remove_suffix(1);
        if (record.empty()) continue;
        const auto fields = split(record, '\0');
        if (fields.size() != 5) throw std::runtime_error("Git returned malformed branch metadata");
        if (!fields[4].empty()) continue; // Skip symbolic remote HEAD aliases.
        GitBranch branch;
        branch.remote = fields[0].starts_with("refs/remotes/");
        if (!branch.remote && !fields[0].starts_with("refs/heads/")) continue;
        branch.name = fields[0].substr(branch.remote ? 13 : 11); branch.upstream = fields[1];
        branch.current = fields[2] == "*"; branch.worktree_path = fields[3]; result.push_back(std::move(branch));
    }
    return result;
}
} // namespace git_parse
} // namespace coincide
