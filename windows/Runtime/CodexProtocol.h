#pragma once
#include <winrt/Windows.Foundation.Collections.h>
#include "RpcPeer.h"
#include <algorithm>
#include <unordered_set>
#include <vector>

namespace coincide {
enum class AgentAccess { approval, full_access };

struct CodexTurn {
    std::string text;
    std::string cwd;
    std::string model;
    std::string effort;
    std::string service_tier;
    bool plan{};
    AgentAccess access{AgentAccess::approval};
    std::vector<std::string> image_paths;
};

struct CodexServiceTier {
    std::string id, name, description;
};
struct CodexModel {
    std::string id, model, display_name, default_effort;
    std::vector<std::string> efforts;
    std::vector<CodexServiceTier> service_tiers;
    bool hidden{}, is_default{}, supports_images{true};
};

// Mirrors the Mac adapter and the official app-server JSONL contract. It does not call the Responses API directly.
// Models come from model/list or the thread's resolved model; no Windows-only model list is hardcoded.
struct CodexProtocol {
    using Object = rpc_json::JsonObject;
    using Array = rpc_json::JsonArray;
    using Json = rpc_json::JsonValue;

    static void text(Object value, const wchar_t* name, const std::string& text) {
        value.SetNamedValue(name, Json::CreateStringValue(winrt::to_hstring(text)));
    }
    static std::string string(const Object& value, const wchar_t* name) {
        const auto item = value.GetNamedValue(name, Json::CreateNullValue());
        return item.ValueType() == rpc_json::JsonValueType::String ? winrt::to_string(item.GetString()) : "";
    }
    static Object model_list(const std::string& cursor = {}) {
        Object params;
        if (!cursor.empty()) text(params, L"cursor", cursor);
        return params;
    }
    // Catalog data remains provider-owned; no Windows-only model names or reasoning levels are invented.
    static std::vector<CodexModel> catalog_entries(const Array& entries, bool include_hidden = false) {
        std::vector<CodexModel> result;
        std::unordered_set<std::string> models;
        for (const auto& raw : entries) {
            if (raw.ValueType() != rpc_json::JsonValueType::Object) continue;
            const auto entry = raw.GetObject();
            CodexModel model;
            model.model = string(entry, L"model");
            if (model.model.empty()) model.model = string(entry, L"id");
            model.id = model.model;
            model.hidden = entry.GetNamedBoolean(L"hidden", false);
            if (model.id.empty() || (!include_hidden && model.hidden) || !models.insert(model.id).second) continue;
            model.display_name = string(entry, L"displayName");
            if (model.display_name.empty()) model.display_name = model.model;
            model.is_default = entry.GetNamedBoolean(L"isDefault", false);
            std::unordered_set<std::string> efforts;
            for (const auto& option : entry.GetNamedArray(L"supportedReasoningEfforts", Array{})) {
                if (option.ValueType() != rpc_json::JsonValueType::Object) continue;
                auto value = string(option.GetObject(), L"reasoningEffort");
                if (!value.empty() && efforts.insert(value).second) model.efforts.push_back(std::move(value));
            }
            model.default_effort = string(entry, L"defaultReasoningEffort");
            if (!model.efforts.empty() && !efforts.contains(model.default_effort)) model.default_effort.clear();
            const auto modalities = entry.GetNamedValue(L"inputModalities", Json::CreateNullValue());
            if (modalities.ValueType() == rpc_json::JsonValueType::Array) {
                model.supports_images = false;
                for (const auto& modality : modalities.GetArray()) {
                    if (modality.ValueType() == rpc_json::JsonValueType::String && modality.GetString() == L"image") model.supports_images = true;
                }
            }
            std::unordered_set<std::string> tiers;
            const auto advertised_tiers = entry.GetNamedArray(L"serviceTiers", Array{});
            for (const auto& raw_tier : advertised_tiers) {
                if (raw_tier.ValueType() != rpc_json::JsonValueType::Object) continue;
                const auto tier = raw_tier.GetObject();
                auto id = string(tier, L"id");
                if (id.empty() || id == "default" || !tiers.insert(id).second) continue;
                auto name = string(tier, L"name");
                model.service_tiers.push_back({id, name.empty() ? id : name, string(tier, L"description")});
            }
            if (advertised_tiers.Size() == 0) {
                for (const auto& raw_tier : entry.GetNamedArray(L"additionalSpeedTiers", Array{})) {
                    if (raw_tier.ValueType() != rpc_json::JsonValueType::String) continue;
                    auto id = winrt::to_string(raw_tier.GetString());
                    if (!id.empty() && id != "default" && tiers.insert(id).second) model.service_tiers.push_back({id, id, {}});
                }
            }
            result.push_back(std::move(model));
        }
        std::stable_sort(result.begin(), result.end(), [](const auto& a, const auto& b) {return a.is_default && !b.is_default;});
        return result;
    }
    static Object initialize() {
        Object result, client, capabilities;
        text(client, L"name", "coincide"); text(client, L"title", "Coincide"); text(client, L"version", "0.1.0");
        capabilities.SetNamedValue(L"experimentalApi", Json::CreateBooleanValue(true));
        capabilities.SetNamedValue(L"requestAttestation", Json::CreateBooleanValue(false));
        Array exclude; exclude.Append(Json::CreateStringValue(L"turn/diff/updated"));
        capabilities.SetNamedValue(L"optOutNotificationMethods", exclude);
        result.SetNamedValue(L"clientInfo", client); result.SetNamedValue(L"capabilities", capabilities);
        return result;
    }
    static Object thread_start(const std::string& cwd, const std::string& model = {}, const std::string& instructions = {}) {
        if (cwd.empty()) throw std::invalid_argument("Codex needs a working directory");
        Object result, config;
        text(result, L"cwd", cwd);
        config.SetNamedValue(L"tools.update_plan.enabled", Json::CreateBooleanValue(true));
        config.SetNamedValue(L"mcp_optional_startup_grace_ms", Json::CreateNumberValue(10000));
        result.SetNamedValue(L"config", config);
        if (!model.empty()) text(result, L"model", model);
        if (!instructions.empty()) text(result, L"developerInstructions", instructions);
        return result;
    }
    static Object thread_resume(const std::string& id, const std::string& cwd, const std::string& model = {}, const std::string& instructions = {}) {
        if (id.empty()) throw std::invalid_argument("Codex needs a native session identity to resume");
        auto result = thread_start(cwd, model, instructions);
        text(result, L"threadId", id); result.SetNamedValue(L"excludeTurns", Json::CreateBooleanValue(true));
        return result;
    }
    static Array user_input(const CodexTurn& turn) {
        Array input;
        if (!turn.text.empty()) {
            Object text_item;
            text(text_item, L"type", "text"); text(text_item, L"text", turn.text);
            text_item.SetNamedValue(L"text_elements", Array{}); input.Append(text_item);
        }
        for (const auto& path : turn.image_paths) {
            Object image; text(image, L"type", "localImage"); text(image, L"path", path); input.Append(image);
        }
        return input;
    }
    static Object turn_start(const std::string& id, const CodexTurn& turn) {
        if (id.empty() || turn.cwd.empty()) throw std::invalid_argument("Codex needs a thread and a working directory");
        if (turn.plan && turn.model.empty()) throw std::invalid_argument("Resolve the thread model before entering Plan mode");
        Object result, sandbox;
        text(result, L"threadId", id); text(result, L"cwd", turn.cwd);
        result.SetNamedValue(L"input", user_input(turn));
        text(result, L"summary", "detailed"); text(result, L"approvalsReviewer", "user");
        text(result, L"approvalPolicy", turn.access == AgentAccess::approval ? "untrusted" : "never");
        text(sandbox, L"type", turn.access == AgentAccess::approval ? "readOnly" : "dangerFullAccess");
        result.SetNamedValue(L"sandboxPolicy", sandbox);
        if (!turn.model.empty()) text(result, L"model", turn.model);
        if (!turn.effort.empty()) text(result, L"effort", turn.effort);
        if (!turn.service_tier.empty()) text(result, L"serviceTier", turn.service_tier);
        if (!turn.model.empty()) {
            Object mode, settings;
            text(mode, L"mode", turn.plan ? "plan" : "default"); text(settings, L"model", turn.model);
            settings.SetNamedValue(L"reasoning_effort", turn.effort.empty() ? Json::CreateNullValue() : Json::CreateStringValue(winrt::to_hstring(turn.effort)));
            settings.SetNamedValue(L"developer_instructions", Json::CreateNullValue());
            mode.SetNamedValue(L"settings", settings); result.SetNamedValue(L"collaborationMode", mode);
        }
        return result;
    }
    static Object interrupt(const std::string& thread, const std::string& turn) {
        if (thread.empty() || turn.empty()) throw std::invalid_argument("Only a known active Codex turn can be interrupted");
        Object result; text(result, L"threadId", thread); text(result, L"turnId", turn); return result;
    }
    static Object steer(const std::string& thread, const std::string& expected_turn, const CodexTurn& turn) {
        if (thread.empty() || expected_turn.empty()) throw std::invalid_argument("Only a known active Codex turn can be steered");
        Object result;
        text(result, L"threadId", thread); text(result, L"expectedTurnId", expected_turn);
        result.SetNamedValue(L"input", user_input(turn)); return result;
    }
};
} // namespace coincide
