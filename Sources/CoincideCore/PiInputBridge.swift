import Foundation

/// These values are embedded in durable inputs, run preparations and command
/// envelopes. Immutable indirection bounds their copy footprint; coding and
/// equality continue to describe their flat contents, not storage identity.
private final class PiInputBridgeStorage<Value: Sendable>: Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A digest-only, one-use permission to associate an authored input with Pi's
/// expanded user entry. This is an app input identity, never a native turn ID.
public struct PiInputBridgeReservation: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let version: Int
        let nonce: UUID
        let processEpoch: UUID
        let runPreparationID: UUID
        let clientMessageID: String
        let originalDigest: String
        let nativeSessionID: String
        let nativeSessionFile: String
        let retirementNonce: UUID?
    }
    private let storage: PiInputBridgeStorage<Payload>
    public var version: Int { storage.value.version }
    public var nonce: UUID { storage.value.nonce }
    public var processEpoch: UUID { storage.value.processEpoch }
    public var runPreparationID: UUID { storage.value.runPreparationID }
    public var clientMessageID: String { storage.value.clientMessageID }
    public var originalDigest: String { storage.value.originalDigest }
    public var nativeSessionID: String { storage.value.nativeSessionID }
    public var nativeSessionFile: String { storage.value.nativeSessionFile }
    public var retirementNonce: UUID? { storage.value.retirementNonce }

    public init(version: Int = 1, nonce: UUID, processEpoch: UUID, runPreparationID: UUID,
                clientMessageID: String, originalDigest: String, nativeSessionID: String,
                nativeSessionFile: String, retirementNonce: UUID? = nil) throws {
        storage = .init(.init(version: version, nonce: nonce, processEpoch: processEpoch, runPreparationID: runPreparationID,
                              clientMessageID: clientMessageID, originalDigest: originalDigest, nativeSessionID: nativeSessionID,
                              nativeSessionFile: nativeSessionFile, retirementNonce: retirementNonce))
        try validate()
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
    public func validate() throws {
        guard version == 1, retirementNonce != nonce else { throw PiHistoryGraphError(.invalidWindow) }
        try ProviderSteeringValidation.id(clientMessageID)
        try PiRunHistoryValidation.digest(originalDigest)
        _ = try PiHistoryValidation.identifier(.string(nativeSessionID))
        try PiRuntimeConfiguration.path(nativeSessionFile)
    }
    /// Wire UUIDs use one spelling so the native marker can be reconstructed
    /// byte-semantically after a journal round trip.
    public var json: JSONValue {
        var object: [String: JSONValue] = [
            "version": .number(Double(version)), "nonce": .string(nonce.uuidString.lowercased()),
            "processEpoch": .string(processEpoch.uuidString.lowercased()),
            "runPreparationID": .string(runPreparationID.uuidString.lowercased()),
            "clientMessageID": .string(clientMessageID), "originalDigest": .string(originalDigest),
            "nativeSessionID": .string(nativeSessionID), "nativeSessionFile": .string(nativeSessionFile)
        ]
        if let retirementNonce { object["retirementNonce"] = .string(retirementNonce.uuidString.lowercased()) }
        return .object(object)
    }
    public func encoded() throws -> Data {
        try validate()
        let bytes = try PiHistoryValidation.bytes(json)
        guard bytes.count <= PiInputBridge.maximumReservationBytes else { throw PiHistoryGraphError(.oversized) }
        return bytes
    }
    public init(json: JSONValue) throws {
        guard let object = json.object,
              Set(object.keys) == PiInputBridge.reservationKeys || Set(object.keys) == PiInputBridge.reservationKeys.union(["retirementNonce"]),
              json["version"] == .number(1) else { throw PiHistoryGraphError(.invalidWindow) }
        func uuid(_ key: String) throws -> UUID {
            guard let text = json[key].string, let value = UUID(uuidString: text),
                  text == value.uuidString.lowercased() else { throw PiHistoryGraphError(.invalidWindow) }
            return value
        }
        try self.init(nonce: uuid("nonce"), processEpoch: uuid("processEpoch"), runPreparationID: uuid("runPreparationID"),
                      clientMessageID: PiHistoryValidation.identifier(json["clientMessageID"]),
                      originalDigest: PiHistoryValidation.identifier(json["originalDigest"]),
                      nativeSessionID: PiHistoryValidation.identifier(json["nativeSessionID"]),
                      nativeSessionFile: PiHistoryValidation.identifier(json["nativeSessionFile"]),
                      retirementNonce: object["retirementNonce"] == nil ? nil : uuid("retirementNonce"))
    }
}

/// The complete small native custom record, including its native envelope.
/// Keeping this representation permits pure journal validation of its digest;
/// it contains no authored text, expanded skill body, image, or credential.
public struct PiInputBridgeMarker: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let reservation: PiInputBridgeReservation
        let expandedDigest: String
        let id: String
        let parentID: String?
        let timestamp: String
    }
    private let storage: PiInputBridgeStorage<Payload>
    public var reservation: PiInputBridgeReservation { storage.value.reservation }
    public var expandedDigest: String { storage.value.expandedDigest }
    public var id: String { storage.value.id }
    public var parentID: String? { storage.value.parentID }
    public var timestamp: String { storage.value.timestamp }
    public init(reservation: PiInputBridgeReservation, expandedDigest: String, id: String,
                parentID: String?, timestamp: String) throws {
        storage = .init(.init(reservation: reservation, expandedDigest: expandedDigest, id: id, parentID: parentID, timestamp: timestamp))
        try validate()
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
    public var rawEntry: JSONValue {
        var data = reservation.json.object ?? [:]
        data["expandedDigest"] = .string(expandedDigest)
        return .object(["type": .string("custom"), "customType": .string(PiInputBridge.customType),
                        "data": .object(data), "id": .string(id), "parentId": parentID.map(JSONValue.string) ?? .null,
                        "timestamp": .string(timestamp)])
    }
    public func validate() throws {
        try reservation.validate(); try PiRunHistoryValidation.digest(expandedDigest)
        _ = try PiHistoryValidation.identifier(.string(id))
        if let parentID { _ = try PiHistoryValidation.identifier(.string(parentID)) }
        try PiHistoryValidation.timestamp(.string(timestamp))
        _ = try PiHistoryEntry(raw: rawEntry)
    }
    public init(entry: PiHistoryEntry) throws {
        guard entry.kind == .custom, entry.raw["customType"] == .string(PiInputBridge.customType),
              let object = entry.raw.object,
              Set(object.keys) == ["type", "customType", "data", "id", "parentId", "timestamp"],
              var data = entry.raw["data"].object,
              Set(data.keys) == PiInputBridge.reservationKeys.union(["expandedDigest"]) ||
                Set(data.keys) == PiInputBridge.reservationKeys.union(["expandedDigest", "retirementNonce"]),
              let expanded = data.removeValue(forKey: "expandedDigest")?.string,
              let timestamp = entry.raw["timestamp"].string else { throw PiHistoryGraphError(.invalidWindow) }
        try self.init(reservation: .init(json: .object(data)), expandedDigest: expanded,
                      id: entry.id, parentID: entry.parentID, timestamp: timestamp)
        guard rawEntry == entry.raw else { throw PiHistoryGraphError(.invalidWindow) }
    }
}

public struct PiInputBridgeEvidence: Codable, Sendable, Equatable {
    private struct Payload: Codable, Sendable, Equatable {
        let marker: PiInputBridgeMarker
        let nativeUserEntryID: String
        let nativeUserEntryDigest: String
    }
    private let storage: PiInputBridgeStorage<Payload>
    public var marker: PiInputBridgeMarker { storage.value.marker }
    public var nativeUserEntryID: String { storage.value.nativeUserEntryID }
    public var nativeUserEntryDigest: String { storage.value.nativeUserEntryDigest }
    public var expandedDigest: String { marker.expandedDigest }
    public init(marker: PiInputBridgeMarker, nativeUserEntryID: String, nativeUserEntryDigest: String) throws {
        storage = .init(.init(marker: marker, nativeUserEntryID: nativeUserEntryID, nativeUserEntryDigest: nativeUserEntryDigest))
        try validate()
    }
    public init(from decoder: any Decoder) throws { storage = .init(try Payload(from: decoder)); try validate() }
    public func encode(to encoder: any Encoder) throws { try storage.value.encode(to: encoder) }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.storage.value == rhs.storage.value }
    public func validate() throws {
        try marker.validate(); _ = try PiHistoryValidation.identifier(.string(nativeUserEntryID))
        try PiRunHistoryValidation.digest(nativeUserEntryDigest)
        guard nativeUserEntryID != marker.id else { throw PiHistoryGraphError(.invalidWindow) }
    }
}

public enum PiInputBridge {
    public static let customType = "coincide.input-proof.v1"
    public static let maximumReservationBytes = 32_768
    public static let maximumInputs = 65
    static let reservationKeys: Set<String> = ["version", "nonce", "processEpoch", "runPreparationID", "clientMessageID",
                                               "originalDigest", "nativeSessionID", "nativeSessionFile"]
    public static func readinessMessage(processEpoch: UUID) -> String {
        "coincide-pi-input-proof-v1:\(processEpoch.uuidString.lowercased())"
    }
    public static func failureMessage(processEpoch: UUID) -> String {
        "coincide-pi-input-proof-v1-invalid:\(processEpoch.uuidString.lowercased())"
    }

    /// Performs the raw-native check while user contents are transient. The
    /// hook's digest is never accepted without hashing the actual native user.
    public static func prove(reservations: [PiInputBridgeReservation], entries: [PiHistoryEntry],
                             baseline: PiRuntimeEntryObservation,
                             finalObservation: PiRuntimeEntryObservation) throws -> [PiInputBridgeEvidence] {
        guard !reservations.isEmpty, reservations.count <= maximumInputs, entries.count <= PiHistoryGraph.maximumEntries,
              entries.map(PiHistoryEntryDescriptor.init) == finalObservation.entries else { throw PiHistoryGraphError(.invalidWindow) }
        let window = try finalObservation.appendedWindow(since: baseline)
        let raw = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var markers: [PiInputBridgeMarker] = []
        for descriptor in window {
            guard let entry = raw[descriptor.id] else { throw PiHistoryGraphError(.invalidWindow) }
            if entry.kind == .custom, entry.raw["customType"] == .string(customType) {
                markers.append(try .init(entry: entry))
            }
        }
        guard markers.count == reservations.count else { throw PiHistoryGraphError(.invalidWindow) }
        let users = window.filter(\.isUser)
        guard users.count == markers.count else { throw PiHistoryGraphError(.invalidWindow) }
        var evidence: [PiInputBridgeEvidence] = []
        for (marker, user) in zip(markers, users) {
            guard let entry = raw[user.id], try PiProtocol.inputDigest(entry) == marker.expandedDigest else {
                throw PiHistoryGraphError(.invalidWindow)
            }
            evidence.append(try .init(marker: marker, nativeUserEntryID: user.id, nativeUserEntryDigest: entry.digest))
        }
        try validate(reservations: reservations, evidence: evidence, baseline: baseline, finalObservation: finalObservation)
        return evidence
    }

    /// Pure revalidation for durable evidence. The caller retains only the
    /// small marker plus native descriptors, never another user-content copy.
    public static func validate(reservations: [PiInputBridgeReservation], evidence: [PiInputBridgeEvidence],
                                baseline: PiRuntimeEntryObservation, finalObservation: PiRuntimeEntryObservation) throws {
        guard !reservations.isEmpty, reservations.count <= maximumInputs, evidence.count == reservations.count else {
            throw PiHistoryGraphError(.invalidWindow)
        }
        let window = try finalObservation.appendedWindow(since: baseline)
        let users = window.filter(\.isUser)
        guard users.map(\.id) == evidence.map(\.nativeUserEntryID),
              Set(reservations.map(\.nonce)).count == reservations.count,
              Set(reservations.map(\.clientMessageID)).count == reservations.count,
              Set(evidence.map { $0.marker.id }).count == evidence.count,
              let owner = reservations.first else { throw PiHistoryGraphError(.invalidWindow) }
        let positions = Dictionary(uniqueKeysWithValues: window.enumerated().map { ($0.element.id, $0.offset) })
        for (reservation, proof) in zip(reservations, evidence) {
            try reservation.validate(); try proof.validate()
            guard reservation.nativeSessionFile == baseline.nativeSessionFile, reservation.nativeSessionID == baseline.nativeSessionID,
                  reservation.processEpoch == owner.processEpoch, reservation.runPreparationID == owner.runPreparationID,
                  proof.marker.reservation == reservation,
                  let markerPosition = positions[proof.marker.id], let userPosition = positions[proof.nativeUserEntryID],
                  userPosition == markerPosition + 1 else { throw PiHistoryGraphError(.invalidWindow) }
            let marker = window[markerPosition], user = window[userPosition]
            let reconstructed = try PiHistoryEntry(raw: proof.marker.rawEntry)
            guard marker == PiHistoryEntryDescriptor(reconstructed), user.parentID == marker.id,
                  user.contentDigest == proof.nativeUserEntryDigest, user.isUser else { throw PiHistoryGraphError(.invalidWindow) }
        }
    }

    /// Imports accompany the fragment below. Pi's pinned extension loader
    /// aliases its own package, including stripFrontmatter, for external files.
    public static let extensionImports = #"""
    import * as coincideInputFS from "node:fs";
    import * as coincideInputPath from "node:path";
    import { createHash as coincideInputHash } from "node:crypto";
    import { stripFrontmatter as coincideStripFrontmatter } from "@earendil-works/pi-coding-agent";
    """#

    /// Statements inserted inside the app-owned extension factory. The actor
    /// must keep its admission fence until the actual user append is observed;
    /// a queued prompt ACK cannot authorize replacing the reservation slot.
    public static func extensionFragment(reservationPath: String, processEpoch: UUID) throws -> String {
        try PiRuntimeConfiguration.path(reservationPath)
        func literal(_ value: String) throws -> String { String(decoding: try PiHistoryValidation.bytes(.string(value)), as: UTF8.self) }
        return #"""
        const cibPath = \#(try literal(reservationPath));
        const cibEpoch = \#(try literal(processEpoch.uuidString.lowercased()));
        const cibReady = \#(try literal(readinessMessage(processEpoch: processEpoch)));
        const cibFailure = \#(try literal(failureMessage(processEpoch: processEpoch)));
        const cibType = "coincide.input-proof.v1";
        const cibKeys = ["clientMessageID", "nativeSessionFile", "nativeSessionID", "nonce", "originalDigest", "processEpoch", "runPreparationID", "version"];
        const cibSeen = new Set();
        const cibUsers = new WeakMap();
        let cibPending;
        let cibLastClaimed;
        let cibInvalid = false;
        const cibFail = (ctx) => {
          cibPending = undefined;
          if (!cibInvalid) { cibInvalid = true; ctx.ui.notify(cibFailure, "warning"); }
        };
        const cibSHA = (value) => coincideInputHash("sha256").update(value).digest("hex");
        const cibString = (value, maximum) => typeof value === "string" && Buffer.byteLength(value, "utf8") <= maximum &&
          !/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(value);
        const cibID = (value) => cibString(value, 4096) && value.trim().length > 0 && !/[\x00-\x1f\x7f]/.test(value);
        const cibUUID = (value) => typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
        const cibDigest = (text, images) => {
          if (!cibString(text, 4194304) || (images !== undefined && !Array.isArray(images))) throw new Error("invalid input");
          const list = images ?? [];
          if (list.length > 100 || (text.length === 0 && list.length === 0)) throw new Error("invalid input");
          let total = 0;
          const normalized = list.map((image) => {
            if (!image || image.type !== "image" || !["image/png", "image/jpeg", "image/gif", "image/webp"].includes(image.mimeType) ||
                typeof image.data !== "string" || image.data.length > 13981016 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(image.data)) throw new Error("invalid image");
            const bytes = Buffer.from(image.data, "base64");
            total += bytes.length;
            if (bytes.length === 0 || bytes.length > 10485760 || bytes.toString("base64") !== image.data) throw new Error("invalid image");
            return { byteCount: bytes.length, digest: cibSHA(bytes), mimeType: image.mimeType };
          });
          if (total > 83886080) throw new Error("invalid images");
          // These ASCII keys are in the same sorted order as Swift's
          // JSONEncoder(sortedKeys, withoutEscapingSlashes) semantic input.
          return cibSHA(JSON.stringify({ images: normalized, text }));
        };
        const cibUserDigest = (message) => {
          if (!message || message.role !== "user") throw new Error("invalid user");
          if (typeof message.content === "string") return cibDigest(message.content, []);
          if (!Array.isArray(message.content)) throw new Error("invalid user");
          let text = ""; const images = [];
          for (const part of message.content) {
            if (part?.type === "text" && typeof part.text === "string") text += part.text;
            else if (part?.type === "image") images.push(part);
            else throw new Error("invalid content");
          }
          return cibDigest(text, images);
        };
        const cibSameFile = (a, b) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs;
        const cibClaim = (event, ctx) => {
          const flags = coincideInputFS.constants.O_RDONLY | coincideInputFS.constants.O_NOFOLLOW | coincideInputFS.constants.O_NONBLOCK;
          const fd = coincideInputFS.openSync(cibPath, flags);
          try {
            const before = coincideInputFS.fstatSync(fd, { bigint: true });
            if (!before.isFile() || before.nlink !== 1n || before.uid !== BigInt(process.getuid()) ||
                (before.mode & 0o7777n) !== 0o600n || before.size <= 0n || before.size > 32768n) throw new Error("invalid reservation");
            const bytes = Buffer.alloc(Number(before.size)); let read = 0;
            while (read < bytes.length) {
              const count = coincideInputFS.readSync(fd, bytes, read, bytes.length - read, read);
              if (count <= 0) throw new Error("invalid reservation"); read += count;
            }
            const value = JSON.parse(bytes.toString("utf8"));
            const keys = Object.keys(value ?? {}).sort().join("|");
            const retiredKeys = [...cibKeys, "retirementNonce"].sort().join("|");
            if (!value || Array.isArray(value) || (keys !== cibKeys.join("|") && keys !== retiredKeys) || value.version !== 1 ||
                !cibUUID(value.nonce) || !cibUUID(value.processEpoch) || !cibUUID(value.runPreparationID) || value.processEpoch !== cibEpoch ||
                !cibID(value.clientMessageID) || !cibID(value.nativeSessionID) || typeof value.nativeSessionFile !== "string" ||
                value.nativeSessionFile !== ctx.sessionManager.getSessionFile() || value.nativeSessionID !== ctx.sessionManager.getSessionId() ||
                !/^[0-9a-f]{64}$/.test(value.originalDigest) || value.originalDigest !== cibDigest(event.text, event.images) ||
                cibSeen.has(value.nonce) || cibSeen.size >= 4096) throw new Error("invalid reservation");
            if (value.retirementNonce !== undefined) {
              if (!cibUUID(value.retirementNonce) || value.retirementNonce === value.nonce ||
                  !cibLastClaimed || value.retirementNonce !== cibLastClaimed.nonce ||
                  cibLastClaimed.nativeSessionID !== value.nativeSessionID || cibLastClaimed.nativeSessionFile !== value.nativeSessionFile ||
                  cibPending?.message || !ctx.isIdle() || ctx.hasPendingMessages()) throw new Error("invalid retirement");
            } else if (cibPending) throw new Error("pending reservation");
            const after = coincideInputFS.fstatSync(fd, { bigint: true });
            const named = coincideInputFS.lstatSync(cibPath, { bigint: true });
            if (!cibSameFile(before, after) || !cibSameFile(after, named) || !named.isFile()) throw new Error("changed reservation");
            coincideInputFS.unlinkSync(cibPath);
            cibSeen.add(value.nonce);
            cibLastClaimed = value;
            return value;
          } finally { coincideInputFS.closeSync(fd); }
        };
        const cibSkillBody = (path) => {
          if (typeof path !== "string" || !coincideInputPath.isAbsolute(path) || path.includes("\0")) throw new Error("invalid skill");
          // Native Pi follows advertised skill symlinks. Open nonblocking, then
          // require a bounded regular file so a FIFO cannot block this hook.
          const fd = coincideInputFS.openSync(path, coincideInputFS.constants.O_RDONLY | coincideInputFS.constants.O_NONBLOCK);
          try {
            const before = coincideInputFS.fstatSync(fd, { bigint: true });
            if (!before.isFile() || before.size > 4194304n) throw new Error("invalid skill");
            const bytes = Buffer.alloc(Number(before.size)); let read = 0;
            while (read < bytes.length) {
              const count = coincideInputFS.readSync(fd, bytes, read, bytes.length - read, read);
              if (count <= 0) throw new Error("changed skill"); read += count;
            }
            if (!cibSameFile(before, coincideInputFS.fstatSync(fd, { bigint: true }))) throw new Error("changed skill");
            return coincideStripFrontmatter(new TextDecoder("utf-8", { fatal: true }).decode(bytes)).trim();
          } finally { coincideInputFS.closeSync(fd); }
        };
        pi.on("session_start", (_event, ctx) => {
          if (cibPending) cibFail(ctx);
          ctx.ui.notify(cibInvalid ? cibFailure : cibReady, "info");
        });
        pi.on("input", (event, ctx) => {
          if (cibInvalid) return { action: "handled" };
          if (event.source !== "rpc") { cibFail(ctx); return { action: "handled" }; }
          try { cibPending = { reservation: cibClaim(event, ctx), message: undefined }; }
          catch { cibFail(ctx); return { action: "handled" }; }
          if (!event.text.includes("$")) return;
          let catalog;
          try {
            catalog = pi.getCommands();
            if (!Array.isArray(catalog) || catalog.length > 4096) throw new Error("invalid commands");
          } catch { cibFail(ctx); return { action: "handled" }; }
          const commands = catalog.filter((command) => command?.source === "skill");
          const nativeSkill = /^\/skill:([^ ]+)(?: |$)/.exec(event.text)?.[1];
          const seen = new Set(nativeSkill === undefined ? [] : [nativeSkill]);
          const folded = (value) => value.normalize("NFC").toLowerCase();
          const matches = (name) => commands.filter((command) => typeof command.name === "string" &&
            command.name.startsWith("skill:") && folded(command.name.slice(6)) === folded(name));
          const blocks = []; let bytes = Buffer.byteLength(event.text, "utf8"), count = 0;
          for (const match of event.text.matchAll(/(^|\s)\$([^\s]+)(?=\s|$)/g)) {
            const name = match[2];
            if (name === undefined) continue;
            // Only selected collisions are refused. An unknown $variable is
            // ordinary text, and never acquires a guessed skill identity.
            if (matches(name).length > 1) { cibFail(ctx); return { action: "handled" }; }
            if (seen.has(name)) continue;
            const command = commands.find((candidate) => candidate.name === "skill:" + name);
            if (command === undefined) continue;
            if ((command.enabled !== undefined && command.enabled !== true) ||
                (command.userInvocable !== undefined && command.userInvocable !== true)) {
              cibFail(ctx); return { action: "handled" };
            }
            seen.add(name);
            try {
              if (++count > 64) throw new Error("too many skills");
              const path = command.sourceInfo?.path;
              const body = cibSkillBody(path);
              const block = `<skill name="${name}" location="${path}">\nReferences are relative to ${coincideInputPath.dirname(path)}.\n\n${body}\n</skill>`;
              bytes += Buffer.byteLength(block, "utf8") + 2;
              if (bytes > 4194304) throw new Error("expanded input too large");
              blocks.push(block);
            } catch { cibFail(ctx); return { action: "handled" }; }
          }
          if (blocks.length > 0) return { action: "transform", text: event.text + "\n\n" + blocks.join("\n\n"), images: event.images };
        });
        pi.on("message_start", (event, ctx) => {
          if (event.message?.role !== "user" || cibInvalid) return;
          if (!cibPending || cibPending.message || cibPending.reservation.nativeSessionFile !== ctx.sessionManager.getSessionFile() ||
              cibPending.reservation.nativeSessionID !== ctx.sessionManager.getSessionId()) { cibFail(ctx); return; }
          cibPending.message = event.message;
          cibUsers.set(event.message, cibPending);
        });
        pi.on("message_end", (event, ctx) => {
          if (event.message?.role !== "user" || cibInvalid) return;
          const owned = cibUsers.get(event.message);
          if (!owned || owned !== cibPending || owned.message !== event.message ||
              owned.reservation.nativeSessionFile !== ctx.sessionManager.getSessionFile() ||
              owned.reservation.nativeSessionID !== ctx.sessionManager.getSessionId()) { cibFail(ctx); return; }
          try {
            const expandedDigest = cibUserDigest(event.message);
            pi.appendEntry(cibType, { ...owned.reservation, expandedDigest });
            cibUsers.delete(event.message); cibPending = undefined;
          } catch { cibFail(ctx); }
        });
        """#
    }
}
