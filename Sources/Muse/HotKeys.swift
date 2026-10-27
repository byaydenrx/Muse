import Carbon
import Foundation

/// System-wide shortcuts (they work even while the window ignores clicks). No Accessibility permission needed.
enum HotKeys {
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false

    static func register(id: UInt32, keyCode: Int, modifiers: Int, handler: @escaping () -> Void) {
        if !installed {
            installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var hotKey = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                let id = hotKey.id
                DispatchQueue.main.async { HotKeys.handlers[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        handlers[id] = handler
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4D555345), id: id),
                            GetApplicationEventTarget(), 0, &ref)
    }
}
