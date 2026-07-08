import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var poller: UsagePoller?
    private var settingsController: SettingsWindowController?
    private var updateTimer: Timer?
    private var notificationManager: NotificationManager?
    private let popoverModel = PopoverModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationSettingsStore.registerDefaults()

        let client = UsageClient(userAgent: AppDelegate.userAgent())
        let poller = UsagePoller(client: client, pollInterval: 180)
        let statusController = StatusItemController(popoverModel: popoverModel)
        let settingsController = SettingsWindowController(model: popoverModel)

        popoverModel.onRefresh = { [weak poller] in poller?.pollNow() }
        popoverModel.onToggleLogin = { [weak self] enabled in
            LoginItem.setEnabled(enabled)
            self?.popoverModel.launchAtLogin = LoginItem.isEnabled
        }
        popoverModel.onOpenSettings = { [weak settingsController] in settingsController?.show() }
        popoverModel.onOpenUpdate = { [weak self] in
            if let url = self?.popoverModel.update?.url { NSWorkspace.shared.open(url) }
        }
        popoverModel.onCheckForUpdates = { [weak self] in self?.performUpdateCheck() }
        popoverModel.onQuit = { NSApp.terminate(nil) }
        popoverModel.launchAtLogin = LoginItem.isEnabled

        // Notification prefs: seed from the store, then round-trip edits through it
        // (write → re-read authoritative value into the model), mirroring the
        // launch-at-login toggle above.
        popoverModel.thresholdEnabled = NotificationSettingsStore.thresholdEnabled
        popoverModel.thresholdPercent = NotificationSettingsStore.thresholdPercent
        popoverModel.burnRateEnabled = NotificationSettingsStore.burnRateEnabled
        popoverModel.onSetThresholdEnabled = { [weak self] enabled in
            NotificationSettingsStore.thresholdEnabled = enabled
            self?.popoverModel.thresholdEnabled = NotificationSettingsStore.thresholdEnabled
        }
        popoverModel.onSetThreshold = { [weak self] percent in
            NotificationSettingsStore.thresholdPercent = percent
            self?.popoverModel.thresholdPercent = NotificationSettingsStore.thresholdPercent
        }
        popoverModel.onSetBurnRateEnabled = { [weak self] enabled in
            NotificationSettingsStore.burnRateEnabled = enabled
            self?.popoverModel.burnRateEnabled = NotificationSettingsStore.burnRateEnabled
        }

        // Notifications require a real .app bundle: UNUserNotificationCenter.current()
        // traps with "bundleProxyForCurrentProcess is nil" in the bare SwiftPM binary
        // (which is how --selftest/--probe and dev runs execute). bundleIdentifier is
        // nil there and "com.maxcerisier.ccusagebar" inside the built app.
        if Bundle.main.bundleIdentifier != nil {
            let manager = NotificationManager()
            manager.requestAuthorization()
            notificationManager = manager
        }

        poller.onUpdate = { [weak self] snapshot in
            self?.statusController?.render(snapshot)
            self?.popoverModel.snapshot = snapshot
            self?.notificationManager?.handle(snapshot)
        }

        self.poller = poller
        self.statusController = statusController
        self.settingsController = settingsController
        poller.start()

        // Check GitHub for a newer release at launch, then once a day.
        performUpdateCheck()
        let timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.performUpdateCheck() }
        }
        timer.tolerance = 3_600
        updateTimer = timer
    }

    private func performUpdateCheck() {
        popoverModel.updateCheckState = .checking
        Task { @MainActor in
            let info = await UpdateChecker.check()
            popoverModel.update = info
            popoverModel.updateCheckState = info.map { .available($0) } ?? .upToDate
        }
    }

    /// The usage API wants a `claude-code/<version>` User-Agent. We can't reliably
    /// find the `claude` binary from a GUI app's minimal PATH, so use a known-good
    /// constant. Bump it occasionally to match the installed CLI.
    nonisolated static func userAgent() -> String {
        "claude-code/2.1.195"
    }
}
