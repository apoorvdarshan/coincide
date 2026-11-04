#include "../Core/Workspace.h"
#include <iostream>
#include <functional>

namespace {
int checks{};
void check(bool value, const char* message) {
    ++checks;
    if (!value) throw std::runtime_error(message);
}
template<class F> void rejects(F operation, const char* message) {
    bool rejected = false;
    try { operation(); } catch (const std::exception&) { rejected = true; }
    check(rejected, message);
}
coincide::Thread thread(std::string id, std::string provider = "claude") {
    coincide::Thread t;
    t.id = std::move(id);
    t.title = "A saved conversation";
    t.provider = std::move(provider);
    return t;
}
}

int main() {
    try {
        coincide::Workspace w;
        w.add_project({"p", "A project", "C:\\Projects\\A folder"});
        auto a = thread("a");
        a.project_id = "p";
        a.draft = "Unsent text\nwith Unicode: नमस्ते";
        w.add_thread(a);
        w.add_thread(thread("b", "codex"));
        check(w.thread("a").draft == a.draft, "drafts must survive thread switches");
        check(!w.thread("b").project_id, "projectless chats must remain projectless");
        rejects([&] { w.add_thread(a); }, "duplicate thread IDs must fail");
        auto missing = thread("orphan"); missing.project_id = "absent";
        rejects([&] { w.add_thread(missing); }, "unknown projects must fail");
        rejects([&] { w.add_thread(thread("unknown", "unknown")); }, "unknown agents must fail");
        check(w.threads.size() == 2, "rejected inserts must not change the workspace");

        rejects([&] { w.archive({"a", "missing"}, true); }, "invalid batches must fail");
        check(!w.thread("a").archived, "batch validation must happen before any mutation");
        w.archive({"a", "a", "b"}, true);
        check(w.visible_threads().empty(), "archived threads must leave the inbox");
        check(w.visible_threads({}, true).size() == 2, "archive must retain both conversations");
        check(w.undo_archive(), "a batch archive needs undo");
        check(!w.thread("a").archived && !w.thread("b").archived, "one undo must restore the complete batch");
        check(w.redo_archive(), "undo needs redo");
        check(w.thread("a").archived && w.thread("b").archived, "redo must restore the complete batch");
        check(w.undo_archive(), "second undo must succeed");
        w.archive({"a"}, true);
        check(!w.redo_archive(), "a new mutation must discard the old redo history");

        w.thread("b").pinned = true;
        w.archive({"a"}, false);
        check(w.visible_threads().front() == "b", "pinned threads must sort before unpinned threads");
        w.thread("a").title = "Find this exact thread";
        check(w.visible_threads("exact") == std::vector<std::string>{"a"}, "search must filter titles");

        auto& messages = w.thread("a").messages;
        messages.push_back({"1", "user", "First question", ""});
        messages.push_back({"2", "assistant", "Claude answer", "claude"});
        w.remember_session("a", {"claude", "claude-session", 2});
        messages.push_back({"3", "user", "Switch to Codex", ""});
        messages.push_back({"4", "assistant", "Codex answer", "codex"});
        w.remember_session("a", {"codex", "codex-session", 4});
        const auto missed = w.missed_messages("a", "claude");
        check(missed.size() == 2 && missed.front().id == "3", "a resumed provider needs exactly the messages it missed");
        check(missed.back().provider == "codex", "handoffs must preserve provider attribution");
        check(w.missed_messages("a", "codex").empty(), "a current session must not replay old turns");
        check(w.missed_messages("a", "grok").size() == 4, "a new provider needs the complete conversation");
        check(w.missed_messages("b", "claude").empty(), "sessions must never leak across threads");
        check(w.thread("a").sessions.size() == 2, "switching agents must preserve both native sessions");
        rejects([&] { w.remember_session("a", {"claude", "invalid", 5}); }, "out-of-range acknowledgements must fail");
        check(w.thread("a").sessions.front().id == "claude-session", "invalid updates must preserve the prior session");

        // Exercise realistic long histories without constructing UI controls for every message.
        for (int i = 0; i < 10000; ++i) messages.push_back({std::to_string(i + 5), "assistant", "A streamed reply", "codex"});
        w.remember_session("a", {"claude", "claude-session", messages.size() - 1});
        check(w.missed_messages("a", "claude").size() == 1, "long histories must not replay acknowledged messages");
        std::cout << checks << " workspace checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
