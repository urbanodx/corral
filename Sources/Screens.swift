import AppKit

/// A display in top-left-origin global coordinates (Terminal's space).
struct ScreenInfo {
    let id: String          // display UUID: survives reconnects, unlike names such as "DELL (1)" / "(2)"
    let name: String
    let frame: CGRect
    let usable: CGRect      // minus menu bar and Dock

    /// Every display, left to right.
    static func all() -> [ScreenInfo] {
        guard let mainHeight = NSScreen.screens.first?.frame.maxY else { return [] }
        func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height) }
        return NSScreen.screens.map { s in
            var usable = flip(s.visibleFrame)
            // With "Displays have separate Spaces" a secondary display can report a
            // visibleFrame that still includes its menu bar; never tile under it.
            let bar = s.safeAreaInsets.top > 0 ? s.safeAreaInsets.top : menuBarHeight
            if usable.minY == flip(s.frame).minY {
                usable.origin.y += bar
                usable.size.height -= bar
            }
            return ScreenInfo(id: s.displayUUID, name: s.localizedName, frame: flip(s.frame), usable: usable)
        }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// A Cocoa point (bottom-left origin, e.g. `NSEvent.mouseLocation`) in top-left global coordinates.
    static func topLeft(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - p.y)
    }

    static var menuBarHeight: CGFloat {
        let h = NSStatusBar.system.thickness
        return h > 0 ? h : 24
    }
}

extension NSScreen {
    var displayUUID: String {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue(),
              let s = CFUUIDCreateString(nil, uuid) as String? else { return localizedName }
        return s
    }
}

/// Preferences in UserDefaults (com.urbanodx.corral).
final class Settings {
    private let d = UserDefaults.standard

    init() {
        d.register(defaults: [
            "autoTile": true,
            "highlightWaiting": true,
            "gap": 4.0,
            "mainFraction": 0.6,
        ])
    }

    var autoTile: Bool {
        get { d.bool(forKey: "autoTile") }
        set { d.set(newValue, forKey: "autoTile") }
    }
    var highlightWaiting: Bool {
        get { d.bool(forKey: "highlightWaiting") }
        set { d.set(newValue, forKey: "highlightWaiting") }
    }
    var gap: CGFloat {
        get { CGFloat(d.double(forKey: "gap")) }
        set { d.set(Double(newValue), forKey: "gap") }
    }
    var mainFraction: CGFloat { CGFloat(d.double(forKey: "mainFraction")) }

    /// Display UUIDs the terminals are tiled onto. Empty = not chosen yet.
    var screenIDs: [String] {
        get { d.stringArray(forKey: "screens") ?? [] }
        set { d.set(newValue, forKey: "screens") }
    }

    // Layout state that survives a restart of Corral. Window ids only mean something while the
    // same Terminal process runs (they start over after a reboot), so the state carries
    // Terminal's launch time and is dropped when Terminal has been relaunched.

    var terminalLaunch: Double? {
        get { d.object(forKey: "terminalLaunch") as? Double }
        set { if let newValue { d.set(newValue, forKey: "terminalLaunch") } else { d.removeObject(forKey: "terminalLaunch") } }
    }

    var floating: Set<Int> {
        get { Set((d.array(forKey: "floating") as? [Int]) ?? []) }
        set { d.set(newValue.sorted(), forKey: "floating") }
    }

    /// The main window of the focus layout, nil for the grid.
    var focusMain: Int? {
        get { d.object(forKey: "focusMain") as? Int }
        set { if let newValue { d.set(newValue, forKey: "focusMain") } else { d.removeObject(forKey: "focusMain") } }
    }

    /// When each window was last looked at, so a restart does not mark every idle session as waiting.
    var seenAt: [Int: Date] {
        get {
            let raw = d.dictionary(forKey: "seenAt") as? [String: Double] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, Date(timeIntervalSince1970: v)) } })
        }
        set { d.set(Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value.timeIntervalSince1970) }), forKey: "seenAt") }
    }
}
