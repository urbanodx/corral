import AppKit
import ApplicationServices

// Private but long-stable: maps an AX window to its CGWindowID. Rectangle,
// AeroSpace, yabai and Hammerspoon all rely on it.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Moves and raises Terminal windows through the Accessibility API.
/// Terminal's own AppleScript `bounds`/`position` setters are wrong on a
/// secondary display (they offset y by that display's top edge), so they are not used.
enum WindowMover {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that deep-links to Privacy & Security > Accessibility.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private static var terminalPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: TerminalBridge.bundleID).first?.processIdentifier
    }

    private static func windows() -> [Int: AXUIElement] {
        guard trusted, let pid = terminalPID else { return [:] }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [:] }
        var out: [Int: AXUIElement] = [:]
        for w in list {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(w, &id) == .success { out[Int(id)] = w }
        }
        return out
    }

    /// `frames` in top-left global coordinates, keyed by CGWindowID.
    /// Returns how many windows were moved.
    @discardableResult
    static func setFrames(_ frames: [Int: CGRect]) -> Int {
        let ax = windows()
        var moved = 0
        for (id, r) in frames {
            guard let w = ax[id] else { continue }
            // Size, then position, then size again: a window crossing displays
            // can be clamped by its old screen on the first resize.
            set(w, kAXSizeAttribute, r.size)
            set(w, kAXPositionAttribute, r.origin)
            set(w, kAXSizeAttribute, r.size)
            moved += 1
        }
        return moved
    }

    /// Raises one window, makes it main and brings Terminal forward.
    static func focus(_ id: Int) -> Bool {
        guard let w = windows()[id] else { return false }
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        NSRunningApplication.runningApplications(withBundleIdentifier: TerminalBridge.bundleID).first?
            .activate(options: [])
        return true
    }

    private static func set(_ w: AXUIElement, _ attr: String, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(w, attr as CFString, v) }
    }

    private static func set(_ w: AXUIElement, _ attr: String, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(w, attr as CFString, v) }
    }
}

/// Ground-truth on-screen frames from the window server (no permission needed).
enum WindowServer {
    static func terminalFrames() -> [Int: CGRect] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalBridge.bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [Int: CGRect] = [:]
        for w in list where (w[kCGWindowOwnerPID as String] as? Int) == Int(pid)
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let n = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            out[n] = r
        }
        return out
    }
}
