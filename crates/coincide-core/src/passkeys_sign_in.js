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
    // Tells Coincide's log why a request went to the browser without being asked about.
    const skipped = reason => { try { apply(then, post({kind: 'skipped', reason}), [undefined, () => {}]); } catch (error) {} };
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
            for (let i = 0; i < publicKey.allowCredentials.length && i < 257; i++) {
                const entry = publicKey.allowCredentials[i];
                // A string like WebIDL makes it; only a missing type is an error.
                if (!entry || entry.type === undefined) throw new TypeError('allowCredentials');
                const item = {id: encode(entry.id), type: String(entry.type)};
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
            // Any real AbortSignal, also one from another frame (the getter checks it is one).
            const signal = options.signal;
            if (signal !== undefined) {
                try { apply(aborted, signal, []); } catch (error) { skipped('signal'); return fallback(); }
            }
            const id = requestID();
            let message;
            try { message = describeRequest(options, id); } catch (error) { skipped('options'); return fallback(); }
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
