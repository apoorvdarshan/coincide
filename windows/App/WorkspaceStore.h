#pragma once

#include "../Core/Workspace.h"
#include <windows.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.h>
#include <filesystem>
#include <fstream>
#include <cmath>
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
        Workspace result;
        const auto path = directory_ / L"workspace.json";
        if (!std::filesystem::exists(path)) return result;
        original_ = read(path);
        if (original_.GetNamedNumber(L"version", 0) != 1) {
            throw std::runtime_error("This workspace format is not supported. Its files have been left unchanged.");
        }
        for (const auto& value : original_.GetNamedArray(L"projects")) {
            const auto p = value.GetObject();
            const auto id = text(p, L"id");
            validate_id(id);
            result.add_project({id, text(p, L"name"), text(p, L"path")});
            project_originals_.insert_or_assign(id, p);
        }
        for (const auto& value : original_.GetNamedArray(L"threads")) {
            const auto t = value.GetObject();
            Thread thread;
            thread.id = text(t, L"id");
            validate_id(thread.id);
            thread.title = text(t, L"title");
            thread.provider = text(t, L"provider");
            thread.model = text(t, L"model");
            const auto project = text(t, L"project");
            if (!project.empty()) thread.project_id = project;
            thread.pinned = t.GetNamedBoolean(L"pinned", false);
            thread.archived = t.GetNamedBoolean(L"archived", false);
            result.add_thread(std::move(thread));
            index_originals_.insert_or_assign(text(t, L"id"), t);
        }
        return result;
    }

    void load_thread(Thread& thread) {
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
            messages.push_back({text(m, L"id"), text(m, L"role"), text(m, L"text"), text(m, L"provider")});
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
        thread.messages = std::move(messages);
        thread.sessions = std::move(sessions);
        thread.draft = text(value, L"draft");
        transcript_originals_.insert_or_assign(thread.id, value);
        loaded_.insert(thread.id);
    }

    void save_index(const Workspace& workspace) {
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
            value.SetNamedValue(L"pinned", json::JsonValue::CreateBooleanValue(t.pinned));
            value.SetNamedValue(L"archived", json::JsonValue::CreateBooleanValue(t.archived));
            threads.Append(value);
        }
        root.SetNamedValue(L"projects", projects); root.SetNamedValue(L"threads", threads);
        write(directory_ / L"workspace.json", root);
        original_ = root;
    }

    void save_thread(const Thread& thread) {
        validate_id(thread.id);
        if (!loaded_.contains(thread.id)) throw std::logic_error("Refusing to overwrite a conversation that was not loaded");
        auto value = transcript_originals_.contains(thread.id) ? transcript_originals_.at(thread.id) : json::JsonObject{};
        put(value, L"id", thread.id); put(value, L"draft", thread.draft);
        value.SetNamedValue(L"version", json::JsonValue::CreateNumberValue(1));
        json::JsonArray messages;
        const auto existing = value.GetNamedArray(L"messages", json::JsonArray{});
        std::unordered_map<std::string, json::JsonObject> originals;
        for (const auto& m : existing) originals.insert_or_assign(text(m.GetObject(), L"id"), m.GetObject());
        for (const auto& m : thread.messages) {
            auto item = originals.contains(m.id) ? originals.at(m.id) : json::JsonObject{};
            put(item, L"id", m.id); put(item, L"role", m.role); put(item, L"text", m.text); put(item, L"provider", m.provider);
            messages.Append(item);
        }
        json::JsonArray sessions;
        for (const auto& s : thread.sessions) {
            json::JsonObject item;
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
    json::JsonObject original_{nullptr};
    std::unordered_map<std::string, json::JsonObject> project_originals_, index_originals_, transcript_originals_;
    std::unordered_set<std::string> loaded_;

    static void validate_id(const std::string& id) {
        if (id.size() != 36 && id.size() != 38) throw std::runtime_error("Invalid conversation identity");
        (void)winrt::guid{winrt::to_hstring(id)};
    }
    std::filesystem::path thread_path(const std::string& id) const { return directory_ / L"threads" / winrt::to_hstring(id + ".json").c_str(); }
    static std::string text(const json::JsonObject& value, const wchar_t* name) {
        return winrt::to_string(value.GetNamedString(name, L""));
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
