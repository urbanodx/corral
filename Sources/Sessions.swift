import Foundation

/// What a window title says about the session inside it.
/// Terminal titles look like "monorepo <em dash> ✳ manga <em dash> claude <em dash> 67×27". Claude Code
/// puts a glyph before its session name: ✳ when it is idle, a spinner (◐◓◑◒) while it works.
/// When Claude exits the glyph part stays, but the process part goes back to the shell ("-zsh").
struct TitleInfo: Equatable {
    let folder: String
    let name: String
    let isClaude: Bool
    let busy: Bool
    /// Claude's glyph is still in the title but the shell is back in front.
    let ended: Bool
    /// The process part when Terminal shows it ("claude --resume …", "-zsh").
    let process: String?

    static let idleGlyph: Character = "\u{2733}"   // ✳
    private static let separator = " \u{2014} "     // Terminal joins title parts with a spaced em dash

    static func parse(_ title: String) -> TitleInfo {
        let parts = title.components(separatedBy: separator)
        let folder = parts.first ?? title
        for (i, part) in parts.enumerated().dropFirst() {
            guard let glyph = part.first, isGlyph(glyph) else { continue }
            let rest = part.dropFirst()
            guard rest.first == " " else { continue }
            let name = rest.trimmingCharacters(in: .whitespaces)
            let process = i + 1 < parts.count && !isSize(parts[i + 1]) ? parts[i + 1] : nil
            let ended = process.map(isShell) ?? false
            return TitleInfo(folder: folder, name: name.isEmpty ? folder : name, isClaude: !ended,
                             busy: !ended && glyph != idleGlyph, ended: ended, process: process)
        }
        let process = parts.count > 1 && !isSize(parts[1]) ? parts[1] : nil
        return TitleInfo(folder: folder, name: process ?? title, isClaude: false, busy: false, ended: false, process: process)
    }

    private static func isGlyph(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        switch s.properties.generalCategory {
        case .otherSymbol: return true
        default: return "·✢✶✻✽".unicodeScalars.contains(s)
        }
    }

    /// "67×27": the window size Terminal appends.
    private static func isSize(_ s: String) -> Bool {
        let p = s.split(separator: "\u{00D7}")
        return p.count == 2 && p.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    static func isShell(_ process: String) -> Bool {
        let first = process.split(separator: " ").first.map(String.init) ?? process
        let program = (first.hasPrefix("-") ? String(first.dropFirst()) : first) as NSString
        return ["zsh", "bash", "sh", "fish", "login", "tcsh", "ksh", "dash", "nu"].contains(program.lastPathComponent)
    }
}

/// What a session is doing, from Claude's status file when there is one, else from the title.
enum Activity: Equatable {
    case shell              // no Claude in this window, or it exited
    case starting           // claude launched, no status yet
    case working
    case asking(String)     // blocked on you: a permission prompt, a question, a startup dialog
    case idle               // finished its turn

    var isAsking: Bool { if case .asking = self { return true }; return false }

    /// Short words for the menu.
    var askLabel: String? {
        guard case .asking(let what) = self else { return nil }
        switch what {
        case "permission prompt": return "permission"
        case "input needed": return "question"
        case "worker request": return "agent request"
        case "dialog open": return "dialog open"
        default: return what
        }
    }

    fileprivate var kind: Int {
        switch self {
        case .shell: return 0
        case .starting: return 1
        case .working: return 2
        case .asking: return 3
        case .idle: return 4
        }
    }
}

struct Session {
    let window: TermWindow
    let info: TitleInfo
    let account: String?
    let cwd: String?
    let activity: Activity
    /// When the current activity started (idle since, asking since).
    let since: Date?
    /// Claude finished and you have not looked at the window since.
    let waiting: Bool
    /// The front Terminal window while Terminal is the active app: you are looking at it.
    let front: Bool
    /// Claude ended its turn but a background shell it started is still running.
    var backgroundShell = false

    var id: Int { window.id }
    var isClaude: Bool { activity != .shell }
    /// Asking, or finished and not looked at.
    var needsYou: Bool { (activity.isAsking && !front) || waiting }

    var name: String {
        if info.isClaude || info.ended { return info.name }
        if activity != .shell { return info.folder }      // claude starting: no title yet
        return info.name
    }
}

/// Turns window snapshots into sessions and remembers who is waiting for you.
/// A session is waiting when Claude finished its turn after the last time its window was
/// the front Terminal window. `seenAt` is saved, so restarting Corral keeps that memory.
final class SessionTracker {
    private(set) var sessions: [Session] = []
    private(set) var seenAt: [Int: Date] = [:]
    /// Fallback timing when Claude gives none (title-only sessions): activity kind and when it began.
    private var began: [Int: (kind: Int, at: Date)] = [:]

    /// A claude process with no status file this long after launch is stuck at a startup
    /// prompt (trust this folder, login, resume picker).
    static let startupGrace: TimeInterval = 10

    func restore(seenAt: [Int: Date]) { self.seenAt = seenAt }

    func update(windows: [TermWindow], frontID: Int?, claude: [String: ClaudeProcess], now: Date = Date()) {
        var next: [Session] = []
        for w in windows {
            let info = TitleInfo.parse(w.title)
            let proc = claude[w.tty]
            var activity: Activity
            var since: Date?
            if let p = proc, let f = p.file {
                // Claude's own `agents --json` rule: idle is idle, waiting is waiting, anything
                // else is busy. "shell" means the turn ended with a background shell still running;
                // Claude resumes by itself when it finishes, so nothing waits for you yet.
                switch f.status {
                case "idle": activity = .idle
                case "waiting": activity = .asking(f.waitingFor ?? "input")
                default: activity = .working
                }
                since = f.statusSince
            } else if let p = proc, !info.isClaude, !info.ended {
                let stuck = now.timeIntervalSince(p.started) > Self.startupGrace
                activity = stuck ? .asking("startup prompt") : .starting
                since = stuck ? p.started.addingTimeInterval(Self.startupGrace) : p.started
            } else if info.isClaude {
                activity = info.busy ? .working : .idle
            } else {
                activity = .shell
            }
            if began[w.id] == nil {
                // First sight (Corral just started): if you had looked at this window before the
                // restart, assume nothing new happened since then.
                began[w.id] = (activity.kind, seenAt[w.id] ?? now)
            } else if began[w.id]?.kind != activity.kind {
                began[w.id] = (activity.kind, now)
            }
            let start = since ?? began[w.id]?.at ?? now

            let isFront = w.id == frontID
            if isFront { seenAt[w.id] = now }
            let waiting = activity == .idle && !isFront && (seenAt[w.id] ?? .distantPast) < start
            next.append(Session(window: w, info: info, account: proc?.account, cwd: proc?.file?.cwd,
                                activity: activity, since: activity == .shell ? nil : start,
                                waiting: waiting, front: isFront, backgroundShell: proc?.file?.status == "shell"))
        }
        let alive = Set(windows.map(\.id))
        began = began.filter { alive.contains($0.key) }
        sessions = next
    }

    /// Forget windows that no longer exist (only call with a snapshot you trust).
    func prune(alive: Set<Int>) {
        seenAt = seenAt.filter { alive.contains($0.key) }
    }

    func markSeen(_ id: Int, now: Date = Date()) {
        seenAt[id] = now
        sessions = sessions.map {
            $0.id == id ? Session(window: $0.window, info: $0.info, account: $0.account, cwd: $0.cwd,
                                  activity: $0.activity, since: $0.since, waiting: false, front: $0.front,
                                  backgroundShell: $0.backgroundShell) : $0
        }
    }

    /// Blocked on you, longest first.
    var asking: [Session] {
        sessions.filter { $0.activity.isAsking && !$0.front }.sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    /// Finished and not looked at, longest first.
    var waiting: [Session] {
        sessions.filter(\.waiting).sorted { ($0.since ?? .distantFuture) < ($1.since ?? .distantFuture) }
    }

    /// The order ⌃⌥N walks: whoever is blocked first, then whoever finished first.
    var attention: [Session] { asking + waiting }
}
