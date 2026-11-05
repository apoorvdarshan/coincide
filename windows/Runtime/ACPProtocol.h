#pragma once
#include "OpenCodeProtocol.h"

namespace coincide {
struct ACPProtocol {
    using Object = CodexProtocol::Object; using Array = CodexProtocol::Array; using Json = CodexProtocol::Json; using Type = rpc_json::JsonValueType;
    static std::string text(const Object& value, const wchar_t* key) {return CodexProtocol::string(value, key);}
    static void put(Object value, const wchar_t* key, const std::string& body) {CodexProtocol::text(value, key, body);}
    static std::vector<std::wstring> arguments(const std::string& provider, AgentAccess access) {
        if (provider == "cursor") return access == AgentAccess::full_access ? std::vector<std::wstring>{L"--force", L"acp"} : std::vector<std::wstring>{L"acp"};
        if (provider == "grok") return access == AgentAccess::full_access ? std::vector<std::wstring>{L"agent", L"--always-approve", L"stdio"} : std::vector<std::wstring>{L"--permission-mode", L"default", L"agent", L"stdio"};
        if (provider == "antigravity") return {};
        throw std::invalid_argument("Unknown ACP provider");
    }
    static Object initialize(const std::string& provider) {
        Object result, capabilities, fs, info, meta, session;
        fs.SetNamedValue(L"readTextFile", Json::CreateBooleanValue(true)); fs.SetNamedValue(L"writeTextFile", Json::CreateBooleanValue(true)); capabilities.SetNamedValue(L"fs", fs);
        capabilities.SetNamedValue(L"terminal", Json::CreateBooleanValue(true)); session.SetNamedValue(L"notices", Object{}); capabilities.SetNamedValue(L"session", session);
        // Form elicitation is implemented; URL/terminal authentication and other capabilities are not.
        Object elicitation; elicitation.SetNamedValue(L"form", Object{}); capabilities.SetNamedValue(L"elicitation", elicitation);
        if (provider == "cursor") {Object picker; picker.SetNamedValue(L"parameterizedModelPicker", Json::CreateBooleanValue(true)); capabilities.SetNamedValue(L"_meta", picker);}
        result.SetNamedValue(L"protocolVersion", Json::CreateNumberValue(1)); result.SetNamedValue(L"clientCapabilities", capabilities); put(info, L"name", "Coincide"); put(info, L"version", "1"); result.SetNamedValue(L"clientInfo", info);
        if (provider == "grok") {put(meta, L"clientType", "extension"); result.SetNamedValue(L"_meta", meta);} return result;
    }
    static Object session(const std::string& id, const std::string& cwd) {Object result; if (!id.empty()) put(result, L"sessionId", id); put(result, L"cwd", cwd); result.SetNamedValue(L"mcpServers", Array{}); return result;}
    static Object cancelled() {Object result, outcome; put(outcome, L"outcome", "cancelled"); result.SetNamedValue(L"outcome", outcome); return result;}
    static Object permission(const Object& request, bool allow) {
        const auto wanted = allow ? "allow_once" : "reject_once";
        for (const auto& raw : request.GetNamedArray(L"options", Array{})) {
            if (raw.ValueType() != Type::Object) continue; const auto option = raw.GetObject();
            if (text(option, L"kind") != wanted || text(option, L"optionId").empty()) continue;
            Object result, outcome; put(outcome, L"outcome", "selected"); put(outcome, L"optionId", text(option, L"optionId")); result.SetNamedValue(L"outcome", outcome); return result;
        }
        return cancelled(); // Never silently choose an allow_always option that persists project grants.
    }
    static Array choices(const Array& raw, unsigned depth = 0) {
        Array result; if (depth > 8) throw std::invalid_argument("ACP config choices are nested too deeply");
        for (const auto& value : raw) {
            if (value.ValueType() != Type::Object) continue; const auto entry = value.GetObject();
            if (entry.HasKey(L"options")) {for (const auto& nested : choices(entry.GetNamedArray(L"options", Array{}), depth + 1)) {if (result.Size() >= 4096) throw std::invalid_argument("Too many ACP config choices"); result.Append(nested);}}
            else if (!text(entry, L"value").empty()) {if (result.Size() >= 4096) throw std::invalid_argument("Too many ACP config choices"); result.Append(entry);}
        }
        return result;
    }
    static std::optional<Object> config(const Object& setup, const char* category, const char* fallback) {
        for (const auto& raw : setup.GetNamedArray(L"configOptions", Array{})) {
            if (raw.ValueType() != Type::Object) continue; const auto option = raw.GetObject();
            if (text(option, L"category") == category || text(option, L"id") == fallback) return option;
        }
        return std::nullopt;
    }
    static Object catalog(const Object& setup, const Object& initialized) {
        auto state = setup.GetNamedObject(L"models", initialized.GetNamedObject(L"_meta", Object{}).GetNamedObject(L"modelState", Object{}));
        Array advertised = state.GetNamedArray(L"availableModels", Array{}), models;
        const auto selected = config(setup, "model", "model");
        if (selected) {
            Array values;
            for (const auto& raw : choices(selected->GetNamedArray(L"options", Array{}))) {
                const auto option = raw.GetObject(); Object model; const auto id = text(option, L"value"); put(model, L"modelId", id); put(model, L"name", text(option, L"name"));
                for (const auto& legacy : advertised) if (legacy.ValueType() == Type::Object && text(legacy.GetObject(), L"modelId") == id && legacy.GetObject().HasKey(L"_meta")) model.SetNamedValue(L"_meta", legacy.GetObject().GetNamedValue(L"_meta"));
                values.Append(model);
            }
            advertised = values;
        }
        const auto current = selected ? text(*selected, L"currentValue") : text(state, L"currentModelId"); const auto reasoning = config(setup, "thought_level", "reasoning_effort");
        std::unordered_set<std::string> seen;
        const auto image = initialized.GetNamedObject(L"agentCapabilities", Object{}).GetNamedObject(L"promptCapabilities", Object{}).GetNamedBoolean(L"image", false);
        for (const auto& raw : advertised) {
            if (raw.ValueType() != Type::Object) continue; const auto source = raw.GetObject(); const auto id = text(source, L"modelId"); if (id.empty() || !seen.insert(id).second) continue;
            Object entry; put(entry, L"model", id); put(entry, L"displayName", text(source, L"name").empty() ? id : text(source, L"name")); entry.SetNamedValue(L"isDefault", Json::CreateBooleanValue(id == current));
            Array efforts; const auto meta = source.GetNamedObject(L"_meta", Object{});
            for (const auto& raw_effort : meta.GetNamedArray(L"reasoningEfforts", Array{})) {
                if (raw_effort.ValueType() != Type::Object) continue; const auto effort = raw_effort.GetObject(); const auto value = text(effort, L"value").empty() ? text(effort, L"id") : text(effort, L"value");
                if (!value.empty()) {Object option; put(option, L"reasoningEffort", value); efforts.Append(option); if (effort.GetNamedBoolean(L"default", false)) put(entry, L"defaultReasoningEffort", value);}
            }
            if (!efforts.Size() && id == current && reasoning) {
                for (const auto& choice : choices(reasoning->GetNamedArray(L"options", Array{}))) {Object effort; put(effort, L"reasoningEffort", text(choice.GetObject(), L"value")); efforts.Append(effort);}
                put(entry, L"defaultReasoningEffort", text(*reasoning, L"currentValue"));
            }
            entry.SetNamedValue(L"supportedReasoningEfforts", efforts); Array modalities; modalities.Append(Json::CreateStringValue(L"text")); if (image) modalities.Append(Json::CreateStringValue(L"image")); entry.SetNamedValue(L"inputModalities", modalities); models.Append(entry);
            if (models.Size() >= 1000) break;
        }
        Object result; result.SetNamedValue(L"data", models); result.SetNamedValue(L"nextCursor", Json::CreateNullValue()); return result;
    }
    // Convert vendor/MCP question contracts into the same typed form used by the native question UI.
    static std::optional<Object> question_form(const std::string& kind, const Object& params) {
        Object form; put(form, L"id", "acp-form"); Array fields;
        auto input = params; if (kind == "grok" && params.HasKey(L"params")) input = params.GetNamedObject(L"params", Object{});
        if (kind == "elicitation") {
            if (text(params, L"mode") != "form" && !text(params, L"mode").empty()) return std::nullopt;
            const auto schema = params.GetNamedObject(L"requestedSchema", Object{}); const auto properties = schema.GetNamedObject(L"properties", Object{});
            for (const auto& item : properties) {
                if (item.Value().ValueType() != Type::Object) return std::nullopt; const auto property = item.Value().GetObject(); Object field; const auto type = text(property, L"type");
                put(field, L"key", winrt::to_string(item.Key())); put(field, L"type", type == "array" ? "multiselect" : type); put(field, L"title", text(property, L"title")); put(field, L"description", text(property, L"description"));
                const auto source = type == "array" ? property.GetNamedObject(L"items", Object{}) : property; Array options;
                for (const auto& value : source.GetNamedArray(L"enum", Array{})) {if (value.ValueType() != Type::String) return std::nullopt; Object option; option.SetNamedValue(L"value", value); options.Append(option);}
                if (type == "array" && !options.Size()) return std::nullopt; field.SetNamedValue(L"options", options); fields.Append(field);
            }
        } else {
            unsigned index{};
            for (const auto& raw : input.GetNamedArray(L"questions", Array{})) {
                if (raw.ValueType() != Type::Object) return std::nullopt; const auto source = raw.GetObject(); Object field; auto id = text(source, L"id"); if (id.empty()) id = "q" + std::to_string(++index);
                const auto prompt = text(source, kind == "cursor" ? L"prompt" : L"question"); if (prompt.empty()) return std::nullopt;
                put(field, L"key", id); put(field, L"title", prompt); put(field, L"type", source.GetNamedBoolean(kind == "cursor" ? L"allowMultiple" : L"multiSelect", false) ? "multiselect" : "string");
                field.SetNamedValue(L"custom", Json::CreateBooleanValue(kind == "grok")); Array options;
                for (const auto& value : source.GetNamedArray(L"options", Array{})) {
                    if (value.ValueType() != Type::Object) return std::nullopt; const auto option = value.GetObject(); Object normalized; const auto label = text(option, L"label");
                    put(normalized, L"label", label); put(normalized, L"value", kind == "cursor" ? text(option, L"id") : label); put(normalized, L"description", text(option, L"description")); options.Append(normalized);
                }
                field.SetNamedValue(L"options", options); fields.Append(field);
            }
        }
        form.SetNamedValue(L"fields", fields); return OpenCodeProtocol::questions(form) ? std::optional<Object>(form) : std::nullopt;
    }
    static Object question_reply(const std::string& kind, const Object& form, const Object& response) {
        const auto answers = OpenCodeProtocol::form_answer(form, response); Object result;
        if (kind == "elicitation") {put(result, L"action", answers.Size() ? "accept" : "cancel"); if (answers.Size()) result.SetNamedValue(L"content", answers); return result;}
        if (kind == "cursor") {
            Object outcome; Array selections; std::string in_words; bool typed{};
            for (const auto& field : form.GetNamedArray(L"fields")) {
                const auto key = text(field.GetObject(), L"key"); const auto value = answers.GetNamedValue(winrt::to_hstring(key), Json::CreateNullValue()); Array selected;
                if (value.ValueType() == Type::Array) selected = value.GetArray(); else if (value.ValueType() == Type::String) selected.Append(value);
                if (selected.Size()) {
                    if (!in_words.empty()) in_words += '\n'; in_words += text(field.GetObject(), L"title") + ": ";
                    const auto original = response.GetNamedObject(L"answers", Object{}).GetNamedObject(winrt::to_hstring(key), Object{}).GetNamedArray(L"answers", Array{});
                    for (std::uint32_t index = 0; index < original.Size(); ++index) {if (index) in_words += ", "; in_words += winrt::to_string(original.GetAt(index).GetString());}
                    if (!field.GetObject().GetNamedArray(L"options", Array{}).Size()) typed = true;
                    else {Object entry; put(entry, L"questionId", key); entry.SetNamedValue(L"selectedOptionIds", selected); selections.Append(entry);}
                }
            }
            put(outcome, L"outcome", !typed && selections.Size() ? "answered" : "skipped");
            if (typed) put(outcome, L"reason", "The user replied in their own words:\n" + in_words);
            else if (selections.Size()) outcome.SetNamedValue(L"answers", selections);
            result.SetNamedValue(L"outcome", outcome); return result;
        }
        put(result, L"outcome", answers.Size() ? "accepted" : "cancelled"); Object selected, annotations;
        for (const auto& raw : form.GetNamedArray(L"fields")) {
            const auto field = raw.GetObject(); const auto key = text(field, L"key"), title = text(field, L"title"); const auto value = answers.GetNamedValue(winrt::to_hstring(key), Json::CreateNullValue());
            Array values; if (value.ValueType() == Type::Array) values = value.GetArray(); else if (value.ValueType() == Type::String) values.Append(value);
            Array picked; std::string notes;
            for (const auto& raw_value : values) {
                const auto candidate = winrt::to_string(raw_value.GetString()); bool option{};
                for (const auto& choice : field.GetNamedArray(L"options", Array{})) if (text(choice.GetObject(), L"value") == candidate) option = true;
                if (option) picked.Append(raw_value); else {if (!notes.empty()) notes += '\n'; notes += candidate;}
            }
            if (!picked.Size() && !notes.empty()) picked.Append(Json::CreateStringValue(L"Other")); if (picked.Size()) selected.SetNamedValue(winrt::to_hstring(title), picked);
            if (!notes.empty()) {Object annotation; put(annotation, L"notes", notes); annotations.SetNamedValue(winrt::to_hstring(title), annotation);}
        }
        result.SetNamedValue(L"answers", selected); if (annotations.Size()) result.SetNamedValue(L"annotations", annotations); return result;
    }
};
} // namespace coincide
