import Foundation

/// Pi has no permission system of its own; it leaves that to extensions. Coincide loads this one into
/// every session (`--extension`): in approval mode it asks before each tool call that is not read-only,
/// and in plan mode it keeps the agent read-only and gives it a tool to hand its plan back.
/// The policy comes from the environment, so it cannot change during a process's lifetime.
enum PiExtension {
    static let fileName = "coincide-pi-extension.ts"
    static let accessKey = "COINCIDE_PI_ACCESS"
    static let planKey = "COINCIDE_PI_PLAN"
    /// Marks the confirmations the extension raises for tool calls; the message carries the tool call id.
    static let approvalMarker = "coincide.toolApproval"
    static let planToolName = "propose_plan"
    /// Start of the reason the extension gives Pi when plan mode blocks a tool.
    static let planModeBlockPrefix = "Plan mode is on, so "

    /// Where the extension file is written: under `COINCIDE_DATA_DIR` when set (tests), otherwise in Caches.
    static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["COINCIDE_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("Pi", isDirectory: true)
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Coincide/Pi", isDirectory: true)
    }

    /// Writes the extension into `directory` unless an identical copy is already there.
    static func materialize(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(fileName)
        if (try? String(contentsOf: url, encoding: .utf8)) == source { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static let planInstructions = """
        Plan mode is on. Research the task and plan it, but do not change anything yet.
        - Do not edit or write files, and do not run commands that change files or system state. Read files, search, and run read-only commands only.
        - If the request is ambiguous, ask the user before planning.
        - When the plan is ready, call \(planToolName) once with the complete plan in Markdown: the goal, the changes file by file, the order of the steps, and how to verify the result. Then stop and wait for the user.
        """

    /// Plain JavaScript (valid TypeScript), so Pi's loader runs it in any version that supports extensions.
    static let source = #"""
        // Written by Coincide. It is replaced whenever Coincide starts Pi, so edits here are lost.
        import { Type } from "typebox";

        const PLAN_TOOL = \#(literal(planToolName));
        const PLAN_SECTION = "coincide_plan_mode";
        const PLAN_INSTRUCTIONS = \#(literal(planInstructions));
        const PLAN_BLOCK_PREFIX = \#(literal(planModeBlockPrefix));
        const APPROVAL_MARKER = \#(literal(approvalMarker));
        const READ_ONLY_TOOLS = new Set(["read", "grep", "find", "ls"]);

        // Pi's plan-mode example: commands that only read, and patterns that change things.
        const DESTRUCTIVE_COMMANDS = [
          /\brm\b/i, /\brmdir\b/i, /\bmv\b/i, /\bcp\b/i, /\bmkdir\b/i, /\btouch\b/i, /\bchmod\b/i, /\bchown\b/i,
          /\bchgrp\b/i, /\bln\b/i, /\btee\b/i, /\btruncate\b/i, /\bdd\b/i, /\bshred\b/i, /(^|[^<])>(?!>)/, />>/,
          /\bnpm\s+(install|uninstall|update|ci|link|publish)/i, /\byarn\s+(add|remove|install|publish)/i,
          /\bpnpm\s+(add|remove|install|publish)/i, /\bpip\s+(install|uninstall)/i,
          /\bapt(-get)?\s+(install|remove|purge|update|upgrade)/i, /\bbrew\s+(install|uninstall|upgrade)/i,
          /\bgit\s+(add|commit|push|pull|merge|rebase|reset|checkout|branch\s+-[dD]|stash|cherry-pick|revert|tag|init|clone)/i,
          /\bsudo\b/i, /\bsu\b/i, /\bkill\b/i, /\bpkill\b/i, /\bkillall\b/i, /\breboot\b/i, /\bshutdown\b/i,
          /\bsystemctl\s+(start|stop|restart|enable|disable)/i, /\bservice\s+\S+\s+(start|stop|restart)/i,
          /\b(vim?|nano|emacs|code|subl)\b/i,
        ];
        const READ_ONLY_COMMANDS = [
          /^\s*cat\b/, /^\s*head\b/, /^\s*tail\b/, /^\s*less\b/, /^\s*more\b/, /^\s*grep\b/, /^\s*find\b/, /^\s*ls\b/,
          /^\s*pwd\b/, /^\s*echo\b/, /^\s*printf\b/, /^\s*wc\b/, /^\s*sort\b/, /^\s*uniq\b/, /^\s*diff\b/, /^\s*file\b/,
          /^\s*stat\b/, /^\s*du\b/, /^\s*df\b/, /^\s*tree\b/, /^\s*which\b/, /^\s*whereis\b/, /^\s*type\b/, /^\s*env\b/,
          /^\s*printenv\b/, /^\s*uname\b/, /^\s*whoami\b/, /^\s*id\b/, /^\s*date\b/, /^\s*cal\b/, /^\s*uptime\b/,
          /^\s*ps\b/, /^\s*top\b/, /^\s*htop\b/, /^\s*free\b/,
          /^\s*git\s+(status|log|diff|show|branch|remote|config\s+--get)/i, /^\s*git\s+ls-/i,
          /^\s*npm\s+(list|ls|view|info|search|outdated|audit)/i, /^\s*yarn\s+(list|info|why|audit)/i,
          /^\s*node\s+--version/i, /^\s*python\s+--version/i, /^\s*curl\s/i, /^\s*wget\s+-O\s*-/i, /^\s*jq\b/,
          /^\s*sed\s+-n/i, /^\s*awk\b/, /^\s*rg\b/, /^\s*fd\b/, /^\s*bat\b/, /^\s*eza\b/,
        ];

        function isReadOnlyCommand(command) {
          return !DESTRUCTIVE_COMMANDS.some((pattern) => pattern.test(command)) &&
            READ_ONLY_COMMANDS.some((pattern) => pattern.test(command));
        }

        export default function coincide(pi) {
          const approvalRequired = process.env[\#(literal(accessKey))] === "approval";
          const planMode = process.env[\#(literal(planKey))] === "1";

          const registered = (name) =>
            typeof pi.getAllTools === "function" ? pi.getAllTools().find((tool) => tool.name === name) : undefined;
          // Only Pi's own tool search is known to be read-only; an extension could reuse the name.
          const isReadOnlyTool = (name) =>
            READ_ONLY_TOOLS.has(name) ||
            (name === "tool_search" && registered(name)?.sourceInfo?.path === "builtin:tool-search");

          if (planMode) {
            pi.registerTool({
              name: PLAN_TOOL,
              label: "Propose plan",
              description: "Show your finished plan to the user. Call it once, when the plan is complete, with the whole plan in Markdown.",
              parameters: Type.Object({ plan: Type.String({ description: "The complete plan in Markdown." }) }),
              async execute(_toolCallId, params) {
                return {
                  content: [{ type: "text", text: "The plan is in front of the user. Stop here and wait for their reply." }],
                  details: { plan: params.plan },
                  terminate: true,
                };
              },
            });

            pi.on("before_agent_start", (event) => {
              const options = event.systemPromptOptions;
              if (options && options.sections && options.forceSystemPrompt === undefined) {
                options.sections[PLAN_SECTION] = PLAN_INSTRUCTIONS;
                return undefined;
              }
              return { systemPrompt: event.systemPrompt + "\n\n" + PLAN_INSTRUCTIONS };
            });
          }

          pi.on("tool_call", async (event, ctx) => {
            const name = event.toolName;
            if (name === PLAN_TOOL) return undefined;
            const readOnly = isReadOnlyTool(name);
            if (planMode) {
              const allowed = readOnly ||
                registered(name)?.annotations?.readOnlyHint === true ||
                (name === "bash" && isReadOnlyCommand(String(event.input?.command ?? "")));
              if (!allowed) {
                return {
                  block: true,
                  reason: `${PLAN_BLOCK_PREFIX}${name} is not available. Use read-only tools, then call ${PLAN_TOOL} with your plan.`,
                };
              }
            }
            if (!approvalRequired || readOnly) return undefined;
            const approved = await ctx.ui.confirm(
              `Allow ${name}?`,
              JSON.stringify({ coincide: APPROVAL_MARKER, toolCallId: event.toolCallId, toolName: name }),
              { signal: ctx.signal },
            );
            if (!approved) return { block: true, reason: `The user declined this ${name} call.` };
            return undefined;
          });
        }
        """#

    /// A JavaScript string literal for `text`.
    private static func literal(_ text: String) -> String {
        JSONValue.string(text).compactJSON
    }
}

/// How Coincide starts `pi --mode rpc`.
enum PiLaunch {
    static func arguments(extensionPath: String, forkingFrom forkPath: String?) -> [String] {
        var arguments = ["--mode", "rpc"]
        if let forkPath { arguments += ["--fork", forkPath] }
        return arguments + ["--extension", extensionPath]
    }

    static func environment(
        _ base: [String: String], accessMode: AccessMode, interactionMode: InteractionMode
    ) -> [String: String] {
        var environment = base
        environment[PiExtension.accessKey] = accessMode == .approval ? "approval" : "full"
        environment[PiExtension.planKey] = interactionMode == .plan ? "1" : "0"
        return environment
    }

    /// What to do with a session id from an earlier run.
    enum Resume: Equatable {
        /// Nothing to resume: use the session Pi creates on startup.
        case fresh
        /// Load the session file with `switch_session`.
        case switchTo(String)
        /// Pi runs a resumed session in the folder recorded in its file. When the thread's folder has moved,
        /// fork the session into the new folder instead (`--fork`), which keeps the conversation.
        case fork(String)

        var forkPath: String? {
            if case .fork(let path) = self { return path }
            return nil
        }
    }

    static func resume(_ sessionPath: String?, workingDirectory: URL) -> Resume {
        // Pi writes a session file with the first message, so a missing file means there is nothing to resume.
        guard let sessionPath, FileManager.default.fileExists(atPath: sessionPath) else { return .fresh }
        guard let recorded = PiSessionFile.workingDirectory(ofSessionAt: sessionPath),
            !PiSessionFile.samePath(recorded, workingDirectory.path)
        else { return .switchTo(sessionPath) }
        return .fork(sessionPath)
    }
}

/// Reads Pi's session files (`~/.pi/agent/sessions/…/*.jsonl`), whose first line is a header.
enum PiSessionFile {
    /// The working folder recorded in the session header, if the file has one.
    static func workingDirectory(ofSessionAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < 1 << 20, !data.contains(0x0A) {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        let line = data.prefix(while: { $0 != 0x0A })
        guard let header = JSONValue.parse(Data(line)), header["type"]?.string == "session" else { return nil }
        return header["cwd"]?.string
    }

    /// Compares folders after resolving symlinks, since Pi records the physical path (`/private/tmp`, not `/tmp`).
    static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
