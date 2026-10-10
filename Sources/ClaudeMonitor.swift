import Foundation

/// What Claude Code writes about each running session in `<config dir>/sessions/<pid>.json`.
/// `status` is "busy", "shell" (turn over, a background shell still runs), "idle" or "waiting";
/// while waiting, `waitingFor` says on what ("permission prompt", "input needed",
/// "worker request", "dialog open").
struct SessionFile: Equatable, Decodable {
    let pid: Int
    var sessionId: String?
    var cwd: String?
    var name: String?
    var status: String?
    var waitingFor: String?
    var statusUpdatedAt: Double?     // ms since 1970
    var kind: String?                // "interactive" for a session you type into

    var statusSince: Date? { statusUpdatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    static func decode(_ data: Data) -> SessionFile? { try? JSONDecoder().decode(SessionFile.self, from: data) }
}

/// A `claude` process on a Terminal tty, with its status file when it has written one.
struct ClaudeProcess: Equatable {
    let pid: Int
    let tty: String
    let account: String
    let started: Date
    let file: SessionFile?
}

/// Finds the Claude process on every tty and what it reports about itself.
/// Each `claude` keeps its status files under its config dir: `~/.claude`, or whatever
/// `CLAUDE_CONFIG_DIR` says in that process's environment (one dir per account when you
/// run several). Session files are checked every poll (a stat per file, a parse only when
/// one changed); `ps` runs in the background every few seconds, or at once when a new tty
/// or pid shows up, and reads the environment of each new `claude` once.
final class ClaudeMonitor {
    private(set) var byTTY: [String: ClaudeProcess] = [:]

    struct Proc: Equatable {
        let pid: Int
        let tty: String
        let comm: String
        let started: Date
    }

    private struct Entry { let mtime: Date; let file: SessionFile? }
    private var entries: [String: Entry] = [:]                       // path -> parsed file
    private var files: [Int: (file: SessionFile, account: String)] = [:]
    private var procs: [Int: Proc] = [:]
    private var configDirs: [Int: String] = [:]                      // pid -> its config dir
    private var checkedPIDs: Set<Int> = []
    private var knownTTYs: Set<String> = []
    private var lastPS = Date.distantPast
    private var running = false
    private let queue = DispatchQueue(label: "corral.claude", qos: .utility)

    /// Call once a poll on the main thread. `onChange` runs when a background `ps` changed the picture.
    func update(ttys: Set<String>, now: Date = Date(), onChange: @escaping () -> Void) {
        let before = Set(files.keys)
        readFiles()
        let unknownPID = files.keys.contains { !checkedPIDs.contains($0) }
        let newTTY = !ttys.isSubset(of: knownTTYs)
        let exited = !before.isSubset(of: Set(files.keys))      // Claude removes its file when it exits
        if exited { lastPS = .distantPast }
        if !running, newTTY || unknownPID || now.timeIntervalSince(lastPS) > 3 {
            running = true
            let filePIDs = Set(files.keys)
            let known = configDirs
            queue.async {
                let ps = Self.readProcesses()
                let fresh = ps.values.filter { $0.tty.hasPrefix("ttys") && Self.isClaude($0.comm) && known[$0.pid] == nil }.map(\.pid)
                let dirs = Self.readConfigDirs(pids: fresh)
                DispatchQueue.main.async {
                    self.running = false
                    self.lastPS = Date()
                    self.knownTTYs = ttys
                    self.checkedPIDs = filePIDs
                    // etime has one-second steps: keep the first start time seen for a pid so it does not wobble.
                    self.procs = ps.mapValues { p in
                        guard let old = self.procs[p.pid], old.comm == p.comm else { return p }
                        return Proc(pid: p.pid, tty: p.tty, comm: p.comm, started: old.started)
                    }
                    self.configDirs = known.merging(dirs) { $1 }.filter { ps[$0.key] != nil }
                    if !Set(dirs.values).isSubset(of: Set(known.values)) { self.readFiles() }   // a new account
                    if self.rebuild() { onChange() }
                }
            }
        }
        _ = rebuild()
    }

    /// One `ps` call and a read of every session file, for `Corral --print`.
    func refreshNow() {
        procs = Self.readProcesses()
        configDirs = Self.readConfigDirs(pids: procs.values.filter { $0.tty.hasPrefix("ttys") && Self.isClaude($0.comm) }.map(\.pid))
        readFiles()
        checkedPIDs = Set(files.keys)
        _ = rebuild()
    }

    /// Per tty, the interactive session that wrote a status file wins, then any process
    /// with a file, then the lowest pid (a `claude -p` child shares its parent's tty).
    private func rebuild() -> Bool {
        var best: [String: ClaudeProcess] = [:]
        func rank(_ p: ClaudeProcess) -> Int { p.file == nil ? 0 : p.file?.kind == "interactive" ? 2 : 1 }
        for p in procs.values where p.tty.hasPrefix("ttys") {
            // A status file left by a dead session can name a pid a shell now has.
            let f = TitleInfo.isShell(p.comm) ? nil : files[p.pid]
            guard f != nil || Self.isClaude(p.comm) else { continue }
            let account = f?.account ?? configDirs[p.pid].map(Self.accountName) ?? "default"
            let c = ClaudeProcess(pid: p.pid, tty: p.tty, account: account, started: p.started, file: f?.file)
            if let cur = best[p.tty], (rank(cur), -cur.pid) >= (rank(c), -c.pid) { continue }
            best[p.tty] = c
        }
        let changed = best != byTTY
        byTTY = best
        return changed
    }

    private func readFiles() {
        let fm = FileManager.default
        var seen: Set<String> = []
        var next: [Int: (file: SessionFile, account: String)] = [:]
        for (account, dir) in Self.sessionDirs(configDirs: Set(configDirs.values)) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in names where name.hasSuffix(".json") {
                let path = dir + "/" + name
                seen.insert(path)
                guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
                var entry = entries[path]
                if entry?.mtime != mtime {
                    entry = Entry(mtime: mtime, file: fm.contents(atPath: path).flatMap(SessionFile.decode))
                    entries[path] = entry
                }
                if let f = entry?.file { next[f.pid] = (f, account) }
            }
        }
        entries = entries.filter { seen.contains($0.key) }
        files = next
    }

    static let defaultConfigDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude"

    /// `~/.claude` always, plus every other config dir a running `claude` uses.
    static func sessionDirs(configDirs: Set<String>) -> [(account: String, dir: String)] {
        let dirs = Set([defaultConfigDir]).union(configDirs)
        return dirs.sorted().map { (accountName($0), $0 + "/sessions") }
    }

    /// "default" for `~/.claude`, else the config dir's folder name without a leading dot
    /// (`~/.claude-accounts/work` -> "work", `~/.claude-personal` -> "claude-personal").
    static func accountName(_ dir: String) -> String {
        if dir == defaultConfigDir { return "default" }
        let name = (dir as NSString).lastPathComponent
        let trimmed = name.hasPrefix(".") ? String(name.dropFirst()) : name
        return trimmed.isEmpty ? "default" : trimmed
    }

    static func isClaude(_ comm: String) -> Bool {
        let program = (comm as NSString).lastPathComponent
        return program == "claude" || program == "claude.exe"
    }

    static func readProcesses(now: Date = Date()) -> [Int: Proc] {
        guard let text = run("/bin/ps", ["-A", "-o", "pid=,etime=,tty=,comm="]) else { return [:] }
        var out: [Int: Proc] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count == 4, let pid = Int(cols[0]) else { continue }
            out[pid] = Proc(pid: pid, tty: String(cols[2]), comm: String(cols[3]),
                            started: now.addingTimeInterval(-elapsed(String(cols[1]))))
        }
        return out
    }

    /// `ps` etime: "[[dd-]hh:]mm:ss".
    static func elapsed(_ s: String) -> TimeInterval {
        let dayParts = s.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        let secs = clock.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return days * 86400 + secs
    }

    /// Each process's config dir: CLAUDE_CONFIG_DIR from its environment (`ps eww`), else `~/.claude`.
    static func readConfigDirs(pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty,
              let text = run("/bin/ps", ["eww", "-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")]) else { return [:] }
        return parseConfigDirs(text)
    }

    static func parseConfigDirs(_ text: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [Int: String] {
        var out: [Int: String] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard cols.count == 2, let pid = Int(cols[0]) else { continue }
            var dir = home + "/.claude"
            if let r = cols[1].range(of: " CLAUDE_CONFIG_DIR=") {
                let value = String(cols[1][r.upperBound...].prefix { $0 != " " })
                if value.hasPrefix("/") { dir = value } else if value.hasPrefix("~/") { dir = home + value.dropFirst() }
            }
            out[pid] = (dir as NSString).standardizingPath
        }
        return out
    }

    private static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
