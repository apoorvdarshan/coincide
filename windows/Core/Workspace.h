#pragma once

#include <algorithm>
#include <array>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <unordered_set>
#include <utility>
#include <vector>

namespace coincide {

// Wire identifiers match CoincideKit/Models/Models.swift. Display names are localized by the UI.
inline constexpr std::array<std::string_view, 6> provider_ids{
    "claude", "codex", "cursor", "grok", "opencode", "antigravity"};

inline bool known_provider(std::string_view id) {
    return std::find(provider_ids.begin(), provider_ids.end(), id) != provider_ids.end();
}

struct Project {
    std::string id;
    std::string name;
    std::string path;
};

struct Message {
    std::string id;
    std::string role;
    std::string text;
    std::string provider;
};

struct NativeSession {
    std::string provider;
    std::string id;
    std::size_t acknowledged_messages{};
};

struct Thread {
    std::string id;
    std::string title;
    std::optional<std::string> project_id;
    std::string provider{"claude"};
    std::string model;
    std::string draft;
    bool pinned{};
    bool archived{};
    std::vector<Message> messages;
    std::vector<NativeSession> sessions;
};

// The Windows store has its own versioned directory. No Mac store is implicitly imported or rewritten.
class Workspace {
public:
    std::vector<Project> projects;
    std::vector<Thread> threads;

    const Thread& thread(std::string_view id) const {
        const auto at = std::find_if(threads.begin(), threads.end(), [&](const Thread& t) { return t.id == id; });
        if (at == threads.end()) throw std::out_of_range("Unknown thread");
        return *at;
    }

    Thread& thread(std::string_view id) {
        return const_cast<Thread&>(std::as_const(*this).thread(id));
    }

    void add_project(Project project) {
        if (project.id.empty() || project.path.empty()) throw std::invalid_argument("Project needs an identity and folder");
        if (std::any_of(projects.begin(), projects.end(), [&](const Project& p) { return p.id == project.id; })) {
            throw std::invalid_argument("Duplicate project identity");
        }
        projects.push_back(std::move(project));
    }

    void add_thread(Thread value) {
        if (value.id.empty()) throw std::invalid_argument("Thread needs an identity");
        if (!known_provider(value.provider)) throw std::invalid_argument("Unknown provider");
        if (std::any_of(threads.begin(), threads.end(), [&](const Thread& t) { return t.id == value.id; })) {
            throw std::invalid_argument("Duplicate thread identity");
        }
        if (value.project_id && !std::any_of(projects.begin(), projects.end(),
                [&](const Project& p) { return p.id == *value.project_id; })) {
            throw std::invalid_argument("Unknown project");
        }
        threads.push_back(std::move(value));
    }

    // Batch mutations are validated before applying any change, and create one undo step.
    void archive(const std::vector<std::string>& ids, bool archived) {
        std::vector<ArchiveChange> changes;
        std::unordered_set<std::string> seen;
        for (const auto& id : ids) {
            const auto& t = thread(id);
            if (seen.insert(id).second && t.archived != archived) changes.push_back({id, t.archived, archived});
        }
        if (changes.empty()) return;
        for (const auto& change : changes) thread(change.id).archived = change.after;
        undo_.push_back(std::move(changes));
        redo_.clear();
    }

    bool undo_archive() { return replay(undo_, redo_, false); }
    bool redo_archive() { return replay(redo_, undo_, true); }

    std::vector<std::string> visible_threads(std::string_view query = {}, bool archived = false) const {
        std::vector<std::string> result;
        for (const auto& t : threads) {
            if (t.archived == archived && (query.empty() || t.title.find(query) != std::string::npos)) {
                result.push_back(t.id);
            }
        }
        std::stable_sort(result.begin(), result.end(), [&](const auto& a, const auto& b) {
            return thread(a).pinned && !thread(b).pinned;
        });
        return result;
    }

    // Sessions belong to a provider AND a thread. Switching the picker never overwrites another provider's ID.
    void remember_session(std::string_view thread_id, NativeSession session) {
        auto& t = thread(thread_id);
        if (!known_provider(session.provider) || session.id.empty() || session.acknowledged_messages > t.messages.size()) {
            throw std::invalid_argument("Invalid native session");
        }
        auto at = std::find_if(t.sessions.begin(), t.sessions.end(), [&](const NativeSession& s) {
            return s.provider == session.provider;
        });
        if (at == t.sessions.end()) t.sessions.push_back(std::move(session));
        else *at = std::move(session);
    }

    // Structured messages, rather than concatenated prompts, preserve roles and provider attribution.
    std::vector<Message> missed_messages(std::string_view thread_id, std::string_view provider) const {
        if (!known_provider(provider)) throw std::invalid_argument("Unknown provider");
        const auto& t = thread(thread_id);
        const auto session = std::find_if(t.sessions.begin(), t.sessions.end(), [&](const NativeSession& s) {
            return s.provider == provider;
        });
        const auto start = session == t.sessions.end() ? 0 : std::min(session->acknowledged_messages, t.messages.size());
        return {t.messages.begin() + static_cast<std::ptrdiff_t>(start), t.messages.end()};
    }

private:
    struct ArchiveChange { std::string id; bool before; bool after; };
    using History = std::vector<std::vector<ArchiveChange>>;
    History undo_;
    History redo_;

    bool replay(History& from, History& to, bool after) {
        if (from.empty()) return false;
        // Resolve every identity before mutating state so a failed replay is atomic too.
        for (const auto& change : from.back()) (void)thread(change.id);
        auto changes = std::move(from.back());
        from.pop_back();
        for (const auto& change : changes) thread(change.id).archived = after ? change.after : change.before;
        to.push_back(std::move(changes));
        return true;
    }
};

} // namespace coincide
