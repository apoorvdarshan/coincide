import Foundation

/// What Coincide's page script does with a passkey request after asking: return a credential, reject with a
/// `DOMException`, or hand the request to the browser's own `navigator.credentials.get` (which, without Apple's
/// passkey entitlement, fails and shows the "Passkeys aren't available" notice).
public nonisolated enum WebAuthnReply: Sendable, Equatable {
    case credential(PasskeyCredential)
    case fallback
    case failure(name: String, message: String)

    public static let notAllowed = WebAuthnReply.failure(name: "NotAllowedError", message: "The operation either timed out or was not allowed.")
    public static let pending = WebAuthnReply.failure(name: "NotAllowedError", message: "A request is already pending.")
    public static let invalidRPID = WebAuthnReply.failure(name: "SecurityError",
        message: "The relying party ID is not a registrable domain suffix of, nor equal to the current domain.")

    /// The reply for WebKit: strings only, binary values in base64url.
    public var message: [String: String] {
        switch self {
        case .credential(let credential): credential.message.merging(["status": "ok"]) { $1 }
        case .fallback: ["status": "fallback"]
        case .failure(let name, let message): ["status": "error", "name": name, "message": message]
        }
    }
}

/// A `PublicKeyCredential` for the page to build: the selected credential's ID, the exact client data that was
/// signed, the authenticator data and signature, and the user handle.
public nonisolated struct PasskeyCredential: Sendable, Equatable {
    public let assertion: PasskeyAssertion
    public let clientDataJSON: Data

    public init(assertion: PasskeyAssertion, clientDataJSON: Data) {
        self.assertion = assertion
        self.clientDataJSON = clientDataJSON
    }

    public var message: [String: String] {
        var message = [
            "id": Base64URL.encode(assertion.credentialID),
            "clientDataJSON": Base64URL.encode(clientDataJSON),
            "authenticatorData": Base64URL.encode(assertion.authenticatorData),
            "signature": Base64URL.encode(assertion.signature),
        ]
        if let handle = assertion.userHandle { message["userHandle"] = Base64URL.encode(handle) }
        return message
    }
}

/// "Sign in to github.com as octocat with your Bitwarden passkey?", and the accounts to pick from when several match.
public nonisolated struct PasskeySignInPrompt: Sendable, Equatable {
    /// The relying party ID: the site the passkey belongs to.
    public let site: String
    /// The host of the page that asked, shown when it isn't the site itself (`accounts.google.com` for `google.com`).
    public let requester: String
    public let choices: [BitwardenPasskey]
    /// Touch ID or the Mac's password follows the click, whichever account is chosen.
    public let verifiesUser: Bool

    public init(site: String, requester: String, choices: [BitwardenPasskey], verifiesUser: Bool) {
        self.site = site
        self.requester = requester
        self.choices = choices
        self.verifiesUser = verifiesUser
    }

    public var title: String {
        if choices.count == 1, let only = choices.first {
            return String(localized: "Sign in to \(site) as \(only.accountName) with your Bitwarden passkey?")
        }
        return String(localized: "Sign in to \(site) with your Bitwarden passkey?")
    }

    /// Who asked when it isn't the site, whether to pick an account, and whether Touch ID or the password comes next;
    /// empty when there is nothing to add.
    public var detail: String {
        switch (choices.count > 1, requester != site, verifiesUser) {
        case (false, false, true): String(localized: "You’ll confirm with Touch ID or your Mac password next.")
        case (true, false, true): String(localized: "Choose an account. You’ll confirm with Touch ID or your Mac password next.")
        case (false, true, true): String(localized: "The request comes from \(requester). You’ll confirm with Touch ID or your Mac password next.")
        case (true, true, true):
            String(localized: "The request comes from \(requester). Choose an account. You’ll confirm with Touch ID or your Mac password next.")
        case (false, false, false): ""
        case (true, false, false): String(localized: "Choose an account.")
        case (false, true, false): String(localized: "The request comes from \(requester).")
        case (true, true, false): String(localized: "The request comes from \(requester). Choose an account.")
        }
    }

    /// For the account picker: the account, with the Bitwarden item it is saved in when that says more.
    public func label(for passkey: BitwardenPasskey) -> String {
        let name = passkey.accountName
        guard !passkey.itemName.isEmpty, passkey.itemName != name else { return name }
        return "\(name) · \(passkey.itemName)"
    }

    /// Completes macOS's "Coincide is trying to …" in the Touch ID or password dialog.
    public var verificationReason: String { String(localized: "sign in to \(site) with your Bitwarden passkey") }
}

/// The outcome of asking for Touch ID or the Mac's password.
public nonisolated enum PasskeyUserVerification: Sendable, Equatable {
    case verified
    /// This Mac can't verify the user (no Touch ID and no password set); only the click confirmed the sign-in.
    case unavailable
    /// The user cancelled or failed.
    case failed
}

/// The user's side of a sign-in, shown by the app. Both steps end early, as a cancel, when the task is cancelled.
@MainActor
public protocol PasskeySignInUI: AnyObject {
    /// Asks whether to sign in, and with which passkey when several match; nil when the user cancels.
    func confirm(_ prompt: PasskeySignInPrompt) async -> BitwardenPasskey?
    func verifyUser(reason: String) async -> PasskeyUserVerification
}

/// Answers a page's passkey request with a Bitwarden passkey, Bitwarden's browser extension's way, but only after the
/// user clicks Sign In, which is the user presence the assertion reports. Touch ID or the Mac's password follows when
/// the user asked for it on every sign-in (`BrowserSettings.confirmsPasskeysWithTouchID`), the site requires user
/// verification, or a matching Bitwarden item has master password re-prompt on; the assertion says the user was
/// verified only when that succeeded.
@MainActor
public enum PasskeySignIn {
    /// `origin` is the requesting frame's, from WebKit. Requests Coincide can't serve (none of the user's passkeys
    /// match, Bitwarden is unavailable, conditional or silent mediation) fall back to the browser; requests it refuses
    /// fail like a browser's. `alwaysVerifiesUser` asks for Touch ID or the password even when the site doesn't need it.
    public static func answer(_ request: WebAuthnGetRequest, from origin: WebAuthnOrigin, vault: PasskeyVault, ui: PasskeySignInUI,
        alwaysVerifiesUser: Bool, suffixes: PublicSuffixList? = PublicSuffixList.bundled) async -> WebAuthnReply {
        guard let suffixes else { return .fallback }
        // Never sign without an explicit click: requests the page makes on its own (autofill-style, silent) aren't offered.
        guard request.mediation == .optional || request.mediation == .required else { return .fallback }
        guard let rpID = WebAuthnRelyingParty.validate(request.rpID, origin: origin, suffixes: suffixes) else { return .invalidRPID }
        // Bitwarden's rule: when every allowed credential says it's only on another kind of authenticator (a security
        // key), Bitwarden can't have it.
        let allowed = request.allowCredentials
        if !allowed.isEmpty, allowed.allSatisfy({ !$0.transports.isEmpty && !$0.transports.contains("internal") }) { return .fallback }
        guard let all = try? await vault.passkeys() else { return .fallback }
        guard !Task.isCancelled else { return .notAllowed }
        let matches = BitwardenPasskey.matching(all, rpID: rpID, allowCredentials: allowed.map(\.id))
        guard !matches.isEmpty else { return .fallback }
        // Decided before asking, so the sheet can say whether Touch ID comes next: a re-prompt item among the choices
        // makes every choice verify.
        let verifies = alwaysVerifiesUser || request.userVerification == .required || matches.contains(where: \.requiresReprompt)
        let prompt = PasskeySignInPrompt(site: rpID, requester: origin.host, choices: matches, verifiesUser: verifies)
        guard let choice = await ui.confirm(prompt), matches.contains(choice), !Task.isCancelled else { return .notAllowed }
        // The UV flag is set only when Touch ID or the password succeeded for this request.
        var userVerified = false
        if verifies {
            switch await ui.verifyUser(reason: prompt.verificationReason) {
            case .verified: userVerified = true
            case .unavailable:
                guard request.userVerification != .required, !choice.requiresReprompt else { return .notAllowed }
            case .failed: return .notAllowed
            }
        }
        guard !Task.isCancelled else { return .notAllowed }
        let clientData = WebAuthnAssertion.clientDataJSON(challenge: request.challenge, origin: origin.serialized)
        guard let assertion = try? await vault.assertion(for: choice, rpID: rpID, clientDataJSON: clientData, userVerified: userVerified),
            !Task.isCancelled
        else { return .notAllowed }
        return .credential(PasskeyCredential(assertion: assertion, clientDataJSON: clientData))
    }
}

/// Coincide's WebAuthn page script, the way Bitwarden's browser extension answers passkey requests in browsers it
/// can't change: it replaces `navigator.credentials.get` in the page's own script world (the only place pages' calls
/// can be answered) and forwards public-key requests to Coincide, which checks the frame's origin itself.
public nonisolated enum BitwardenPasskeyScript {
    /// The message handler, which replies to each message.
    public static let messageHandler = "coincideBitwardenPasskey"

    /// Installed at document start in main frames, after `PasskeySupport.detectionScript`, so the `get` it falls back
    /// to is the detection wrapper and an unanswered request still shows the notice. It captures everything it uses
    /// before the page runs; returns credentials built on the real prototypes, so `instanceof` checks pass; rejects
    /// with the `DOMException` names browsers use; honors `signal`; and gives up when Coincide never answers.
    /// `create` (registration) is left alone. Pages on other origins than https (or http on localhost) and opaque
    /// origins get nothing.
    public static let source = #"""
        (() => {
            const handlers = window.webkit && window.webkit.messageHandlers;
            const handler = handlers && handlers.coincideBitwardenPasskey;
            const Container = typeof CredentialsContainer === 'function' && CredentialsContainer;
            const Credential = typeof PublicKeyCredential === 'function' && PublicKeyCredential;
            const AssertionResponse = typeof AuthenticatorAssertionResponse === 'function' && AuthenticatorAssertionResponse;
            const secure = location.protocol === 'https:' || (location.protocol === 'http:' && location.hostname === 'localhost');
            if (!handler || !Container || !Credential || !AssertionResponse || !secure || window.origin === 'null') return;

            const post = handler.postMessage.bind(handler);
            const apply = Reflect.apply, define = Object.defineProperty, describe = Object.getOwnPropertyDescriptor;
            const create = Object.create, isArray = Array.isArray, isView = ArrayBuffer.isView;
            const OwnPromise = Promise, then = Promise.prototype.then, OwnDOMException = DOMException;
            const OwnArrayBuffer = ArrayBuffer, Bytes = Uint8Array, OwnDataView = DataView;
            const OwnAbortSignal = typeof AbortSignal === 'function' && AbortSignal;
            const charCodeAt = String.prototype.charCodeAt, setTimer = setTimeout, clearTimer = clearTimeout;
            const random = crypto.getRandomValues.bind(crypto);
            const buffer = describe(Object.getPrototypeOf(Uint8Array.prototype), 'buffer').get;
            const byteOffset = describe(Object.getPrototypeOf(Uint8Array.prototype), 'byteOffset').get;
            const byteLength = describe(Object.getPrototypeOf(Uint8Array.prototype), 'byteLength').get;
            const viewBuffer = describe(DataView.prototype, 'buffer').get;
            const viewOffset = describe(DataView.prototype, 'byteOffset').get;
            const viewLength = describe(DataView.prototype, 'byteLength').get;
            const aborted = OwnAbortSignal && describe(OwnAbortSignal.prototype, 'aborted').get;
            const reason = OwnAbortSignal && describe(OwnAbortSignal.prototype, 'reason');
            const listen = EventTarget.prototype.addEventListener, unlisten = EventTarget.prototype.removeEventListener;
            const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
            const idAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
            const values = new Bytes(128);
            for (let i = 0; i < 128; i++) values[i] = 255;
            for (let i = 0; i < 64; i++) values[apply(charCodeAt, alphabet, [i])] = i;

            const bytesOf = source => {
                if (source instanceof OwnArrayBuffer) return new Bytes(source);
                if (source instanceof OwnDataView)
                    return new Bytes(apply(viewBuffer, source, []), apply(viewOffset, source, []), apply(viewLength, source, []));
                if (isView(source))
                    return new Bytes(apply(buffer, source, []), apply(byteOffset, source, []), apply(byteLength, source, []));
                throw new TypeError('Not a BufferSource');
            };
            const encode = source => {
                const bytes = bytesOf(source), length = bytes.length;
                let out = '', i = 0;
                for (; i + 2 < length; i += 3) {
                    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
                    out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63] + alphabet[(n >> 6) & 63] + alphabet[n & 63];
                }
                if (length - i === 1) {
                    const n = bytes[i] << 16;
                    out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63];
                } else if (length - i === 2) {
                    const n = (bytes[i] << 16) | (bytes[i + 1] << 8);
                    out += alphabet[(n >> 18) & 63] + alphabet[(n >> 12) & 63] + alphabet[(n >> 6) & 63];
                }
                return out;
            };
            const decode = text => {
                if (typeof text !== 'string') throw new TypeError('Not base64url');
                const length = text.length, result = new OwnArrayBuffer((length * 3) >> 2), out = new Bytes(result);
                let bits = 0, value = 0, o = 0;
                for (let i = 0; i < length; i++) {
                    const code = apply(charCodeAt, text, [i]), digit = code < 128 ? values[code] : 255;
                    if (digit === 255) throw new TypeError('Not base64url');
                    value = ((value << 6) | digit) & 0xffffff;
                    bits += 6;
                    if (bits >= 8) { bits -= 8; out[o++] = (value >> bits) & 255; }
                }
                return result;
            };
            const requestID = () => {
                const bytes = random(new Bytes(16));
                let id = '';
                for (let i = 0; i < 16; i++) id += idAlphabet[bytes[i] % 62];
                return id;
            };
            // A reply from Coincide, or undefined when the handler is gone.
            const ask = message => new OwnPromise(resolve => {
                let reply;
                try { reply = post(message); } catch (error) { resolve(undefined); return; }
                apply(then, reply, [resolve, () => resolve(undefined)]);
            });
            const isAvailable = () => new OwnPromise(resolve => {
                apply(then, ask({kind: 'available'}), [value => resolve(value === true)]);
            });
            // Calls the browser's own function; a synchronous throw becomes a rejection, as from the real API.
            const call = (fn, self, args) => {
                try { return apply(fn, self, args); } catch (error) { return new OwnPromise((_, reject) => reject(error)); }
            };
            const notAllowed = () => new OwnDOMException('The operation either timed out or was not allowed.', 'NotAllowedError');
            const reasonOf = signal => {
                const value = reason && reason.get ? apply(reason.get, signal, []) : undefined;
                return value === undefined ? new OwnDOMException('The operation was aborted.', 'AbortError') : value;
            };

            const credentialFrom = reply => {
                const handle = typeof reply.userHandle === 'string' ? reply.userHandle : undefined;
                const response = create(AssertionResponse.prototype);
                define(response, 'clientDataJSON', {value: decode(reply.clientDataJSON), enumerable: true});
                define(response, 'authenticatorData', {value: decode(reply.authenticatorData), enumerable: true});
                define(response, 'signature', {value: decode(reply.signature), enumerable: true});
                define(response, 'userHandle', {value: handle === undefined ? null : decode(handle), enumerable: true});
                const credential = create(Credential.prototype);
                define(credential, 'id', {value: String(reply.id), enumerable: true});
                define(credential, 'rawId', {value: decode(reply.id), enumerable: true});
                define(credential, 'type', {value: 'public-key', enumerable: true});
                define(credential, 'authenticatorAttachment', {value: 'platform', enumerable: true});
                define(credential, 'response', {value: response, enumerable: true});
                define(credential, 'getClientExtensionResults', {value: {getClientExtensionResults() { return {}; }}.getClientExtensionResults});
                // PublicKeyCredentialJSON, a new object each time.
                define(credential, 'toJSON', {value: {toJSON() {
                    const json = {
                        id: String(reply.id), rawId: String(reply.id), type: 'public-key', authenticatorAttachment: 'platform',
                        clientExtensionResults: {},
                        response: {clientDataJSON: reply.clientDataJSON, authenticatorData: reply.authenticatorData, signature: reply.signature},
                    };
                    if (handle !== undefined) json.response.userHandle = handle;
                    return json;
                }}.toJSON});
                return credential;
            };

            // The request as Coincide reads it; throws for options the browser itself would reject, which then go to it.
            const describeRequest = (options, id) => {
                const publicKey = options.publicKey;
                const message = {kind: 'get', id, publicKey: {challenge: encode(publicKey.challenge)}};
                if (publicKey.rpId !== undefined) {
                    if (typeof publicKey.rpId !== 'string') throw new TypeError('rpId');
                    message.publicKey.rpId = publicKey.rpId;
                }
                if (publicKey.allowCredentials !== undefined) {
                    if (!isArray(publicKey.allowCredentials)) throw new TypeError('allowCredentials');
                    const list = [];
                    for (let i = 0; i < publicKey.allowCredentials.length && i < 65; i++) {
                        const entry = publicKey.allowCredentials[i];
                        if (!entry || typeof entry.type !== 'string') throw new TypeError('allowCredentials');
                        const item = {id: encode(entry.id), type: entry.type};
                        if (isArray(entry.transports)) {
                            item.transports = [];
                            for (let t = 0; t < entry.transports.length && t < 16; t++) item.transports[t] = String(entry.transports[t]);
                        }
                        list[list.length] = item;
                    }
                    message.publicKey.allowCredentials = list;
                }
                if (typeof publicKey.userVerification === 'string') message.publicKey.userVerification = publicKey.userVerification;
                if (typeof publicKey.timeout === 'number') message.publicKey.timeout = publicKey.timeout;
                if (options.mediation !== undefined) message.mediation = String(options.mediation);
                return message;
            };

            const descriptor = describe(Container.prototype, 'get');
            const original = descriptor && descriptor.value;
            if (typeof original !== 'function') return;
            const wrapped = {
                get(options) {
                    const self = this, args = arguments;
                    const fallback = () => call(original, self, args);
                    if (!options || typeof options !== 'object' || !options.publicKey || !(self instanceof Container)) return fallback();
                    const signal = options.signal;
                    if (signal !== undefined && !(OwnAbortSignal && signal instanceof OwnAbortSignal)) return fallback();
                    const id = requestID();
                    let message;
                    try { message = describeRequest(options, id); } catch (error) { return fallback(); }
                    return new OwnPromise((resolve, reject) => {
                        if (signal && apply(aborted, signal, [])) { reject(reasonOf(signal)); return; }
                        let settled = false, timer;
                        const onAbort = () => {
                            if (settled) return;
                            ask({kind: 'abort', id});
                            finish(reject, reasonOf(signal));
                        };
                        const finish = (action, value) => {
                            if (settled) return;
                            settled = true;
                            if (timer !== undefined) clearTimer(timer);
                            if (signal) apply(unlisten, signal, ['abort', onAbort]);
                            action(value);
                        };
                        if (signal) apply(listen, signal, ['abort', onAbort]);
                        if (message.mediation === 'conditional') {
                            // Autofill-style requests stay open without offering anything until the page aborts them:
                            // Coincide never signs without a click.
                            apply(then, isAvailable(), [available => { if (!available) finish(resolve, fallback()); }]);
                            return;
                        }
                        // Coincide answers within the page's clamped timeout; this only covers a reply that never comes.
                        timer = setTimer(() => { ask({kind: 'abort', id}); finish(reject, notAllowed()); }, 11 * 60 * 1000);
                        apply(then, ask(message), [reply => {
                            if (!reply || typeof reply !== 'object' || reply.status === 'fallback') { finish(resolve, fallback()); return; }
                            if (reply.status === 'ok') {
                                let credential;
                                try { credential = credentialFrom(reply); } catch (error) { finish(reject, notAllowed()); return; }
                                finish(resolve, credential);
                                return;
                            }
                            finish(reject, new OwnDOMException(String(reply.message || ''), String(reply.name || 'NotAllowedError')));
                        }]);
                    });
                },
            }.get;
            define(wrapped, 'length', {value: original.length});
            define(Container.prototype, 'get', {...descriptor, value: wrapped});

            // Bitwarden is a platform authenticator that can verify the user (Touch ID or the Mac's password, asked
            // whenever a site requires it) while it is connected; without it, the browser's own answers stand.
            // Autofill-style sign-in isn't offered.
            const replaceStatic = (name, make) => {
                const own = describe(Credential, name);
                if (!own || typeof own.value !== 'function') return;
                const replacement = make(own.value);
                define(replacement, 'length', {value: own.value.length});
                define(Credential, name, {...own, value: replacement});
            };
            replaceStatic('isUserVerifyingPlatformAuthenticatorAvailable', base => ({
                isUserVerifyingPlatformAuthenticatorAvailable() {
                    const self = this, args = arguments;
                    return new OwnPromise(resolve => apply(then, isAvailable(), [available => resolve(available ? true : call(base, self, args))]));
                },
            }).isUserVerifyingPlatformAuthenticatorAvailable);
            replaceStatic('isConditionalMediationAvailable', base => ({
                isConditionalMediationAvailable() {
                    const self = this, args = arguments;
                    return new OwnPromise(resolve => apply(then, isAvailable(), [available => resolve(available ? false : call(base, self, args))]));
                },
            }).isConditionalMediationAvailable);
            replaceStatic('getClientCapabilities', base => ({
                getClientCapabilities() {
                    const self = this, args = arguments;
                    return new OwnPromise((resolve, reject) => apply(then, isAvailable(), [available => {
                        const native = call(base, self, args);
                        if (!available) { resolve(native); return; }
                        apply(then, native, [capabilities => resolve({...capabilities, userVerifyingPlatformAuthenticator: true, conditionalGet: false}), reject]);
                    }]));
                },
            }).getClientCapabilities);
        })();
        """#
}
