import Darwin
import Foundation

public enum PiMCPBridgeError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration, ownershipLost
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The owned Pi MCP connection could not be configured safely."
        case .ownershipLost: "The owned Pi MCP configuration changed. Its files were preserved."
        }
    }
}

/// Private handoff to Pi's awaited extension factory. Neither this value nor the
/// sidecar belongs in durable configuration, argv, environment or diagnostics.
public enum PiMCPBridge {
    public final class Sidecar: @unchecked Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        public let configurationPath: URL
        public let scopeID: UUID
        private let descriptor: Int32
        private let directoryPath: String
        private let name: String
        private let device: dev_t
        private let inode: ino_t
        private let lock = NSLock()
        private var removed = false
        fileprivate init(path: URL, scopeID: UUID, descriptor: Int32, directoryPath: String, name: String, info: stat) {
            configurationPath = path; self.scopeID = scopeID; self.descriptor = descriptor
            self.directoryPath = directoryPath; self.name = name; device = info.st_dev; inode = info.st_ino
        }
        deinit { Darwin.close(descriptor) }
        public var description: String { "PiMCPBridge.Sidecar(<private>)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: [:]) }

        /// Call only after this exact child has drained. Never follows a
        /// replaced directory or deletes a foreign replacement configuration.
        public func remove() throws {
            try lock.withLock {
                if removed { return }
                var root = stat(), namedRoot = stat(), file = stat()
                guard fstat(descriptor, &root) == 0, lstat(directoryPath, &namedRoot) == 0,
                      root.st_dev == namedRoot.st_dev, root.st_ino == namedRoot.st_ino,
                      namedRoot.st_mode & S_IFMT == S_IFDIR,
                      fstatat(descriptor, name, &file, AT_SYMLINK_NOFOLLOW) == 0,
                      file.st_mode & S_IFMT == S_IFREG, file.st_dev == device, file.st_ino == inode,
                      file.st_uid == getuid(), file.st_nlink == 1, file.st_mode & 0o7777 == 0o600 else {
                    throw PiMCPBridgeError.ownershipLost
                }
                guard unlinkat(descriptor, name, 0) == 0 else { throw PiMCPBridgeError.ownershipLost }
                removed = true
            }
        }
    }

    public static func materialize(endpoint: URL, authorizationHeader: String, scopeID: UUID,
                                   directory: URL) throws -> Sidecar {
        guard validEndpoint(endpoint), authorizationHeader.hasPrefix("Bearer "),
              authorizationHeader.utf8.count > 7, authorizationHeader.utf8.count <= 4_096,
              authorizationHeader.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 || $0.value == 32 }),
              !authorizationHeader.dropFirst(7).contains(where: \.isWhitespace),
              directory.isFileURL, directory.host == nil || directory.host == "" || directory.host == "localhost",
              directory.user == nil, directory.password == nil, directory.query == nil, directory.fragment == nil else {
            throw PiMCPBridgeError.invalidConfiguration
        }
        do { try PiRuntimeConfiguration.lexicalPath(directory.path) }
        catch { throw PiMCPBridgeError.invalidConfiguration }
        var selectedRoot = stat()
        guard lstat(directory.path, &selectedRoot) == 0, selectedRoot.st_mode & S_IFMT == S_IFDIR else { throw PiMCPBridgeError.invalidConfiguration }
        let path: String
        do { path = try PiRuntimeConfiguration.physical(directory.path) } catch { throw PiMCPBridgeError.invalidConfiguration }
        let root = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw PiMCPBridgeError.invalidConfiguration }
        var rootInfo = stat()
        guard fstat(root, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o7777 == 0o700 else {
            Darwin.close(root); throw PiMCPBridgeError.invalidConfiguration
        }
        let name = "mcp-" + scopeID.uuidString.lowercased() + ".json"
        let fd = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { Darwin.close(root); throw PiMCPBridgeError.invalidConfiguration }
        var created = stat()
        var completed = false
        defer {
            Darwin.close(fd)
            if !completed {
                var named = stat()
                if fstatat(root, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                   named.st_dev == created.st_dev, named.st_ino == created.st_ino,
                   named.st_mode & S_IFMT == S_IFREG { _ = unlinkat(root, name, 0) }
                Darwin.close(root)
            }
        }
        guard fstat(fd, &created) == 0, created.st_mode & S_IFMT == S_IFREG,
              created.st_nlink == 1, created.st_uid == getuid(), created.st_mode & 0o7777 == 0o600 else {
            throw PiMCPBridgeError.invalidConfiguration
        }
        let object: JSONValue = .object(["version": .number(1), "scopeID": .string(scopeID.uuidString.lowercased()),
            "endpoint": .string(endpoint.absoluteString), "authorizationHeader": .string(authorizationHeader)])
        let bytes = try JSONEncoder().encode(object)
        guard bytes.count <= 32_768 else { throw PiMCPBridgeError.invalidConfiguration }
        try bytes.withUnsafeBytes { raw in
            guard let pointer = raw.baseAddress else { throw PiMCPBridgeError.invalidConfiguration }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, pointer.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw PiMCPBridgeError.invalidConfiguration }
                offset += count
            }
        }
        var after = stat(), namedRoot = stat()
        guard fsync(fd) == 0, fstat(fd, &after) == 0, after.st_dev == created.st_dev, after.st_ino == created.st_ino,
              after.st_size == bytes.count, lstat(path, &namedRoot) == 0,
              namedRoot.st_dev == rootInfo.st_dev, namedRoot.st_ino == rootInfo.st_ino,
              namedRoot.st_mode & S_IFMT == S_IFDIR else { throw PiMCPBridgeError.ownershipLost }
        completed = true
        return Sidecar(path: URL(fileURLWithPath: path).appendingPathComponent(name), scopeID: scopeID,
                       descriptor: root, directoryPath: path, name: name, info: created)
    }

    private static func validEndpoint(_ endpoint: URL) -> Bool {
        guard let value = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), value.scheme == "http",
              value.host == "127.0.0.1", let port = value.port, (1...65_535).contains(port),
              value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
              !value.path.isEmpty, value.path.utf8.count <= 4_096,
              value.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 })
              }), value.percentEncodedPath == value.path else { return false }
        return true
    }

    public static let readOnlyToolExpression = "coincideMCPReadOnlyTool(event.toolName)"
    public static func readinessMessage(scopeID: UUID) -> String { "coincide-pi-mcp-ready:" + scopeID.uuidString.lowercased() }
    public static func failureMessage(scopeID: UUID) -> String { "coincide-pi-mcp-failed:" + scopeID.uuidString.lowercased() }
    public static let extensionImports = #"""
    import * as coincideMCPFS from "node:fs";
    import * as coincideMCPPath from "node:path";
    import { Type as CoincideMCPType } from "typebox";
    """#

    /// Statements inside the SAME async extension factory as the permission
    /// and authored-input hooks. Pi0.80.5 loader.js awaits that factory.
    public static func extensionFragment(configurationPath: String, extensionPath: String) throws -> String {
        do { try PiRuntimeConfiguration.lexicalPath(configurationPath); try PiRuntimeConfiguration.lexicalPath(extensionPath) }
        catch { throw PiMCPBridgeError.invalidConfiguration }
        func literal(_ value: String) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        return #"""
        const coincideMCPConfigPath = \#(try literal(configurationPath));
        const coincideMCPExtensionPath = \#(try literal(extensionPath));
        const coincideMCPFailure = "Coincide could not complete this MCP operation. It was not retried.";
        const coincideMCPPrefix = "mcp__coincide__";
        const coincideMCPProtocol = "2025-06-18";
        const coincideMCPStop = new AbortController();
        const coincideMCPReadOnly = new Set();
        const coincideMCPExpectedScope = /^mcp-([0-9a-f-]{36})\.json$/.exec(coincideMCPPath.basename(coincideMCPConfigPath))?.[1];
        let coincideMCPReady = false, coincideMCPScope = coincideMCPExpectedScope, coincideMCPSession, coincideMCPNextID = 1;
        const coincideMCPFail = () => { throw new Error(coincideMCPFailure); };
        const coincideMCPObject = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
        const coincideMCPText = (value, maximum) => typeof value === "string" && Buffer.byteLength(value, "utf8") <= maximum;
        const coincideMCPSameFile = (a, b) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs;
        const coincideMCPConfig = () => {
          const fd = coincideMCPFS.openSync(coincideMCPConfigPath,
            coincideMCPFS.constants.O_RDONLY | coincideMCPFS.constants.O_NOFOLLOW | coincideMCPFS.constants.O_NONBLOCK);
          try {
            const before = coincideMCPFS.fstatSync(fd, { bigint: true });
            if (!before.isFile() || before.nlink !== 1n || before.uid !== BigInt(process.getuid()) ||
                (before.mode & 0o7777n) !== 0o600n || before.size <= 0n || before.size > 32768n) coincideMCPFail();
            const bytes = Buffer.alloc(Number(before.size)); let offset = 0;
            while (offset < bytes.length) {
              const count = coincideMCPFS.readSync(fd, bytes, offset, bytes.length - offset, offset);
              if (count <= 0) coincideMCPFail(); offset += count;
            }
            const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
            const after = coincideMCPFS.fstatSync(fd, { bigint: true }), named = coincideMCPFS.lstatSync(coincideMCPConfigPath, { bigint: true });
            if (!coincideMCPSameFile(before, after) || !coincideMCPSameFile(after, named) || !named.isFile() ||
                !coincideMCPObject(value) || Object.keys(value).sort().join("|") !== "authorizationHeader|endpoint|scopeID|version" || value.version !== 1 ||
                !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value.scopeID) ||
                value.scopeID !== coincideMCPExpectedScope ||
                !coincideMCPText(value.authorizationHeader, 4096) || !/^Bearer [!-~]+$/.test(value.authorizationHeader) ||
                !coincideMCPText(value.endpoint, 8192)) coincideMCPFail();
            const url = new URL(value.endpoint);
            if (url.protocol !== "http:" || url.hostname !== "127.0.0.1" || !/^[0-9]+$/.test(url.port) ||
                Number(url.port) < 1 || Number(url.port) > 65535 || url.username || url.password || url.search || url.hash ||
                !url.pathname.startsWith("/") || url.pathname.length > 4096 || /[%\\\x00-\x20\x7f]/.test(url.pathname) ||
                url.pathname.slice(1).split("/").some((part) => !part || part === "." || part === "..")) coincideMCPFail();
            coincideMCPScope = value.scopeID;
            return value;
          } finally { coincideMCPFS.closeSync(fd); }
        };
        const coincideMCPReadOnlyTool = (name) => {
          if (!coincideMCPReady || !coincideMCPReadOnly.has(name) || typeof pi.getAllTools !== "function") return false;
          try {
            const own = coincideMCPFS.realpathSync(coincideMCPExtensionPath);
            const tools = pi.getAllTools().filter((tool) => tool.name === name);
            return tools.length === 1 && typeof tools[0].sourceInfo?.path === "string" &&
              coincideMCPFS.realpathSync(tools[0].sourceInfo.path) === own;
          } catch { return false; }
        };
        const coincideMCPResponse = async (response, id) => {
          if (response.status !== 200 || !response.body || response.redirected) coincideMCPFail();
          const type = (response.headers.get("content-type") ?? "").split(";", 1)[0].trim().toLowerCase();
          if (type !== "application/json" && type !== "text/event-stream") coincideMCPFail();
          const reader = response.body.getReader(), decoder = new TextDecoder("utf-8", { fatal: true });
          let bytes = 0, pending = "", data = [], messages = 0;
          const parse = (text) => {
            const value = JSON.parse(text);
            if (!coincideMCPObject(value) || value.jsonrpc !== "2.0") coincideMCPFail();
            if (value.id === undefined) {
              if (++messages > 256 || typeof value.method !== "string") coincideMCPFail();
              return undefined;
            }
            if (value.id !== id || Object.hasOwn(value, "error") || !Object.hasOwn(value, "result")) coincideMCPFail();
            return { result: value.result };
          };
          try {
            while (true) {
              const part = await reader.read();
              if (part.done) {
                pending += decoder.decode();
                if (type === "application/json") { const value = parse(pending); if (!value) coincideMCPFail(); return value.result; }
                coincideMCPFail();
              }
              bytes += part.value.byteLength;
              if (bytes > 4194304) coincideMCPFail();
              pending += decoder.decode(part.value, { stream: true });
              if (type === "application/json") continue;
              let end;
              while ((end = pending.indexOf("\n")) >= 0) {
                let line = pending.slice(0, end); pending = pending.slice(end + 1);
                if (line.endsWith("\r")) line = line.slice(0, -1);
                if (line === "") {
                  if (data.length) { const value = parse(data.join("\n")); data = []; if (value) return value.result; }
                } else if (line.startsWith("data:")) { data.push(line.slice(5).replace(/^ /, "")); }
              }
            }
          } finally { try { await reader.cancel(); } catch {} reader.releaseLock(); }
        };
        const coincideMCPBounds = (value, maximum = 262144) => {
          let visited = 0;
          const visit = (item, depth) => {
            if (++visited > 32768 || depth > 32) coincideMCPFail();
            if (Array.isArray(item)) { if (item.length > 4096) coincideMCPFail(); for (const child of item) visit(child, depth + 1); }
            else if (coincideMCPObject(item)) { const keys = Object.keys(item); if (keys.length > 4096) coincideMCPFail(); for (const key of keys) visit(item[key], depth + 1); }
            else if (item !== null && !["string", "boolean", "number"].includes(typeof item) || typeof item === "number" && !Number.isFinite(item)) coincideMCPFail();
          };
          visit(value, 0);
          const text = JSON.stringify(value);
          if (Buffer.byteLength(text, "utf8") > maximum) coincideMCPFail();
          return text;
        };
        let coincideMCPConnection;
        const coincideMCPCancel = async (id) => {
          // Streamable HTTP disconnect is not protocol cancellation. Send one
          // exact control notification independently of the aborted tool fetch.
          if (!coincideMCPConnection) return;
          let response;
          try {
            const headers = { accept: "application/json, text/event-stream", "content-type": "application/json",
              authorization: coincideMCPConnection.authorizationHeader, "mcp-protocol-version": coincideMCPProtocol };
            if (coincideMCPSession !== undefined) headers["mcp-session-id"] = coincideMCPSession;
            response = await fetch(coincideMCPConnection.endpoint, { method: "POST", headers,
              body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: id } }),
              redirect: "error", cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer", signal: AbortSignal.timeout(2000) });
          } catch {} finally { try { await response?.body?.cancel(); } catch {} }
        };
        const coincideMCPRequest = async (method, params, signal, notification = false) => {
          if (!coincideMCPConnection || coincideMCPNextID > 1000000) coincideMCPFail();
          const id = notification ? undefined : coincideMCPNextID++;
          const body = coincideMCPBounds({ jsonrpc: "2.0", ...(notification ? {} : { id }), method, params }, 1048576);
          const headers = { accept: "application/json, text/event-stream", "content-type": "application/json",
            authorization: coincideMCPConnection.authorizationHeader, "mcp-protocol-version": coincideMCPProtocol };
          if (coincideMCPSession !== undefined) headers["mcp-session-id"] = coincideMCPSession;
          const signals = [coincideMCPStop.signal, AbortSignal.timeout(method === "tools/call" ? 660000 : 10000)];
          if (signal) signals.push(signal);
          let response;
          try {
          response = await fetch(coincideMCPConnection.endpoint, { method: "POST", headers, body,
            redirect: "error", cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer", signal: AbortSignal.any(signals) });
          const session = response.headers.get("mcp-session-id");
          if (session !== null) {
            if (!/^[!-~]{1,1024}$/.test(session) || coincideMCPSession !== undefined && session !== coincideMCPSession) coincideMCPFail();
            coincideMCPSession = session;
          }
          if (notification) {
            try { if (![202, 204].includes(response.status) || response.redirected) coincideMCPFail(); }
            finally { try { await response.body?.cancel(); } catch {} }
            return;
          }
          return await coincideMCPResponse(response, id);
          } catch (error) {
            if (method === "tools/call" && (signal?.aborted || coincideMCPStop.signal.aborted)) await coincideMCPCancel(id);
            throw error;
          } finally { try { await response?.body?.cancel(); } catch {} }
        };
        pi.on("session_shutdown", () => { coincideMCPStop.abort(); });
        try {
          coincideMCPConnection = coincideMCPConfig();
          const initialized = await coincideMCPRequest("initialize", { protocolVersion: coincideMCPProtocol, capabilities: {},
            clientInfo: { name: "coincide-pi", version: "1.0.0" } });
          if (!coincideMCPObject(initialized) || initialized.protocolVersion !== coincideMCPProtocol) coincideMCPFail();
          await coincideMCPRequest("notifications/initialized", {}, undefined, true);
          const tools = [], seen = new Set(), cursors = new Set(); let cursor;
          for (let page = 0; page < 32; page++) {
            const result = await coincideMCPRequest("tools/list", cursor === undefined ? {} : { cursor });
            if (!coincideMCPObject(result) || !Array.isArray(result.tools) || result.tools.length > 128) coincideMCPFail();
            for (const tool of result.tools) {
              if (!coincideMCPObject(tool) || typeof tool.name !== "string" || !/^[A-Za-z0-9_.-]{1,128}$/.test(tool.name) ||
                  seen.has(tool.name.toLowerCase()) || !coincideMCPObject(tool.inputSchema) || tool.inputSchema.type !== "object" ||
                  tool.description !== undefined && !coincideMCPText(tool.description, 16384) ||
                  tool.annotations !== undefined && !coincideMCPObject(tool.annotations) ||
                  tool.annotations?.readOnlyHint !== undefined && typeof tool.annotations.readOnlyHint !== "boolean") coincideMCPFail();
              coincideMCPBounds(tool.inputSchema); seen.add(tool.name.toLowerCase()); tools.push(tool);
              if (tools.length > 128) coincideMCPFail();
            }
            if (result.nextCursor === undefined) break;
            if (page === 31 || !coincideMCPText(result.nextCursor, 4096) || !result.nextCursor.length || cursors.has(result.nextCursor)) coincideMCPFail();
            cursors.add(result.nextCursor); cursor = result.nextCursor;
          }
          for (const tool of tools) {
            const name = coincideMCPPrefix + tool.name;
            if (tool.annotations?.readOnlyHint === true) coincideMCPReadOnly.add(name);
            pi.registerTool({ name, label: tool.name, description: tool.description ?? tool.name,
              parameters: CoincideMCPType.Unsafe(tool.inputSchema),
              async execute(_toolCallID, params, signal) {
                try {
                  if (!coincideMCPObject(params)) coincideMCPFail();
                  const result = await coincideMCPRequest("tools/call", { name: tool.name, arguments: params }, signal);
                  if (!coincideMCPObject(result) || result.isError === true) coincideMCPFail();
                  const content = [];
                  if (result.content !== undefined) {
                    if (!Array.isArray(result.content) || result.content.length > 128) coincideMCPFail();
                    for (const item of result.content) {
                      if (item?.type === "text" && coincideMCPText(item.text, 2097152)) content.push({ type: "text", text: item.text });
                      else if (item?.type === "image" && coincideMCPText(item.data, 4194304) && ["image/png", "image/jpeg", "image/gif", "image/webp"].includes(item.mimeType)) {
                        content.push({ type: "image", data: item.data, mimeType: item.mimeType });
                      }
                    }
                  }
                  if (!content.length) content.push({ type: "text", text: coincideMCPBounds(result.structuredContent ?? {}, 2097152) });
                  return { content, details: { server: "coincide", tool: tool.name } };
                } catch { throw new Error(coincideMCPFailure); }
              }
            });
          }
          coincideMCPReady = true;
        } catch { coincideMCPReadOnly.clear(); }
        const coincideMCPNotice = () => (coincideMCPReady ? "coincide-pi-mcp-ready:" : "coincide-pi-mcp-failed:") + (coincideMCPScope ?? "invalid");
        pi.on("session_start", (_event, ctx) => { ctx.ui.notify(coincideMCPNotice(), coincideMCPReady ? "info" : "error"); });
        pi.on("input", (_event, ctx) => {
          if (!coincideMCPReady) { ctx.ui.notify(coincideMCPNotice(), "error"); return { action: "handled" }; }
        });
        """#
    }
}
