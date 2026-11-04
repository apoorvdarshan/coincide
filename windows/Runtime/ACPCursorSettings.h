#pragma once
#include "ACPProtocol.h"
#include "ACPFileSystem.h"
#include <map>
#include <set>

namespace coincide {
// Cursor writes ACP model/effort choices into its CLI defaults. Share one model-only snapshot
// across overlapping operations of this profile, and restore only those keys after the last one.
// Unrelated settings are re-read immediately before the atomic write and are never snapshotted.
class ACPCursorSettings {
public:
    using Object = ACPProtocol::Object; using Json = ACPProtocol::Json;
    explicit ACPCursorSettings(const std::filesystem::path& file) {
        const auto filename = file.filename().wstring();
        if (CompareStringOrdinal(filename.data(), static_cast<int>(filename.size()), L"cli-config.json", 15, TRUE) != CSTR_EQUAL) throw std::invalid_argument("Cursor model protection requires its cli-config.json file");
        auto files = std::make_shared<ACPFileSystem>(file.parent_path());
        const auto resolved = files->literal(winrt::to_string((files->root() / file.filename()).wstring()));
        auto key = resolved.wstring(); std::transform(key.begin(), key.end(), key.begin(), [](wchar_t value) {return static_cast<wchar_t>(std::towupper(value));});
        std::lock_guard lock(registry_mutex_);
        if (const auto previous = registry_[key].lock()) state_ = previous;
        else {state_ = std::make_shared<State>(); state_->files = std::move(files); state_->file = winrt::to_string(resolved.wstring()); registry_[key] = state_;}
    }
    const std::filesystem::path& profile_directory() const {return state_->files->root();}
    void begin() {
        std::lock_guard lock(state_->mutex);
        if (!state_->depth) {state_->snapshot = model_values(read()); state_->touched.clear();}
        ++state_->depth;
    }
    void end(const std::set<std::string>& touched = {}) {
        std::lock_guard lock(state_->mutex); if (!state_->depth) throw std::logic_error("Cursor settings operation was not started");
        state_->touched.insert(touched.begin(), touched.end()); if (--state_->depth) return;
        const auto clear = [&] {state_->snapshot.clear(); state_->touched.clear();};
        try {
            auto current = read(); const auto values = model_values(current); if (values == state_->snapshot) {clear(); return;}
            const auto model = model_id(current), original = model_id(from_values(state_->snapshot));
            // A different model chosen by the user or another CLI while this operation ran wins.
            if (model != original && !state_->touched.contains(model)) {clear(); return;}
            for (const auto* key : keys()) {
                const auto saved = state_->snapshot.find(key);
                if (saved == state_->snapshot.end()) {if (current.HasKey(key)) current.Remove(key);}
                else current.SetNamedValue(key, Json::Parse(winrt::to_hstring(saved->second)));
            }
            state_->files->write(state_->file, winrt::to_string(current.Stringify()) + "\n"); clear();
        } catch (...) {clear(); throw std::runtime_error("Cursor's CLI model defaults could not be restored");}
    }
    static std::string model_id(const Object& values) {
        for (const auto* key : {L"selectedModel", L"model"}) {
            const auto value = values.GetNamedValue(key, Json::CreateNullValue());
            if (value.ValueType() == rpc_json::JsonValueType::Object) {const auto id = ACPProtocol::text(value.GetObject(), L"modelId"); if (!id.empty()) return id;}
        }
        return {};
    }
    class Lease {
    public:
        explicit Lease(ACPCursorSettings* owner, std::function<void(const std::string&)> warning = {}) : owner_(owner), warning_(std::move(warning)) {if (owner_) owner_->begin();}
        ~Lease() {if (owner_) {try {finish();} catch (const std::exception& error) {try {if (warning_) warning_(error.what());} catch (...) {}}}}
        void touch(std::string model) {if (!model.empty()) touched_.insert(std::move(model));}
        void finish() {if (auto* owner = std::exchange(owner_, nullptr)) owner->end(touched_);}
        Lease(const Lease&) = delete;
        Lease& operator=(const Lease&) = delete;
    private:
        ACPCursorSettings* owner_; std::function<void(const std::string&)> warning_; std::set<std::string> touched_;
    };
private:
    using Values = std::map<std::wstring, std::string>;
    struct State {std::mutex mutex; std::shared_ptr<ACPFileSystem> files; std::string file; unsigned depth{}; Values snapshot; std::set<std::string> touched;};
    std::shared_ptr<State> state_;
    inline static std::mutex registry_mutex_;
    inline static std::map<std::wstring, std::weak_ptr<State>> registry_;
    static std::array<const wchar_t*, 7> keys() {return {L"model", L"selectedModel", L"modelParameters", L"hasChangedDefaultModel", L"maxMode", L"maxModeAutoEnabled", L"modelSelectionHistory"};}
    Object read() const {
        const auto path = std::filesystem::path(ACPFileSystem::wide(state_->file));
        const auto attributes = GetFileAttributesW(path.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES) {if (GetLastError() == ERROR_FILE_NOT_FOUND) return Object{}; throw std::runtime_error("Could not inspect Cursor's CLI model settings");}
        if (attributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) throw std::runtime_error("Cursor model settings must be a regular local file");
        Object value{nullptr};
        try {if (Object::TryParse(winrt::to_hstring(state_->files->read(state_->file)), value)) return value;} catch (...) {}
        throw std::runtime_error("Cursor's CLI settings could not be read safely; model defaults were not changed");
    }
    static Values model_values(const Object& object) {
        Values result; for (const auto* key : keys()) if (object.HasKey(key)) result.emplace(key, winrt::to_string(object.GetNamedValue(key).Stringify())); return result;
    }
    static Object from_values(const Values& values) {Object result; for (const auto& [key, value] : values) result.SetNamedValue(key, Json::Parse(winrt::to_hstring(value))); return result;}
};
} // namespace coincide
