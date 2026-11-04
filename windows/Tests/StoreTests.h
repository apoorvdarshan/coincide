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
        value.messages.front().attachments = {{"C:\\pictures\\猫.png", "猫.png", "image/png"}, {"C:\\pictures\\猫.png", "猫.png", "image/png"}};
        value.draft_attachments = {{"C:\\documents\\draft.txt", "draft.txt", "text/plain"}};
        value.model = "model-from-provider"; value.effort = "high"; value.service_tier = "priority";
        value.plan = true; value.full_access = true; value.created_at = 100; value.updated_at = 200;
        QueuedInput queued;
        queued.id = "queued-first"; queued.text = "Send this after the active turn"; queued.model = "queued-model";
        queued.effort = "medium"; queued.service_tier = "priority"; queued.plan = true;
        queued.attachments = {{"C:\\pictures\\queued.png", "queued.png", "image/png"}};
        value.queued_inputs.push_back(queued);
        queued.id = "queued-image-only"; queued.text.clear(); value.queued_inputs.push_back(queued);
        workspace.select_provider(thread_id, "codex"); value.model = "saved-codex-model"; value.effort = "xhigh";
        workspace.select_provider(thread_id, "claude");
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
        check(loaded.thread(thread_id).model == value.model && loaded.thread(thread_id).effort == "high"
                && loaded.thread(thread_id).service_tier == "priority", "model and capability choices must round trip");
        check(loaded.thread(thread_id).plan && loaded.thread(thread_id).full_access, "explicit plan and access choices must round trip");
        check(loaded.thread(thread_id).created_at == 100 && loaded.thread(thread_id).updated_at == 200, "activity timestamps must round trip");
        check(loaded.thread(thread_id).messages.front().attachments.size() == 2
                && loaded.thread(thread_id).messages.front().attachments.front().path == "C:\\pictures\\猫.png", "message attachments and repeated paths must round trip");
        check(loaded.thread(thread_id).draft_attachments.size() == 1
                && loaded.thread(thread_id).draft_attachments.front().name == "draft.txt", "draft attachments must survive restart");
        check(loaded.thread(thread_id).queued_inputs.size() == 2 && loaded.thread(thread_id).queued_inputs.front().id == "queued-first"
                && loaded.thread(thread_id).queued_inputs.front().model == "queued-model" && loaded.thread(thread_id).queued_inputs.front().plan
                && loaded.thread(thread_id).queued_inputs.front().effort == "medium", "queued inputs must retain order, correlation IDs, and their own captured model preferences");
        check(loaded.thread(thread_id).queued_inputs.back().text.empty() && loaded.thread(thread_id).queued_inputs.back().attachments.size() == 1,
            "an image-only queued input must retain its attachment");
        check(loaded.thread(thread_id).model_preferences.size() == 2, "per-provider model preferences must survive restart");
        loaded.select_provider(thread_id, "codex");
        check(loaded.thread(thread_id).model == "saved-codex-model" && loaded.thread(thread_id).effort == "xhigh"
                && !loaded.thread(thread_id).full_access, "a reopened conversation must restore the selected provider's isolated preferences");
        loaded.select_provider(thread_id, "claude");
        const auto transcript_path = root / "threads" / winrt::to_hstring(thread_id + ".json").c_str();
        const auto index_path = root / "workspace.json";

        // Index-only lifecycle operations must never load, rewrite, or remove a transcript.
        const auto untouched_transcript = contents(transcript_path);
        WorkspaceStore metadata_store(root); auto metadata_only = metadata_store.open();
        metadata_only.delete_threads({thread_id}, 1000); metadata_only.pin({thread_id}, true);
        metadata_only.snooze({thread_id}, 2000); metadata_only.settle({thread_id}, true, 1200);
        metadata_store.save_index(metadata_only);
        check(contents(transcript_path) == untouched_transcript, "unloaded lifecycle edits must preserve transcript bytes exactly");
        WorkspaceStore after_delete(root); auto trashed = after_delete.open();
        check(trashed.thread(thread_id).deleted_at == 1000 && trashed.thread(thread_id).pinned
                && trashed.thread(thread_id).snoozed_until == 2000 && trashed.thread(thread_id).settled_at == 1200,
            "trash, pin, snooze, and settlement metadata must survive restart");
        check(trashed.listed_threads(ThreadView::trash).size() == 1, "persisted soft deletion must remain restorable");
        metadata_only.restore_threads({thread_id}); metadata_only.snooze({thread_id}, 0); metadata_only.settle({thread_id}, false);
        metadata_store.save_index(metadata_only);
        check(contents(transcript_path) == untouched_transcript, "restoring a conversation must not recreate or rewrite its saved history");

        auto index_document = json::JsonObject::Parse(winrt::to_hstring(contents(index_path)));
        index_document.SetNamedValue(L"futureRoot", json::JsonValue::CreateBooleanValue(true));
        index_document.GetNamedArray(L"projects").GetAt(0).GetObject().SetNamedValue(L"futureProject", json::JsonValue::CreateStringValue(L"keep project"));
        index_document.GetNamedArray(L"threads").GetAt(0).GetObject().SetNamedValue(L"futureIndex", json::JsonValue::CreateNumberValue(42));
        index_document.GetNamedArray(L"threads").GetAt(0).GetObject().GetNamedArray(L"modelPreferences").GetAt(0).GetObject()
            .SetNamedValue(L"futureModelPreference", json::JsonValue::CreateStringValue(L"keep preference"));
        {std::ofstream stream(index_path, std::ios::binary); stream << winrt::to_string(index_document.Stringify());}

        // Add fields from a future client, then edit only known fields through the current store.
        auto doc = json::JsonObject::Parse(winrt::to_hstring(contents(transcript_path)));
        doc.SetNamedValue(L"future", json::JsonValue::CreateStringValue(L"preserve me"));
        doc.GetNamedArray(L"messages").GetAt(0).GetObject().SetNamedValue(L"futureMessage", json::JsonValue::CreateBooleanValue(true));
        doc.GetNamedArray(L"sessions").GetAt(0).GetObject().SetNamedValue(L"futureSession", json::JsonValue::CreateStringValue(L"keep"));
        auto duplicate_attachments = doc.GetNamedArray(L"messages").GetAt(0).GetObject().GetNamedArray(L"attachments");
        duplicate_attachments.GetAt(0).GetObject().SetNamedValue(L"futureAttachment", json::JsonValue::CreateStringValue(L"first"));
        duplicate_attachments.GetAt(1).GetObject().SetNamedValue(L"futureAttachment", json::JsonValue::CreateStringValue(L"second"));
        doc.GetNamedArray(L"draftAttachments").GetAt(0).GetObject().SetNamedValue(L"futureDraftAttachment", json::JsonValue::CreateBooleanValue(true));
        doc.GetNamedArray(L"queuedInputs").GetAt(0).GetObject().SetNamedValue(L"futureQueuedInput", json::JsonValue::CreateBooleanValue(true));
        doc.GetNamedArray(L"queuedInputs").GetAt(0).GetObject().GetNamedArray(L"attachments").GetAt(0).GetObject()
            .SetNamedValue(L"futureQueuedAttachment", json::JsonValue::CreateNumberValue(99));
        {std::ofstream stream(transcript_path, std::ios::binary); stream << winrt::to_string(doc.Stringify());}
        WorkspaceStore third(root); auto round_trip = third.open(); third.load_thread(round_trip.thread(thread_id));
        round_trip.thread(thread_id).draft = "Edited draft";
        third.save_thread(round_trip.thread(thread_id));
        third.save_index(round_trip);
        auto saved = json::JsonObject::Parse(winrt::to_hstring(contents(transcript_path)));
        check(saved.GetNamedString(L"future") == L"preserve me", "unknown transcript fields must survive edits");
        check(saved.GetNamedArray(L"messages").GetAt(0).GetObject().GetNamedBoolean(L"futureMessage"), "unknown message fields must survive edits");
        check(saved.GetNamedArray(L"sessions").GetAt(0).GetObject().GetNamedString(L"futureSession") == L"keep", "unknown session fields must survive edits");
        const auto saved_attachments = saved.GetNamedArray(L"messages").GetAt(0).GetObject().GetNamedArray(L"attachments");
        check(saved_attachments.GetAt(0).GetObject().GetNamedString(L"futureAttachment") == L"first"
                && saved_attachments.GetAt(1).GetObject().GetNamedString(L"futureAttachment") == L"second",
            "unknown attachment fields must preserve the order of duplicate attachment identities");
        check(saved.GetNamedArray(L"draftAttachments").GetAt(0).GetObject().GetNamedBoolean(L"futureDraftAttachment"), "unknown draft attachment fields must survive edits");
        check(saved.GetNamedArray(L"queuedInputs").Size() == 2 && saved.GetNamedArray(L"queuedInputs").GetAt(0).GetObject().GetNamedBoolean(L"futureQueuedInput")
                && saved.GetNamedArray(L"queuedInputs").GetAt(0).GetObject().GetNamedArray(L"attachments").GetAt(0).GetObject().GetNamedNumber(L"futureQueuedAttachment") == 99,
            "saving a draft must retain pending outbox entries and unknown queued-input/attachment fields");
        const auto saved_index = json::JsonObject::Parse(winrt::to_hstring(contents(index_path)));
        check(saved_index.GetNamedBoolean(L"futureRoot") && saved_index.GetNamedArray(L"projects").GetAt(0).GetObject().GetNamedString(L"futureProject") == L"keep project"
                && saved_index.GetNamedArray(L"threads").GetAt(0).GetObject().GetNamedNumber(L"futureIndex") == 42,
            "unknown root, project, and conversation index fields must survive lifecycle saves");
        check(saved_index.GetNamedArray(L"threads").GetAt(0).GetObject().GetNamedArray(L"modelPreferences").GetAt(0).GetObject()
                .GetNamedString(L"futureModelPreference") == L"keep preference", "unknown per-provider preference fields must survive updates");

        const auto before_invalid_attachment = contents(transcript_path);
        auto invalid_attachment = round_trip.thread(thread_id);
        invalid_attachment.messages.front().attachments.front().path.clear();
        rejects([&]{third.save_thread(invalid_attachment);}, "invalid attachment paths must fail before overwriting the transcript");
        check(contents(transcript_path) == before_invalid_attachment, "an invalid attachment must leave the transcript unchanged");
        auto invalid_queue = round_trip.thread(thread_id);
        invalid_queue.queued_inputs.push_back(invalid_queue.queued_inputs.front());
        rejects([&]{third.save_thread(invalid_queue);}, "duplicate outbox correlation IDs must be rejected");
        invalid_queue = round_trip.thread(thread_id); invalid_queue.queued_inputs.front().id = std::string(129, 'q');
        rejects([&]{third.save_thread(invalid_queue);}, "outbox correlation IDs must be bounded");
        invalid_queue = round_trip.thread(thread_id); invalid_queue.queued_inputs.resize(101);
        rejects([&]{third.save_thread(invalid_queue);}, "saved queues must not grow beyond one hundred entries");
        check(contents(transcript_path) == before_invalid_attachment, "invalid queues must leave the original outbox and transcript unchanged");
        auto wrong_attachment_type = json::JsonObject::Parse(winrt::to_hstring(before_invalid_attachment));
        wrong_attachment_type.SetNamedValue(L"draftAttachments", json::JsonValue::CreateStringValue(L"not an array"));
        {std::ofstream stream(transcript_path, std::ios::binary); stream << winrt::to_string(wrong_attachment_type.Stringify());}
        WorkspaceStore malformed_attachment(root); auto attachment_workspace = malformed_attachment.open();
        rejects([&]{malformed_attachment.load_thread(attachment_workspace.thread(thread_id));}, "malformed attachment collections must fail closed");
        check(attachment_workspace.thread(thread_id).messages.empty() && attachment_workspace.thread(thread_id).draft_attachments.empty(),
            "a failed attachment load must not partially populate a conversation");
        auto wrong_draft_type = json::JsonObject::Parse(winrt::to_hstring(before_invalid_attachment));
        wrong_draft_type.SetNamedValue(L"draft", json::JsonValue::CreateBooleanValue(true));
        {std::ofstream stream(transcript_path, std::ios::binary); stream << winrt::to_string(wrong_draft_type.Stringify());}
        WorkspaceStore malformed_draft(root); auto draft_workspace = malformed_draft.open();
        rejects([&]{malformed_draft.load_thread(draft_workspace.thread(thread_id));}, "a malformed draft must reject the whole conversation load");
        const auto& unpopulated = draft_workspace.thread(thread_id);
        check(unpopulated.messages.empty() && unpopulated.sessions.empty() && unpopulated.draft.empty()
                && unpopulated.draft_attachments.empty() && unpopulated.queued_inputs.empty(),
            "a malformed draft must not partially replace messages, sessions, attachments, or queued work in memory");
        {std::ofstream stream(transcript_path, std::ios::binary); stream << before_invalid_attachment;}

        const auto valid_index = contents(index_path);
        for (const auto invalid_stamp : {-1.0, 1.5, 253402300800.0}) {
            auto malformed = json::JsonObject::Parse(winrt::to_hstring(valid_index));
            malformed.GetNamedArray(L"threads").GetAt(0).GetObject().SetNamedValue(L"snoozedUntil", json::JsonValue::CreateNumberValue(invalid_stamp));
            {std::ofstream stream(index_path, std::ios::binary); stream << winrt::to_string(malformed.Stringify());}
            const auto before = contents(index_path);
            WorkspaceStore bad_timestamp(root);
            rejects([&]{(void)bad_timestamp.open();}, "invalid epoch timestamps must fail closed");
            rejects([&]{bad_timestamp.save_index(workspace);}, "failed timestamp loads must revoke writes");
            check(contents(index_path) == before, "invalid timestamp data must remain untouched");
        }
        auto wrong_access_type = json::JsonObject::Parse(winrt::to_hstring(valid_index));
        wrong_access_type.GetNamedArray(L"threads").GetAt(0).GetObject().SetNamedValue(L"fullAccess", json::JsonValue::CreateStringValue(L"true"));
        {std::ofstream stream(index_path, std::ios::binary); stream << winrt::to_string(wrong_access_type.Stringify());}
        WorkspaceStore malformed_access(root);
        rejects([&]{(void)malformed_access.open();}, "a malformed access mode must not silently become a different permission mode");
        auto aliases = json::JsonObject::Parse(winrt::to_hstring(valid_index));
        auto alias = json::JsonObject::Parse(aliases.GetNamedArray(L"threads").GetAt(0).GetObject().Stringify());
        const auto alternate_id = thread_id.front() == '{' ? thread_id.substr(1, 36) : "{" + thread_id + "}";
        alias.SetNamedValue(L"id", json::JsonValue::CreateStringValue(winrt::to_hstring(alternate_id)));
        aliases.GetNamedArray(L"threads").Append(alias);
        {std::ofstream stream(index_path, std::ios::binary); stream << winrt::to_string(aliases.Stringify());}
        WorkspaceStore aliased_ids(root);
        rejects([&]{(void)aliased_ids.open();}, "GUID aliases must not create two conversation identities for the same Windows file");
        {std::ofstream stream(index_path, std::ios::binary); stream << valid_index;}

        const auto legacy_root = root / "legacy";
        WorkspaceStore legacy_seed(legacy_root); auto legacy_workspace = legacy_seed.open();
        Thread legacy_thread; legacy_thread.id = new_id(); legacy_thread.title = "Older conversation"; legacy_thread.draft = "Original older draft";
        legacy_thread.messages.push_back({new_id(), "user", "Original older message", ""});
        legacy_workspace.add_thread(legacy_thread); legacy_seed.load_thread(legacy_workspace.thread(legacy_thread.id));
        // load_thread initializes the missing file; populate the legacy draft and message afterward.
        legacy_workspace.thread(legacy_thread.id).draft = legacy_thread.draft;
        legacy_workspace.thread(legacy_thread.id).messages = legacy_thread.messages;
        legacy_seed.save_thread(legacy_workspace.thread(legacy_thread.id)); legacy_seed.save_index(legacy_workspace);
        const auto legacy_index_path = legacy_root / "workspace.json";
        auto legacy_index = json::JsonObject::Parse(winrt::to_hstring(contents(legacy_index_path)));
        auto legacy_summary = legacy_index.GetNamedArray(L"threads").GetAt(0).GetObject();
        for (const auto key : {L"effort", L"serviceTier", L"plan", L"fullAccess", L"titledByUser", L"createdAt", L"updatedAt", L"snoozedUntil", L"settledAt", L"deletedAt"}) legacy_summary.Remove(key);
        legacy_summary.Remove(L"modelPreferences");
        {std::ofstream stream(legacy_index_path, std::ios::binary); stream << winrt::to_string(legacy_index.Stringify());}
        const auto legacy_transcript_path = legacy_root / "threads" / winrt::to_hstring(legacy_thread.id + ".json").c_str();
        auto legacy_transcript = json::JsonObject::Parse(winrt::to_hstring(contents(legacy_transcript_path)));
        legacy_transcript.Remove(L"draftAttachments");
        legacy_transcript.Remove(L"queuedInputs");
        legacy_transcript.GetNamedArray(L"messages").GetAt(0).GetObject().Remove(L"attachments");
        {std::ofstream stream(legacy_transcript_path, std::ios::binary); stream << winrt::to_string(legacy_transcript.Stringify());}
        WorkspaceStore legacy_reader(legacy_root); auto legacy = legacy_reader.open();
        const auto& legacy_value = legacy.thread(legacy_thread.id);
        check(legacy_value.effort.empty() && legacy_value.service_tier.empty() && !legacy_value.plan && !legacy_value.full_access
                && !legacy_value.deleted_at && !legacy_value.snoozed_until && !legacy_value.settled_at && !legacy_value.created_at,
            "older indexes must default to approval mode without hiding or retiming conversations");
        legacy_reader.load_thread(legacy.thread(legacy_thread.id));
        check(legacy_value.draft == legacy_thread.draft && legacy_value.messages.front().text == legacy_thread.messages.front().text
                && legacy_value.draft_attachments.empty() && legacy_value.messages.front().attachments.empty(),
            "older conversations without attachment fields must retain their original content");
        check(legacy_value.queued_inputs.empty(), "older conversations without an outbox must not invent queued work");
        check(legacy_value.model_preferences.empty(), "older conversation indexes must not invent another provider's preferences");

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
        rejects([&]{invalid_store.save_index(workspace);}, "failed opens must prevent later index writes");
        check(contents(index_path) == invalid, "malformed workspaces must remain untouched");
        rejects([&]{(void)third.open();}, "reopening an existing store with malformed data must fail");
        rejects([&]{third.save_index(round_trip);}, "a failed reopen must revoke the earlier successful store's write permission");
        {std::ofstream stream(index_path, std::ios::binary); stream << R"({"version":2,"projects":[],"threads":[]})";}
        const auto future = contents(index_path);
        WorkspaceStore future_store(root);
        rejects([&]{(void)future_store.open();}, "future store versions must fail closed");
        rejects([&]{future_store.save_index(workspace);}, "future-version refusal must prevent later index writes");
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
