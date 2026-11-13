import AppKit

/// The drop-down under the menu bar icon. A non-activating panel: it takes the
/// keyboard (Esc, ⌘Q, ⌘,) without making Runbar the active app, so the app you
/// were in keeps its focus and its windows stay lit, the way a menu behaves.
final class FloatingPanel: NSPanel {
    var onClose: (() -> Void)?
    /// Esc. Falls back to `onClose`.
    var onCancel: (() -> Void)?
    private let effect = NSVisualEffectView()
    /// Holds the content pinned to the top at a fixed height, as tall as the
    /// screen. The window grows and shrinks around it. Any change to the
    /// content's own height makes SwiftUI lay out again a frame late, and the
    /// content jumps down for that frame.
    private let stage = TopAlignedView()
    private let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(contentRect: NSRect(x: 0, y: 0, width: 330, height: 200),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        // Opens instantly; AppDelegate fades it out on close.
        animationBehavior = .none

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        // A menu's corner, measured against Docker's status menu: about half
        // the 10 pt of a popover.
        effect.maskImage = Self.roundedMask(radius: 6)
        stage.frame = effect.bounds
        stage.autoresizingMask = [.width, .height]
        effect.addSubview(stage)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width]
        content.frame = NSRect(x: 0, y: 0, width: 330, height: 200)
        stage.addSubview(content)
        contentView = effect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { (onCancel ?? onClose)?() }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    /// Places the panel under `anchor`, the status item's window in screen
    /// coordinates, keeping its top edge fixed as the content grows or shrinks.
    /// The top sits on the menu bar's bottom edge and the side lines up with the
    /// icon's highlight, which is inset `inset` from the window, like a menu.
    func place(below anchor: NSRect, size: NSSize, animated: Bool) {
        let inset: CGFloat = 2
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let bounds = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.minX + inset
        if x + size.width > bounds.maxX {
            x = anchor.maxX - inset - size.width
        }
        x = max(x, bounds.minX)
        let top = anchor.minY
        let target = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        // Changes only when moving to a taller screen or past its height.
        let stageHeight = max(bounds.height, size.height)
        if content.frame.height != stageHeight || content.frame.width != size.width {
            content.setFrameSize(NSSize(width: size.width, height: stageHeight))
        }
        guard animated, target != frame else {
            setFrame(target, display: true)
            return
        }
        // Same duration and curve as the SwiftUI changes inside (Motion).
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration
            let c = Motion.curve
            context.timingFunction = CAMediaTimingFunction(controlPoints: Float(c.0), Float(c.1), Float(c.2), Float(c.3))
            animator().setFrame(target, display: true)
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Lays subviews out from the top edge, so they stay put while it resizes.
private final class TopAlignedView: NSView {
    override var isFlipped: Bool { true }
}
