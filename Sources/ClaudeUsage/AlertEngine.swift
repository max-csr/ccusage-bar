import Foundation

// MARK: - Notification settings (values passed into the pure engine)

/// A plain snapshot of the user's notification preferences. The engine takes
/// this as a parameter so it never touches UserDefaults — keeping it pure and
/// unit-testable offline.
struct NotificationSettings: Equatable {
    var thresholdEnabled: Bool
    var thresholdPercent: Double
    var burnRateEnabled: Bool

    static let defaults = NotificationSettings(
        thresholdEnabled: true, thresholdPercent: 90, burnRateEnabled: true)
}

// MARK: - Semantic alerts (copy is formatted later by NotificationManager)

enum Alert: Equatable {
    case threshold(BarKind, percent: Double)
    case burnRate(percent: Double)   // 5-hour session only
}

extension BarKind {
    var label: String {
        switch self {
        case .session: return "session"
        case .weekly:  return "weekly"
        }
    }
}

// MARK: - Tunable constants

/// Burn-rate + reset-detection knobs. See the design notes below each field for
/// why the defaults are what they are (session window = 300 min).
struct AlertConfig {
    var burnDelta: Double         = 10    // % points per burnWindow (10%/10min = 3× steady pace)
    var burnWindow: TimeInterval  = 600   // 10-minute look-back
    var burnMinSpan: TimeInterval = 300   // require ≥5 min of samples (≈2 poll gaps)
    var burnMinSamples: Int       = 3     // ⇒ elevated rate persisted across ~2 gaps
    var burnMaxGap: TimeInterval  = 420   // cut the window across sleep/outage gaps (>2 intervals)
    var burnCooldown: TimeInterval = 1800 // ≤1 burn alert / 30 min
    var resetDropMargin: Double   = 10    // a ≥10-pt percent drop ⇒ window reset
    var resetsAtEpsilon: TimeInterval = 60 // absorb resetsAt wiggle
    var bufferRetention: TimeInterval = 900 // keep 15 min of session samples
    var bufferCapacity: Int       = 16    // hard count cap (defensive vs. manual-refresh bursts)
}

// MARK: - The engine

/// Pure, stateful detector. Fed a fresh `.ok` `UsageSnapshot` on each poll, it
/// returns the alerts that should fire *this* tick. All history and latch state
/// live in-memory (a ≤10-min window; persisting would manufacture bogus rates
/// across a restart gap).
struct AlertEngine {
    var config = AlertConfig()

    private struct Sample { let time: Date; let percent: Double }

    /// Per-window threshold latch. Fires once on the arm→cross transition, then
    /// latches until a genuine window reset re-arms it.
    private struct WindowState {
        var seeded = false
        var armed = true
        var lastPercent: Double?
        var lastResetsAt: Date?

        /// Advance one tick. Returns the alert to fire (if any) and whether a
        /// window reset was detected (so the caller can clear burn history).
        mutating func step(_ kind: BarKind, percent: Double, resetsAt: Date?,
                           settings: NotificationSettings, config: AlertConfig) -> (Alert?, Bool) {
            // Seed: never fire on first sight; if already above threshold, stay
            // disarmed so we don't re-alert on every relaunch.
            if !seeded {
                seeded = true
                lastPercent = percent
                lastResetsAt = resetsAt
                armed = percent < settings.thresholdPercent
                return (nil, false)
            }

            // Reset detection: resets_at advanced past the stored boundary, OR
            // percent collapsed (usage is monotone within a window, so a big
            // drop is unambiguously a rollover — batch jumps only go up).
            let resetsAdvanced: Bool = {
                guard let r = resetsAt, let prev = lastResetsAt else { return false }
                return r > prev.addingTimeInterval(config.resetsAtEpsilon)
            }()
            let percentCollapsed: Bool = {
                guard let prev = lastPercent else { return false }
                return percent <= prev - config.resetDropMargin
            }()
            let didReset = resetsAdvanced || percentCollapsed
            if didReset { armed = true }

            var alert: Alert?
            if armed && percent >= settings.thresholdPercent {
                if settings.thresholdEnabled { alert = .threshold(kind, percent: percent) }
                armed = false   // latch consumed even when disabled → no retro-fire on re-enable
            }

            lastPercent = percent
            if resetsAt != nil { lastResetsAt = resetsAt }   // never overwrite with nil
            return (alert, didReset)
        }

        /// Re-arm (without firing) when the user changes the threshold at runtime.
        mutating func rearmForThreshold(_ threshold: Double) {
            guard seeded else { return }
            armed = lastPercent.map { $0 < threshold } ?? true
        }
    }

    private var session = WindowState()
    private var weekly = WindowState()
    private var sessionSamples: [Sample] = []
    private var lastBurnFire: Date?
    private var lastProcessed: Date?
    private var lastThreshold: Double?

    mutating func evaluate(_ snap: UsageSnapshot, _ settings: NotificationSettings) -> [Alert] {
        // 1. Only genuinely-fresh data. `emit()` re-emits last-good with a non-.ok
        //    status and the old lastUpdated; `succeed()` alone produces .ok + a new
        //    stamp. Dedupe on lastUpdated as belt-and-suspenders.
        guard snap.status == .ok, let ts = snap.lastUpdated else { return [] }
        if let last = lastProcessed, ts <= last { return [] }
        lastProcessed = ts

        // 2. Runtime threshold change → re-arm without firing retroactively.
        if lastThreshold != settings.thresholdPercent {
            lastThreshold = settings.thresholdPercent
            session.rearmForThreshold(settings.thresholdPercent)
            weekly.rearmForThreshold(settings.thresholdPercent)
        }

        var alerts: [Alert] = []

        // 3. Threshold latch per window (independent).
        if let sp = snap.sessionPercent {
            let (alert, didReset) = session.step(.session, percent: sp,
                resetsAt: snap.sessionResetsAt, settings: settings, config: config)
            if let alert { alerts.append(alert) }
            if didReset { sessionSamples.removeAll(); lastBurnFire = nil }
        }
        if let wp = snap.weeklyPercent {
            let (alert, _) = weekly.step(.weekly, percent: wp,
                resetsAt: snap.weeklyResetsAt, settings: settings, config: config)
            if let alert { alerts.append(alert) }
        }

        // 4. Burn-rate (session only). Runs after any reset above cleared the buffer.
        if let burn = evaluateBurn(percent: snap.sessionPercent, ts: ts, settings: settings) {
            alerts.append(burn)
        }
        return alerts
    }

    private mutating func evaluateBurn(percent: Double?, ts: Date,
                                       settings: NotificationSettings) -> Alert? {
        guard let p = percent else { return nil }   // nil = unknown, not 0 — don't fake a rise
        if sessionSamples.last.map({ ts > $0.time }) ?? true {
            sessionSamples.append(Sample(time: ts, percent: p))
        }
        // Prune relative to the newest sample's time (not wall-clock), so a sleep
        // gap doesn't silently empty the buffer mid-computation.
        let cutoff = ts.addingTimeInterval(-config.bufferRetention)
        sessionSamples.removeAll { $0.time < cutoff }
        if sessionSamples.count > config.bufferCapacity {
            sessionSamples.removeFirst(sessionSamples.count - config.bufferCapacity)
        }

        guard settings.burnRateEnabled, let latest = sessionSamples.last else { return nil }
        if latest.percent >= settings.thresholdPercent { return nil }   // threshold alert owns this regime
        if let fired = lastBurnFire, ts.timeIntervalSince(fired) < config.burnCooldown { return nil }

        let windowStart = ts.addingTimeInterval(-config.burnWindow)
        let inWindow = sessionSamples.filter { $0.time > windowStart }
        let tail = contiguousTail(inWindow)
        guard tail.count >= config.burnMinSamples,
              let oldest = tail.first, let newest = tail.last else { return nil }
        let span = newest.time.timeIntervalSince(oldest.time)
        guard span >= config.burnMinSpan else { return nil }
        let rise = newest.percent - oldest.percent
        guard rise > 0 else { return nil }

        let deltaPerWindow = rise / span * config.burnWindow   // observed rate, projected over 10 min
        guard deltaPerWindow >= config.burnDelta else { return nil }
        lastBurnFire = ts
        return .burnRate(percent: newest.percent)
    }

    /// The newest run of samples with no adjacent gap larger than `burnMaxGap` —
    /// drops everything before a sleep/outage cluster.
    private func contiguousTail(_ s: [Sample]) -> [Sample] {
        guard let last = s.last else { return [] }
        var out = [last]
        var i = s.count - 2
        while i >= 0, out[0].time.timeIntervalSince(s[i].time) <= config.burnMaxGap {
            out.insert(s[i], at: 0)
            i -= 1
        }
        return out
    }
}
