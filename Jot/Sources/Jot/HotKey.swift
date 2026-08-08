import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut.
///
/// Carbon's `RegisterEventHotKey` rather than an `NSEvent` global monitor,
/// deliberately: a global monitor needs the Accessibility permission, and an app
/// whose whole point is "press a key, start typing" should not open with a
/// permissions dialog and a trip to System Settings. Carbon needs nothing.
///
/// The API is ancient and the callback is a C function pointer, so the mapping
/// from hot-key id back to a Swift closure lives in a file-scope table.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `key` is a Carbon virtual key code (`kVK_ANSI_N`), `modifiers` a Carbon
    /// mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    init?(key: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x53544B59), id: id)  // 'STKY'
        let status = RegisterEventHotKey(UInt32(key), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            Self.handlers[id] = nil
            return nil
        }
        _ = hotKeyID
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        let id = self.id
        DispatchQueue.main.async { HotKey.handlers[id] = nil }
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            DispatchQueue.main.async { HotKey.handlers[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The shortcuts this app claims, in one place so they can be read at a glance
/// and changed without hunting.
enum Shortcuts {
    /// ⌃⌥Space — a new sticky, focused, ready to type.
    ///
    /// Not ⌘-anything: every app owns its own ⌘ keys and a global one would
    /// steal from whatever is in front. Control-Option is nearly unclaimed, and
    /// Space is reachable without looking.
    static let newSticky = (key: kVK_Space, mods: controlKey | optionKey)

    /// ⌃⌥S — show every sticky, or hide them all if they are already up.
    static let toggleAll = (key: kVK_ANSI_S, mods: controlKey | optionKey)
}
