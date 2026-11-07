(() => {
    const handlers = window.webkit && window.webkit.messageHandlers;
    const handler = handlers && handlers.coincidePasskey;
    const proto = typeof CredentialsContainer === 'function' && CredentialsContainer.prototype;
    if (!handler || !proto) return;
    const post = handler.postMessage.bind(handler);
    for (const name of ['get', 'create']) {
        const descriptor = Object.getOwnPropertyDescriptor(proto, name);
        const original = descriptor && descriptor.value;
        if (typeof original !== 'function') continue;
        // Method syntax keeps the built-in's name and, like a native method, has no prototype.
        const wrapped = {
            [name](options) {
                try {
                    if (options && typeof options === 'object' && options.publicKey) post({kind: name});
                } catch (error) {}
                return Reflect.apply(original, this, arguments);
            }
        }[name];
        Object.defineProperty(wrapped, 'length', {value: original.length});
        Object.defineProperty(proto, name, {...descriptor, value: wrapped});
    }
})();
