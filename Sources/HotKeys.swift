import AppKit
import Carbon.HIToolbox

/// Global shortcuts through Carbon's RegisterEventHotKey: works without
/// Accessibility or Input Monitoring permission.
final class HotKeys {
    static let shared = HotKeys()

    struct Binding {
        let keyCode: Int
        let label: String      // what the menu shows, e.g. "⌃⌥T"
        let action: () -> Void
    }

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false
    private(set) var failed: [String] = []

    /// All shortcuts use Control+Option: Option alone types characters on
    /// many European layouts (Spanish, German, French...), and ⌃⌥Space is the macOS input switcher.
    static let modifiers = UInt32(controlKey | optionKey)

    func register(_ b: Binding) {
        installHandler()
        let id = UInt32(actions.count + 1)
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4352_4C4C), id: id)   // 'CRLL'
        let status = RegisterEventHotKey(UInt32(b.keyCode), Self.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            actions[id] = b.action
            refs.append(ref)
        } else {
            failed.append(b.label)
            NSLog("Corral: could not register \(b.label) (status \(status))")
        }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum Key {
    static let t = kVK_ANSI_T, f = kVK_ANSI_F, n = kVK_ANSI_N, z = kVK_ANSI_Z
    static let s = kVK_ANSI_S, o = kVK_ANSI_O
    static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                         kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
}
