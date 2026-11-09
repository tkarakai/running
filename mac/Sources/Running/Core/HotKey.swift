import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut (Carbon's RegisterEventHotKey: needs no Accessibility permission).
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static var all: [UInt32: HotKey] = [:]
    private static var nextId: UInt32 = 1
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        id = HotKey.nextId
        HotKey.nextId += 1
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let h = HotKey.all[hk.id] { DispatchQueue.main.async { h.action() } }
            return noErr
        }, 1, &spec, nil, &handler)
        guard status == noErr else { return nil }
        let hkID = EventHotKeyID(signature: OSType(0x524E_4E47), id: id) // 'RNNG'
        guard RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return nil
        }
        HotKey.all[id] = self
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
        HotKey.all[id] = nil
    }

    /// ⌃⌥R
    static func controlOptionR(_ action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey), action: action)
    }
}

extension HotKey {
    /// ⇧⌃⌥R
    static func shiftControlOptionR(_ action: @escaping () -> Void) -> HotKey? {
        HotKey(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey | shiftKey), action: action)
    }
}
