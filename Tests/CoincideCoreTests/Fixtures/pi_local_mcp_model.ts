/** Intact-Pi acceptance: local model stream only, never remote auth/model I/O. */
import * as fs from "node:fs";
import * as path from "node:path";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai/compat";

export default function (pi) {
  const root = process.env.COINCIDE_PI_LOCAL_MCP_ROOT;
  if (!root || !path.isAbsolute(root)) throw new Error("The private MCP model requires its owned root.");
  const configBytes = fs.readFileSync(path.join(root, "model-config.json"));
  if (configBytes.length > 4096) throw new Error("The private model configuration is oversized.");
  const config = JSON.parse(configBytes.toString("utf8"));
  if (!/^[0-9A-Fa-f-]{36}$/.test(config.threadID) || typeof config.title !== "string") throw new Error("The private model configuration is invalid.");
  const read = "mcp__coincide__t3_thread_read", write = "mcp__coincide__t3_thread_update";
  const stamp = (kind, values = {}) => fs.appendFileSync(path.join(root, "model.jsonl"),
    JSON.stringify({ kind, pid: process.pid, ...values }) + "\n", { mode: 0o600 });
  let ordinal = 0;
  pi.on("session_start", () => stamp("session-start", {
    credentialEnvironmentAbsent: ["T3_MCP_BEARER_TOKEN", "T3_ACP_MCP_AUTHORIZATION", "COINCIDE_MCP_TOKEN", "COINCIDE_MCP_AUTHORIZATION"].every((key) => process.env[key] === undefined),
  }));
  pi.on("session_shutdown", () => stamp("session-shutdown"));
  pi.on("tool_call", (event) => stamp("tool-call", { name: event.toolName, callID: event.toolCallId }));
  pi.on("tool_result", (event) => stamp("tool-result", { name: event.toolName, callID: event.toolCallId, isError: event.isError === true }));
  pi.registerProvider("coincide-mcp-local", {
    name: "Coincide private MCP acceptance model", api: "coincide-mcp-local-api", baseUrl: "https://fixture.invalid",
    // Native configured-auth preflight needs a value. This literal is a
    // noncredential sentinel consumed solely by this local stream provider.
    apiKey: "synthetic-local-noncredential", authHeader: false,
    models: [{ id: "local-tools", name: "Private local tools", reasoning: false, input: ["text"],
      contextWindow: 131072, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    streamSimple(model, context, options) {
      const stream = createAssistantMessageEventStream();
      const output = { role: "assistant", api: model.api, provider: model.provider, model: model.id,
        content: [], timestamp: Date.now(), stopReason: "stop",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
      void (async () => {
        try {
          const current = ++ordinal, users = context.messages.filter((message) => message.role === "user").length;
          const advertised = (context.tools ?? []).map((tool) => tool.name).sort();
          if (JSON.stringify(advertised) !== JSON.stringify([read, write].sort())) throw new Error("The private model did not receive the exact native app tools.");
          const last = context.messages.at(-1);
          let tool, args, callID;
          if (last?.role === "user") { tool = read; args = { threadId: config.threadID, limit: 2 }; callID = "mcp-read-" + users; }
          else if (last?.role === "toolResult") {
            if (last.isError) throw new Error("The native app tool returned an error.");
            const text = (last.content ?? []).filter((part) => part.type === "text").map((part) => part.text).join("");
            const value = JSON.parse(text);
            if (last.toolName === read) {
              if (value.thread?.threadId !== config.threadID) throw new Error("The read result named another thread.");
              stamp("read-result", { users, exactThread: true, renamed: value.thread.title === config.title });
              if (users === 1) { tool = write; args = { action: "rename", title: config.title, clientRequestId: "native-mcp-rename" }; callID = "mcp-write-1"; }
            } else if (last.toolName === write) { stamp("write-result", { users, received: true }); }
            else throw new Error("The private model received an unowned tool result.");
          } else throw new Error("The private model received an unexpected native message.");
          stamp("model", { ordinal: current, users, tool: tool ?? "final" });
          stream.push({ type: "start", partial: output });
          if (options?.signal?.aborted) throw new Error("The private model was interrupted.");
          if (tool) {
            output.stopReason = "toolUse";
            output.content = [{ type: "toolCall", id: callID, name: tool, arguments: args }];
            stream.push({ type: "toolcall_start", contentIndex: 0, partial: output });
            stream.push({ type: "toolcall_delta", contentIndex: 0, delta: JSON.stringify(args), partial: output });
            stream.push({ type: "toolcall_end", contentIndex: 0, toolCall: output.content[0], partial: output });
            stream.push({ type: "done", reason: "toolUse", message: output });
          } else {
            const text = users === 1 ? "MCP_NATIVE_FIRST_DONE" : "MCP_NATIVE_SECOND_DONE";
            output.content = [{ type: "text", text }];
            stream.push({ type: "text_start", contentIndex: 0, partial: output });
            stream.push({ type: "text_delta", contentIndex: 0, delta: text, partial: output });
            stream.push({ type: "text_end", contentIndex: 0, content: text, partial: output });
            stream.push({ type: "done", reason: "stop", message: output });
          }
          stream.end();
        } catch {
          output.stopReason = options?.signal?.aborted ? "aborted" : "error";
          output.errorMessage = "The private MCP model could not verify its native tool flow.";
          stamp("model-failed", { ordinal });
          stream.push({ type: "error", reason: output.stopReason, error: output }); stream.end();
        }
      })();
      return stream;
    },
  });
}
