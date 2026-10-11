import AppKit
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var corral: Corral?

    static func main() {
        let args = CommandLine.arguments
        if args.contains("--print") {
            Corral().printReport()
            return
        }
        if let i = args.firstIndex(of: "--open-at-login") {
            let on = i + 1 >= args.count || args[i + 1] != "off"
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                print("open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
            } catch {
                print("open at login failed: \(error)")
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = Corral()
        c.start()
        corral = c
    }

    func applicationWillTerminate(_ notification: Notification) {
        corral?.saveState()
    }
}

/// The whole app: polls Terminal once a second, tiles its windows onto the
/// chosen displays, tracks which Claude sessions need you, and draws the menu.
final class Corral: NSObject, NSMenuDelegate {
    enum Mode: Equatable { case grid, focus(Int) }
    enum Problem { case automation, accessibility, script(String) }

    /// What Corral asked of a window and what Terminal made of it.
    private struct Placement {
        var target: CGRect      // the slot
        var request: CGSize     // the size asked for (smaller than the slot once Terminal rounded it up)
        var actual: CGRect?     // where the window settled; nil while a move is in flight
    }

    private let bridge = TerminalBridge()
    private let tracker = SessionTracker()
    private let claude = ClaudeMonitor()
    private let borders = Borders()
    private let settings = Settings()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var windows: [TermWindow] = []
    private var mode: Mode = .grid
    private var floating: Set<Int> = []
    private var known: Set<Int> = []          // windows that have been tiled at least once
    private var lastTiled: Set<Int>?          // nil until the first tile
    private var order: [Int] = []             // slot order; windows that left keep their place for when they return
    private var placements: [Int: Placement] = [:]
    private var undoStack: [[Int: CGRect]] = []
    private var lastPending: Set<Int> = []    // sessions that needed you at the last poll
    private var pendingTile: DispatchWorkItem?
    private var problem: Problem?
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var savedSeenAt: [Int: Date] = [:]
    private var lastSave = Date()
    private var shownStatus = ""
    private var reportOnly = false            // `--print`: look, never move or listen
    private var termSource: DispatchSourceSignal?

    private var tileable: [TermWindow] { windows.filter { $0.tileable && !floating.contains($0.id) } }

    // MARK: - lifecycle

    func start() {
        floating = settings.floating
        if let main = settings.focusMain { mode = .focus(main) }
        tracker.restore(seenAt: settings.seenAt)
        savedSeenAt = tracker.seenAt

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.imagePosition = .imageLeading
        registerHotKeys()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, self.settings.autoTile else { return }
            self.scheduleTile(after: 1.0)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.poll() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.poll() }

        installTerminationHandler()
        if !WindowMover.trusted { WindowMover.requestTrust() }
        // One synchronous ps first, so the first frame does not fall back to titles and
        // paint every idle session orange for a moment.
        claude.refreshNow()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    private func registerHotKeys() {
        let hk = HotKeys.shared
        hk.register(.init(keyCode: Key.t, label: "⌃⌥T") { [weak self] in self?.tileGrid() })
        hk.register(.init(keyCode: Key.f, label: "⌃⌥F") { [weak self] in self?.toggleFocusLayout() })
        hk.register(.init(keyCode: Key.n, label: "⌃⌥N") { [weak self] in self?.nextNeedingYou() })
        hk.register(.init(keyCode: Key.o, label: "⌃⌥O") { [weak self] in self?.toggleFloat() })
        hk.register(.init(keyCode: Key.z, label: "⌃⌥Z") { [weak self] in self?.undoLayout() })
        hk.register(.init(keyCode: Key.s, label: "⌃⌥S") { [weak self] in self?.openMenu() })
        hk.register(.init(keyCode: Key.p, label: "⌃⌥P") { [weak self] in self?.needsYouFirst() })
        hk.register(.init(keyCode: Key.left, label: "⌃⌥←") { [weak self] in self?.moveFront(by: -1) })
        hk.register(.init(keyCode: Key.right, label: "⌃⌥→") { [weak self] in self?.moveFront(by: 1) })
        hk.register(.init(keyCode: Key.up, label: "⌃⌥↑") { [weak self] in self?.moveFrontRow(up: true) })
        hk.register(.init(keyCode: Key.down, label: "⌃⌥↓") { [weak self] in self?.moveFrontRow(up: false) })
        hk.register(.init(keyCode: Key.left, modifiers: HotKeys.withShift, label: "⌃⌥⇧←") { [weak self] in self?.moveFrontToEnd(first: true) })
        hk.register(.init(keyCode: Key.right, modifiers: HotKeys.withShift, label: "⌃⌥⇧→") { [weak self] in self?.moveFrontToEnd(first: false) })
        for (i, code) in Key.digits.enumerated() {
            hk.register(.init(keyCode: code, label: "⌃⌥\(i + 1)") { [weak self] in self?.focusSlot(i) })
        }
    }

    /// Writes what has to survive a restart. Floating and focus are written when they change;
    /// `seenAt` changes every second while you look at a window, so it is written every 15 s.
    func saveState() {
        guard tracker.seenAt != savedSeenAt else { return }
        settings.seenAt = tracker.seenAt
        savedSeenAt = tracker.seenAt
        lastSave = Date()
    }

    /// `make install` and `pkill` send SIGTERM, which ends an AppKit app without
    /// `applicationWillTerminate`: save first, then exit.
    private func installTerminationHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.saveState()
            exit(0)
        }
        source.resume()
        termSource = source
    }

    private func setMode(_ m: Mode) {
        mode = m
        if case .focus(let main) = m { settings.focusMain = main } else { settings.focusMain = nil }
    }

    private func setFloating(_ ids: Set<Int>) {
        floating = ids
        settings.floating = ids
    }

    // MARK: - polling

    private func poll() {
        var trusted = false
        switch bridge.snapshot() {
        case .failure(.notPermitted):
            problem = .automation
            windows = []
        case .failure(.script(let message)):
            problem = .script(message)     // keep the last good snapshot
        case .success(var ws):
            problem = WindowMover.trusted ? nil : .accessibility
            let truth = WindowServer.terminalFrames()
            for i in ws.indices {
                if let f = truth[ws[i].id] { ws[i].frame = f } else { ws[i].onScreen = false }
            }
            windows = ws
            trusted = true
        }
        if trusted { forgetClosedWindows() }

        claude.update(ttys: Set(windows.map(\.tty))) { [weak self] in
            self?.updateSessions()
            self?.refreshStatus()
        }
        updateSessions()
        if reportOnly { return }
        installMouseMonitor()
        keepNeedsYouFirst()

        if settings.autoTile, WindowMover.trusted, pendingTile == nil {
            let ids = Set(tileable.map(\.id))
            if ids != lastTiled, !ids.isEmpty || lastTiled != nil {
                // New windows settle their own size first; give them a moment.
                scheduleTile(after: lastTiled == nil ? 0 : 0.5)
            }
        }
        refreshStatus()
        if Date().timeIntervalSince(lastSave) > 15 { saveState() }
    }

    private func updateSessions() {
        let front = TerminalBridge.isFrontmost ? windows.first(where: \.tileable)?.id : nil
        tracker.update(windows: windows, frontID: front, claude: claude.byTTY)
    }

    /// Drops state about windows that no longer exist. Only runs on a snapshot Terminal answered.
    private func forgetClosedWindows() {
        if let launch = NSRunningApplication.runningApplications(withBundleIdentifier: TerminalBridge.bundleID)
            .first?.launchDate?.timeIntervalSince1970 {
            if let saved = settings.terminalLaunch, abs(saved - launch) > 1 {
                // Terminal was relaunched (or the Mac rebooted): saved window ids now name other windows.
                setFloating([])
                setMode(.grid)
                tracker.restore(seenAt: [:])
            }
            if settings.terminalLaunch != launch { settings.terminalLaunch = launch }
        }
        let alive = Set(windows.map(\.id))
        if !floating.isSubset(of: alive) { setFloating(floating.intersection(alive)) }
        if case .focus(let main) = mode, !alive.contains(main) { setMode(.grid) }
        order = order.filter(alive.contains)
        placements = placements.filter { alive.contains($0.key) }
        tracker.prune(alive: alive)
    }

    // MARK: - layout

    private func scheduleTile(after delay: TimeInterval) {
        pendingTile?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingTile = nil
            self?.tile()
        }
        pendingTile = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func tileGrid() {
        setMode(.grid)
        tile(fromFrames: true)
    }

    /// `fromFrames`: read the slot order from where the windows are now (an explicit tile, or
    /// auto-tile switched back on) instead of keeping the last order.
    private func tile(fromFrames: Bool = false) {
        pendingTile?.cancel()
        pendingTile = nil
        guard WindowMover.trusted else { WindowMover.requestTrust(); return }
        // Fresh frames: the last poll can be up to a second old (a drag that just ended).
        let truth = WindowServer.terminalFrames()
        let ws = tileable.map { w -> TermWindow in
            var w = w
            if let f = truth[w.id] { w.frame = f }
            return w
        }
        let (slots, frames) = plan(ws, fromFrames: fromFrames)
        guard !frames.isEmpty || slots.isEmpty else { return }
        if fromFrames || order.isEmpty {
            order = slots
        } else {
            let inOrder = Set(order)
            order += slots.filter { !inOrder.contains($0) }
        }
        lastTiled = Set(slots)
        known.formUnion(slots)

        // Move only what is not already where it belongs: every resize makes a Claude
        // session redraw its whole screen.
        let current = Dictionary(ws.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        var moves: [Int: CGRect] = [:]
        var next: [Int: Placement] = [:]
        for (id, target) in frames {
            var p = placements[id].flatMap { $0.target.size == target.size ? $0 : nil }
                ?? Placement(target: target, request: target.size, actual: nil)
            let settled = p.target == target && p.actual != nil && current[id].map { Layout.close($0, p.actual!) } == true
            p.target = target
            if !settled {
                p.actual = nil
                moves[id] = CGRect(origin: target.origin, size: p.request)
            }
            next[id] = p
        }
        placements = next
        guard !moves.isEmpty else { return }
        pushUndo(moves.keys.compactMap { id in current[id].map { (id, $0) } })
        WindowMover.setFrames(moves)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.fitOverflow() }
    }

    /// One correction round after a tile: Terminal rounds a window to whole character cells
    /// and can make it a few points bigger than its slot, so it overlaps the next one.
    /// Those windows are asked again for a smaller size, which is remembered for that slot size.
    private func fitOverflow() {
        let truth = WindowServer.terminalFrames()
        var fixes: [Int: CGRect] = [:]
        for (id, var p) in placements where p.actual == nil {
            guard let a = truth[id] else { continue }
            let atSlot = abs(a.minX - p.target.minX) <= 2 && abs(a.minY - p.target.minY) <= 2
            var request = Layout.shrunkRequest(request: p.request, target: p.target.size, actual: a.size)
            // A learned smaller request that now lands well short (the font got smaller): start over.
            if a.width < p.target.width - 16, request.width < p.target.width { request.width = p.target.width }
            if a.height < p.target.height - 16, request.height < p.target.height { request.height = p.target.height }
            if atSlot, request != p.request, request.width > 100, request.height > 60 {
                p.request = request
                fixes[id] = CGRect(origin: p.target.origin, size: request)
            } else {
                p.actual = a
            }
            placements[id] = p
        }
        guard !fixes.isEmpty else { poll(); return }
        WindowMover.setFrames(fixes)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            let truth = WindowServer.terminalFrames()
            for id in fixes.keys { if let a = truth[id] { self.placements[id]?.actual = a } }
            self.poll()
        }
    }

    /// Where every tileable window goes, without moving anything.
    private func plan(_ ws: [TermWindow], fromFrames: Bool = false) -> (order: [Int], frames: [Int: CGRect]) {
        let targets = targetScreens()
        guard !targets.isEmpty else { return ([], [:]) }
        let slots = tileOrder(ws, fromFrames: fromFrames)
        let gap = settings.gap
        var frames: [Int: CGRect] = [:]
        var next = 0
        for (screen, count) in zip(targets, Layout.split(n: slots.count, areas: targets.map(\.usable))) {
            let ids = Array(slots[next..<next + count])
            next += count
            let area = screen.usable.insetBy(dx: gap, dy: gap)
            if case .focus(let main) = mode, let at = ids.firstIndex(of: main) {
                var rest = ids
                rest.remove(at: at)
                let rects = Layout.focus(n: ids.count, in: area, gap: gap, mainFraction: settings.mainFraction)
                for (id, r) in zip([main] + rest, rects) { frames[id] = r }
            } else {
                for (id, r) in zip(ids, Layout.grid(n: ids.count, in: area, gap: gap)) { frames[id] = r }
            }
        }
        return (slots, frames)
    }

    /// Auto-tiles keep the last slot order and put new windows last. An explicit tile, or the
    /// first one, reads the order from where the windows are (windows never tiled before go last).
    private func tileOrder(_ ws: [TermWindow], fromFrames: Bool) -> [Int] {
        let ids = ws.map(\.id)
        if !fromFrames, !order.isEmpty {
            let present = Set(ids)
            let kept = order.filter(present.contains)
            let keptSet = Set(kept)
            return kept + ids.filter { !keptSet.contains($0) }.sorted()
        }
        let firstTime = known.isEmpty
        let old = ws.filter { firstTime || known.contains($0.id) }
        let new = ws.filter { !firstTime && !known.contains($0.id) }.map(\.id).sorted()
        return Layout.readingOrder(old.map { (id: $0.id, frame: $0.frame) }, screens: ScreenInfo.all().map(\.frame)) + new
    }

    /// Chosen displays that are connected; otherwise the display holding the most terminals.
    private func targetScreens() -> [ScreenInfo] {
        let all = ScreenInfo.all()
        let chosen = all.filter { settings.screenIDs.contains($0.id) }
        if !chosen.isEmpty { return chosen }
        let counts = all.map { s in
            windows.filter { $0.tileable && s.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }.count
        }
        guard let best = counts.indices.max(by: { counts[$0] < counts[$1] }) else { return [] }
        if settings.screenIDs.isEmpty, counts[best] > 0 { settings.screenIDs = [all[best].id] }
        return [all[best]]
    }

    private func pushUndo(_ frames: [(Int, CGRect)]) {
        undoStack.append(Dictionary(frames, uniquingKeysWith: { a, _ in a }))
        if undoStack.count > 20 { undoStack.removeFirst() }
    }

    private func undoLayout() {
        guard let last = undoStack.popLast() else { NSSound.beep(); return }
        WindowMover.setFrames(last)
        // The next tile reads the order from where the windows are now.
        order = []
        placements = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    private var frontWindowID: Int? { windows.first(where: \.tileable)?.id }

    private func toggleFocusLayout() {
        guard let front = frontWindowID else { NSSound.beep(); return }
        setMode(mode == .focus(front) ? .grid : .focus(front))
        if floating.contains(front) { setFloating(floating.subtracting([front])) }
        tile()
    }

    private func toggleFloat() {
        guard let front = frontWindowID else { NSSound.beep(); return }
        setFloating(floating.symmetricDifference([front]))
        if settings.autoTile { tile() } else { refreshStatus() }
    }

    // MARK: - reordering

    /// The tiled windows in slot order, as the next tile places them. In the focus layout the
    /// main pane stays where it is, so it is left out.
    private var movableSequence: [Int] {
        let seq = tileOrder(tileable, fromFrames: false)
        if case .focus(let main) = mode { return seq.filter { $0 != main } }
        return seq
    }

    /// Puts the windows in `visible` in this slot order; every other window keeps its place.
    /// Returns false when nothing changes.
    @discardableResult
    private func setSlotOrder(_ visible: [Int]) -> Bool {
        let base = order + tileOrder(tileable, fromFrames: false).filter { !order.contains($0) }
        let next = Layout.reordered(base, visible: visible)
        guard next != base else { return false }
        order = next
        return true
    }

    private func reorderAndTile(_ visible: [Int]) {
        if setSlotOrder(visible) { tile() } else { NSSound.beep() }
    }

    /// The front window moves one slot back or forward; the window there takes its place.
    private func moveFront(by step: Int) {
        let seq = movableSequence
        guard let id = frontWindowID, let i = seq.firstIndex(of: id), seq.indices.contains(i + step) else {
            NSSound.beep(); return
        }
        reorderAndTile(Layout.moving(id, to: i + step, in: seq))
    }

    /// The front window goes to the first or the last slot; everyone in between shifts by one.
    private func moveFrontToEnd(first: Bool) {
        let seq = movableSequence
        guard let id = frontWindowID, seq.contains(id) else { NSSound.beep(); return }
        reorderAndTile(Layout.moving(id, to: first ? 0 : seq.count - 1, in: seq))
    }

    /// The front window swaps with the window above or below it.
    private func moveFrontRow(up: Bool) {
        let seq = movableSequence
        let frames = plan(tileable).frames.filter { seq.contains($0.key) }
        guard let id = frontWindowID, let i = seq.firstIndex(of: id),
              let other = Layout.neighbour(of: id, up: up, frames: frames), let j = seq.firstIndex(of: other) else {
            NSSound.beep(); return
        }
        var next = seq
        next.swapAt(i, j)
        reorderAndTile(next)
    }

    /// Sessions that need you take the first slots: asking longest first, then finished longest first.
    private func needsYouFirst() {
        let seq = movableSequence
        reorderAndTile(Layout.needsYouFirst(seq, pending: tracker.attention.map(\.id)))
    }

    /// With "Keep sessions that need you first" on: when a session starts asking or finishes, the
    /// ones that need you move to the first slots. Nothing moves back once you have dealt with one,
    /// so the window you are typing in only moves when another session starts needing you.
    private func keepNeedsYouFirst() {
        let pending = tracker.attention.map(\.id)
        let current = Set(pending)
        guard settings.needsYouFirst, settings.autoTile, !current.isSubset(of: lastPending) else {
            lastPending = current
            return
        }
        // Not in the middle of a drag or another tile: try again at the next poll.
        guard WindowMover.trusted, pendingTile == nil, NSEvent.pressedMouseButtons == 0 else { return }
        lastPending = current
        if setSlotOrder(Layout.needsYouFirst(movableSequence, pending: pending)) { tile() }
    }

    // MARK: - dragging

    /// Watches for the mouse button going up while Terminal is in front: that is the end
    /// of a window drag. Needs the Accessibility grant, so it is installed once that exists.
    private func installMouseMonitor() {
        guard mouseMonitor == nil, WindowMover.trusted else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            guard let self, TerminalBridge.isFrontmost, self.settings.autoTile else { return }
            let point = ScreenInfo.topLeft(NSEvent.mouseLocation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.handleDrop(at: point) }
        }
    }

    /// After you drag a tiled window and let go: dropped on another slot, it moves there and the
    /// windows in between shift by one; dropped on a display Corral does not tile onto, it floats
    /// there; anywhere else it snaps back. In the focus layout a drop onto or from the main pane
    /// swaps the two windows, so the main pane always holds one.
    private func handleDrop(at point: CGPoint) {
        guard pendingTile == nil, WindowMover.trusted, !placements.isEmpty else { return }
        let result = Layout.drop(at: point, slots: placements.mapValues(\.target),
                                 sizes: placements.mapValues { $0.actual?.size ?? $0.request },
                                 frames: WindowServer.terminalFrames(), screens: targetScreens().map(\.frame))
        switch result {
        case .none:
            return
        case .snapBack:
            break
        case .float(let id):
            setFloating(floating.union([id]))
            if mode == .focus(id) { setMode(.grid) }
        case .move(let id, let other):
            if case .focus(let main) = mode, main == id || main == other {
                if let i = order.firstIndex(of: id), let j = order.firstIndex(of: other) { order.swapAt(i, j) }
                setMode(.focus(main == id ? other : id))
            } else {
                let seq = movableSequence
                if let to = seq.firstIndex(of: other) { setSlotOrder(Layout.moving(id, to: to, in: seq)) }
            }
        }
        tile()
    }

    // MARK: - focus

    private func focus(_ id: Int) {
        if !WindowMover.focus(id) { bridge.focus(id) }
        tracker.markSeen(id)
        refreshStatus()
    }

    private func nextNeedingYou() {
        guard let s = tracker.attention.first else { NSSound.beep(); return }
        focus(s.id)
    }

    /// Slots follow the grid: 1 is top-left of the leftmost display.
    private var slotOrder: [Int] {
        let visible = windows.filter(\.tileable)
        return Layout.readingOrder(visible.map { (id: $0.id, frame: $0.frame) }, screens: ScreenInfo.all().map(\.frame))
    }

    private func focusSlot(_ index: Int) {
        let slots = slotOrder
        guard index < slots.count else { NSSound.beep(); return }
        focus(slots[index])
    }

    private func openMenu() {
        statusItem.button?.performClick(nil)
    }

    // MARK: - diagnostics

    /// `Corral --print`: what Corral sees and where it would tile, without moving anything.
    func printReport() {
        reportOnly = true
        tracker.restore(seenAt: settings.seenAt)
        floating = settings.floating
        if let main = settings.focusMain { mode = .focus(main) }
        poll()
        claude.refreshNow()
        updateSessions()
        if let problem { print("problem: \(problem)") }
        print("accessibility trusted: \(WindowMover.trusted)")
        for s in ScreenInfo.all() { print("screen \(s.name) frame \(s.frame) usable \(s.usable) id \(s.id)") }
        print("tile onto: \(targetScreens().map(\.name))")
        let (order, frames) = plan(tileable)
        for s in tracker.sessions {
            let state: String
            switch s.activity {
            case .shell: state = s.info.ended ? "ended" : "shell"
            case .starting: state = "starting"
            case .working: state = "working"
            case .asking: state = "asking:\(s.activity.askLabel ?? "")"
            case .idle: state = s.waiting ? "waiting" : "idle"
            }
            let slot = floating.contains(s.id) ? "floating" : order.firstIndex(of: s.id).map { "slot \($0 + 1)" } ?? "not tiled"
            print("\(s.id)\t\(s.window.tty)\t\(state)\t\(s.account ?? "-")\t\(s.name)\t\(slot)\tnow \(s.window.frame)\t-> \(frames[s.id].map { "\($0)" } ?? "-")")
        }
    }

    // MARK: - status item

    private func refreshStatus() {
        let asking = tracker.asking.count
        let waiting = tracker.waiting.count
        let working = tracker.sessions.filter { $0.activity == .working }.count
        let symbol = problem == nil ? "rectangle.grid.2x2" : "exclamationmark.triangle"
        let key = "\(symbol) \(asking) \(waiting)"
        if let button = statusItem.button, key != shownStatus {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Corral")
            image?.isTemplate = true
            button.image = image
            if asking == 0 {
                button.title = waiting == 0 ? "" : " \(waiting)"
            } else {
                // Asking in red with a "!", finished count beside it in the normal colour.
                let font = NSFont.menuBarFont(ofSize: 0)
                let title = NSMutableAttributedString(string: " \(asking)!", attributes: [
                    .font: NSFont.boldSystemFont(ofSize: font.pointSize), .foregroundColor: NSColor.systemRed,
                ])
                if waiting > 0 {
                    title.append(NSAttributedString(string: " \(waiting)", attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
                }
                button.attributedTitle = title
            }
            shownStatus = key
        }
        statusItem.button?.toolTip = "Corral: \(asking) asking, \(waiting) finished and waiting, \(working) working"
        if settings.highlightWaiting {
            var targets: [Int: Borders.Target] = [:]
            for s in tracker.sessions where s.needsYou && s.window.tileable {
                targets[s.id] = .init(frame: s.window.frame, color: s.activity.isAsking ? .systemRed : .systemOrange)
            }
            borders.show(targets)
        } else {
            borders.hideAll()
        }
    }

    // MARK: - menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        poll()
        menu.removeAllItems()
        let sessions = tracker.sessions
        let asking = sessions.filter { $0.activity.isAsking }.count
        let waiting = sessions.filter(\.waiting).count
        let working = sessions.filter { $0.activity == .working }.count
        let idle = sessions.filter { s in (s.activity == .idle && !s.waiting) || s.activity == .starting }.count
        let pairs: [(Int, String)] = [(asking, "asking"), (waiting, "waiting"), (working, "working"), (idle, "idle")]
        let counts = pairs.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        menu.addItem(disabled(windows.isEmpty ? "No Terminal windows"
                              : counts.isEmpty ? "No Claude sessions" : counts.joined(separator: " · ")))

        switch problem {
        case .automation?:
            menu.addItem(action("Allow Corral to read Terminal windows…", #selector(openAutomationSettings)))
        case .accessibility?:
            menu.addItem(action("Allow Corral to move windows (Accessibility)…", #selector(grantAccessibility)))
        case .script(let m)?:
            menu.addItem(disabled("Terminal did not answer: \(m.prefix(60))"))
        case nil:
            break
        }
        menu.addItem(.separator())

        let tileItem = action("Tile terminals", #selector(menuTile), key: "t")
        tileItem.state = mode == .grid ? .on : .off
        menu.addItem(tileItem)
        let focusItem = action("Focus layout for front window", #selector(menuFocus), key: "f")
        if case .focus = mode { focusItem.state = .on }
        menu.addItem(focusItem)
        menu.addItem(action("Jump to the session that needs you", #selector(menuNextWaiting), key: "n"))
        menu.addItem(action("Put sessions that need you first", #selector(menuNeedsYouFirst), key: "p"))
        let move = NSMenuItem(title: "Move front window", action: nil, keyEquivalent: "")
        move.submenu = moveMenu()
        menu.addItem(move)
        menu.addItem(action("Float front window (leave it out of the grid)", #selector(menuFloat), key: "o"))
        let undo = action("Undo last layout", #selector(menuUndo), key: "z")
        undo.isEnabled = !undoStack.isEmpty
        menu.addItem(undo)
        menu.addItem(.separator())

        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let slots = slotOrder
        let offGrid = sessions.filter { !slots.contains($0.id) }.map(\.id)
        for (i, id) in (slots + offGrid).enumerated() {
            guard let s = byID[id] else { continue }
            let item = NSMenuItem(title: s.name, action: #selector(menuFocusSession(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.id
            item.image = dot(color(for: s))
            item.attributedTitle = sessionTitle(s)
            if i < 9, slots.contains(id) {
                item.keyEquivalent = "\(i + 1)"
                item.keyEquivalentModifierMask = [.control, .option]
            }
            menu.addItem(item)
        }
        if !sessions.isEmpty { menu.addItem(.separator()) }

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu()
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let commit = info?["CorralCommit"] as? String ?? "local"
        menu.addItem(disabled("Corral \(version) (\(commit))"))
        if !HotKeys.shared.failed.isEmpty {
            menu.addItem(disabled("Shortcuts taken by another app: \(HotKeys.shared.failed.joined(separator: " "))"))
        }
        let quit = NSMenuItem(title: "Quit Corral", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func moveMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let items: [(String, Selector, Int, Bool)] = [
            ("To the first slot", #selector(menuMoveFirst), NSLeftArrowFunctionKey, true),
            ("To the last slot", #selector(menuMoveLast), NSRightArrowFunctionKey, true),
            ("One slot back", #selector(menuMoveBack), NSLeftArrowFunctionKey, false),
            ("One slot forward", #selector(menuMoveForward), NSRightArrowFunctionKey, false),
            ("Up a row", #selector(menuMoveUp), NSUpArrowFunctionKey, false),
            ("Down a row", #selector(menuMoveDown), NSDownArrowFunctionKey, false),
        ]
        for (title, selector, key, shift) in items {
            let item = action(title, selector, key: Unicode.Scalar(UInt32(key)).map { String(Character($0)) } ?? "")
            if shift { item.keyEquivalentModifierMask.insert(.shift) }
            m.addItem(item)
        }
        m.addItem(.separator())
        m.addItem(disabled("Or drag a window onto another slot"))
        return m
    }

    private func settingsMenu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        let auto = action("Auto-tile when windows open or close", #selector(toggleAutoTile))
        auto.state = settings.autoTile ? .on : .off
        m.addItem(auto)
        let hl = action("Frame sessions that need you (red asking, orange finished)", #selector(toggleHighlight))
        hl.state = settings.highlightWaiting ? .on : .off
        m.addItem(hl)
        let first = action("Keep sessions that need you first (moves windows on its own)", #selector(toggleNeedsYouFirst))
        first.state = settings.needsYouFirst ? .on : .off
        m.addItem(first)
        m.addItem(.separator())

        m.addItem(disabled("Tile onto"))
        let chosen = Set(targetScreens().map(\.id))
        for s in ScreenInfo.all() {
            let item = action("\(s.name)  \(Int(s.frame.width))×\(Int(s.frame.height))", #selector(toggleScreen(_:)))
            item.representedObject = s.id
            item.state = chosen.contains(s.id) ? .on : .off
            item.indentationLevel = 1
            m.addItem(item)
        }
        m.addItem(.separator())

        m.addItem(disabled("Gap between windows"))
        for g in [0, 4, 8, 12] {
            let item = action(g == 0 ? "None" : "\(g) pt", #selector(setGap(_:)))
            item.tag = g
            item.state = Int(settings.gap) == g ? .on : .off
            item.indentationLevel = 1
            m.addItem(item)
        }
        m.addItem(.separator())
        let login = action("Open at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        return m
    }

    private func sessionTitle(_ s: Session) -> NSAttributedString {
        let t = NSMutableAttributedString(string: s.name, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        var detail: [String] = []
        if let a = s.account { detail.append(a) }
        let age = s.since.map(Self.age) ?? ""
        switch s.activity {
        case .shell: detail.append(s.info.ended ? "ended" : s.info.folder)
        case .starting: detail.append("starting")
        case .working: detail.append(s.backgroundShell ? "background shell" : "working")
        case .asking: detail.append("asks: \(s.activity.askLabel ?? "") \(age)")
        case .idle: detail.append((s.waiting ? "waiting " : "idle ") + age)
        }
        if floating.contains(s.id) { detail.append("floating") }
        if !s.window.tileable { detail.append(s.window.minimized ? "minimized" : "other Space") }
        t.append(NSAttributedString(string: "   " + detail.joined(separator: " · "), attributes: [
            .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: s.activity.isAsking ? NSColor.systemRed : NSColor.secondaryLabelColor,
        ]))
        return t
    }

    private static func age(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    private func color(for s: Session) -> NSColor {
        switch s.activity {
        case .shell: return .tertiaryLabelColor
        case .asking: return .systemRed
        case .working: return .systemGreen
        case .idle where s.waiting: return .systemOrange
        default: return .secondaryLabelColor
        }
    }

    private func dot(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10), flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = [.control, .option] }
        return item
    }

    // MARK: - menu actions

    @objc private func menuTile() { tileGrid() }
    @objc private func menuFocus() { toggleFocusLayout() }
    @objc private func menuNextWaiting() { nextNeedingYou() }
    @objc private func menuFloat() { toggleFloat() }
    @objc private func menuUndo() { undoLayout() }
    @objc private func menuNeedsYouFirst() { needsYouFirst() }
    @objc private func menuMoveFirst() { moveFrontToEnd(first: true) }
    @objc private func menuMoveLast() { moveFrontToEnd(first: false) }
    @objc private func menuMoveBack() { moveFront(by: -1) }
    @objc private func menuMoveForward() { moveFront(by: 1) }
    @objc private func menuMoveUp() { moveFrontRow(up: true) }
    @objc private func menuMoveDown() { moveFrontRow(up: false) }

    @objc private func menuFocusSession(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? Int { focus(id) }
    }

    @objc private func toggleAutoTile() {
        settings.autoTile.toggle()
        if settings.autoTile { tile(fromFrames: true) }
    }

    @objc private func toggleNeedsYouFirst() {
        settings.needsYouFirst.toggle()
        lastPending = []      // on: the sessions that already need you move first now
    }

    @objc private func toggleHighlight() {
        settings.highlightWaiting.toggle()
        refreshStatus()
    }

    @objc private func toggleScreen(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var ids = Set(targetScreens().map(\.id))
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        guard !ids.isEmpty else { NSSound.beep(); return }
        settings.screenIDs = Array(ids)
        tile()
    }

    @objc private func setGap(_ sender: NSMenuItem) {
        settings.gap = CGFloat(sender.tag)
        tile()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Corral: open at login failed: \(error)")
            NSSound.beep()
        }
    }

    @objc private func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }

    @objc private func grantAccessibility() {
        WindowMover.requestTrust()
        WindowMover.openAccessibilitySettings()
    }
}
