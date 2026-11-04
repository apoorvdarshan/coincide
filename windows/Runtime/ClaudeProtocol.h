#pragma once
#include "AgentSession.h"
#include <fstream>

namespace coincide {
struct ClaudeProtocol {
    using Object = rpc_json::JsonObject;
    using Array = rpc_json::JsonArray;
    using Json = rpc_json::JsonValue;
    static std::string text(const Object& value, const wchar_t* key) {return CodexProtocol::string(value, key);}
    static void put(Object value, const wchar_t* key, const std::string& text) {CodexProtocol::text(value, key, text);}
    static Object control(const std::string& id, const Object& request) {
        Object value; put(value, L"type", "control_request"); put(value, L"request_id", id); value.SetNamedValue(L"request", request); return value;
    }
    static Object response(const std::string& id, const Object& result, bool error = false) {
        Object frame, body; put(frame, L"type", "control_response"); put(body, L"subtype", error ? "error" : "success"); put(body, L"request_id", id);
        if (error) put(body, L"error", text(result, L"message")); else body.SetNamedValue(L"response", result);
        frame.SetNamedValue(L"response", body); return frame;
    }
    static std::string permission_mode(const CodexTurn& turn) {return turn.plan ? "plan" : turn.access == AgentAccess::full_access ? "bypassPermissions" : "default";}
    static std::vector<std::wstring> arguments(const CodexTurn& turn, const std::string& session, bool resume, bool probe = false) {
        std::vector<std::wstring> result{L"--output-format", L"stream-json", L"--verbose", L"--input-format", L"stream-json", L"--include-partial-messages",
            L"--permission-prompt-tool", L"stdio", L"--setting-sources=user,project,local"};
        if (probe) {
            result.insert(result.end(), {L"--no-session-persistence", L"--strict-mcp-config", L"--settings", L"{\"disableAllHooks\":true}"});
            return result;
        }
        result.insert(result.end(), {L"--permission-mode", winrt::to_hstring(permission_mode(turn)).c_str()});
        if (turn.access == AgentAccess::full_access) result.push_back(L"--allow-dangerously-skip-permissions");
        if (!turn.model.empty()) {result.push_back(L"--model"); result.emplace_back(winrt::to_hstring(turn.model).c_str());}
        if (!turn.effort.empty()) {result.push_back(L"--effort"); result.emplace_back(winrt::to_hstring(turn.effort).c_str());}
        if (!turn.service_tier.empty() && turn.service_tier != "default" && turn.service_tier != "fast") throw std::invalid_argument("This Claude Code service tier is not supported");
        if (turn.service_tier == "fast") result.insert(result.end(), {L"--settings", L"{\"fastMode\":true}"});
        result.emplace_back(winrt::to_hstring(std::string(resume ? "--resume=" : "--session-id=") + session).c_str());
        return result;
    }
    static Object catalog(const Object& initialized) {
        Array models;
        for (const auto& raw : initialized.GetNamedArray(L"models", Array{})) {
            if (raw.ValueType() != rpc_json::JsonValueType::Object) continue;
            const auto entry = raw.GetObject(); const auto id = text(entry, L"value"); if (id.empty()) continue;
            Object model; put(model, L"model", id); put(model, L"displayName", text(entry, L"displayName").empty() ? id : text(entry, L"displayName"));
            model.SetNamedValue(L"isDefault", Json::CreateBooleanValue(id == "default"));
            Array efforts;
            if (entry.GetNamedBoolean(L"supportsEffort", true)) for (const auto& raw_effort : entry.GetNamedArray(L"supportedEffortLevels", Array{})) {
                if (raw_effort.ValueType() != rpc_json::JsonValueType::String) continue;
                Object effort; effort.SetNamedValue(L"reasoningEffort", raw_effort); efforts.Append(effort);
            }
            model.SetNamedValue(L"supportedReasoningEfforts", efforts);
            if (entry.GetNamedBoolean(L"supportsFastMode", false)) {
                Array tiers; Object fast; put(fast, L"id", "fast"); put(fast, L"name", "Fast"); tiers.Append(fast); model.SetNamedValue(L"serviceTiers", tiers);
            }
            models.Append(model);
        }
        Object result; result.SetNamedValue(L"data", models); result.SetNamedValue(L"nextCursor", Json::CreateNullValue()); return result;
    }
    static Object allow(const Object& request, const Object& input) {
        Object result; put(result, L"behavior", "allow"); put(result, L"decisionClassification", "user_temporary"); result.SetNamedValue(L"updatedInput", input);
        const auto tool = request.GetNamedValue(L"tool_use_id", Json::CreateNullValue()); if (tool.ValueType() != rpc_json::JsonValueType::Null) result.SetNamedValue(L"toolUseID", tool);
        return result;
    }
    static Object deny(const Object& request, bool interrupt = false) {
        Object result; put(result, L"behavior", "deny"); put(result, L"decisionClassification", "user_reject"); put(result, L"message", "The user declined this tool use in Coincide.");
        result.SetNamedValue(L"interrupt", Json::CreateBooleanValue(interrupt));
        const auto tool = request.GetNamedValue(L"tool_use_id", Json::CreateNullValue()); if (tool.ValueType() != rpc_json::JsonValueType::Null) result.SetNamedValue(L"toolUseID", tool);
        return result;
    }
    static std::string base64(const std::string& data) {
        static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        std::string output; output.reserve((data.size() + 2) / 3 * 4);
        for (std::size_t index = 0; index < data.size(); index += 3) {
            const auto first = static_cast<unsigned char>(data[index]);
            const auto second = index + 1 < data.size() ? static_cast<unsigned char>(data[index + 1]) : 0;
            const auto third = index + 2 < data.size() ? static_cast<unsigned char>(data[index + 2]) : 0;
            output += alphabet[first >> 2]; output += alphabet[((first & 3) << 4) | (second >> 4)];
            output += index + 1 < data.size() ? alphabet[((second & 15) << 2) | (third >> 6)] : '=';
            output += index + 2 < data.size() ? alphabet[third & 63] : '=';
        }
        return output;
    }
    static Object user_message(const CodexTurn& turn, const std::string& id) {
        Object frame, message, origin; put(frame, L"type", "user"); put(frame, L"uuid", id); put(origin, L"kind", "human"); frame.SetNamedValue(L"origin", origin);
        frame.SetNamedValue(L"parent_tool_use_id", Json::CreateNullValue()); put(message, L"role", "user");
        if (turn.image_paths.empty()) put(message, L"content", turn.text);
        else {
            Array content; std::size_t total{};
            for (const auto& name : turn.image_paths) {
                const std::filesystem::path path(winrt::to_hstring(name).c_str());
                const auto size = std::filesystem::file_size(path);
                if (size > 8 * 1024 * 1024 || size > 16 * 1024 * 1024 - total) throw std::invalid_argument("Claude image attachments exceed the local size limit");
                total += static_cast<std::size_t>(size); std::ifstream file(path, std::ios::binary);
                if (!file) throw std::runtime_error("Could not read a Claude image attachment");
                std::string bytes(static_cast<std::size_t>(size), '\0');
                file.read(bytes.data(), static_cast<std::streamsize>(bytes.size()));
                if (file.gcount() != static_cast<std::streamsize>(bytes.size()) || file.peek() != std::char_traits<char>::eof()) throw std::runtime_error("A Claude image attachment changed while being read");
                std::string mime;
                if (bytes.starts_with("\x89PNG\r\n\x1a\n")) mime = "image/png";
                else if (bytes.size() >= 3 && static_cast<unsigned char>(bytes[0]) == 0xff && static_cast<unsigned char>(bytes[1]) == 0xd8 && static_cast<unsigned char>(bytes[2]) == 0xff) mime = "image/jpeg";
                else if (bytes.starts_with("GIF87a") || bytes.starts_with("GIF89a")) mime = "image/gif";
                else if (bytes.size() >= 12 && bytes.starts_with("RIFF") && bytes.substr(8, 4) == "WEBP") mime = "image/webp";
                else throw std::invalid_argument("Claude image attachments must be PNG, JPEG, GIF or WebP");
                Object block, source; put(block, L"type", "image"); put(source, L"type", "base64"); put(source, L"media_type", mime); put(source, L"data", base64(bytes));
                block.SetNamedValue(L"source", source); content.Append(block);
            }
            if (!turn.text.empty()) {Object block; put(block, L"type", "text"); put(block, L"text", turn.text); content.Append(block);}
            message.SetNamedValue(L"content", content);
        }
        frame.SetNamedValue(L"message", message); return frame;
    }
};
} // namespace coincide
