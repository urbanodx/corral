import AppKit

/// Click-through coloured frames drawn on top of the Terminal windows whose
/// Claude session needs you (red: asking, orange: finished), so the grid shows
/// at a glance who needs you.
final class Borders {
    struct Target: Equatable {
        let frame: CGRect      // top-left global coordinates
        let color: NSColor
    }

    private var overlays: [Int: NSWindow] = [:]
    var lineWidth: CGFloat = 4
    var cornerRadius: CGFloat = 12

    func show(_ targets: [Int: Target]) {
        for (id, win) in overlays where targets[id] == nil {
            win.orderOut(nil)
            overlays[id] = nil
        }
        guard let mainHeight = NSScreen.screens.first?.frame.maxY else { return }
        for (id, target) in targets {
            let frame = target.frame
            let cocoa = CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
            let win = overlays[id] ?? makeOverlay()
            overlays[id] = win
            if win.frame != cocoa { win.setFrame(cocoa, display: true) }
            (win.contentView as? FrameView)?.update(color: target.color, width: lineWidth, radius: cornerRadius)
            // Sit just above that Terminal window, not above every app.
            win.order(.above, relativeTo: id)
        }
    }

    func hideAll() { show([:]) }

    private func makeOverlay() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary, .transient]
        w.contentView = FrameView()
        return w
    }
}

private final class FrameView: NSView {
    private var color = NSColor.systemOrange
    private var width: CGFloat = 4
    private var radius: CGFloat = 12

    func update(color: NSColor, width: CGFloat, radius: CGFloat) {
        guard color != self.color || width != self.width || radius != self.radius else { return }
        self.color = color; self.width = width; self.radius = radius
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }
}
