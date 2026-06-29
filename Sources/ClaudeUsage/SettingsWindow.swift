import AppKit
import SwiftUI

/// Small settings window opened from the popover's "Settings…" item. Lazily
/// created and reused. Accessory apps must call NSApp.activate to bring it forward.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: PopoverModel

    init(model: PopoverModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            let w = NSWindow(contentViewController: hosting)
            w.title = "CC Usage"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 340, height: 310))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: PopoverModel

    private let repoURL = URL(string: "https://github.com/max-csr/ccusage-bar")!

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.title3.weight(.semibold))

            // Launch at login
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.onToggleLogin?($0) }))
                    .toggleStyle(.switch)
                Text("Start CC Usage automatically when you log in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Updates
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button("Check for Updates…") { model.onCheckForUpdates?() }
                        .disabled(model.updateCheckState == .checking)
                    if model.updateCheckState == .checking {
                        ProgressView().controlSize(.small)
                    }
                }
                updateStatus
            }

            Spacer()

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Link("github.com/max-csr/ccusage-bar", destination: repoURL)
                    .font(.caption)
                Text("CC Usage \(appVersion) · created by maxcrsr")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .frame(width: 340, height: 310, alignment: .topLeading)
    }

    @ViewBuilder
    private var updateStatus: some View {
        switch model.updateCheckState {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .upToDate:
            Text("You're on the latest version (\(appVersion)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available(let info):
            HStack(spacing: 6) {
                Text("Update available — v\(info.version)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                Link("Download", destination: info.url)
                    .font(.caption)
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(v)"
    }
}
