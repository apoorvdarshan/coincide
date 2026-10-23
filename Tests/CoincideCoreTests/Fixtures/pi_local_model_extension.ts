/** Offline acceptance peer loaded by the intact, opt-in Pi 0.80.5 package.
 * This is a local stream implementation, not a remote model or auth provider.
 * Its only writes are bounded, synthetic milestones under the private test root.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { createHash } from "node:crypto";
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai/compat";

export default function (pi) {
  const root = process.env.COINCIDE_PI_LOCAL_ROOT;
  if (!root || !path.isAbsolute(root)) throw new Error("The local Pi fixture requires its private root.");
  const milestones = path.join(root, "local-model.jsonl");
  const stamp = (kind, fields = {}) => {
    fs.appendFileSync(milestones, JSON.stringify({ kind, pid: process.pid, ...fields }) + "\n", { mode: 0o600 });
  };
  let calls = 0;
  pi.on("session_start", () => stamp("session-start"));
  pi.on("session_shutdown", () => stamp("session-shutdown"));
  pi.on("input", (event) => {
    stamp("input", {
      source: event.source,
      textDigest: createHash("sha256").update(event.text).digest("hex"),
      alphaBodies: event.text.split("COINCIDE_ALPHA_SYNTHETIC_BODY").length - 1,
      betaBodies: event.text.split("COINCIDE_BETA_SYNTHETIC_BODY").length - 1,
      imageCount: event.images?.length ?? 0,
    });
  });

  pi.registerProvider("coincide-local-fixture", {
    name: "Coincide offline acceptance model",
    api: "coincide-local-fixture-api",
    baseUrl: "https://fixture.invalid",
    // Required by Pi's native configured-auth preflight. This is a literal
    // synthetic sentinel, never a credential or an OAuth/login implementation.
    apiKey: "synthetic-local-noncredential",
    authHeader: false,
    models: [{
      id: "local-stream", name: "Local synthetic stream", reasoning: false,
      input: ["text", "image"], contextWindow: 131072, maxTokens: 1024,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    }],
    streamSimple(model, context, options) {
      const stream = createAssistantMessageEventStream();
      const ordinal = ++calls;
      const output = {
        role: "assistant", api: model.api, provider: model.provider, model: model.id,
        content: [{ type: "text", text: "" }], timestamp: Date.now(), stopReason: "stop",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      };
      void (async () => {
        try {
          stamp("model-start", { ordinal, userCount: context.messages.filter((message) => message.role === "user").length });
          stream.push({ type: "start", partial: output });
          stream.push({ type: "text_start", contentIndex: 0, partial: output });
          const first = "LOCAL_SYNTHETIC_RESPONSE_";
          output.content[0].text = first;
          stream.push({ type: "text_delta", contentIndex: 0, delta: first, partial: output });
          // The test releases this gate only after actual Engine steering has
          // been admitted. There is no time-based model completion shortcut.
          if (ordinal === 1 && fs.existsSync(path.join(root, "hold-first-model"))) {
            const deadline = Date.now() + 15000;
            while (fs.existsSync(path.join(root, "hold-first-model"))) {
              if (options?.signal?.aborted) throw new Error("The local stream was interrupted.");
              if (Date.now() >= deadline) throw new Error("The local stream gate was not released.");
              await new Promise((resolve) => setTimeout(resolve, 5));
            }
          }
          if (options?.signal?.aborted) throw new Error("The local stream was interrupted.");
          const last = String(ordinal);
          output.content[0].text += last;
          stream.push({ type: "text_delta", contentIndex: 0, delta: last, partial: output });
          stream.push({ type: "text_end", contentIndex: 0, content: output.content[0].text, partial: output });
          stamp("model-end", { ordinal });
          stream.push({ type: "done", reason: "stop", message: output });
          stream.end();
        } catch {
          output.stopReason = options?.signal?.aborted ? "aborted" : "error";
          output.errorMessage = "The private local model stream did not complete.";
          stamp("model-stopped", { ordinal, aborted: options?.signal?.aborted === true });
          stream.push({ type: "error", reason: output.stopReason, error: output });
          stream.end();
        }
      })();
      return stream;
    },
  });
}
