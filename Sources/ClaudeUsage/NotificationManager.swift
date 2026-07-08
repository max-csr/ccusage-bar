import Foundation
import UserNotifications

// MARK: - Persistence

/// UserDefaults-backed store for the two notification prefs. Register defaults
/// once at launch before any read (`bool(forKey:)` is `false` for unset keys).
enum NotificationSettingsStore {
    private static let kThresholdEnabled = "notify.threshold.enabled"
    private static let kThresholdPercent = "notify.threshold.percent"
    private static let kBurnRateEnabled  = "notify.burnRate.enabled"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            kThresholdEnabled: true,
            kThresholdPercent: 90.0,
            kBurnRateEnabled: true,
        ])
    }

    static var thresholdEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: kThresholdEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: kThresholdEnabled) }
    }
    static var thresholdPercent: Double {
        get { UserDefaults.standard.double(forKey: kThresholdPercent) }
        set { UserDefaults.standard.set(newValue, forKey: kThresholdPercent) }
    }
    static var burnRateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: kBurnRateEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: kBurnRateEnabled) }
    }

    static var current: NotificationSettings {
        NotificationSettings(thresholdEnabled: thresholdEnabled,
                             thresholdPercent: thresholdPercent,
                             burnRateEnabled: burnRateEnabled)
    }
}

// MARK: - The impure shell

/// Owns the pure `AlertEngine`, reads settings, formats copy, and is the ONLY
/// place that touches `UNUserNotificationCenter`. Must be instantiated only when
/// a real bundle exists (see AppDelegate's `Bundle.main.bundleIdentifier` guard)
/// — `.current()` throws `bundleProxyForCurrentProcess is nil` in a bare binary.
@MainActor
final class NotificationManager {
    private var engine = AlertEngine()
    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("NotificationManager: authorization error — \(error)") }
        }
    }

    /// Called on every poll snapshot. The engine drops non-fresh/stale data, so
    /// this is safe to call unconditionally.
    func handle(_ snapshot: UsageSnapshot) {
        let alerts = engine.evaluate(snapshot, NotificationSettingsStore.current)
        for alert in alerts { post(alert, snapshot: snapshot) }
    }

    private func post(_ alert: Alert, snapshot: UsageSnapshot) {
        let content = UNMutableNotificationContent()
        content.sound = .default
        let identifier: String

        switch alert {
        case .threshold(let kind, let percent):
            let pct = Int(percent.rounded())
            switch kind {
            case .session:
                content.title = "Session usage at \(pct)%"
                content.body = "You've used \(pct)% of your 5-hour session limit. "
                    + countdownString(to: snapshot.sessionResetsAt) + "."
            case .weekly:
                content.title = "Weekly usage at \(pct)%"
                content.body = "You've used \(pct)% of your weekly limit. "
                    + countdownString(to: snapshot.weeklyResetsAt) + "."
            }
            identifier = "threshold.\(kind.label)"

        case .burnRate(let percent):
            let pct = Int(percent.rounded())
            content.title = "Rapid usage"
            content.body = "Your 5-hour session usage is climbing fast — now at \(pct)%."
            identifier = "burnrate.session"
        }

        // Stable identifier per kind so a repeat replaces rather than stacks.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request)
    }
}
