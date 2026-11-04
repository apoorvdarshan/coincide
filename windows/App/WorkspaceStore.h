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
#include <type_traits>
#include <optional>
#include <memory>

namespace coincide {
namespace json = winrt::Windows::Data::Json;

inline std::string new_id() {
    winrt::guid id;
    winrt::check_hresult(CoCreateGuid(reinterpret_cast<GUID*>(&id)));
    return winrt::to_string(winrt::to_hstring(id));
}

struct StoredSessionIdentity {std::string thread_id; NativeSession session;bool imported_origin{};};

class WorkspaceStore {
public:
    explicit WorkspaceStore(std::filesystem::path directory) : directory_(std::filesystem::absolute(std::move(directory)).lexically_normal()) {}

    Workspace open() {
        // A failed reopen must revoke writes, rather than retaining an earlier successful open.
        opened_ = false;
        scope_identity_.reset();
        original_ = nullptr;
        project_originals_.clear(); index_originals_.clear(); transcript_originals_.clear(); loaded_.clear();
        Workspace result;
        if(std::filesystem::exists(directory_))scope_identity_=directory_identity(directory_);
        const auto path = directory_ / L"workspace.json";
        if (!std::filesystem::exists(path)) { opened_ = true; return result; }
        original_ = read(path);
        const auto version=original_.GetNamedNumber(L"version",0);
        if (version!=1&&version!=2) {
            throw std::runtime_error("This workspace format is not supported. Its files have been left unchanged.");
        }
        if(version==2)require_host_format(original_);
        result.requires_background_host=version==2;
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
            const auto bot=text(t,L"botID");if(!bot.empty()){validate_id(bot);thread.bot_id=canonical_id(bot);}
            const auto bot_folder=text(t,L"botFolder");if(!bot_folder.empty())thread.bot_folder=bot_folder;
            const auto preferred_profile=text(t,L"preferredProfileID");if(!preferred_profile.empty())thread.preferred_profile_id=preferred_profile;
            thread.host_cursors=read_host_cursors(optional_array(t,L"hostEventCursors"));if(version==1&&!thread.host_cursors.empty())throw std::runtime_error("Hosted work requires the newer workspace format. Its files were preserved.");
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
        const auto version=value.GetNamedNumber(L"version",0);
        if ((version!=1&&version!=2) || text(value, L"id") != thread.id) {
            throw std::runtime_error("The conversation format or identity is not supported. Its file has been left unchanged.");
        }
        if(version==2)require_host_format(value);
        auto host_cursors=read_host_cursors(optional_array(value,L"hostEventCursors"));
        if(version==1&&!host_cursors.empty())throw std::runtime_error("Hosted event receipts require the newer conversation format. Its file was preserved.");
        for(const auto& indexed:thread.host_cursors){const auto durable=std::find_if(host_cursors.begin(),host_cursors.end(),[&](const auto& cursor){return cursor.provider==indexed.provider;});
            if(durable==host_cursors.end()||durable->epoch!=indexed.epoch||durable->sequence<indexed.sequence)throw std::runtime_error("The hosted conversation receipt does not match its index. Review its saved history before reconnecting.");}
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
            NativeSession session{text(s,L"provider"),text(s,L"id"),static_cast<std::size_t>(count),winrt::to_string(s.GetNamedString(L"profileID",L"default")),winrt::to_string(s.GetNamedString(L"accountScope",L""))};
            if(!valid_session_binding(session))throw std::runtime_error("The conversation contains invalid account routing metadata. Its file was preserved.");
            sessions.push_back(std::move(session));
        }
        auto draft_attachments = read_attachments(optional_array(value, L"draftAttachments"));
        auto queued_inputs = read_queue(optional_array(value, L"queuedInputs"));
        auto draft = text(value, L"draft");
        thread.messages = std::move(messages);
        thread.sessions = std::move(sessions);
        thread.draft = std::move(draft);
        thread.draft_attachments = std::move(draft_attachments);
        thread.queued_inputs = std::move(queued_inputs);
        thread.host_cursors=std::move(host_cursors);
        transcript_originals_.insert_or_assign(thread.id, value);
        loaded_.insert(thread.id);
    }

    void save_index(const Workspace& workspace) {
        require_open();
        WriterLease writer(directory_,scope_identity_);scope_identity_=writer.identity;assert_index_unchanged(writer.directory);
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
        auto root = original_ ? json::JsonObject::Parse(original_.Stringify()) : json::JsonObject{};
        auto project_originals=clone_objects(project_originals_),index_originals=clone_objects(index_originals_);
        const bool hosted=workspace.requires_background_host||(original_&&original_.GetNamedNumber(L"version",1)==2)||std::any_of(workspace.threads.begin(),workspace.threads.end(),[](const auto& thread){return !thread.host_cursors.empty();});
        // Old clients reject version2 before they can start an in-process duplicate provider.
        root.SetNamedValue(L"version", json::JsonValue::CreateNumberValue(hosted?2:1));
        if(hosted)put_host_format(root);
        json::JsonArray projects;
        for (const auto& p : workspace.projects) {
            auto value = project_originals.contains(p.id) ? project_originals.at(p.id) : json::JsonObject{};
            put(value, L"id", p.id); put(value, L"name", p.name); put(value, L"path", p.path);
            projects.Append(value);
            project_originals.insert_or_assign(p.id,value);
        }
        json::JsonArray threads;
        for (const auto& t : workspace.threads) {
            auto value = index_originals.contains(t.id) ? index_originals.at(t.id) : json::JsonObject{};
            put(value, L"id", t.id); put(value, L"title", t.title); put(value, L"provider", t.provider);
            put(value, L"model", t.model); put(value, L"project", t.project_id.value_or(""));
            put(value,L"botID",t.bot_id?canonical_id(*t.bot_id):std::string{});
            put(value,L"botFolder",t.bot_folder.value_or(""));
            put(value,L"preferredProfileID",t.preferred_profile_id.value_or(""));
            value.SetNamedValue(L"hostEventCursors",host_cursors_json(t.host_cursors,optional_array(value,L"hostEventCursors")));
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
            index_originals.insert_or_assign(t.id,value);
        }
        root.SetNamedValue(L"projects", projects); root.SetNamedValue(L"threads", threads);
        write(writer.directory / L"workspace.json", root);
        original_ = root;project_originals_.swap(project_originals);index_originals_.swap(index_originals);
    }

    void save_thread(const Thread& thread) {
        require_open();
        WriterLease writer(directory_,scope_identity_);scope_identity_=writer.identity;
        validate_id(thread.id);
        if (!loaded_.contains(thread.id)) throw std::logic_error("Refusing to overwrite a conversation that was not loaded");
        for (const auto& message : thread.messages) {
            if (message.attachments.size() > 256) throw std::runtime_error("A message has too many attachments");
            for (const auto& attachment : message.attachments) validate_attachment(attachment);
        }
        if (thread.draft_attachments.size() > 256) throw std::runtime_error("A draft has too many attachments");
        for (const auto& attachment : thread.draft_attachments) validate_attachment(attachment);
        validate_queue(thread.queued_inputs);
        auto value = transcript_originals_.contains(thread.id) ? json::JsonObject::Parse(transcript_originals_.at(thread.id).Stringify()) : json::JsonObject{};
        put(value, L"id", thread.id); put(value, L"draft", thread.draft);
        value.SetNamedValue(L"draftAttachments", attachments_json(thread.draft_attachments,
            optional_array(value, L"draftAttachments")));
        value.SetNamedValue(L"queuedInputs", queue_json(thread.queued_inputs, optional_array(value, L"queuedInputs")));
        const bool hosted=!thread.host_cursors.empty()||value.GetNamedNumber(L"version",1)==2;
        value.SetNamedValue(L"version", json::JsonValue::CreateNumberValue(hosted?2:1));if(hosted)put_host_format(value);
        value.SetNamedValue(L"hostEventCursors",host_cursors_json(thread.host_cursors,optional_array(value,L"hostEventCursors")));
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
            if(!valid_session_binding(s))throw std::runtime_error("Invalid native account binding");
            put(item,L"profileID",s.profile_id);put(item,L"accountScope",s.account_scope);
            put(item, L"provider", s.provider); put(item, L"id", s.id);
            item.SetNamedValue(L"acknowledged", json::JsonValue::CreateNumberValue(static_cast<double>(s.acknowledged_messages)));
            sessions.Append(item);
        }
        value.SetNamedValue(L"messages", messages); value.SetNamedValue(L"sessions", sessions);
        write(writer.directory / L"threads" / winrt::to_hstring(thread.id+".json").c_str(), value);
        transcript_originals_.insert_or_assign(thread.id, value);
    }

    // Read-only identity discovery for import duplicate checks. It deliberately does not construct
    // Message vectors or change any live store caches. Run this static operation on a worker and
    // overlay the live workspace's native sessions before the final UI-thread transaction.
    static std::vector<StoredSessionIdentity> session_snapshot(const std::filesystem::path& directory,
            const std::vector<std::string>& thread_ids) {
        if (!directory.is_absolute() || thread_ids.size() > 10000) throw std::invalid_argument("Invalid or oversized native-session snapshot scope");
        std::vector<StoredSessionIdentity> result; std::unordered_set<std::string> seen; std::size_t total{};
        for (const auto& id : thread_ids) {
            if (!seen.insert(canonical_id(id)).second) throw std::runtime_error("Duplicate conversation identity in session snapshot");
            const auto file = directory / L"threads" / winrt::to_hstring(id + ".json").c_str();
            const auto value = read_session_file(file, total);
            const auto version=value.GetNamedNumber(L"version",0);if ((version!=1&&version!=2) || text(value, L"id") != id) throw std::runtime_error("A conversation identity or format is invalid; duplicate checking was stopped");
            if(version==2)require_host_format(value);
            const auto count = value.GetNamedArray(L"messages").Size();
            if (count > 100000) throw std::runtime_error("A conversation exceeds the native-session snapshot record limit");
            const auto sessions = value.GetNamedArray(L"sessions");
            if (sessions.Size() > provider_ids.size()) throw std::runtime_error("A conversation contains too many native sessions");
            std::unordered_set<std::string> providers;
            std::unordered_set<std::string> emitted;
            for (const auto& raw : sessions) {
                const auto session = raw.GetObject(); const auto provider = text(session, L"provider"), native = text(session, L"id");
                const auto acknowledged = session.GetNamedNumber(L"acknowledged", 0);
                if (!known_provider(provider) || !providers.insert(provider).second || native.empty() || native.size() > 1024 || native.find('\0') != std::string::npos
                        || !std::isfinite(acknowledged) || acknowledged < 0 || acknowledged > count || acknowledged != std::floor(acknowledged))
                    throw std::runtime_error("A conversation contains invalid native-session metadata; duplicate checking was stopped");
                NativeSession binding{provider,native,static_cast<std::size_t>(acknowledged),winrt::to_string(session.GetNamedString(L"profileID",L"default")),winrt::to_string(session.GetNamedString(L"accountScope",L""))};
                if(!valid_session_binding(binding))throw std::runtime_error("Invalid native account routing metadata; duplicate checking stopped");
                result.push_back({id,std::move(binding)});
                emitted.insert(provider+"/"+session_key(native));
            }
            const auto provenance=value.GetNamedValue(L"importedSession",json::JsonValue::CreateNullValue());
            if(provenance.ValueType()!=json::JsonValueType::Null){
                if(provenance.ValueType()!=json::JsonValueType::Object)throw std::runtime_error("Import provenance has an unsupported format; duplicate checking was stopped");
                const auto origin=provenance.GetObject();const auto provider=text(origin,L"provider"),native=text(origin,L"sessionID"),digest=text(origin,L"sourceSHA256");
                const auto source_bytes=origin.GetNamedNumber(L"sourceBytes",-1);const auto origins=origin.GetNamedArray(L"origins");
                if(origin.GetNamedNumber(L"version",0)!=1||(provider!="claude"&&provider!="codex")||canonical_id(native).empty()||origins.Size()>count||digest.size()!=64
                        ||!std::all_of(digest.begin(),digest.end(),[](unsigned char ch){return(ch>='0'&&ch<='9')||(ch>='a'&&ch<='f');})||!std::isfinite(source_bytes)||source_bytes<0||source_bytes>32*1024*1024||source_bytes!=std::floor(source_bytes))
                    throw std::runtime_error("Import origin identity is invalid; duplicate checking was stopped");
                if(emitted.insert(provider+"/"+session_key(native)).second)result.push_back({id,{provider,native,origins.Size()},true});
                else for(auto& existing:result)if(existing.thread_id==id&&existing.session.provider==provider&&session_key(existing.session.id)==session_key(native))existing.imported_origin=true;
            }
        }
        return result;
    }

    // A new import is visible only after its new transcript/provenance is durable. The live index
    // objects and caller Workspace are not mutated until the atomic index replacement succeeds.
    void publish_import(Workspace& workspace, const Thread& thread, const json::JsonObject& allowlisted_provenance) {
        require_open(); validate_id(thread.id); Workspace::validate_thread_metadata(thread);
        if (thread.full_access || !thread.queued_inputs.empty() || !thread.draft.empty() || !thread.draft_attachments.empty()
                || std::any_of(thread.model_preferences.begin(), thread.model_preferences.end(), [](const auto& preference){return preference.full_access;}))
            throw std::invalid_argument("Imported conversations must start in approval mode without pending inputs");
        if (std::any_of(workspace.threads.begin(), workspace.threads.end(), [&](const auto& existing){return canonical_id(existing.id) == canonical_id(thread.id);})
                || loaded_.contains(thread.id) || transcript_originals_.contains(thread.id)) throw std::runtime_error("The imported conversation identity already exists");
        if (!allowlisted_provenance || allowlisted_provenance.GetNamedNumber(L"version", 0) != 1) throw std::invalid_argument("Unsupported import provenance format");
        const auto provider = text(allowlisted_provenance, L"provider"), native = canonical_id(text(allowlisted_provenance, L"sessionID"));
        const auto digest = text(allowlisted_provenance, L"sourceSHA256");
        const auto source_bytes=allowlisted_provenance.GetNamedNumber(L"sourceBytes",-1);
        const bool valid_resume=thread.sessions.empty()||(thread.sessions.size()==1&&thread.sessions.front().provider==provider&&canonical_id(thread.sessions.front().id)==native&&thread.sessions.front().acknowledged_messages==thread.messages.size());
        if ((provider != "codex" && provider != "claude") || thread.provider != provider || !valid_resume || thread.messages.empty() || thread.messages.size() > 100000
                || digest.size() != 64 || !std::all_of(digest.begin(), digest.end(), [](unsigned char ch){return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f');})
                || !std::isfinite(source_bytes)||source_bytes<0||source_bytes>32*1024*1024||source_bytes!=std::floor(source_bytes)
                || allowlisted_provenance.GetNamedArray(L"origins").Size() != thread.messages.size()) throw std::invalid_argument("Imported transcript and provenance identity do not match");
        std::unordered_set<std::string> message_ids;
        for (const auto& message : thread.messages) {
            if (message.id.empty()||message.id.size()>1024||!message_ids.insert(message.id).second||message.provider != provider || (message.role != "user" && message.role != "assistant" && message.role != "tool") || !message.attachments.empty())
                throw std::invalid_argument("The import contains unsupported message roles, providers or attachments");
        }
        validate_import_provenance(allowlisted_provenance);
        const auto provenance_bytes = winrt::to_string(allowlisted_provenance.Stringify());
        if (provenance_bytes.size() > 32 * 1024 * 1024) throw std::runtime_error("Import provenance exceeds its bounded size");
        WriterLease writer(directory_,scope_identity_);scope_identity_=writer.identity;assert_index_unchanged(writer.directory);
        std::vector<std::string> ids; ids.reserve(workspace.threads.size()); for (const auto& existing : workspace.threads) ids.push_back(existing.id);
        for (const auto& existing : session_snapshot(writer.directory, ids)) if (existing.session.provider == provider && session_key(existing.session.id) == session_key(native))
            throw std::runtime_error("This native session already belongs to an existing conversation");
        for (const auto& existing : workspace.threads) for (const auto& session : existing.sessions) if (session.provider == provider && session_key(session.id) == session_key(native))
            throw std::runtime_error("This native session already belongs to an existing conversation");
        Workspace candidate = workspace; candidate.add_thread(thread);
        json::JsonObject transcript; put(transcript, L"id", thread.id); put(transcript, L"draft", ""); transcript.SetNamedValue(L"version", json::JsonValue::CreateNumberValue(1));
        transcript.SetNamedValue(L"draftAttachments", json::JsonArray{}); transcript.SetNamedValue(L"queuedInputs", json::JsonArray{});
        json::JsonArray messages; for (const auto& message : thread.messages) {json::JsonObject value; put(value, L"id", message.id); put(value, L"role", message.role); put(value, L"text", message.text); put(value, L"provider", message.provider); value.SetNamedValue(L"attachments", json::JsonArray{}); messages.Append(value);}
        transcript.SetNamedValue(L"messages", messages); json::JsonArray sessions;
        for (const auto& session : thread.sessions) {if(!valid_session_binding(session))throw std::runtime_error("Invalid native account binding");json::JsonObject value;put(value,L"profileID",session.profile_id);put(value,L"accountScope",session.account_scope); put(value, L"provider", session.provider); put(value, L"id", session.id); value.SetNamedValue(L"acknowledged", json::JsonValue::CreateNumberValue(static_cast<double>(session.acknowledged_messages))); sessions.Append(value);}
        transcript.SetNamedValue(L"sessions", sessions); transcript.SetNamedValue(L"importedSession", json::JsonObject::Parse(winrt::to_hstring(provenance_bytes)));
        const auto bytes = winrt::to_string(transcript.Stringify()); if (bytes.size() > 128 * 1024 * 1024) throw std::runtime_error("Imported transcript exceeds its write bound");
        auto loaded = loaded_; loaded.insert(thread.id); auto transcripts = transcript_originals_; transcripts.emplace(thread.id, transcript);
        WorkspaceStore transaction(writer.directory); transaction.opened_ = true;
        transaction.original_ = original_ ? json::JsonObject::Parse(original_.Stringify()) : nullptr;
        for (const auto& [id, value] : project_originals_) transaction.project_originals_.emplace(id, json::JsonObject::Parse(value.Stringify()));
        for (const auto& [id, value] : index_originals_) transaction.index_originals_.emplace(id, json::JsonObject::Parse(value.Stringify()));
        transaction.index_originals_.emplace(thread.id, json::JsonObject{});
        const auto path = writer.directory/L"threads"/winrt::to_hstring(thread.id+".json").c_str(); std::filesystem::create_directories(path.parent_path());
        const auto file = CreateFileW(path.c_str(), GENERIC_WRITE | DELETE, FILE_SHARE_READ, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("The import target already exists or cannot be created; no existing file was overwritten");
        struct NewFile {HANDLE value; bool keep{}; ~NewFile(){if (!keep) {FILE_DISPOSITION_INFO remove{TRUE}; SetFileInformationByHandle(value, FileDispositionInfo, &remove, sizeof(remove));} CloseHandle(value);}} created{file};
        DWORD written{}; if (!WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) || written != bytes.size() || !FlushFileBuffers(file)) {
            const auto error=GetLastError(); throw winrt::hresult_error(HRESULT_FROM_WIN32(error?error:ERROR_WRITE_FAULT));
        }
        transaction.save_index(candidate);
        static_assert(std::is_nothrow_move_assignable_v<Workspace>);
        workspace = std::move(candidate); original_ = transaction.original_; project_originals_.swap(transaction.project_originals_); index_originals_.swap(transaction.index_originals_);
        loaded_.swap(loaded); transcript_originals_.swap(transcripts); created.keep = true;
    }

private:
    struct DirectoryIdentity{ULONGLONG volume{};std::array<BYTE,16> id{};bool operator==(const DirectoryIdentity&)const=default;};
    struct DirectoryHandle{
        HANDLE value{INVALID_HANDLE_VALUE};DirectoryIdentity identity;std::filesystem::path resolved;
        explicit DirectoryHandle(const std::filesystem::path& path){
            value=CreateFileW(path.c_str(),FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,nullptr);
            if(value==INVALID_HANDLE_VALUE)throw std::runtime_error("The workspace storage folder is unavailable");
            FILE_ID_INFO info{};BY_HANDLE_FILE_INFORMATION attributes{};std::array<wchar_t,32768> name{};
            const auto length=GetFinalPathNameByHandleW(value,name.data(),static_cast<DWORD>(name.size()),FILE_NAME_NORMALIZED|VOLUME_NAME_DOS);
            if(!GetFileInformationByHandleEx(value,FileIdInfo,&info,sizeof(info))||!GetFileInformationByHandle(value,&attributes)||!(attributes.dwFileAttributes&FILE_ATTRIBUTE_DIRECTORY)||!length||length>=name.size()){
                CloseHandle(value);value=INVALID_HANDLE_VALUE;throw std::runtime_error("Could not bind the physical workspace storage folder");
            }
            identity.volume=info.VolumeSerialNumber;std::copy(std::begin(info.FileId.Identifier),std::end(info.FileId.Identifier),identity.id.begin());resolved=std::filesystem::path(std::wstring(name.data(),length));
        }
        ~DirectoryHandle(){if(value!=INVALID_HANDLE_VALUE)CloseHandle(value);}
        DirectoryHandle(const DirectoryHandle&)=delete;DirectoryHandle& operator=(const DirectoryHandle&)=delete;
    };
    struct WriterLease{
        std::unique_ptr<DirectoryHandle> pinned;HANDLE mutex{};DirectoryIdentity identity;std::filesystem::path directory;
        WriterLease(const std::filesystem::path& path,const std::optional<DirectoryIdentity>& expected){
            if(expected&&!std::filesystem::exists(path))throw std::runtime_error("The workspace storage folder moved; reopen it before writing");
            std::filesystem::create_directories(path);pinned=std::make_unique<DirectoryHandle>(path);identity=pinned->identity;directory=pinned->resolved;
            if(expected&&*expected!=identity)throw std::runtime_error("The workspace storage identity changed; reopen it before writing");
            constexpr wchar_t hex[]=L"0123456789abcdef";auto name=L"Global\\Coincide-Workspace-"+std::to_wstring(identity.volume)+L"-";for(const auto ch:identity.id){name+=hex[ch>>4];name+=hex[ch&15];}
            mutex=CreateMutexW(nullptr,FALSE,name.c_str());if(!mutex)throw std::runtime_error("The workspace writer lease is unavailable");const auto status=WaitForSingleObject(mutex,5000);
            if(status!=WAIT_OBJECT_0&&status!=WAIT_ABANDONED){CloseHandle(mutex);mutex=nullptr;throw std::runtime_error("Another process is writing this workspace; retry after it finishes");}
        }
        ~WriterLease(){if(mutex){ReleaseMutex(mutex);CloseHandle(mutex);}}
        WriterLease(const WriterLease&)=delete;WriterLease& operator=(const WriterLease&)=delete;
    };
    std::filesystem::path directory_;
    std::optional<DirectoryIdentity> scope_identity_;
    bool opened_{};
    json::JsonObject original_{nullptr};
    std::unordered_map<std::string, json::JsonObject> project_originals_, index_originals_, transcript_originals_;
    std::unordered_set<std::string> loaded_;

    void require_open() const {
        if (!opened_) throw std::logic_error("The workspace must open successfully before any reads or writes");
        if(scope_identity_&&directory_identity(directory_)!=*scope_identity_)throw std::runtime_error("The workspace storage identity changed; reopen it before reading or writing");
    }
    static DirectoryIdentity directory_identity(const std::filesystem::path& path){const DirectoryHandle handle(path);return handle.identity;}
    static std::unordered_map<std::string,json::JsonObject> clone_objects(const std::unordered_map<std::string,json::JsonObject>& objects){
        std::unordered_map<std::string,json::JsonObject> result;result.reserve(objects.size());for(const auto& [id,value]:objects)result.emplace(id,json::JsonObject::Parse(value.Stringify()));return result;
    }
    void assert_index_unchanged(const std::filesystem::path& directory)const{
        const auto index=directory/L"workspace.json";if(std::filesystem::exists(index)!=static_cast<bool>(original_))throw std::runtime_error("The workspace index changed outside this store; reopen it before writing");
        if(original_){std::size_t bytes{};if(read_session_file(index,bytes).Stringify()!=original_.Stringify())throw std::runtime_error("The workspace index changed outside this store; reopen it before writing");}
    }

    static json::JsonObject read_session_file(const std::filesystem::path& path, std::size_t& total) {
        constexpr std::size_t per_file = 128 * 1024 * 1024, aggregate = 512 * 1024 * 1024;
        if (total >= aggregate) throw std::runtime_error("Native-session discovery exceeded its aggregate read bound");
        std::error_code size_error;const auto size=std::filesystem::file_size(path,size_error);
        if(size_error)throw std::runtime_error("A conversation file is missing or unreadable; duplicate checking was stopped");
        if(size>std::min(per_file,aggregate-total))throw std::runtime_error("A conversation file exceeds the native-session snapshot read bound");
        std::ifstream input(path, std::ios::binary); if (!input) throw std::runtime_error("A conversation file is missing or unreadable; duplicate checking was stopped");
        std::string bytes; std::array<char, 65536> buffer{}; const auto maximum = std::min(per_file, aggregate - total);
        while (input && bytes.size() <= maximum) {input.read(buffer.data(), static_cast<std::streamsize>(std::min(buffer.size(), maximum + 1 - bytes.size()))); bytes.append(buffer.data(), static_cast<std::size_t>(input.gcount()));}
        if (input.bad() || (!input.eof()&&input.fail()) || bytes.size() > maximum) throw std::runtime_error("A conversation file could not be read within the native-session snapshot bound");
        total += bytes.size(); return json::JsonObject::Parse(winrt::to_hstring(bytes));
    }
    static std::string session_key(std::string id) {
        if(id.size()>1&&id.front()=='{'&&id.back()=='}')id=id.substr(1,id.size()-2);
        for(auto& ch:id)if(ch>='A'&&ch<='Z')ch=static_cast<char>(ch+('a'-'A'));return id;
    }
    static void validate_import_provenance(const json::IJsonValue& value,unsigned depth=0,std::size_t* nodes=nullptr) {
        std::size_t local{};if(!nodes)nodes=&local;
        if(depth>16||++*nodes>1000000)throw std::invalid_argument("Import provenance nesting or field count exceeds its bound");
        if(value.ValueType()==json::JsonValueType::Object)for(const auto& field:value.GetObject()){
            auto key=winrt::to_string(field.Key());for(auto& ch:key)if(ch>='A'&&ch<='Z')ch=static_cast<char>(ch+('a'-'A'));
            if(key=="auth"||key=="authorization"||key=="password"||key=="access_token"||key=="refresh_token"||key=="api_key"||key=="client_secret"||key=="private_key"||key=="credentials"||key=="cookies")
                throw std::invalid_argument("Authentication material is not supported in import provenance");
            validate_import_provenance(field.Value(),depth+1,nodes);
        }else if(value.ValueType()==json::JsonValueType::Array)for(const auto& entry:value.GetArray())validate_import_provenance(entry,depth+1,nodes);
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
    static void require_host_format(const json::JsonObject& value){if(value.GetNamedString(L"hostFormat",L"")!=L"coincide.windows.background-agent"||value.GetNamedNumber(L"hostFormatVersion",0)!=1)throw std::runtime_error("This hosted storage format is not supported. Its file was preserved.");}
    static void put_host_format(const json::JsonObject& value){put(value,L"hostFormat","coincide.windows.background-agent");value.SetNamedValue(L"hostFormatVersion",json::JsonValue::CreateNumberValue(1));}
    static std::vector<HostEventCursor> read_host_cursors(const json::JsonArray& array){
        if(array.Size()>provider_ids.size())throw std::runtime_error("Too many hosted event receipts");std::vector<HostEventCursor> result;std::unordered_set<std::string> providers;
        for(const auto& raw:array){const auto value=raw.GetObject();const auto number=value.GetNamedNumber(L"sequence",-1);
            if(!std::isfinite(number)||number<0||number>9007199254740991.0||number!=std::floor(number))throw std::runtime_error("Invalid hosted event receipt sequence");
            HostEventCursor cursor{text(value,L"provider"),canonical_id(text(value,L"epoch")),static_cast<std::uint64_t>(number)};
            if(!valid_host_event_cursor(cursor)||!providers.insert(cursor.provider).second)throw std::runtime_error("Invalid or duplicate hosted event receipt");result.push_back(std::move(cursor));
        }return result;
    }
    static json::JsonArray host_cursors_json(const std::vector<HostEventCursor>& cursors,const json::JsonArray& existing){
        if(cursors.size()>provider_ids.size())throw std::runtime_error("Too many hosted event receipts");json::JsonArray result;std::unordered_set<std::string> providers;std::unordered_map<std::string,json::JsonObject> originals;
        for(const auto& raw:existing){const auto item=raw.GetObject();originals.insert_or_assign(text(item,L"provider"),item);}
        for(const auto& cursor:cursors){if(!valid_host_event_cursor(cursor)||!providers.insert(cursor.provider).second)throw std::runtime_error("Invalid or duplicate hosted event receipt");auto item=originals.contains(cursor.provider)?originals.at(cursor.provider):json::JsonObject{};
            put(item,L"provider",cursor.provider);put(item,L"epoch",canonical_id(cursor.epoch));item.SetNamedValue(L"sequence",json::JsonValue::CreateNumberValue(static_cast<double>(cursor.sequence)));result.Append(item);
        }return result;
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
