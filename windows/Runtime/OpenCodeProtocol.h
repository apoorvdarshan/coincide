#pragma once
#include "AgentSession.h"
#include <cmath>
#include <unordered_map>

namespace coincide {
struct OpenCodeProtocol {
    using Object = CodexProtocol::Object;
    using Array = CodexProtocol::Array;
    using Json = CodexProtocol::Json;
    using Type = rpc_json::JsonValueType;
    static std::string text(const Object& object, const wchar_t* key) {return CodexProtocol::string(object, key);}
    static void put(Object object, const wchar_t* key, const std::string& value) {CodexProtocol::text(object, key, value);}
    static std::string encode(std::string_view value) {
        static constexpr char digits[] = "0123456789ABCDEF"; std::string result;
        for (const unsigned char ch : value) {
            if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' || ch == '~') result += static_cast<char>(ch);
            else {result += '%'; result += digits[ch >> 4]; result += digits[ch & 15];}
        }
        return result;
    }
    static Object model(const CodexTurn& turn) {
        const auto slash = turn.model.find('/');
        if (slash == std::string::npos || slash == 0 || slash + 1 == turn.model.size()) throw std::invalid_argument("Choose an OpenCode provider/model from its model catalog");
        Object value; put(value, L"providerID", turn.model.substr(0, slash)); put(value, L"id", turn.model.substr(slash + 1));
        if (!turn.effort.empty()) put(value, L"variant", turn.effort); return value;
    }
    static Array permissions(const CodexTurn& turn) {
        Array rules;
        const auto add = [&](const char* action, const char* effect) {Object rule; put(rule, L"action", action); put(rule, L"resource", "*"); put(rule, L"effect", effect); rules.Append(rule);};
        if (turn.access == AgentAccess::full_access) add("*", "allow");
        else {add("shell", "ask"); add("edit", "ask"); add("external_directory", "ask");}
        if (turn.plan) add("edit", "deny"); return rules;
    }
    static Object create(const CodexTurn& turn, const std::string& directory) {
        Object result, location; put(location, L"directory", directory); result.SetNamedValue(L"location", location);
        put(result, L"agent", turn.plan ? "plan" : "build"); result.SetNamedValue(L"permissions", permissions(turn));
        if (!turn.model.empty()) result.SetNamedValue(L"model", model(turn)); return result;
    }
    static Object catalog(const Object& raw) {
        Array entries; std::unordered_set<std::string> seen;
        for (const auto& value : raw.GetNamedArray(L"data", Array{})) {
            if (value.ValueType() != Type::Object) continue;
            const auto source = value.GetObject(); const auto provider = text(source, L"providerID"), id = text(source, L"id");
            if (provider.empty() || id.empty() || !source.GetNamedBoolean(L"enabled", false) || !seen.insert(provider + "/" + id).second) continue;
            Object model; put(model, L"model", provider + "/" + id); put(model, L"displayName", text(source, L"name").empty() ? provider + "/" + id : text(source, L"name"));
            Array efforts;
            for (const auto& variant : source.GetNamedArray(L"variants", Array{})) {
                if (variant.ValueType() != Type::Object || text(variant.GetObject(), L"id").empty()) continue;
                Object effort; put(effort, L"reasoningEffort", text(variant.GetObject(), L"id")); efforts.Append(effort);
            }
            model.SetNamedValue(L"supportedReasoningEfforts", efforts);
            model.SetNamedValue(L"inputModalities", source.GetNamedObject(L"capabilities", Object{}).GetNamedArray(L"input", Array{})); entries.Append(model);
            if (entries.Size() >= 1000) break;
        }
        Object result; result.SetNamedValue(L"data", entries); result.SetNamedValue(L"nextCursor", Json::CreateNullValue()); return result;
    }
    // A form's displayed labels and protocol values are kept separate; duplicate/conditional fields
    // cannot be represented faithfully by the current UI, so decline rather than fabricate an answer.
    static std::optional<Object> questions(const Object& form) {
        Array questions; std::unordered_set<std::string> keys;
        const auto fields = form.GetNamedArray(L"fields", Array{});
        if (text(form, L"id").empty() || !fields.Size() || fields.Size() > 64) return std::nullopt;
        for (const auto& raw : fields) {
            if (raw.ValueType() != Type::Object) return std::nullopt;
            const auto field = raw.GetObject(); const auto key = text(field, L"key"), type = text(field, L"type");
            const auto condition = field.GetNamedValue(L"when", Json::CreateNullValue());
            if (key.empty() || !keys.insert(key).second || field.GetNamedBoolean(L"hidden", false)
                    || (condition.ValueType() != Type::Null && (condition.ValueType() != Type::Array || condition.GetArray().Size()))
                    || (type != "string" && type != "multiselect" && type != "boolean" && type != "number" && type != "integer")) return std::nullopt;
            Object question; put(question, L"id", key);
            const auto title = text(field, L"title"), description = text(field, L"description");
            put(question, L"question", description.empty() ? (title.empty() ? key : title) : description);
            if (!title.empty() && !description.empty()) put(question, L"header", title);
            Array options; std::unordered_set<std::string> labels;
            if (type == "boolean") for (const char* label : {"Yes", "No"}) {Object option; put(option, L"label", label); options.Append(option);}
            else for (const auto& option : field.GetNamedArray(L"options", Array{})) {
                if (option.ValueType() != Type::Object || option.GetObject().GetNamedValue(L"value", Json::CreateNullValue()).ValueType() != Type::String) return std::nullopt;
                const auto value = option.GetObject(); const auto label = text(value, L"label").empty() ? text(value, L"value") : text(value, L"label");
                if (label.empty() || !labels.insert(label).second) return std::nullopt;
                Object normalized; put(normalized, L"label", label); put(normalized, L"description", text(value, L"description") == label ? "" : text(value, L"description")); options.Append(normalized);
            }
            question.SetNamedValue(L"options", options); question.SetNamedValue(L"allowsMultipleSelection", Json::CreateBooleanValue(type == "multiselect"));
            question.SetNamedValue(L"allowsFreeText", Json::CreateBooleanValue(type != "boolean" && (field.GetNamedBoolean(L"custom", false) || !options.Size()))); questions.Append(question);
        }
        Object result; result.SetNamedValue(L"questions", questions); return result;
    }
    static Object form_answer(const Object& form, const Object& response) {
        Object result; const auto answers = response.GetNamedObject(L"answers", Object{});
        for (const auto& raw : form.GetNamedArray(L"fields", Array{})) {
            const auto field = raw.GetObject(); const auto key = text(field, L"key"), type = text(field, L"type");
            const auto values = answers.GetNamedObject(winrt::to_hstring(key), Object{}).GetNamedArray(L"answers", Array{});
            std::vector<std::string> selected;
            for (const auto& raw_value : values) {
                if (raw_value.ValueType() != Type::String) continue;
                auto value = winrt::to_string(raw_value.GetString()); if (value.empty()) continue;
                bool mapped{};
                for (const auto& option : field.GetNamedArray(L"options", Array{})) {
                    const auto entry = option.GetObject(); const auto label = text(entry, L"label").empty() ? text(entry, L"value") : text(entry, L"label");
                    if (value == label) {value = text(entry, L"value"); mapped = true; break;}
                }
                if (!mapped && (type == "string" || type == "multiselect") && field.GetNamedArray(L"options", Array{}).Size() && !field.GetNamedBoolean(L"custom", false))
                    throw std::invalid_argument("Choose an advertised OpenCode question option");
                selected.push_back(std::move(value));
            }
            if (selected.empty()) continue;
            const auto first = selected.front();
            if (type == "boolean") {
                if (first == "Yes" || first == "true") result.SetNamedValue(winrt::to_hstring(key), Json::CreateBooleanValue(true));
                else if (first == "No" || first == "false") result.SetNamedValue(winrt::to_hstring(key), Json::CreateBooleanValue(false));
                else throw std::invalid_argument("Invalid OpenCode boolean answer");
            } else if (type == "number" || type == "integer") {
                std::size_t consumed{}; double number{};
                try {number = std::stod(first, &consumed);} catch (const std::exception&) {throw std::invalid_argument("Invalid OpenCode numeric answer");}
                if (consumed != first.size() || !std::isfinite(number) || (type == "integer" && std::trunc(number) != number)) throw std::invalid_argument("Invalid OpenCode numeric answer");
                result.SetNamedValue(winrt::to_hstring(key), Json::CreateNumberValue(number));
            } else if (type == "multiselect") {Array array; for (const auto& value : selected) array.Append(Json::CreateStringValue(winrt::to_hstring(value))); result.SetNamedValue(winrt::to_hstring(key), array);}
            else {std::string joined; for (const auto& value : selected) {if (!joined.empty()) joined += ", "; joined += value;} put(result, winrt::to_hstring(key).c_str(), joined);}
        }
        // A partially answered required form must remain pending rather than sending incomplete data.
        if (result.Size() && result.Size() != form.GetNamedArray(L"fields").Size()) throw std::invalid_argument("Answer every OpenCode question before submitting");
        return result;
    }
};
} // namespace coincide
