import CoreGraphics
import Foundation

// Tiny harness: no XCTest in the Command Line Tools.
var failures = 0
func check(_ cond: Bool, _ msg: String, line: Int = #line) {
    if !cond { failures += 1; print("FAIL line \(line): \(msg)") }
}

// 10 windows on a 1920x1080 display: 3 rows of 4, 3, 3.
let hd = CGRect(x: 2560, y: 186, width: 1920, height: 1080)
check(Layout.rowCounts(n: 10, area: hd.size, gap: 0) == [4, 3, 3], "10 on 1080p -> \(Layout.rowCounts(n: 10, area: hd.size, gap: 0))")
check(Layout.rowCounts(n: 1, area: hd.size, gap: 0) == [1], "1 window")
check(Layout.rowCounts(n: 2, area: hd.size, gap: 0) == [2], "2 side by side -> \(Layout.rowCounts(n: 2, area: hd.size, gap: 0))")
check(Layout.rowCounts(n: 4, area: hd.size, gap: 0) == [2, 2], "4 -> 2x2")
check(Layout.rowCounts(n: 0, area: hd.size, gap: 0) == [], "0 windows")

// Grid cells tile the area exactly: no overlap, full coverage, edges shared.
for n in 1...16 {
    for gap in [CGFloat(0), 4, 8] {
        let rects = Layout.grid(n: n, in: hd, gap: gap)
        check(rects.count == n, "count n=\(n)")
        for r in rects { check(hd.contains(r), "n=\(n) gap=\(gap) cell \(r) outside area") }
        for i in rects.indices { for j in rects.indices where i < j {
            check(!rects[i].intersects(rects[j]) || rects[i].intersection(rects[j]).isEmpty,
                  "n=\(n) gap=\(gap) overlap \(rects[i]) \(rects[j])")
        } }
        if gap == 0 {
            let area = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            check(area == hd.width * hd.height, "n=\(n) coverage \(area)")
        }
        check(rects.allSatisfy { $0.origin.x == $0.origin.x.rounded() && $0.width == $0.width.rounded() }, "integral n=\(n)")
    }
}

// Focus: main pane first, takes the fraction, others to its right.
let f = Layout.focus(n: 5, in: hd, gap: 0, mainFraction: 0.6)
check(f.count == 5, "focus count")
check(f[0].width == 1152 && f[0].height == 1080 && f[0].minX == hd.minX, "focus main \(f[0])")
check(f.dropFirst().allSatisfy { $0.minX >= f[0].maxX }, "focus side right of main")
check(Layout.focus(n: 1, in: hd, gap: 0, mainFraction: 0.6) == [hd], "focus single = full")

// Split by area, largest remainder, sums to n.
let builtIn = CGRect(x: -1728, y: 355, width: 1728, height: 1085)
check(Layout.split(n: 10, areas: [hd, builtIn]) == [5, 5], "split 10 -> \(Layout.split(n: 10, areas: [hd, builtIn]))")
check(Layout.split(n: 3, areas: [hd]) == [3], "split single")
check(Layout.split(n: 0, areas: [hd, builtIn]) == [0, 0], "split zero")
for n in 0...20 { check(Layout.split(n: n, areas: [hd, builtIn, CGRect(x: 0, y: 0, width: 2560, height: 1343)]).reduce(0, +) == n, "split sum n=\(n)") }

// Reading order: screens left to right, rows top to bottom, then left to right.
let screens = [builtIn, hd]
let items: [(id: Int, frame: CGRect)] = [
    (1, CGRect(x: 3000, y: 600, width: 400, height: 300)),   // hd, row 2
    (2, CGRect(x: 2600, y: 200, width: 400, height: 300)),   // hd, row 1 left
    (3, CGRect(x: 3400, y: 210, width: 400, height: 300)),   // hd, row 1 right (same bucket)
    (4, CGRect(x: -1000, y: 900, width: 400, height: 300)),  // built-in
    (5, CGRect(x: 9000, y: 9000, width: 10, height: 10)),    // off every screen: nearest = hd
]
check(Layout.readingOrder(items, screens: screens) == [4, 2, 3, 1, 5], "reading order \(Layout.readingOrder(items, screens: screens))")

// Re-tiling a tiled grid keeps the order.
let cells = Layout.grid(n: 10, in: hd, gap: 4)
let tiled = cells.enumerated().map { (id: 100 + $0.offset, frame: $0.element) }
check(Layout.readingOrder(tiled.shuffled(), screens: screens) == tiled.map(\.id), "stable re-tile")

// Rows: a window a few points off its row still reads in that row (no bucket edge at y=240).
let straddle: [(id: Int, frame: CGRect)] = [
    (1, CGRect(x: 3200, y: 241, width: 400, height: 300)),
    (2, CGRect(x: 2600, y: 239, width: 400, height: 300)),
    (3, CGRect(x: 2600, y: 600, width: 400, height: 300)),
]
check(Layout.readingOrder(straddle, screens: screens) == [2, 1, 3], "straddle \(Layout.readingOrder(straddle, screens: screens))")

// Drop target: the cell under the point, else the nearest.
let dropCells: [Int: CGRect] = [1: CGRect(x: 0, y: 0, width: 100, height: 100), 2: CGRect(x: 104, y: 0, width: 100, height: 100)]
check(Layout.cell(at: CGPoint(x: 150, y: 50), in: dropCells) == 2, "drop on cell 2")
check(Layout.cell(at: CGPoint(x: 101, y: 50), in: dropCells) == 1, "drop in gap goes to nearest")
check(Layout.cell(at: CGPoint(x: 500, y: 50), in: dropCells) == 2, "drop far right goes to nearest")
check(Layout.cell(at: .zero, in: [:]) == nil, "no cells")

// Dropping a dragged window.
let slotA = CGRect(x: 0, y: 30, width: 500, height: 400), slotB = CGRect(x: 504, y: 30, width: 500, height: 400)
let tiledScreens = [CGRect(x: 0, y: 0, width: 1008, height: 800)]
let slotsAB: [Int: CGRect] = [1: slotA, 2: slotB]
// A dragged onto B's slot, pointer in A's title bar: A moves there.
check(Layout.drop(at: CGPoint(x: 700, y: 45), slots: slotsAB, sizes: [:], frames: [1: CGRect(x: 600, y: 35, width: 500, height: 400), 2: slotB],
                  screens: tiledScreens) == .move(1, 2), "drag onto another slot moves there")
// A nudged a little: back to its slot.
check(Layout.drop(at: CGPoint(x: 100, y: 75), slots: slotsAB, sizes: [:], frames: [1: CGRect(x: 40, y: 70, width: 500, height: 400), 2: slotB],
                  screens: tiledScreens) == .snapBack(1), "small drag snaps back")
// A dragged to another display: float.
check(Layout.drop(at: CGPoint(x: -500, y: 300), slots: slotsAB, sizes: [:], frames: [1: CGRect(x: -800, y: 280, width: 500, height: 400), 2: slotB],
                  screens: tiledScreens) == .float(1), "drag off the tiled display floats")
// Nothing moved (a click or a text selection): nothing to do. Moves under the threshold do not count.
check(Layout.drop(at: CGPoint(x: 100, y: 100), slots: slotsAB, sizes: [:], frames: [1: slotA, 2: slotB], screens: tiledScreens) == .none, "click")
check(Layout.drop(at: CGPoint(x: 100, y: 100), slots: slotsAB, sizes: [:], frames: [1: slotA.offsetBy(dx: 3, dy: 0), 2: slotB],
                  screens: tiledScreens) == .none, "rounding wobble is not a drag")

// Resizing B from its left edge moves its origin but also its size: not a drag (review finding).
check(Layout.drop(at: CGPoint(x: 300, y: 200), slots: slotsAB, sizes: [:], frames: [1: slotA, 2: CGRect(x: 300, y: 30, width: 704, height: 400)],
                  screens: tiledScreens) == .none, "left-edge resize is not a drag")
// A window moved from the keyboard, then a click somewhere else: the pointer is not on it, nothing happens.
check(Layout.drop(at: CGPoint(x: 100, y: 100), slots: slotsAB, sizes: [:], frames: [1: slotA, 2: CGRect(x: 600, y: 300, width: 500, height: 400)],
                  screens: tiledScreens) == .none, "keyboard move plus an unrelated click")
// Sizes compare against what the window settled at (Terminal rounding), not the slot.
check(Layout.drop(at: CGPoint(x: 700, y: 45), slots: slotsAB, sizes: [1: CGSize(width: 471, height: 395)],
                  frames: [1: CGRect(x: 600, y: 35, width: 471, height: 395), 2: slotB], screens: tiledScreens) == .move(1, 2), "settled size drag")

// Moving: the first window to the end, the last to the front, one step, an unknown id.
check(Layout.moving(1, to: 3, in: [1, 2, 3, 4]) == [2, 3, 4, 1], "first to last")
check(Layout.moving(4, to: 0, in: [1, 2, 3, 4]) == [4, 1, 2, 3], "last to first")
check(Layout.moving(2, to: 2, in: [1, 2, 3, 4]) == [1, 3, 2, 4], "one forward")
check(Layout.moving(3, to: 1, in: [1, 2, 3, 4]) == [1, 3, 2, 4], "one back")
check(Layout.moving(9, to: 0, in: [1, 2]) == [1, 2], "unknown id")
check(Layout.moving(1, to: 99, in: [1, 2, 3]) == [2, 3, 1], "index clamped")

// Needs you first: pending in the order given, the rest as they were; not-tiled ids ignored.
check(Layout.needsYouFirst([1, 2, 3, 4, 5], pending: [4, 9, 2]) == [4, 2, 1, 3, 5], "needs you first")
check(Layout.needsYouFirst([1, 2, 3], pending: []) == [1, 2, 3], "nobody pending")
check(Layout.needsYouFirst([1, 2, 3], pending: [3, 3]) == [3, 1, 2], "duplicate pending")

// Writing a new slot order back: a minimised window (9) keeps its place, new ones go last, no crash on duplicates.
check(Layout.reordered([1, 9, 2, 3, 4], visible: [2, 3, 4, 1]) == [2, 9, 3, 4, 1], "hidden window keeps its place")
check(Layout.reordered([1, 9, 2], visible: [3, 2, 1]) == [3, 9, 2, 1], "a tiled window order did not know: tiled ones in the new order, 9 stays")
check(Layout.reordered([1, 1, 2], visible: [2, 1]) == [2, 1], "duplicates in order")
check(Layout.reordered([], visible: [2, 1]) == [2, 1], "empty order")

// Up and down: 14 windows in rows of 5, 5 and 4.
check(Layout.rowCounts(n: 14, area: hd.size, gap: 4) == [5, 5, 4], "14 on 1080p -> \(Layout.rowCounts(n: 14, area: hd.size, gap: 4))")
let grid14 = Dictionary(uniqueKeysWithValues: Layout.grid(n: 14, in: hd, gap: 4).enumerated().map { ($0.offset + 1, $0.element) })
check(Layout.neighbour(of: 7, up: true, frames: grid14) == 2, "up from 7")
check(Layout.neighbour(of: 2, up: false, frames: grid14) == 7, "down from 2")
check(Layout.neighbour(of: 7, up: false, frames: grid14) == 12, "down from 7 to the closest wider cell \(String(describing: Layout.neighbour(of: 7, up: false, frames: grid14)))")
check(Layout.neighbour(of: 3, up: true, frames: grid14) == nil, "nothing above the top row")
check(Layout.neighbour(of: 11, up: false, frames: grid14) == nil, "nothing below the bottom row")
// A window on a display to the right is never above or below.
var twoScreens = grid14
twoScreens[99] = CGRect(x: 0, y: 0, width: 800, height: 300)
check(Layout.neighbour(of: 1, up: true, frames: twoScreens) == nil, "other display is not above")

// Any display size: every count from 1 to 20 fills the area, inside it, without overlaps.
let displays: [CGSize] = [CGSize(width: 1280, height: 800), CGSize(width: 1440, height: 900), CGSize(width: 1512, height: 982),
                          CGSize(width: 1728, height: 1117), CGSize(width: 1920, height: 1080), CGSize(width: 2560, height: 1440),
                          CGSize(width: 3008, height: 1692), CGSize(width: 3840, height: 2160), CGSize(width: 5120, height: 2880),
                          CGSize(width: 1080, height: 1920)]
for size in displays {
    let area = CGRect(origin: CGPoint(x: -size.width, y: 30), size: size).insetBy(dx: 4, dy: 4)
    for n in 1...20 {
        let rects = Layout.grid(n: n, in: area, gap: 4)
        let counts = Layout.rowCounts(n: n, area: area.size, gap: 4)
        check(rects.count == n, "\(size) n=\(n) count")
        check((counts.max() ?? 0) - (counts.min() ?? 0) <= 1, "\(size) n=\(n) uneven rows \(counts)")
        for r in rects { check(area.contains(r) && r.width > 0 && r.height > 0, "\(size) n=\(n) cell \(r) outside") }
        for i in rects.indices { for j in rects.indices where i < j {
            check(rects[i].intersection(rects[j]).isEmpty, "\(size) n=\(n) overlap")
        } }
    }
}

// Terminal rounding: 519 high slot came out 525 -> ask for 506, which rounds to 511.
let shrunk = Layout.shrunkRequest(request: CGSize(width: 635, height: 519), target: CGSize(width: 635, height: 519),
                                  actual: CGSize(width: 632, height: 525))
check(shrunk == CGSize(width: 635, height: 506), "shrunk \(shrunk)")
check(Layout.shrunkRequest(request: CGSize(width: 400, height: 300), target: CGSize(width: 400, height: 300),
                           actual: CGSize(width: 401, height: 297)) == CGSize(width: 400, height: 300), "1 pt over is fine")

// Titles.
let busy = TitleInfo.parse("monorepo \u{2014} \u{25D1} Rain4d home VPS deployment \u{2014} caffeinate \u{25C2} claude --dangerously-skip-permissions \u{2014} 63\u{00D7}34")
check(busy.isClaude && busy.busy && busy.name == "Rain4d home VPS deployment" && !busy.ended, "busy title \(busy)")
let idle = TitleInfo.parse("monorepo \u{2014} \u{2733} Claude Code \u{2014} claude --dangerously-skip-permissions \u{2014} 55\u{00D7}28")
check(idle.isClaude && !idle.busy && idle.name == "Claude Code", "idle title \(idle)")
let ended = TitleInfo.parse("monorepo \u{2014} \u{2733} tiktok \u{2014} -zsh \u{2014} 75\u{00D7}28")
check(!ended.isClaude && ended.ended && ended.name == "tiktok", "ended title \(ended)")
let noProcess = TitleInfo.parse("monorepo \u{2014} \u{2733} manga \u{2014} 67\u{00D7}27")
check(noProcess.isClaude && noProcess.process == nil, "title without process part \(noProcess)")
let shell = TitleInfo.parse("monorepo \u{2014} -zsh \u{2014} 85\u{00D7}34")
check(!shell.isClaude && shell.name == "-zsh" && !shell.ended, "shell title \(shell)")
let launching = TitleInfo.parse("monorepo \u{2014} claude --dangerously-skip-permissions --resume c864 \u{2014} 80\u{00D7}24")
check(!launching.isClaude && launching.process?.hasPrefix("claude") == true, "launching title \(launching)")
check(TitleInfo.isShell("-zsh") && TitleInfo.isShell("/bin/bash -l") && !TitleInfo.isShell("ssh home-vps"), "isShell")

// Claude's own status file.
let json = #"{"pid":26754,"sessionId":"24196c98","cwd":"/Users/me/code/app","name":"app-0e","status":"waiting","waitingFor":"permission prompt","statusUpdatedAt":1791671672647,"kind":"interactive","peerFeatures":["notify_idle"]}"#
let sf = SessionFile.decode(Data(json.utf8))
check(sf?.pid == 26754 && sf?.status == "waiting" && sf?.waitingFor == "permission prompt" && sf?.kind == "interactive", "session file \(String(describing: sf))")
check(sf?.statusSince == Date(timeIntervalSince1970: 1791671672.647), "statusSince")
check(SessionFile.decode(Data("{}".utf8)) == nil, "file without pid is ignored")
check(ClaudeMonitor.elapsed("05:07") == 307 && ClaudeMonitor.elapsed("01:00:01") == 3601 && ClaudeMonitor.elapsed("2-00:00:10") == 172810, "etime")

// Config dirs from `ps eww` output: CLAUDE_CONFIG_DIR, "~/" expanded, trailing slash dropped, else ~/.claude.
let envText = """
  101 claude --resume x TERM=xterm CLAUDE_CONFIG_DIR=/Users/me/.claude-accounts/work HOME=/Users/me
  102 claude PATH=/bin CLAUDE_CONFIG_DIR=~/.claude-personal/ HOME=/Users/me
  103 claude PATH=/bin HOME=/Users/me
"""
let dirs = ClaudeMonitor.parseConfigDirs(envText, home: "/Users/me")
check(dirs == [101: "/Users/me/.claude-accounts/work", 102: "/Users/me/.claude-personal", 103: "/Users/me/.claude"], "config dirs \(dirs)")
check(ClaudeMonitor.accountName("/Users/me/.claude-accounts/work") == "work"
      && ClaudeMonitor.accountName("/Users/me/.claude-personal") == "claude-personal"
      && ClaudeMonitor.accountName(ClaudeMonitor.defaultConfigDir) == "default", "account names")

// Sessions: status file beats the title; finished + unseen = waiting; front = seen.
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func win(_ id: Int, _ title: String, tty: String) -> TermWindow {
    TermWindow(id: id, title: title, frame: CGRect(x: 0, y: 0, width: 10, height: 10), visible: true, minimized: false, tty: tty)
}
func file(_ pid: Int, _ status: String, _ waitingFor: String? = nil, at: Date) -> SessionFile {
    SessionFile(pid: pid, status: status, waitingFor: waitingFor, statusUpdatedAt: at.timeIntervalSince1970 * 1000, kind: "interactive")
}
let idleTitle = "m \u{2014} \u{2733} a \u{2014} claude"
let ws = [win(1, idleTitle, tty: "ttys001"), win(2, idleTitle, tty: "ttys002"), win(3, idleTitle, tty: "ttys003"),
          win(4, "m \u{2014} claude --resume x", tty: "ttys004"), win(5, "m \u{2014} -zsh", tty: "ttys005")]
let procs: [String: ClaudeProcess] = [
    "ttys001": ClaudeProcess(pid: 11, tty: "ttys001", account: "work", started: t0, file: file(11, "waiting", "permission prompt", at: t0)),
    "ttys002": ClaudeProcess(pid: 12, tty: "ttys002", account: "personal", started: t0, file: file(12, "busy", at: t0)),
    "ttys003": ClaudeProcess(pid: 13, tty: "ttys003", account: "default", started: t0, file: file(13, "idle", at: t0)),
    "ttys004": ClaudeProcess(pid: 14, tty: "ttys004", account: "personal", started: t0, file: nil),
]
let tracker = SessionTracker()
tracker.update(windows: ws, frontID: nil, claude: procs, now: t0.addingTimeInterval(5))
let byID = Dictionary(uniqueKeysWithValues: tracker.sessions.map { ($0.id, $0) })
check(byID[1]?.activity == .asking("permission prompt") && byID[1]?.activity.askLabel == "permission", "asking from file")
check(byID[2]?.activity == .working, "file says busy although the title says idle")
check(byID[3]?.activity == .idle && byID[3]?.waiting == true, "idle, never seen = waiting")
check(byID[4]?.activity == .starting && byID[4]?.account == "personal", "starting inside the grace period")
check(byID[5]?.activity == .shell && byID[5]?.waiting == false, "plain shell")
check(tracker.attention.map(\.id) == [1, 3], "attention order \(tracker.attention.map(\.id))")

tracker.update(windows: ws, frontID: 3, claude: procs, now: t0.addingTimeInterval(20))
let later = Dictionary(uniqueKeysWithValues: tracker.sessions.map { ($0.id, $0) })
check(later[3]?.waiting == false, "front window is seen")
check(later[4]?.activity == .asking("startup prompt"), "no status file after the grace period = stuck at a startup prompt")
tracker.update(windows: ws, frontID: nil, claude: procs, now: t0.addingTimeInterval(30))
check(tracker.sessions.first { $0.id == 3 }?.waiting == false, "stays seen after you look away")

// Restart: a restored seenAt keeps an already-seen idle session quiet.
let restarted = SessionTracker()
restarted.restore(seenAt: tracker.seenAt)
restarted.update(windows: ws, frontID: nil, claude: procs, now: t0.addingTimeInterval(40))
check(restarted.sessions.first { $0.id == 3 }?.waiting == false, "seen state survives a restart")
// It finishes again later: waiting again.
var again = procs
again["ttys003"] = ClaudeProcess(pid: 13, tty: "ttys003", account: "default", started: t0, file: file(13, "idle", at: t0.addingTimeInterval(60)))
restarted.update(windows: ws, frontID: nil, claude: again, now: t0.addingTimeInterval(61))
check(restarted.sessions.first { $0.id == 3 }?.waiting == true, "finished after you looked = waiting")

// "shell": the turn ended with a background shell running; Claude resumes by itself, so it is working (review finding).
let shellProcs = ["ttys003": ClaudeProcess(pid: 13, tty: "ttys003", account: "default", started: t0, file: file(13, "shell", at: t0))]
let shellTracker = SessionTracker()
shellTracker.update(windows: [ws[2]], frontID: nil, claude: shellProcs, now: t0)
check(shellTracker.sessions.first?.activity == .working && shellTracker.sessions.first?.backgroundShell == true
      && shellTracker.waiting.isEmpty, "shell status = working, not waiting")
let futureProcs = ["ttys003": ClaudeProcess(pid: 13, tty: "ttys003", account: "default", started: t0, file: file(13, "something-new", at: t0))]
shellTracker.update(windows: [ws[2]], frontID: nil, claude: futureProcs, now: t0)
check(shellTracker.sessions.first?.activity == .working, "unknown status = working")

// Claude just exited (title shows the shell again) while ps still lists its pid: a shell, not a startup prompt.
let exitTracker = SessionTracker()
exitTracker.update(windows: [win(8, "m \u{2014} \u{2733} tiktok \u{2014} -zsh", tty: "ttys008")], frontID: nil,
                   claude: ["ttys008": ClaudeProcess(pid: 18, tty: "ttys008", account: "work", started: t0, file: nil)],
                   now: t0.addingTimeInterval(600))
check(exitTracker.sessions.first?.activity == .shell, "exiting claude is not asking")

// Title-only session seen before a restart: still quiet after it.
let titleOnly = SessionTracker()
titleOnly.restore(seenAt: [7: t0])
titleOnly.update(windows: [win(7, "m \u{2014} \u{2733} remote \u{2014} ssh home-vps", tty: "ttys007")], frontID: nil, claude: [:],
                 now: t0.addingTimeInterval(100))
check(titleOnly.sessions.first?.activity == .idle && titleOnly.waiting.isEmpty, "title-only seen session stays quiet after a restart")

// An ended Claude session (glyph left in the title, shell in front) is a shell, not a waiting session.
let endedTracker = SessionTracker()
endedTracker.update(windows: [win(9, "m \u{2014} \u{2733} tiktok \u{2014} -zsh", tty: "ttys009")], frontID: nil, claude: [:], now: t0)
check(endedTracker.sessions.first?.activity == .shell && endedTracker.waiting.isEmpty, "ended session is quiet")

if failures == 0 { print("tests: all passed") } else { print("tests: \(failures) failed"); exit(1) }
