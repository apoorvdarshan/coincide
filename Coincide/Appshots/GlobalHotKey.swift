import AppKit
import Carbon.HIToolbox
import CoincideKit

/// A shortcut that works in every app, registered with the Carbon Event Manager (`RegisterEventHotKey`), as menu bar
/// utilities register theirs. Unlike watching the keyboard, it needs no permission: macOS delivers only this one
/// combination to Coincide, and nothing else the user types. Unregisters when released. Used on the main thread only,
/// where Carbon delivers hot key events.
nonisolated final class GlobalHotKey: @unchecked Sendable {
    /// 'COIN', so Coincide's hot keys are told apart from any other code's in the process.
    private static let signature: OSType = 0x434F_494E
    nonisolated(unsafe) private static var lastID: UInt32 = 0

    private let id: UInt32
    private let action: @MainActor () -> Void
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    nonisolated(unsafe) private var handler: EventHandlerRef?

    /// Registers `keyCode` (a `kVK_…` virtual key code) with `modifiers`; nil when macOS refuses, such as when another
    /// app has the same shortcut.
    @MainActor
    init?(keyCode: Int, modifiers: KeyModifiers, action: @escaping @MainActor () -> Void) {
        Self.lastID &+= 1
        id = Self.lastID
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(
            GetApplicationEventTarget(), Self.handle, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return nil }
        let registered = RegisterEventHotKey(
            UInt32(keyCode), Self.carbonModifiers(modifiers), EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Carbon's modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    static func carbonModifiers(_ modifiers: KeyModifiers) -> UInt32 {
        var flags = 0
        if modifiers.contains(.command) { flags |= cmdKey }
        if modifiers.contains(.shift) { flags |= shiftKey }
        if modifiers.contains(.option) { flags |= optionKey }
        if modifiers.contains(.control) { flags |= controlKey }
        return UInt32(flags)
    }

    /// The application event target's handler, called on the main thread for every hot key of the process.
    private static let handle: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var pressed = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
            MemoryLayout<EventHotKeyID>.size, nil, &pressed)
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
        guard status == noErr, pressed.signature == signature, pressed.id == hotKey.id else {
            return OSStatus(eventNotHandledErr)
        }
        MainActor.assumeIsolated { hotKey.action() }
        return noErr
    }
}
