import AppKit

/// One Terminal.app window as Terminal's AppleScript reports it.
struct TermWindow {
    let id: Int            // also the CGWindowID
    let title: String
    var frame: CGRect      // top-left-origin global points (replaced by the window server's value)
    let visible: Bool
    let minimized: Bool
    let tty: String        // selected tab, e.g. "ttys007"
    var onScreen = true    // false when the window server does not draw it (another Space)

    var tileable: Bool { visible && !minimized && onScreen }
}

/// Talks to Terminal.app over Apple Events. Needs one Automation consent
/// ("Corral wants to control Terminal"), no Accessibility permission.
final class TerminalBridge {
    static let bundleID = "com.apple.Terminal"

    enum Failure: Error {
        case notPermitted
        case script(String)
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    // Fast path: six Apple events for every window at once.
    private lazy var fastSnapshot = compiled("""
        with timeout of 3 seconds
            tell application id "com.apple.Terminal"
                return ({id, name, bounds, visible, miniaturized} of every window) & {tty of selected tab of every window}
            end tell
        end timeout
        """)

    // Slow path for when one window has no tab (e.g. a sheet): per-window, each in a try.
    private lazy var slowSnapshot = compiled("""
        with timeout of 3 seconds
            tell application id "com.apple.Terminal"
                set out to {}
                repeat with w in every window
                    try
                        set end of out to {id of w, name of w, bounds of w, visible of w, miniaturized of w, tty of selected tab of w}
                    end try
                end repeat
                return out
            end tell
        end timeout
        """)

    /// Never launches Terminal: returns [] when it is not running.
    func snapshot() -> Result<[TermWindow], Failure> {
        guard Self.isRunning else { return .success([]) }
        switch run(fastSnapshot) {
        case .success(let d):
            if let ws = parseColumns(d) { return .success(ws) }
        case .failure(.notPermitted):
            return .failure(.notPermitted)
        case .failure:
            break
        }
        return run(slowSnapshot).map(parseRows)
    }

    /// Fallback raise when Accessibility is not granted yet.
    func focus(_ id: Int) {
        guard Self.isRunning else { return }
        _ = run(compiled("""
            with timeout of 3 seconds
            tell application id "com.apple.Terminal"
                try
                    set index of window id \(id) to 1
                    set frontmost of window id \(id) to true
                end try
                activate
            end tell
            end timeout
            """))
    }

    // MARK: - plumbing

    private func compiled(_ source: String) -> NSAppleScript {
        let s = NSAppleScript(source: source)!
        var err: NSDictionary?
        s.compileAndReturnError(&err)
        return s
    }

    private func run(_ script: NSAppleScript) -> Result<NSAppleEventDescriptor, Failure> {
        var err: NSDictionary?
        let d = script.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 || code == -10004 { return .failure(.notPermitted) }
            return .failure(.script("\(code): \(err[NSAppleScript.errorMessage] as? String ?? "")"))
        }
        return .success(d)
    }

    private func items(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    private func rect(_ d: NSAppleEventDescriptor) -> CGRect? {
        let v = items(d).map { CGFloat($0.int32Value) }
        guard v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
    }

    private func shortTTY(_ s: String) -> String {
        s.hasPrefix("/dev/") ? String(s.dropFirst(5)) : s
    }

    /// {ids, names, bounds, visibles, minis, ttys}: nil if the columns disagree
    /// (a window opened or closed between two of the six events).
    private func parseColumns(_ d: NSAppleEventDescriptor) -> [TermWindow]? {
        let cols = items(d).map(items)
        guard cols.count == 6 else { return nil }
        let n = cols[0].count
        guard cols.allSatisfy({ $0.count == n }) else { return nil }
        var out: [TermWindow] = []
        for i in 0..<n {
            guard let r = rect(cols[2][i]) else { return nil }
            out.append(TermWindow(id: Int(cols[0][i].int32Value),
                                  title: cols[1][i].stringValue ?? "",
                                  frame: r,
                                  visible: cols[3][i].booleanValue,
                                  minimized: cols[4][i].booleanValue,
                                  tty: shortTTY(cols[5][i].stringValue ?? "")))
        }
        return out
    }

    private func parseRows(_ d: NSAppleEventDescriptor) -> [TermWindow] {
        items(d).compactMap { row in
            let f = items(row)
            guard f.count == 6, let r = rect(f[2]) else { return nil }
            return TermWindow(id: Int(f[0].int32Value), title: f[1].stringValue ?? "", frame: r,
                              visible: f[3].booleanValue, minimized: f[4].booleanValue,
                              tty: shortTTY(f[5].stringValue ?? ""))
        }
    }
}
