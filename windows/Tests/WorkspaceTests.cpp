#include "../Core/Workspace.h"
#include "../Core/LineFramer.h"
#include <iostream>
#include <functional>
#ifdef _WIN32
#include "ProcessTests.h"
#include "TerminalTests.h"
#endif

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

int run_workspace_tests() {
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

        // Lifecycle actions share one bounded undo history, but never snapshot live transcript content.
        coincide::Workspace lifecycle;
        lifecycle.add_project({"p", "  A project  ", "C:\\Projects\\Keep this folder"});
        lifecycle.add_project({"q", "Other Project", "C:\\Projects\\Other"});
        auto first = thread("first"); first.project_id = "p"; first.updated_at = 200;
        first.messages.push_back({"original", "assistant", "A retained reply", "codex"});
        first.sessions.push_back({"codex", "retained-native-session", 1}); first.draft = "Retained unsent draft";
        first.draft_attachments.push_back({"C:\\images\\猫.png", "猫.png", "image/png"});
        lifecycle.add_thread(first);
        auto second = thread("second"); second.project_id = "p"; second.updated_at = 100; lifecycle.add_thread(second);
        auto third = thread("third"); third.updated_at = 300; lifecycle.add_thread(third);
        check(lifecycle.project("p").name == "A project", "project names must be trimmed");
        check(lifecycle.visible_threads() == std::vector<std::string>{"third", "first", "second"}, "new activity must sort first within an unpinned group");
        lifecycle.pin({"second", "second"}, true);
        check(lifecycle.visible_threads().front() == "second", "pinning must outrank recent activity");
        check(lifecycle.undo() && !lifecycle.thread("second").pinned, "duplicate batch identities must create only one undo action");
        check(lifecycle.redo() && lifecycle.thread("second").pinned, "pinning needs redo");
        rejects([&] {lifecycle.pin({"first", "unknown"}, true);}, "a pin batch must validate all identities");
        check(!lifecycle.thread("first").pinned, "a rejected batch must leave earlier members unchanged");

        lifecycle.rename_thread("first", "  Café Σίσυφος ПРИВЕТ Straße\u2003");
        check(lifecycle.thread("first").title == "Café Σίσυφος ПРИВЕТ Straße" && lifecycle.thread("first").titled_by_user,
            "manual names must be trimmed and remembered");
        for (const auto query : {"CAFÉ", "ΣΊΣΥΦΟΣ", "привет", "STRASSE"}) {
            check(lifecycle.visible_threads(query) == std::vector<std::string>{"first"}, "search must case-fold multilingual names and expansions");
        }
        check(lifecycle.visible_threads("OTHER PROJECT").empty(), "project search must not include unrelated conversations");
        check(lifecycle.visible_threads("a PROJECT").size() == 2, "search must match the associated project name");
        check(coincide::workspace_text::fold("İ") == "i\u0307", "case folding must retain a combining mark in a one-to-many mapping");
        rejects([&] {lifecycle.rename_thread("first", "\u2003\u00a0");}, "Unicode whitespace alone is not a valid name");
        rejects([&] {lifecycle.rename_thread("first", std::string(4097, 'x'));}, "oversized conversation names must be rejected");
        rejects([&] {lifecycle.rename_thread("first", "a\nb");}, "names must not contain interior line breaks");
        rejects([&] {lifecycle.rename_thread("first", std::string("bad\0name", 8));}, "names must not contain embedded NULs");
        rejects([&] {lifecycle.visible_threads(std::string("\xc0\xaf", 2));}, "overlong UTF-8 must be rejected rather than ambiguously searched");
        rejects([&] {lifecycle.visible_threads(std::string("\xed\xa0\x80", 3));}, "surrogate UTF-8 must be rejected");
        rejects([&] {lifecycle.rename_project("p", " \t ");}, "a project cannot be renamed to blank text");
        check(lifecycle.project("p").path == "C:\\Projects\\Keep this folder", "renaming must preserve the on-disk project location");

        lifecycle.settle({"first"}, true, 5000);
        check(coincide::Workspace::is_settled(lifecycle.thread("first")), "settled state must refer to the latest activity");
        check(lifecycle.listed_threads(coincide::ThreadView::settled, {}, 5500) == std::vector<std::string>{"first"}, "settled conversations need their own view");
        check(lifecycle.visible_threads("STRASSE", false, 5500).empty(), "settled conversations must leave the inbox");
        lifecycle.note_activity("first", 5000);
        check(!coincide::Workspace::is_settled(lifecycle.thread("first")), "activity in the same clock second must reopen settlement");
        lifecycle.note_activity("first", 4000);
        check(lifecycle.thread("first").updated_at == 5000, "clock movement must not reorder activity backwards");
        lifecycle.settle({"first"}, true, 4000);
        check(coincide::Workspace::is_settled(lifecycle.thread("first")), "settlement must work even after the system clock moves backwards");
        lifecycle.settle({"first"}, false);
        lifecycle.snooze({"first"}, 6000);
        check(lifecycle.visible_threads("STRASSE", false, 5999).empty(), "a snoozed conversation must be hidden before its deadline");
        check(lifecycle.visible_threads("STRASSE", false, 6000) == std::vector<std::string>{"first"}, "snoozed conversations must return exactly at their deadline");
        check(lifecycle.listed_threads(coincide::ThreadView::snoozed, {}, 5999) == std::vector<std::string>{"first"}, "snoozed conversations must remain discoverable");
        lifecycle.note_activity("first", 5500);
        check(lifecycle.thread("first").snoozed_until == 6000, "background output must not wake a snooze early");
        lifecycle.note_activity("first", 5500, true);
        check(!lifecycle.thread("first").snoozed_until, "an input request must wake its snoozed conversation");
        rejects([&] {lifecycle.snooze({"first", "second"}, -1);}, "negative timestamps must fail before changing a batch");
        rejects([&] {lifecycle.delete_threads({"first"}, 0);}, "soft deletion needs a nonzero timestamp");

        lifecycle.delete_threads({"first", "second", "first"}, 7000);
        check(lifecycle.listed_threads(coincide::ThreadView::trash).size() == 2, "soft-deleted conversations must remain in trash");
        check(lifecycle.listed_threads(coincide::ThreadView::all) == std::vector<std::string>{"third"}, "deleted conversations must leave ordinary and archived views");
        check(lifecycle.thread("first").messages.size() == 1 && lifecycle.thread("first").sessions.front().id == "retained-native-session",
            "soft deletion must retain transcripts and provider sessions");
        lifecycle.thread("first").draft = "A newer draft";
        lifecycle.thread("first").messages.push_back({"later", "assistant", "A later reply", "codex"});
        check(lifecycle.undo() && !lifecycle.thread("first").deleted_at && !lifecycle.thread("second").deleted_at, "one undo must restore a whole deleted batch");
        check(lifecycle.thread("first").draft == "A newer draft" && lifecycle.thread("first").messages.size() == 2
                && lifecycle.thread("first").draft_attachments.front().name == "猫.png",
            "undo must not roll back a newer draft, attachment, or streamed message");
        check(lifecycle.redo() && lifecycle.listed_threads(coincide::ThreadView::trash).size() == 2, "deletion redo must not discard the saved content");
        lifecycle.restore_threads({"first", "second"});
        check(lifecycle.listed_threads(coincide::ThreadView::trash).empty(), "explicit restore must empty the selected trash entries");
        rejects([&] {lifecycle.move_threads({"first", "second"}, "missing");}, "moves must validate the destination before applying");
        check(lifecycle.thread("first").project_id == std::optional<std::string>("p"), "failed moves must preserve the original project");
        lifecycle.move_threads({"first", "second"}, "q");
        check(lifecycle.thread("first").project_id == std::optional<std::string>("q") && lifecycle.thread("second").project_id == std::optional<std::string>("q"), "batch moves must reach every selected conversation");
        check(lifecycle.undo() && lifecycle.thread("first").project_id == std::optional<std::string>("p"), "moving conversations needs undo");
        lifecycle.rename_project("p", " Renamed project ");
        check(lifecycle.project("p").name == "Renamed project", "project renaming must normalize its label");
        check(lifecycle.undo() && lifecycle.project("p").name == "A project", "project renaming needs undo");
        lifecycle.remove_project("p");
        check(lifecycle.projects.size() == 1 && !lifecycle.thread("first").project_id && !lifecycle.thread("second").project_id,
            "project removal must detach every conversation without deleting it");
        lifecycle.note_activity("first", 8000);
        check(lifecycle.undo() && lifecycle.project("p").path == "C:\\Projects\\Keep this folder"
                && lifecycle.thread("first").project_id == std::optional<std::string>("p"), "project removal undo must restore its folder metadata and memberships");
        check(lifecycle.thread("first").updated_at == 8000 && lifecycle.thread("first").sessions.front().id == "retained-native-session",
            "project undo must preserve later activity and session history");
        check(lifecycle.redo() && !lifecycle.thread("first").project_id, "project removal redo must detach without erasing data");
        check(lifecycle.undo(), "the removed project must remain recoverable");
        lifecycle.add_thread(thread("created-after-undo"));
        check(!lifecycle.can_redo(), "creating another conversation must invalidate old redo actions");

        coincide::Workspace history;
        history.add_thread(thread("one")); history.add_thread(thread("two"));
        history.pin({"one", "two"}, true); history.threads.pop_back();
        rejects([&] {history.undo();}, "undo must validate all identities before changing any member");
        check(history.thread("one").pinned && history.can_undo(), "failed undo must preserve state and the recoverable history entry");
        coincide::Workspace scoped;
        scoped.add_thread(thread("one")); scoped.pin({"one"}, true);
        scoped.thread("one").title = "A later title"; scoped.thread("one").draft = "A later draft";
        check(scoped.undo() && !scoped.thread("one").pinned && scoped.thread("one").title == "A later title"
                && scoped.thread("one").draft == "A later draft", "undo must restore only fields the original action owned");
        scoped.pin({"one"}, false);
        check(scoped.can_redo(), "no-op actions must not discard redo history");
        for (int i = 0; i < 30; ++i) scoped.pin({"one"}, i % 2 == 0);
        int undos{}; while (scoped.undo()) ++undos;
        check(undos == 20, "session undo history must have a bounded number of actions");

        coincide::Workspace models;
        auto preferred = thread("preferences"); preferred.model = "claude-model"; preferred.effort = "high";
        preferred.service_tier = "priority"; preferred.plan = true; preferred.full_access = true;
        preferred.draft = "An unsent draft"; preferred.draft_attachments = {{"C:\\draft.png", "draft.png", "image/png"}};
        preferred.messages.push_back({"history", "user", "Existing context", ""});
        preferred.sessions = {{"claude", "claude-native", 1}, {"codex", "codex-native", 0}};
        models.add_thread(preferred); models.add_thread(thread("unrelated"));
        models.select_provider("preferences", "codex");
        check(models.thread("preferences").provider == "codex" && models.thread("preferences").model.empty()
                && models.thread("preferences").effort.empty() && !models.thread("preferences").plan && !models.thread("preferences").full_access,
            "a new provider must start with its own safe defaults rather than another provider's model or access choice");
        check(models.thread("preferences").draft == preferred.draft && models.thread("preferences").draft_attachments.size() == 1
                && models.thread("preferences").messages.size() == 1 && models.thread("preferences").sessions.size() == 2,
            "switching providers must preserve the transcript, draft, attachments, and native session histories");
        models.thread("preferences").model = "codex-model"; models.thread("preferences").effort = "xhigh";
        models.select_provider("preferences", "claude");
        check(models.thread("preferences").model == "claude-model" && models.thread("preferences").effort == "high"
                && models.thread("preferences").service_tier == "priority" && models.thread("preferences").plan && models.thread("preferences").full_access,
            "returning to a provider must restore its complete captured preferences");
        models.select_provider("preferences", "codex");
        check(models.thread("preferences").model == "codex-model" && models.thread("preferences").effort == "xhigh"
                && !models.thread("preferences").full_access, "a provider's model and permissions must remain isolated");
        rejects([&] {models.select_provider("preferences", "not-a-provider");}, "unknown provider selections must fail before mutating state");
        check(models.thread("preferences").provider == "codex" && models.thread("preferences").model == "codex-model",
            "a rejected selection must retain the current provider and model");
        models.select_provider("preferences", "codex");
        check(models.thread("preferences").model_preferences.size() == 2, "reselecting a provider must not duplicate its preference entry");
        models.select_provider("unrelated", "codex");
        check(models.thread("unrelated").model.empty(), "model choices must not leak to another conversation");
        models.pin({"preferences"}, true); models.select_provider("preferences", "claude");
        check(models.undo() && models.thread("preferences").provider == "claude" && models.thread("preferences").model == "claude-model",
            "lifecycle undo must not rewind a later provider selection");

        // Exercise realistic long histories without constructing UI controls for every message.
        for (int i = 0; i < 10000; ++i) messages.push_back({std::to_string(i + 5), "assistant", "A streamed reply", "codex"});
        w.remember_session("a", {"claude", "claude-session", messages.size() - 1});
        check(w.missed_messages("a", "claude").size() == 1, "long histories must not replay acknowledged messages");
        const std::string stream = "one\r\nनमस्ते\nlast";
        for (std::size_t split = 0; split <= stream.size(); ++split) {
            coincide::LineFramer framer;
            std::vector<std::string> framed;
            auto emit = [&](std::string line) {framed.push_back(std::move(line));};
            framer.consume(std::string_view(stream).substr(0, split), emit);
            framer.consume(std::string_view(stream).substr(split), emit);
            framer.finish(emit);
            check(framed == std::vector<std::string>{"one", "नमस्ते", "last"}, "JSONL framing must preserve every possible chunk boundary");
        }
        coincide::LineFramer bounded(4);
        bounded.consume("1234", [](auto){});
        rejects([&]{bounded.consume("5", [](auto){});}, "oversized lines must fail instead of growing without bound");
#ifdef _WIN32
        coincide::process_tests(check, [](auto operation, const char* message){rejects(operation, message);});
#endif
        std::cout << checks << " workspace/process checks passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}

#ifdef _WIN32
int wmain(int argc, wchar_t** argv) {
    if (argc > 1 && std::wstring_view(argv[1]) == L"--process-fixture") return coincide::process_fixture(argc, argv);
    if (argc > 1 && std::wstring_view(argv[1]) == L"--terminal-fixture") return coincide::terminal_fixture(argc, argv);
    return run_workspace_tests();
}
#else
int main() { return run_workspace_tests(); }
#endif
