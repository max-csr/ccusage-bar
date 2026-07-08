import AppKit
import SwiftUI

/// A borderless panel that can become key so its SwiftUI controls are clickable.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Solid, appearance-adaptive panel background. Replaces NSVisualEffectView: the
/// behind-window vibrancy view makes AppKit spawn an out-of-process
/// ThemeWidgetControlViewService (~8 MB) at launch. A solid panel matches the
/// inspiration's look and keeps everything in one process.
final class PanelBackgroundView: NSView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    func applyBackground() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }
}

/// Owns the menu-bar item (circular usage ring + %) and a borderless panel that
/// drops below the menu bar with a clean gap (no arrow, no overlap).
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: KeyablePanel
    private let hosting: NSHostingView<PopoverView>
    private var clickMonitor: Any?
    private var escMonitor: Any?

    init(popoverModel: PopoverModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        hosting = NSHostingView(rootView: PopoverView(model: popoverModel))
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        super.init()

        configurePanel()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.imagePosition = .imageLeading
        }
        render(UsageSnapshot(status: .loading))
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 360, height: 240))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.applyBackground()

        hosting.autoresizingMask = [.width, .height]
        hosting.frame = container.bounds

        container.addSubview(hosting)
        panel.contentView = container
    }

    // MARK: - Menu-bar rendering

    func render(_ snap: UsageSnapshot) {
        guard let button = statusItem.button else { return }

        // Error / pre-data states use an SF Symbol instead of the ring.
        if let symbol = statusSymbol(for: snap.status) {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Code usage")
            image?.isTemplate = true
            button.image = image
            button.attributedTitle = NSAttributedString(string: "")
            button.imagePosition = .imageOnly
            button.toolTip = tooltip(snap)
            return
        }

        // Normal: ring (arc = % used) + the usage % of the binding window.
        let display = bindingMetric(snap)
        let tier = Tier.of(display.percent)
        button.image = StatusItemController.ringImage(percent: display.percent ?? 0, tier: tier)
        button.imagePosition = .imageLeading

        let pct = display.percent.map { "\(Int($0.rounded()))%" } ?? "—"
        let prefix = (display.kind == .weekly) ? "W " : ""
        // Monospaced digits stop the item jiggling as the number's width changes.
        // No explicit foreground color -> the status bar renders it adaptively.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .medium)
        button.attributedTitle = NSAttributedString(
            string: " \(prefix)\(pct)", attributes: [.font: font])
        button.toolTip = tooltip(snap)
    }

    /// A thin circular ring: a faint full-circle track plus a colored arc for the
    /// fraction used, drawn clockwise from 12 o'clock. Explicit RGBA colors so it
    /// reads on both light and dark menu bars without appearance gymnastics.
    static func ringImage(percent: Double, tier: Tier, diameter: CGFloat = 15, lineWidth: CGFloat = 2.0) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let fraction = max(0, min(percent / 100, 1))
        let arcColor = tier.color
        let image = NSImage(size: size, flipped: false) { _ in
            let inset = lineWidth / 2 + 0.5
            let rect = NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let center = NSPoint(x: size.width / 2, y: size.height / 2)
            let radius = rect.width / 2

            let track = NSBezierPath(ovalIn: rect)
            track.lineWidth = lineWidth
            NSColor(white: 0.55, alpha: 0.45).setStroke()
            track.stroke()

            if fraction > 0 {
                let start: CGFloat = 90
                let end = start - 360 * fraction
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius,
                              startAngle: start, endAngle: end, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                arcColor.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// nil means "draw the ring"; otherwise use this SF Symbol.
    private func statusSymbol(for status: UsageStatus) -> String? {
        switch status {
        case .noToken:      return "person.crop.circle.badge.questionmark"
        case .unauthorized: return "exclamationmark.triangle"
        case .loading:      return "hourglass"
        case .rateLimited, .offline, .ok: return nil
        }
    }

    private func tooltip(_ snap: UsageSnapshot) -> String {
        switch snap.status {
        case .noToken:      return "Sign in with Claude Code first"
        case .unauthorized: return "Token expired — open Claude Code to re-authenticate"
        case .loading:      return "Loading…"
        default: break
        }
        func part(_ label: String, _ pct: Double?, _ reset: Date?) -> String {
            let p = pct.map { "\(Int($0.rounded()))%" } ?? "—"
            return "\(label) \(p) · \(menuBarTimeString(to: reset))"
        }
        var line = part("Session", snap.sessionPercent, snap.sessionResetsAt)
            + "  •  " + part("Weekly", snap.weeklyPercent, snap.weeklyResetsAt)
        if snap.status == .offline { line += "  •  offline" }
        if snap.status == .rateLimited { line += "  •  rate-limited" }
        return line
    }

    // MARK: - Panel show / hide

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button, let btnWindow = button.window else { return }

        hosting.layoutSubtreeIfNeeded()
        var size = hosting.fittingSize
        if size.width < 1 { size.width = 360 }
        if size.height < 80 { size.height = 240 }
        panel.setContentSize(size)

        // Anchor under the button with a real gap (screen coords: y increases upward).
        let buttonFrame = btnWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let gap: CGFloat = 6
        var x = buttonFrame.midX - size.width / 2
        let y = buttonFrame.minY - gap - size.height
        if let visible = (btnWindow.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)

        // Close when the user clicks anywhere outside our app (global monitors only
        // see events bound for other apps, so clicks in the panel / on the status
        // button never trigger this — no double-toggle).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }

        // Esc closes the panel. A local monitor sees our own key events (the panel
        // is key); swallow the Escape (return nil) so it doesn't beep.
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // 53 = Escape
            Task { @MainActor in self?.hidePanel() }
            return nil
        }
    }

    private func hidePanel() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        panel.orderOut(nil)
    }
}
