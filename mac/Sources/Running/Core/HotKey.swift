import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut (Carbon's RegisterEventHotKey: needs no Accessibility permission).
/// One event handler serves every shortcut — installing the same handler twice fails
/// (eventHandlerAlreadyInstalledErr), which silently cost the second shortcut.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let action: () -> Void
    private let id: UInt32
    private static var all: [UInt32: HotKey] = [:]
    private static var nextId: UInt32 = 1
    private static var handler: EventHandlerRef?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        guard HotKey.installHandler() else { return nil }
        self.action = action
        id = HotKey.nextId
        HotKey.nextId += 1
        let hkID = EventHotKeyID(signature: OSType(0x524E_4E47), id: id) // 'RNNG'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            FileHandle.standardError.write("running: couldn't register a global shortcut (\(status))\n".data(using: .utf8)!)
            return nil
        }
        HotKey.all[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.all[id] = nil
    }

    private static func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard hk.signature == OSType(0x524E_4E47), let h = HotKey.all[hk.id] else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { h.action() }
            return noErr
        }, 1, &spec, nil, &handler)
        return status == noErr
    }

    /// The menu bar panel: ⌃⌥R (dev app: ⌃⌥⌘R).
    static func panel(_ action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: Variant.current.hotKeyModifiers, action: action)
    }

    /// The window: ⇧⌃⌥R (dev app: ⇧⌃⌥⌘R).
    static func window(_ action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: Variant.current.hotKeyModifiers | UInt32(shiftKey), action: action)
    }
}
