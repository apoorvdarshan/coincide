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
    /// The command that adds a handoff recap to the conversation without starting a run. It also shows that the
    /// extension loaded: `get_commands` lists it.
    static let handoffCommand = "coincide-handoff"

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

    /// The name to invoke the handoff command by, from `get_commands`; nil when Pi did not load the extension.
    static func handoffCommandName(in data: JSONValue?) -> String? {
        let commands = data?["commands"]?.array ?? []
        let ours = commands.first { command in
            guard let name = command["name"]?.string, name.hasPrefix(handoffCommand) else { return false }
            // Another extension could register the same name; ours is the one loaded from our file.
            let path = command["sourceInfo"]?["path"]?.string ?? command["path"]?.string
            return path.map { ($0 as NSString).lastPathComponent == fileName } ?? true
        }
        return ours?["name"]?.string
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
        const HANDOFF_COMMAND = \#(literal(handoffCommand));
        const READ_ONLY_TOOLS = new Set(["read", "grep", "find", "ls"]);

        // Patterns that change files or system state, after Pi's plan-mode example. They are checked against the
        // whole command, quoted text included, so they err on the side of blocking.
        const DESTRUCTIVE_COMMANDS = [
          /\brm\b/i, /\brmdir\b/i, /\bmv\b/i, /\bcp\b/i, /\bmkdir\b/i, /\btouch\b/i, /\bchmod\b/i, /\bchown\b/i,
          /\bchgrp\b/i, /\bln\b/i, /\btee\b/i, /\btruncate\b/i, /\bdd\b/i, /\bshred\b/i, /(^|[^<])>(?!>)/, />>/,
          /\bnpm\s+(install|uninstall|update|ci|link|publish)/i, /\byarn\s+(add|remove|install|publish)/i,
          /\bpnpm\s+(add|remove|install|publish)/i, /\bpip3?\s+(install|uninstall)/i,
          /\bapt(-get)?\s+(install|remove|purge|update|upgrade)/i, /\bbrew\s+(install|uninstall|upgrade)/i,
          /\bgit\s+(add|commit|push|pull|merge|rebase|reset|checkout|switch|restore|clean|branch\s+-[dDmM]|stash|cherry-pick|revert|tag|init|clone|apply|am)\b/i,
          /\bsudo\b/i, /\bsu\b/i, /\bkill\b/i, /\bpkill\b/i, /\bkillall\b/i, /\breboot\b/i, /\bshutdown\b/i,
          /\bsystemctl\s+(start|stop|restart|enable|disable)/i, /\bservice\s+\S+\s+(start|stop|restart)/i,
          /\b(vim?|nano|emacs|code|subl)\b/i,
          // find can delete, write or run anything; sed -i edits in place; curl can write files or send data.
          /\s-(delete|exec|execdir|ok|okdir|fprint\w*|fls)\b/, /\bsystem\s*\(/, /\bsed\b[^|;&]*\s-[a-zA-Z]*i/,
          /\bcurl\b[^|;&]*\s(-[a-zA-Z]*[oOTdFXcDK]|--(output|remote-name|upload-file|data[\w-]*|form|request|json|dump-header|cookie-jar|config|trace[\w-]*|libcurl|stderr|etag-save|hsts|alt-svc)\b)/,
          // git grep -O runs any command as a pager; log, diff and show --output write a file. Abbreviations count.
          /\bgit\b[^|;&]*\s(-[a-zA-Z]*O|--op|--out)/,
          /\bgit\s+remote\b[^|;&]*\s(add|remove|rm|rename|set-\w+|prune|update)\b/i,
          /\bgit\s+reflog\b[^|;&]*\s(expire|delete)\b/i,
          /\bnpm\s+audit\s+fix\b/i,
        ];
        // Commands that only read. Every command of a pipeline, list or substitution has to be one of them, so
        // commands that can also run programs or write files are listed only in their reading forms (awk, fd,
        // xxd and pagers not at all).
        const READ_ONLY_COMMANDS = [
          /^cat\b/, /^head\b/, /^tail\b/, /^e?f?grep\b/, /^find\b/, /^ls\b/, /^pwd\b/, /^echo\b/,
          /^printf\b/, /^wc\b/, /^diff\b/, /^file\b/, /^stat\b/, /^du\b/, /^df\b/,
          /^which\b/, /^whereis\b/, /^type\b/, /^env$/, /^printenv\b/, /^uname\b/, /^whoami\b/, /^id\b/, /^date\b/,
          /^cal\b/, /^uptime\b/, /^ps\b/, /^top\b/, /^free\b/, /^nl\b/, /^cut\b/, /^tr\b/, /^column\b/, /^comm\b/,
          /^cmp\b/, /^basename\b/, /^dirname\b/, /^realpath\b/, /^readlink\b/, /^(md5|shasum|sha\d+sum)\b/,
          /^od\b/, /^hexdump\b/, /^strings\b/, /^cd\b/, /^pushd\b/, /^popd\b/, /^true\b/, /^false\b/,
          /^git\s+(status|log|diff|show|branch(\s+-[avrl]+|\s+--(list|all|remotes|verbose|show-current))*\s*$|remote(\s+-v|\s+show\b|\s+get-url\b|\s*$)|config\s+--get|ls-|grep|blame|rev-parse|describe|shortlog|cat-file|reflog)/i,
          /^npm\s+(list|ls|view|info|search|outdated|audit)/i, /^yarn\s+(list|info|why|audit)/i,
          /^(node|python3?|swift|ruby|go|cargo|rustc)\s+-{0,2}version\b/i, /^curl\s/i, /^jq\b/, /^eza\b/,
          // sort -o and --compress-program, tree -o, a second uniq operand: these write or run something.
          /^sort\b(?!.*\s(-[a-zA-Z]*o|--o|--co))/, /^uniq(\s+-\S+)*(\s+[^\s-]\S*)?$/, /^tree\b(?!.*\s(-[a-zA-Z]*o|--o))/,
          // rg --pre and --hostname-bin run a command; bat runs its pager.
          /^rg\b(?!.*\s--(pre|hostname-bin)\b)/, /^bat\b(?!.*\s(--pag|--gen|cache\b))/,
          // sed only printing lines by number: its w, W and e commands write files and run commands.
          /^sed\s+-n\s+(['"]?)[\d\s,$;p]+\1(\s+[^\s-]\S*)*$/, /^wget\s+(-q\s+)?-O\s*-\s+[^\s-]\S*$/,
        ];

        // Splits a command at pipes, lists and command substitutions, outside quotes.
        function commandSegments(command) {
          const segments = [];
          let current = "";
          let quote = null;
          for (let index = 0; index < command.length; index++) {
            const char = command[index];
            if (quote === "'") {
              if (char === "'") quote = null;
              current += char;
              continue;
            }
            if (char === "\\" && index + 1 < command.length) {
              current += char + command[++index];
              continue;
            }
            const substitution = char === "`" || (char === "$" && command[index + 1] === "(");
            if (quote === '"' && !substitution) {
              if (char === '"') quote = null;
              current += char;
              continue;
            }
            if (quote === null && (char === "'" || char === '"')) {
              quote = char;
              current += char;
              continue;
            }
            if (substitution || (quote === null && "|&;\n()".includes(char))) {
              segments.push(current);
              current = "";
              if (char === "$") index++;
              continue;
            }
            current += char;
          }
          segments.push(current);
          return segments.map((segment) => segment.trim()).filter((segment) => segment.length > 0);
        }

        function isReadOnlyCommand(command) {
          // Discarding output or merging streams writes nothing.
          const normalized = command.replace(/(\d*|&)>>?\s*\/dev\/null\b/g, " ").replace(/\d*>&\d+/g, " ");
          if (DESTRUCTIVE_COMMANDS.some((pattern) => pattern.test(normalized))) return false;
          const segments = commandSegments(normalized);
          return segments.length > 0 &&
            segments.every((segment) => READ_ONLY_COMMANDS.some((pattern) => pattern.test(segment)));
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

          // A slash command only works at the start of a prompt, so when the user's message is one, Coincide sends
          // the recap of what other agents did in this thread through this command first.
          pi.registerCommand(HANDOFF_COMMAND, {
            description: "Adds Coincide's recap of the turns other agents handled to this conversation.",
            handler: async (args) => {
              const text = typeof args === "string" ? args.trim() : "";
              if (text.length === 0) return;
              pi.sendMessage(
                { customType: HANDOFF_COMMAND, content: [{ type: "text", text }], display: false },
                { triggerTurn: false },
              );
            },
          });

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

    /// The path with symlinks resolved, or the standardized path when it does not exist.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
