#pragma once

#include "../Core/Workspace.h"
#include <windows.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <filesystem>
#include <fstream>
#include <cmath>
#include <deque>
#include <unordered_map>
#include <unordered_set>

namespace coincide {
namespace json = winrt::Windows::Data::Json;

inline std::string new_id() {
    winrt::guid id;
    winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&id)));
    return winrt::to_string(winrt::to_hstring(id));
}

class WorkspaceStore {
public:
    explicit WorkspaceStore(std::filesystem::path directory) : directory_(std::move(directory)) {}

    Workspace open() {
        // A failed reopen must revoke writes, rather than retaining an earlier successful open.
        opened_ = false;
        original_ = nullptr;
        project_originals_.clear(); index_originals_.clear(); transcript_originals_.clear(); loaded_.clear();
        Workspace result;
        const auto path = directory_ / L"workspace.json";
        if (!std::filesystem::exists(path)) { opened_ = true; return result; }
        original_ = read(path);
        if (original_.GetNamedNumber(L"version", 0) != 1) {
            throw std::runtime_error("This workspace format is not supported. Its files have been left unchanged.");
        }
        std::unordered_set<std::string> project_ids, thread_ids;
        for (const auto& value : original_.GetNamedArray(L"projects")) {
            const auto p = value.GetObject();
            const auto id = text(p, L"id");
            validate_id(id);
            if (!project_ids.insert(canonical_id(id)).second) throw std::runtime_error("Duplicate project identity");
            result.add_project({id, text(p, L"name"), text(p, L"path")});
            project_originals_.insert_or_assign(id, p);
        }
        for (const auto& value : original_.GetNamedArray(L"threads")) {
            const auto t = value.GetObject();
            Thread thread;
            thread.id = text(t, L"id");
            validate_id(thread.id);
            if (!thread_ids.insert(canonical_id(thread.id)).second) throw std::runtime_error("Duplicate conversation identity");
            thread.title = text(t, L"title");
            thread.provider = text(t, L"provider");
            thread.model = text(t, L"model");
            thread.effort = text(t, L"effort"); thread.service_tier = text(t, L"serviceTier");
            thread.plan = boolean(t, L"plan"); thread.full_access = boolean(t, L"fullAccess");
            thread.titled_by_user = boolean(t, L"titledByUser");
            thread.created_at = timestamp(t, L"createdAt"); thread.updated_at = timestamp(t, L"updatedAt");
            thread.snoozed_until = timestamp(t, L"snoozedUntil"); thread.settled_at = timestamp(t, L"settledAt");
            thread.deleted_at = timestamp(t, L"deletedAt");
            thread.model_preferences = read_model_preferences(optional_array(t, L"modelPreferences"));
            const auto project = text(t, L"project");
            if (!project.empty()) thread.project_id = project;
            thread.pinned = boolean(t, L"pinned");
            thread.archived = boolean(t, L"archived");
            result.add_thread(std::move(thread));
            index_originals_.insert_or_assign(text(t, L"id"), t);
        }
        opened_ = true;
        return result;
    }

    void load_thread(Thread& thread) {
        require_open();
        if (loaded_.contains(thread.id)) return;
        validate_id(thread.id);
        const auto path = thread_path(thread.id);
        if (!std::filesystem::exists(path)) {
            // A thread listed in the index must have a transcript. Never silently replace a missing file.
            if (index_originals_.contains(thread.id)) throw std::runtime_error("A conversation file is missing. The index has been left unchanged.");
            loaded_.insert(thread.id);
            return;
        }
        const auto value = read(path);
        if (value.GetNamedNumber(L"version", 0) != 1 || text(value, L"id") != thread.id) {
            throw std::runtime_error("The conversation format or identity is not supported. Its file has been left unchanged.");
        }
        auto messages = std::vector<Message>{};
        for (const auto& item : value.GetNamedArray(L"messages")) {
            const auto m = item.GetObject();
            Message message{text(m, L"id"), text(m, L"role"), text(m, L"text"), text(m, L"provider")};
            message.attachments = read_attachments(optional_array(m, L"attachments"));
            messages.push_back(std::move(message));
        }
        auto sessions = std::vector<NativeSession>{};
        for (const auto& item : value.GetNamedArray(L"sessions")) {
            const auto s = item.GetObject();
            const auto count = s.GetNamedNumber(L"acknowledged", 0);
            if (!known_provider(text(s, L"provider")) || text(s, L"id").empty() || count < 0 ||
                    count > static_cast<double>(messages.size()) || count != std::floor(count)) {
                throw std::runtime_error("The conversation contains an invalid session. Its file has been left unchanged.");
            }
            sessions.push_back({text(s, L"provider"), text(s, L"id"), static_cast<std::size_t>(count)});
        }
        auto draft_attachments = read_attachments(optional_array(value, L"draftAttachments"));
        auto queued_inputs = read_queue(optional_array(value, L"queuedInputs"));
        auto draft = text(value, L"draft");
        thread.messages = std::move(messages);
        thread.sessions = std::move(sessions);
        thread.draft = std::move(draft);
        thread.draft_attachments = std::move(draft_attachments);
        thread.queued_inputs = std::move(queued_inputs);
        transcript_originals_.insert_or_assign(thread.id, value);
        loaded_.insert(thread.id);
    }

    void save_index(const Workspace& workspace) {
        require_open();
        std::unordered_set<std::string> project_ids, thread_ids;
        for (const auto& p : workspace.projects) {
            if (!project_ids.insert(canonical_id(p.id)).second) throw std::runtime_error("Duplicate project identity");
            (void)workspace_text::label(p.name, 512);
            if (p.path.empty() || p.path.size() > 32768 || p.path.find('\0') != std::string::npos) throw std::runtime_error("Invalid project folder");
        }
        for (const auto& t : workspace.threads) {
            if (!thread_ids.insert(canonical_id(t.id)).second) throw std::runtime_error("Duplicate conversation identity");
            if (!known_provider(t.provider)) throw std::runtime_error("Unknown provider");
            if (t.project_id) (void)workspace.project(*t.project_id);
            (void)workspace_text::label(t.title, 4096); Workspace::validate_thread_metadata(t);
        }
        auto root = original_ ? original_ : json::JsonObject{};
        root.SetNamedValue(L"version", json::JsonValue::CreateNumberValue(1));
        json::JsonArray projects;
        for (const auto& p : workspace.projects) {
            auto value = project_originals_.contains(p.id) ? project_originals_.at(p.id) : json::JsonObject{};
            put(value, L"id", p.id); put(value, L"name", p.name); put(value, L"path", p.path);
            projects.Append(value);
        }
        json::JsonArray threads;
        for (const auto& t : workspace.threads) {
            auto value = index_originals_.contains(t.id) ? index_originals_.at(t.id) : json::JsonObject{};
            put(value, L"id", t.id); put(value, L"title", t.title); put(value, L"provider", t.provider);
            put(value, L"model", t.model); put(value, L"project", t.project_id.value_or(""));
            put(value, L"effort", t.effort); put(value, L"serviceTier", t.service_tier);
            value.SetNamedValue(L"plan", json::JsonValue::CreateBooleanValue(t.plan));
            value.SetNamedValue(L"fullAccess", json::JsonValue::CreateBooleanValue(t.full_access));
            value.SetNamedValue(L"titledByUser", json::JsonValue::CreateBooleanValue(t.titled_by_user));
            put_timestamp(value, L"createdAt", t.created_at); put_timestamp(value, L"updatedAt", t.updated_at);
            put_timestamp(value, L"snoozedUntil", t.snoozed_until); put_timestamp(value, L"settledAt", t.settled_at);
            put_timestamp(value, L"deletedAt", t.deleted_at);
            value.SetNamedValue(L"modelPreferences", model_preferences_json(t.model_preferences, optional_array(value, L"modelPreferences")));
            value.SetNamedValue(L"pinned", json::JsonValue::CreateBooleanValue(t.pinned));
            value.SetNamedValue(L"archived", json::JsonValue::CreateBooleanValue(t.archived));
            threads.Append(value);
        }
        root.SetNamedValue(L"projects", projects); root.SetNamedValue(L"threads", threads);
        write(directory_ / L"workspace.json", root);
        original_ = root;
    }

    void save_thread(const Thread& thread) {
        require_open();
        validate_id(thread.id);
        if (!loaded_.contains(thread.id)) throw std::logic_error("Refusing to overwrite a conversation that was not loaded");
        for (const auto& message : thread.messages) {
            if (message.attachments.size() > 256) throw std::runtime_error("A message has too many attachments");
            for (const auto& attachment : message.attachments) validate_attachment(attachment);
        }
        if (thread.draft_attachments.size() > 256) throw std::runtime_error("A draft has too many attachments");
        for (const auto& attachment : thread.draft_attachments) validate_attachment(attachment);
        validate_queue(thread.queued_inputs);
        auto value = transcript_originals_.contains(thread.id) ? transcript_originals_.at(thread.id) : json::JsonObject{};
        put(value, L"id", thread.id); put(value, L"draft", thread.draft);
        value.SetNamedValue(L"draftAttachments", attachments_json(thread.draft_attachments,
            optional_array(value, L"draftAttachments")));
        value.SetNamedValue(L"queuedInputs", queue_json(thread.queued_inputs, optional_array(value, L"queuedInputs")));
        value.SetNamedValue(L"version", json::JsonValue::CreateNumberValue(1));
        json::JsonArray messages;
        const auto existing = value.GetNamedArray(L"messages", json::JsonArray{});
        std::unordered_map<std::string, json::JsonObject> originals;
        for (const auto& m : existing) originals.insert_or_assign(text(m.GetObject(), L"id"), m.GetObject());
        for (const auto& m : thread.messages) {
            auto item = originals.contains(m.id) ? originals.at(m.id) : json::JsonObject{};
            put(item, L"id", m.id); put(item, L"role", m.role); put(item, L"text", m.text); put(item, L"provider", m.provider);
            item.SetNamedValue(L"attachments", attachments_json(m.attachments, optional_array(item, L"attachments")));
            messages.Append(item);
        }
        json::JsonArray sessions;
        std::unordered_map<std::string, json::JsonObject> session_originals;
        for (const auto& s : value.GetNamedArray(L"sessions", json::JsonArray{})) {
            session_originals.insert_or_assign(text(s.GetObject(), L"provider"), s.GetObject());
        }
        for (const auto& s : thread.sessions) {
            auto item = session_originals.contains(s.provider) ? session_originals.at(s.provider) : json::JsonObject{};
            put(item, L"provider", s.provider); put(item, L"id", s.id);
            item.SetNamedValue(L"acknowledged", json::JsonValue::CreateNumberValue(static_cast<double>(s.acknowledged_messages)));
            sessions.Append(item);
        }
        value.SetNamedValue(L"messages", messages); value.SetNamedValue(L"sessions", sessions);
        write(thread_path(thread.id), value);
        transcript_originals_.insert_or_assign(thread.id, value);
    }

private:
    std::filesystem::path directory_;
    bool opened_{};
    json::JsonObject original_{nullptr};
    std::unordered_map<std::string, json::JsonObject> project_originals_, index_originals_, transcript_originals_;
    std::unordered_set<std::string> loaded_;

    void require_open() const {
        if (!opened_) throw std::logic_error("The workspace must open successfully before any reads or writes");
    }

    static void validate_id(const std::string& id) {
        if (id.size() != 36 && id.size() != 38) throw std::runtime_error("Invalid conversation identity");
        (void)winrt::guid{winrt::to_hstring(id)};
    }
    static std::string canonical_id(const std::string& id) {
        validate_id(id);
        return winrt::to_string(winrt::to_hstring(winrt::guid{winrt::to_hstring(id)}));
    }
    static std::int64_t timestamp(const json::JsonObject& value, const wchar_t* name) {
        const auto entry = value.GetNamedValue(name, json::JsonValue::CreateNullValue());
        if (entry.ValueType() == json::JsonValueType::Null) return 0;
        if (entry.ValueType() != json::JsonValueType::Number) throw std::runtime_error("Invalid conversation timestamp");
        const auto raw = entry.GetNumber();
        if (!std::isfinite(raw) || raw < 0 || raw > 253402300799.0 || raw != std::floor(raw)) {
            throw std::runtime_error("Invalid conversation timestamp");
        }
        return static_cast<std::int64_t>(raw);
    }
    static void put_timestamp(const json::JsonObject& value, const wchar_t* name, std::int64_t stamp) {
        Workspace::validate_timestamp(stamp);
        value.SetNamedValue(name, json::JsonValue::CreateNumberValue(static_cast<double>(stamp)));
    }
    static void validate_attachment(const MessageAttachment& value) {
        if (value.path.empty() || value.path.size() > 32768 || value.name.size() > 1024 || value.media_type.size() > 256
                || value.path.find('\0') != std::string::npos || value.name.find('\0') != std::string::npos
                || value.media_type.find('\0') != std::string::npos) throw std::runtime_error("Invalid message attachment");
        (void)workspace_text::fold(value.path); (void)workspace_text::fold(value.name); (void)workspace_text::fold(value.media_type);
    }
    static std::vector<MessageAttachment> read_attachments(const json::JsonArray& array) {
        if (array.Size() > 256) throw std::runtime_error("A message or draft has too many attachments");
        std::vector<MessageAttachment> result; result.reserve(array.Size());
        for (const auto& raw : array) {
            const auto value = raw.GetObject();
            MessageAttachment entry{text(value, L"path"), text(value, L"name"), text(value, L"mediaType")};
            validate_attachment(entry); result.push_back(std::move(entry));
        }
        return result;
    }
    static json::JsonArray attachments_json(const std::vector<MessageAttachment>& values, const json::JsonArray& existing) {
        std::unordered_map<std::string, std::deque<json::JsonObject>> originals;
        for (const auto& raw : existing) {
            const auto value = raw.GetObject(); originals[text(value, L"path") + '\0' + text(value, L"name")].push_back(value);
        }
        json::JsonArray result;
        for (const auto& attachment : values) {
            const auto key = attachment.path + '\0' + attachment.name;
            auto& matching = originals[key];
            auto value = matching.empty() ? json::JsonObject{} : matching.front();
            if (!matching.empty()) matching.pop_front();
            put(value, L"path", attachment.path); put(value, L"name", attachment.name); put(value, L"mediaType", attachment.media_type);
            result.Append(value);
        }
        return result;
    }
    static void validate_queue(const std::vector<QueuedInput>& values) {
        if (values.size() > 100) throw std::runtime_error("The saved input queue exceeds its entry limit");
        std::unordered_set<std::string> identities;
        std::size_t total_bytes{};
        for (const auto& value : values) {
            if (value.id.empty() || value.id.size() > 128 || workspace_text::label(value.id, 128) != value.id
                    || !identities.insert(value.id).second) throw std::runtime_error("Invalid or duplicate queued input identity");
            if (value.text.size() > 8ULL * 1024 * 1024 || (value.text.empty() && value.attachments.empty())) {
                throw std::runtime_error("A queued input is empty or exceeds its text limit");
            }
            for (std::size_t offset = 0; offset < value.text.size();) (void)workspace_text::next(value.text, offset);
            for (const auto* preference : {&value.model, &value.effort, &value.service_tier}) {
                if (preference->size() > 1024 || preference->find('\0') != std::string::npos) throw std::runtime_error("Invalid queued model preference");
                (void)workspace_text::fold(*preference);
            }
            if (value.attachments.size() > 256) throw std::runtime_error("A queued input has too many attachments");
            total_bytes += value.text.size() + value.id.size() + value.model.size() + value.effort.size() + value.service_tier.size();
            for (const auto& attachment : value.attachments) {
                validate_attachment(attachment); total_bytes += attachment.path.size() + attachment.name.size() + attachment.media_type.size();
            }
            if (total_bytes > 64ULL * 1024 * 1024) throw std::runtime_error("The saved input queue exceeds its byte limit");
        }
    }
    static std::vector<QueuedInput> read_queue(const json::JsonArray& array) {
        if (array.Size() > 100) throw std::runtime_error("The saved input queue exceeds its entry limit");
        std::vector<QueuedInput> result; result.reserve(array.Size());
        for (const auto& raw : array) {
            const auto value = raw.GetObject();
            QueuedInput entry;
            entry.id = text(value, L"id"); entry.text = text(value, L"text"); entry.model = text(value, L"model");
            entry.effort = text(value, L"effort"); entry.service_tier = text(value, L"serviceTier");
            entry.plan = boolean(value, L"plan"); entry.full_access = boolean(value, L"fullAccess");
            entry.attachments = read_attachments(optional_array(value, L"attachments"));
            result.push_back(std::move(entry));
        }
        validate_queue(result); return result;
    }
    static std::vector<ProviderModelPreference> read_model_preferences(const json::JsonArray& array) {
        if (array.Size() > provider_ids.size()) throw std::runtime_error("Too many provider model preferences");
        std::vector<ProviderModelPreference> result; result.reserve(array.Size());
        for (const auto& raw : array) {
            const auto value = raw.GetObject();
            result.push_back({text(value, L"provider"), text(value, L"model"), text(value, L"effort"), text(value, L"serviceTier"),
                boolean(value, L"plan"), boolean(value, L"fullAccess")});
        }
        Workspace::validate_model_preferences(result); return result;
    }
    static json::JsonArray model_preferences_json(const std::vector<ProviderModelPreference>& preferences, const json::JsonArray& existing) {
        std::unordered_map<std::string, json::JsonObject> originals;
        for (const auto& raw : existing) {const auto value = raw.GetObject(); originals.insert_or_assign(text(value, L"provider"), value);}
        json::JsonArray result;
        for (const auto& preference : preferences) {
            auto value = originals.contains(preference.provider) ? originals.at(preference.provider) : json::JsonObject{};
            put(value, L"provider", preference.provider); put(value, L"model", preference.model);
            put(value, L"effort", preference.effort); put(value, L"serviceTier", preference.service_tier);
            value.SetNamedValue(L"plan", json::JsonValue::CreateBooleanValue(preference.plan));
            value.SetNamedValue(L"fullAccess", json::JsonValue::CreateBooleanValue(preference.full_access)); result.Append(value);
        }
        return result;
    }
    static json::JsonArray queue_json(const std::vector<QueuedInput>& values, const json::JsonArray& existing) {
        std::unordered_map<std::string, json::JsonObject> originals;
        for (const auto& raw : existing) {const auto entry = raw.GetObject(); originals.insert_or_assign(text(entry, L"id"), entry);}
        json::JsonArray result;
        for (const auto& input : values) {
            auto value = originals.contains(input.id) ? originals.at(input.id) : json::JsonObject{};
            put(value, L"id", input.id); put(value, L"text", input.text); put(value, L"model", input.model);
            put(value, L"effort", input.effort); put(value, L"serviceTier", input.service_tier);
            value.SetNamedValue(L"plan", json::JsonValue::CreateBooleanValue(input.plan));
            value.SetNamedValue(L"fullAccess", json::JsonValue::CreateBooleanValue(input.full_access));
            value.SetNamedValue(L"attachments", attachments_json(input.attachments, optional_array(value, L"attachments")));
            result.Append(value);
        }
        return result;
    }
    std::filesystem::path thread_path(const std::string& id) const { return directory_ / L"threads" / winrt::to_hstring(id + ".json").c_str(); }
    static std::string text(const json::JsonObject& value, const wchar_t* name) {
        const auto raw = value.GetNamedValue(name, json::JsonValue::CreateNullValue());
        if (raw.ValueType() == json::JsonValueType::Null) return {};
        if (raw.ValueType() != json::JsonValueType::String) throw std::runtime_error("Invalid workspace text field");
        return winrt::to_string(raw.GetString());
    }
    static bool boolean(const json::JsonObject& value, const wchar_t* name) {
        const auto raw = value.GetNamedValue(name, json::JsonValue::CreateNullValue());
        if (raw.ValueType() == json::JsonValueType::Null) return false;
        if (raw.ValueType() != json::JsonValueType::Boolean) throw std::runtime_error("Invalid workspace boolean field");
        return raw.GetBoolean();
    }
    static json::JsonArray optional_array(const json::JsonObject& value, const wchar_t* name) {
        const auto raw = value.GetNamedValue(name, json::JsonValue::CreateNullValue());
        return raw.ValueType() == json::JsonValueType::Null ? json::JsonArray{} : raw.GetArray();
    }
    static void put(const json::JsonObject& value, const wchar_t* name, const std::string& text) {
        value.SetNamedValue(name, json::JsonValue::CreateStringValue(winrt::to_hstring(text)));
    }
    static json::JsonObject read(const std::filesystem::path& path) {
        std::ifstream input(path, std::ios::binary);
        if (!input) throw std::runtime_error("Could not open the workspace. No files have been changed.");
        const auto size = std::filesystem::file_size(path);
        if (size > 128ULL * 1024 * 1024) throw std::runtime_error("The workspace file exceeds the read limit. No files have been changed.");
        const std::string bytes((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
        return json::JsonObject::Parse(winrt::to_hstring(bytes));
    }
    static void write(const std::filesystem::path& path, const json::JsonObject& value) {
        std::filesystem::create_directories(path.parent_path());
        auto temporary = path; temporary += winrt::to_hstring("." + new_id() + ".tmp").c_str();
        const auto bytes = winrt::to_string(value.Stringify());
        if (bytes.size() > 128ULL * 1024 * 1024) throw std::runtime_error("The workspace file exceeds the write limit. No files have been changed.");
        HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) winrt::throw_last_error();
        DWORD written{};
        const auto ok = bytes.size() <= MAXDWORD && WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr)
            && written == bytes.size() && FlushFileBuffers(file);
        const auto error = GetLastError();
        CloseHandle(file);
        if (!ok) { DeleteFileW(temporary.c_str()); throw winrt::hresult_error(HRESULT_FROM_WIN32(error ? error : ERROR_WRITE_FAULT)); }
        if (!MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
            const auto move_error = GetLastError(); DeleteFileW(temporary.c_str());
            throw winrt::hresult_error(HRESULT_FROM_WIN32(move_error));
        }
    }
};
} // namespace coincide
