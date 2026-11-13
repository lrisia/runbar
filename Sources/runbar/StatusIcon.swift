import AppKit

/// The menu bar icon. It sits in an image view inside the status button,
/// because only NSImageView plays SF Symbol effects. The symbol changes with
/// a replace transition, bounces when one more thing starts, pulses while a
/// command or scheduled run is going, and wiggles when something fails.
/// Under Reduce Motion the icon still changes, without the motion.
final class StatusIcon {
    private let view = PassThroughImageView()
    private var shown: String?
    private var active = 0
    private var pulsing = false
    private var failed = false

    init(button: NSStatusBarButton) {
        button.image = nil
        button.setAccessibilityLabel("Runbar")
        view.imageScaling = .scaleNone
        view.setAccessibilityElement(false)
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    /// - Parameters:
    ///   - symbol: the SF Symbol to show, or nil when `custom` is used.
    ///   - custom: the user's own image; it has no effects and is dimmed while idle.
    ///   - active: services running plus commands running.
    ///   - commandRunning: a command or scheduled run is going.
    ///   - failed: the failure icon is showing.
    func update(symbol: String?, custom: NSImage? = nil, active: Int, commandRunning: Bool, failed: Bool) {
        let still = Motion.reduced
        if let custom {
            custom.isTemplate = true
            stopPulse()
            view.image = custom
            view.alphaValue = active > 0 ? 1 : 0.45
            shown = nil
        } else if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            view.alphaValue = 1
            if symbol != shown {
                if shown == nil || still {
                    view.image = image
                } else {
                    view.setSymbolImage(image, contentTransition: .replace)
                }
                shown = symbol
                // A new image can drop a running effect; start it again.
                if pulsing { stopPulse(); startPulse() }
            } else if active > self.active && !still {
                view.addSymbolEffect(.bounce, options: .nonRepeating)
            }
            if failed && !self.failed && !still {
                if #available(macOS 15, *) {
                    view.addSymbolEffect(.wiggle, options: .nonRepeating)
                } else {
                    view.addSymbolEffect(.bounce, options: .nonRepeating)
                }
            }
            if commandRunning && !still { startPulse() } else { stopPulse() }
        }
        self.active = active
        self.failed = failed
    }

    private func startPulse() {
        guard !pulsing else { return }
        view.addSymbolEffect(.pulse)
        pulsing = true
    }

    private func stopPulse() {
        guard pulsing else { return }
        view.removeSymbolEffect(ofType: .pulse)
        pulsing = false
    }
}

/// Lets clicks fall through to the status button, so ⌘-drag still moves it.
private final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
