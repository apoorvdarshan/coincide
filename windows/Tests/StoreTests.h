#pragma once
#include "../App/WorkspaceStore.h"

namespace coincide {
inline int store_tests(const std::filesystem::path& report) {
    auto root = std::filesystem::temp_directory_path() / ("coincide-store-test-" + new_id());
    std::filesystem::create_directories(root);
    int checks = 0;
    auto check = [&](bool condition, const char* failure) {
        ++checks;
        if (!condition) throw std::runtime_error(failure);
    };
    auto rejects = [&](auto&& operation, const char* failure) {
        bool rejected = false;
        try { operation(); } catch (...) { rejected = true; }
        check(rejected, failure);
    };
    auto contents = [](const std::filesystem::path& path) {
        std::ifstream stream(path, std::ios::binary);
        return std::string((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
    };
    try {
        const auto project_id = new_id(); const auto thread_id = new_id();
        WorkspaceStore first(root);
        auto workspace = first.open();
        workspace.add_project({project_id, "Unicode project — नमस्ते", "C:\\A folder\\Project"});
        Thread thread;
        thread.id = thread_id; thread.title = "A saved thread"; thread.project_id = project_id;
        workspace.add_thread(thread);
        first.load_thread(workspace.thread(thread_id));
        auto& value = workspace.thread(thread_id);
        value.draft = "An unsent draft\n你好";
        value.messages.push_back({new_id(), "user", "A question with Unicode: नमस्ते", ""});
        workspace.remember_session(thread_id, {"claude", "native-session", 1});
        first.save_thread(value); first.save_index(workspace);

        WorkspaceStore second(root);
        auto loaded = second.open();
        check(loaded.thread(thread_id).messages.empty(), "startup must load only the index");
        second.load_thread(loaded.thread(thread_id));
        check(loaded.thread(thread_id).draft == value.draft, "draft round trip failed");
        check(loaded.thread(thread_id).messages.front().text == value.messages.front().text, "Unicode message round trip failed");
        check(loaded.thread(thread_id).sessions.front().id == "native-session", "native session round trip failed");
        check(loaded.projects.front().path == workspace.projects.front().path, "Windows project paths must round trip");
        const auto transcript_path = root / "threads" / winrt::to_hstring(thread_id + ".json").c_str();
        const auto index_path = root / "workspace.json";

        // Add fields from a future client, then edit only known fields through the current store.
        auto doc = json::JsonObject::Parse(winrt::to_hstring(contents(transcript_path)));
        doc.SetNamedValue(L"future", json::JsonValue::CreateStringValue(L"preserve me"));
        doc.GetNamedArray(L"messages").GetAt(0).GetObject().SetNamedValue(L"futureMessage", json::JsonValue::CreateBooleanValue(true));
        {std::ofstream stream(transcript_path, std::ios::binary); stream << winrt::to_string(doc.Stringify());}
        WorkspaceStore third(root); auto round_trip = third.open(); third.load_thread(round_trip.thread(thread_id));
        round_trip.thread(thread_id).draft = "Edited draft";
        third.save_thread(round_trip.thread(thread_id));
        auto saved = json::JsonObject::Parse(winrt::to_hstring(contents(transcript_path)));
        check(saved.GetNamedString(L"future") == L"preserve me", "unknown transcript fields must survive edits");
        check(saved.GetNamedArray(L"messages").GetAt(0).GetObject().GetNamedBoolean(L"futureMessage"), "unknown message fields must survive edits");

        WorkspaceStore unopened(root); auto unopened_workspace = unopened.open();
        rejects([&]{unopened.save_thread(unopened_workspace.thread(thread_id));}, "unloaded transcripts must never be overwritten");

        std::filesystem::remove(transcript_path);
        WorkspaceStore missing(root); auto missing_workspace = missing.open();
        rejects([&]{missing.load_thread(missing_workspace.thread(thread_id));}, "missing transcripts must not be silently replaced");
        check(!std::filesystem::exists(transcript_path), "a failed load must not create a replacement");

        {std::ofstream stream(index_path, std::ios::binary); stream << "{ invalid JSON";}
        const auto invalid = contents(index_path);
        WorkspaceStore invalid_store(root);
        rejects([&]{(void)invalid_store.open();}, "malformed workspaces must fail closed");
        check(contents(index_path) == invalid, "malformed workspaces must remain untouched");
        {std::ofstream stream(index_path, std::ios::binary); stream << R"({"version":2,"projects":[],"threads":[]})";}
        const auto future = contents(index_path);
        WorkspaceStore future_store(root);
        rejects([&]{(void)future_store.open();}, "future store versions must fail closed");
        check(contents(index_path) == future, "future store versions must remain untouched");

        std::filesystem::remove_all(root);
        std::ofstream output(report);
        output << "PASS: " << checks << " Windows store checks\n";
        if (!output) return 2;
        return 0;
    } catch (const winrt::hresult_error& error) {
        std::ofstream(report) << "FAIL: " << winrt::to_string(error.message()) << '\n';
    } catch (const std::exception& error) {
        std::ofstream(report) << "FAIL: " << error.what() << '\n';
    }
    // Only the unique temporary test directory is cleaned up, including on a failing test.
    std::error_code ignored; std::filesystem::remove_all(root, ignored);
    return 1;
}
} // namespace coincide
