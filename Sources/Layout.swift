import CoreGraphics

/// Pure layout math. Every rectangle uses the top-left-origin global space that
/// Terminal's AppleScript `bounds` uses (y grows downward from the top of the main screen).
enum Layout {
    /// Width over height a cell should aim for. 80x24 Terminal at 11 pt is about 1.5.
    static let targetAspect: CGFloat = 1.5
    /// Cells smaller than this are heavily penalised.
    static let minCell = CGSize(width: 320, height: 200)

    /// Windows per row for `n` windows in `area`, top row first.
    /// Tries every row count and keeps the one whose cells sit closest to `targetAspect`.
    static func rowCounts(n: Int, area: CGSize, gap: CGFloat) -> [Int] {
        guard n > 0 else { return [] }
        var best = [n]
        var bestScore = CGFloat.infinity
        for rows in 1...n {
            let base = n / rows, extra = n % rows
            let counts = (0..<rows).map { $0 < extra ? base + 1 : base }
            let h = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            var score: CGFloat = 0
            for c in counts {
                let w = (area.width - gap * CGFloat(c - 1)) / CGFloat(c)
                guard w > 0, h > 0 else { score = .infinity; break }
                var s = abs(log((w / h) / targetAspect))
                if w < minCell.width || h < minCell.height { s += 10 }
                score += s * CGFloat(c)
            }
            if score < bestScore { bestScore = score; best = counts }
        }
        return best
    }

    /// `n` cells filling `area` with no empty slots: rows with fewer windows get wider cells.
    static func grid(n: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        let counts = rowCounts(n: n, area: area.size, gap: gap)
        let rows = CGFloat(counts.count)
        let h = (area.height - gap * (rows - 1)) / rows
        var rects: [CGRect] = []
        for (i, c) in counts.enumerated() {
            let w = (area.width - gap * CGFloat(c - 1)) / CGFloat(c)
            let top = area.minY + CGFloat(i) * (h + gap)
            for j in 0..<c {
                let left = area.minX + CGFloat(j) * (w + gap)
                rects.append(snapped(left, top, left + w, top + h))
            }
        }
        return rects
    }

    /// One big main pane on the left, the rest gridded in the column to its right.
    /// The first rect returned is the main pane.
    static func focus(n: Int, in area: CGRect, gap: CGFloat, mainFraction: CGFloat) -> [CGRect] {
        guard n > 1 else { return n == 1 ? [snapped(area.minX, area.minY, area.maxX, area.maxY)] : [] }
        let mainW = (area.width - gap) * mainFraction
        let main = snapped(area.minX, area.minY, area.minX + mainW, area.maxY)
        let side = CGRect(x: area.minX + mainW + gap, y: area.minY,
                          width: area.width - mainW - gap, height: area.height)
        return [main] + grid(n: n - 1, in: side, gap: gap)
    }

    /// Splits `n` windows across areas in proportion to their size (largest remainder).
    static func split(n: Int, areas: [CGRect]) -> [Int] {
        let sizes = areas.map { max(0, $0.width * $0.height) }
        let total = sizes.reduce(0, +)
        guard total > 0, n > 0 else { return areas.map { _ in 0 } }
        let exact = sizes.map { CGFloat(n) * $0 / total }
        var counts = exact.map { Int($0.rounded(.down)) }
        var left = n - counts.reduce(0, +)
        let byRemainder = exact.indices.sorted {
            let a = exact[$0] - CGFloat(counts[$0]), b = exact[$1] - CGFloat(counts[$1])
            return a == b ? $0 < $1 : a > b
        }
        for i in byRemainder where left > 0 { counts[i] += 1; left -= 1 }
        return counts
    }

    /// Windows whose top edges are this close sit in the same row.
    static let rowTolerance: CGFloat = 40

    /// Orders windows the way you read a page: screen by screen (left to right),
    /// then rows top to bottom, then left to right. Re-tiling a tiled layout keeps
    /// its order. A row starts at its highest window and takes every window whose
    /// top is within `rowTolerance` of it, so a window a few points off still reads in its row.
    static func readingOrder(_ items: [(id: Int, frame: CGRect)], screens: [CGRect]) -> [Int] {
        func screenIndex(_ r: CGRect) -> Int {
            let c = CGPoint(x: r.midX, y: r.midY)
            if let i = screens.firstIndex(where: { $0.contains(c) }) { return i }
            let d = screens.map { hypot($0.midX - c.x, $0.midY - c.y) }
            return d.indices.min(by: { d[$0] < d[$1] }) ?? 0
        }
        let keyed = items.map { (id: $0.id, s: screenIndex($0.frame), frame: $0.frame) }
        var out: [Int] = []
        for s in Set(keyed.map(\.s)).sorted() {
            let byTop = keyed.filter { $0.s == s }.sorted {
                $0.frame.minY != $1.frame.minY ? $0.frame.minY < $1.frame.minY : $0.id < $1.id
            }
            var rows: [[(id: Int, s: Int, frame: CGRect)]] = []
            var rowTop = -CGFloat.infinity
            for item in byTop {
                if item.frame.minY - rowTop > rowTolerance {
                    rows.append([item])
                    rowTop = item.frame.minY
                } else {
                    rows[rows.count - 1].append(item)
                }
            }
            for row in rows {
                out += row.sorted { $0.frame.minX != $1.frame.minX ? $0.frame.minX < $1.frame.minX : $0.id < $1.id }.map(\.id)
            }
        }
        return out
    }

    /// The slot a window dropped at `point` takes: the cell under the point, else the nearest one.
    static func cell(at point: CGPoint, in cells: [Int: CGRect]) -> Int? {
        if let hit = cells.filter({ $0.value.contains(point) }).keys.min() { return hit }
        func distance(_ r: CGRect) -> CGFloat {
            hypot(max(r.minX - point.x, 0, point.x - r.maxX), max(r.minY - point.y, 0, point.y - r.maxY))
        }
        return cells.min { (distance($0.value), $0.key) < (distance($1.value), $1.key) }?.key
    }

    enum DropResult: Equatable {
        case none
        case snapBack(Int)
        case move(Int, Int)     // the dragged window takes the slot of the second one
        case float(Int)
    }

    /// What to do after the mouse comes up at `point`. `slots` is where the last tile put each
    /// window, `sizes` the size each one settled at, `frames` where the windows are now and
    /// `screens` the displays Corral tiles onto. A drag moves a window without resizing it and
    /// ends with the pointer on it; an edge resize changes the size, and a window moved from the
    /// keyboard has no pointer on it, so neither counts.
    /// Dropped off every tiled display it floats; over another window's slot it moves there;
    /// anywhere else it goes back to its slot.
    static func drop(at point: CGPoint, slots: [Int: CGRect], sizes: [Int: CGSize], frames: [Int: CGRect],
                     screens: [CGRect], threshold: CGFloat = 24, sizeTolerance: CGFloat = 8) -> DropResult {
        let dragged = slots.compactMap { id, slot -> Int? in
            guard let now = frames[id], now.contains(point),
                  abs(now.minX - slot.minX) > threshold || abs(now.minY - slot.minY) > threshold else { return nil }
            let size = sizes[id] ?? slot.size
            guard abs(now.width - size.width) <= sizeTolerance, abs(now.height - size.height) <= sizeTolerance else { return nil }
            return id
        }
        guard let id = dragged.min() else { return .none }
        guard screens.contains(where: { $0.contains(point) }) else { return .float(id) }
        guard let other = cell(at: point, in: slots), other != id else { return .snapBack(id) }
        return .move(id, other)
    }

    // MARK: - reordering

    /// `visible` with `id` moved to position `index`; the windows in between shift by one.
    static func moving(_ id: Int, to index: Int, in visible: [Int]) -> [Int] {
        guard let from = visible.firstIndex(of: id) else { return visible }
        var v = visible
        v.remove(at: from)
        v.insert(id, at: min(max(index, 0), v.count))
        return v
    }

    /// Sessions that need you first, in the order given, then everyone else as they were.
    static func needsYouFirst(_ visible: [Int], pending: [Int]) -> [Int] {
        let present = Set(visible)
        var seen: Set<Int> = []
        let first = pending.filter { present.contains($0) && seen.insert($0).inserted }
        return first + visible.filter { !seen.contains($0) }
    }

    /// Writes a new slot order for the tiled windows (`visible`) back into `order`, which also
    /// holds windows that are not tiled right now (minimised, on another Space). Those keep their
    /// place; the tiled ones fill the positions tiled ones had, in exactly the `visible` order
    /// (a tiled window `order` did not know yet adds one position at the end).
    static func reordered(_ order: [Int], visible: [Int]) -> [Int] {
        var seen: Set<Int> = []
        let full = (order + visible).filter { seen.insert($0).inserted }
        let tiled = Set(visible)
        var next = visible.makeIterator()
        return full.map { tiled.contains($0) ? next.next() ?? $0 : $0 }
    }

    /// The window an up or down move swaps with: in the nearest row above (or below) `id`, the one
    /// closest to it horizontally. Only windows that overlap it horizontally count, so a window
    /// on a display beside this one is never above or below it.
    static func neighbour(of id: Int, up: Bool, frames: [Int: CGRect]) -> Int? {
        guard let cur = frames[id] else { return nil }
        let candidates = frames.filter { other, f in
            other != id && f.maxX > cur.minX && f.minX < cur.maxX && (up ? f.midY < cur.minY : f.midY > cur.maxY)
        }
        let tops = candidates.values.map(\.minY)
        guard let row = up ? tops.max() : tops.min() else { return nil }
        return candidates.filter { abs($0.value.minY - row) <= rowTolerance }
            .min { (abs($0.value.midX - cur.midX), $0.key) < (abs($1.value.midX - cur.midX), $1.key) }?.key
    }

    /// Same rectangle give or take `tolerance` points on every edge.
    static func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The size to ask Terminal for next time. Terminal rounds a window to whole character
    /// cells, to the nearest cell, so it can come out a few points bigger than its slot and
    /// overlap the next one. Asking for less by twice the overflow lands one cell smaller.
    static func shrunkRequest(request: CGSize, target: CGSize, actual: CGSize) -> CGSize {
        var r = request
        let ew = actual.width - target.width, eh = actual.height - target.height
        if ew > 1 { r.width = (r.width - 2 * ew - 1).rounded() }
        if eh > 1 { r.height = (r.height - 2 * eh - 1).rounded() }
        return r
    }

    /// Rounds each edge on its own so neighbouring cells share edges exactly.
    private static func snapped(_ l: CGFloat, _ t: CGFloat, _ r: CGFloat, _ b: CGFloat) -> CGRect {
        let L = l.rounded(), T = t.rounded(), R = r.rounded(), B = b.rounded()
        return CGRect(x: L, y: T, width: R - L, height: B - T)
    }
}
