import AppKit

// Headless modes for verification, handled before any GUI bootstrap.
let args = CommandLine.arguments
if args.contains("--selftest") {
    SelfTest.run()
} else if args.contains("--probe") {
    Probe.run()
} else if args.contains("--register-login") {
    let ok = LoginItem.setEnabled(true)
    print("register login: \(ok ? "ok" : "failed") — status=\(LoginItem.statusString)")
    exit(ok ? 0 : 1)
} else if args.contains("--unregister-login") {
    let ok = LoginItem.setEnabled(false)
    print("unregister login: \(ok ? "ok" : "failed") — status=\(LoginItem.statusString)")
    exit(ok ? 0 : 1)
} else if let i = args.firstIndex(of: "--screenshots") {
    let dir = (i + 1 < args.count) ? args[i + 1] : "docs"
    _ = NSApplication.shared   // initialize AppKit for offscreen SwiftUI rendering
    MainActor.assumeIsolated { Screenshots.render(to: dir) }
} else if args.contains("--check-update") {
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        print("current version: \(UpdateChecker.currentVersion())")
        if let info = await UpdateChecker.check() {
            print("update available: v\(info.version) -> \(info.url)")
        } else {
            print("up to date (no newer release)")
        }
        sem.signal()
    }
    sem.wait()
} else {
    // Top-level main.swift code runs on the main thread; assert that to the
    // compiler so we can touch the @MainActor AppDelegate/app objects.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Agent app: no Dock icon, no app menu. Belt-and-suspenders with LSUIElement.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

// MARK: - --selftest : parse the verified fixture offline

enum SelfTest {
    static let fixture = """
    {
      "five_hour":  { "utilization": 24.0, "resets_at": "2026-06-29T12:49:59.673455+00:00" },
      "seven_day":  { "utilization": 52.0, "resets_at": "2026-07-01T20:59:59.673479+00:00" },
      "seven_day_sonnet": { "utilization": 0.0, "resets_at": null },
      "limits": [
        { "kind": "session",    "group": "session", "percent": 24, "resets_at": "2026-06-29T12:49:59.673455+00:00", "is_active": false },
        { "kind": "weekly_all", "group": "weekly",  "percent": 52, "resets_at": "2026-07-01T20:59:59.673479+00:00", "is_active": true }
      ],
      "extra_usage": { "is_enabled": true, "monthly_limit": 0, "used_credits": 0.0, "currency": "EUR", "decimal_places": 2 },
      "spend": { "percent": 0, "severity": "normal" }
    }
    """

    static func run() {
        do {
            let r = try JSONDecoder.usage.decode(UsageResponse.self, from: Data(fixture.utf8))
            try check(Int(r.fiveHour?.utilization ?? -1) == 24, "five_hour.utilization == 24")
            try check(Int(r.sevenDay?.utilization ?? -1) == 52, "seven_day.utilization == 52")
            try check(r.fiveHour?.resetsAt != nil, "five_hour.resets_at parsed (fractional seconds)")
            try check(r.sevenDay?.resetsAt != nil, "seven_day.resets_at parsed")
            try check(r.sevenDaySonnet?.resetsAt == nil, "seven_day_sonnet.resets_at is null -> nil")

            let session = r.limits?.first { $0.kind == "session" }
            let weekly = r.limits?.first { $0.kind == "weekly_all" }
            try check(session?.percent == 24, "limits[session].percent == 24")
            try check(weekly?.isActive == true, "limits[weekly_all].is_active == true")

            let snap = UsageSnapshot.from(r)
            try check(bindingMetric(snap).kind == .session, "binding metric defaults to session (24% vs 52%, neither dangerous)")

            // Danger switch: weekly 85% active, session 24% -> show weekly.
            let danger = UsageSnapshot(sessionPercent: 24, weeklyPercent: 85, status: .ok)
            try check(bindingMetric(danger).kind == .weekly, "switches to weekly when weekly >= 80 and session < 80")
            // Both dangerous -> session wins.
            let both = UsageSnapshot(sessionPercent: 90, weeklyPercent: 95, status: .ok)
            try check(bindingMetric(both).kind == .session, "session wins when both dangerous")

            // Update version comparison.
            try check(UpdateChecker.isNewer("1.0.1", than: "1.0.0"), "1.0.1 > 1.0.0")
            try check(!UpdateChecker.isNewer("1.0.0", than: "1.0.0"), "1.0.0 == 1.0.0 (no update)")
            try check(UpdateChecker.isNewer("1.0.10", than: "1.0.9"), "1.0.10 > 1.0.9 (numeric, not lexical)")
            try check(UpdateChecker.isNewer("2.0.0", than: "1.9.9"), "2.0.0 > 1.9.9")
            try check(!UpdateChecker.isNewer("1.0.0", than: "1.1.0"), "older is not newer")

            try checkAlertEngine()

            print("selftest: PASS")
            print("  5h=\(r.fiveHour!.utilization!)%  resets \(r.fiveHour!.resetsAt!)")
            print("  7d=\(r.sevenDay!.utilization!)%  resets \(r.sevenDay!.resetsAt!)")
            print("  countdown(5h) = \(countdownString(to: r.fiveHour!.resetsAt!, now: Date(timeIntervalSince1970: 1782740000)))")
        } catch {
            print("selftest: FAIL — \(error)")
            exit(1)
        }
    }

    struct CheckError: Error { let message: String }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckError(message: message) }
    }

    // MARK: - Notification AlertEngine (pure logic)

    static func checkAlertEngine() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let allOn = NotificationSettings(thresholdEnabled: true, thresholdPercent: 90, burnRateEnabled: true)

        func snap(_ session: Double?, _ weekly: Double? = nil, at offset: TimeInterval,
                  sessionReset: Date? = nil, weeklyReset: Date? = nil,
                  status: UsageStatus = .ok) -> UsageSnapshot {
            UsageSnapshot(sessionPercent: session, sessionResetsAt: sessionReset,
                          weeklyPercent: weekly, weeklyResetsAt: weeklyReset,
                          status: status, lastUpdated: base.addingTimeInterval(offset))
        }

        // Threshold: fires once at the crossing, then latches.
        var e1 = AlertEngine()
        _ = e1.evaluate(snap(70, at: 0), allOn)
        _ = e1.evaluate(snap(85, at: 180), allOn)
        try check(e1.evaluate(snap(92, at: 360), allOn) == [.threshold(.session, percent: 92)],
                  "threshold fires once at crossing")
        try check(e1.evaluate(snap(95, at: 540), allOn).isEmpty, "threshold latches (no refire)")

        // Jitter around the threshold fires at most once.
        var e2 = AlertEngine()
        _ = e2.evaluate(snap(88, at: 0), allOn)
        try check(e2.evaluate(snap(91, at: 180), allOn) == [.threshold(.session, percent: 91)], "jitter: fire at 91")
        _ = e2.evaluate(snap(89, at: 360), allOn)
        try check(e2.evaluate(snap(92, at: 540), allOn).isEmpty, "jitter: 89 does not re-arm")

        // Re-arms after a genuine window reset (percent collapse + advanced resets_at).
        var e3 = AlertEngine()
        let r0 = base.addingTimeInterval(5 * 3600), r1 = base.addingTimeInterval(10 * 3600)
        _ = e3.evaluate(snap(70, at: 0, sessionReset: r0), allOn)
        let c1 = e3.evaluate(snap(92, at: 180, sessionReset: r0), allOn)
        _ = e3.evaluate(snap(3, at: 360, sessionReset: r1), allOn)   // reset
        let c2 = e3.evaluate(snap(91, at: 540, sessionReset: r1), allOn)
        try check(c1 == [.threshold(.session, percent: 92)] && c2 == [.threshold(.session, percent: 91)],
                  "re-arms after window reset")

        // Already above threshold on first sight → suppressed until a reset.
        var e4 = AlertEngine()
        let s0 = base.addingTimeInterval(5 * 3600), s1 = base.addingTimeInterval(10 * 3600)
        try check(e4.evaluate(snap(95, at: 0, sessionReset: s0), allOn).isEmpty, "seed-above: no fire at seed")
        try check(e4.evaluate(snap(96, at: 180, sessionReset: s0), allOn).isEmpty, "seed-above: still no fire")
        _ = e4.evaluate(snap(5, at: 360, sessionReset: s1), allOn)
        try check(e4.evaluate(snap(92, at: 540, sessionReset: s1), allOn) == [.threshold(.session, percent: 92)],
                  "seed-above: fires after reset + re-cross")

        // Stale/error re-emit is ignored.
        var e5 = AlertEngine()
        try check(e5.evaluate(snap(99, at: 0, status: .offline), allOn).isEmpty, "stale/error snapshot ignored")

        // Dedup by lastUpdated.
        var e6 = AlertEngine()
        _ = e6.evaluate(snap(70, at: 0), allOn)
        let d1 = e6.evaluate(snap(92, at: 180), allOn)
        let d2 = e6.evaluate(snap(92, at: 180), allOn)   // same lastUpdated
        try check(d1 == [.threshold(.session, percent: 92)] && d2.isEmpty, "dedup by lastUpdated")

        // Lowering the threshold below current usage does not retro-fire.
        var e7 = AlertEngine()
        _ = e7.evaluate(snap(70, at: 0), allOn)
        _ = e7.evaluate(snap(80, at: 180), allOn)
        let lowered = NotificationSettings(thresholdEnabled: true, thresholdPercent: 75, burnRateEnabled: true)
        try check(e7.evaluate(snap(82, at: 360), lowered).isEmpty, "runtime threshold lowered: no retro-fire")

        // Session and weekly can both cross in one tick.
        var e8 = AlertEngine()
        _ = e8.evaluate(snap(70, 80, at: 0), allOn)
        let both = e8.evaluate(snap(92, 95, at: 180), allOn)
        try check(both.count == 2
                  && both.contains(.threshold(.session, percent: 92))
                  && both.contains(.threshold(.weekly, percent: 95)), "session + weekly cross together")

        // Burn-rate fires on a rapid session rise.
        var b1 = AlertEngine()
        _ = b1.evaluate(snap(50, at: 0), allOn)
        _ = b1.evaluate(snap(54, at: 180), allOn)
        try check(b1.evaluate(snap(58, at: 360), allOn) == [.burnRate(percent: 58)], "burn-rate fires on rapid rise")

        // Slow rise never fires.
        var b2 = AlertEngine()
        _ = b2.evaluate(snap(50, at: 0), allOn)
        _ = b2.evaluate(snap(52, at: 180), allOn)
        _ = b2.evaluate(snap(54, at: 360), allOn)
        try check(b2.evaluate(snap(56, at: 540), allOn).isEmpty, "slow rise does not fire burn-rate")

        // Needs ≥3 samples: a lone 2-sample jump does not fire.
        var b3 = AlertEngine()
        _ = b3.evaluate(snap(50, at: 0), allOn)
        try check(b3.evaluate(snap(62, at: 180), allOn).isEmpty, "burn-rate needs ≥3 samples")

        // Rise across a sleep/outage gap is ignored.
        var b4 = AlertEngine()
        _ = b4.evaluate(snap(50, at: 0), allOn)
        _ = b4.evaluate(snap(53, at: 180), allOn)
        try check(b4.evaluate(snap(80, at: 7200), allOn).isEmpty, "burn-rate ignores rise across sleep gap")

        // At/above threshold: threshold alert only, no duplicate burn.
        var b5 = AlertEngine()
        _ = b5.evaluate(snap(85, at: 0), allOn)
        _ = b5.evaluate(snap(88, at: 180), allOn)
        try check(b5.evaluate(snap(93, at: 360), allOn) == [.threshold(.session, percent: 93)],
                  "burn suppressed when at/above threshold")

        // Cooldown caps a sustained burn to one alert per 30 min.
        var b6 = AlertEngine()
        _ = b6.evaluate(snap(40, at: 0), allOn)
        _ = b6.evaluate(snap(48, at: 180), allOn)
        let f = b6.evaluate(snap(56, at: 360), allOn)
        let g = b6.evaluate(snap(64, at: 540), allOn)
        try check(f == [.burnRate(percent: 56)] && g.isEmpty, "burn-rate respects cooldown")

        // nil percent is skipped, not treated as 0.
        var b7 = AlertEngine()
        _ = b7.evaluate(snap(50, at: 0), allOn)
        _ = b7.evaluate(snap(nil, at: 180), allOn)
        let h1 = b7.evaluate(snap(58, at: 360), allOn)
        let h2 = b7.evaluate(snap(61, at: 540), allOn)
        try check(h1.isEmpty && h2 == [.burnRate(percent: 61)], "nil percent skipped; fires once span/count met")

        // Weekly surge never triggers burn-rate (session-only).
        var b8 = AlertEngine()
        _ = b8.evaluate(snap(10, 50, at: 0), allOn)
        _ = b8.evaluate(snap(10, 60, at: 180), allOn)
        try check(b8.evaluate(snap(10, 70, at: 360), allOn).isEmpty, "weekly surge never triggers burn-rate")
    }
}

// MARK: - --probe : read keychain + one live GET /usage, print, exit

enum Probe {
    static func run() {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await probe()
            sem.signal()
        }
        sem.wait()
    }

    static func probe() async {
        let credResult = KeychainReader.readCredentials()
        guard case .success(let creds) = credResult else {
            if case .failure(let error) = credResult { print("keychain: FAILED — \(error)") }
            return
        }

        // Stop at the non-secret label boundary ("sk-ant-oat01-" is 13 chars) — never print any secret byte.
        let prefix = String(creds.accessToken.prefix(13))
        let refresh = creds.refreshToken != nil ? "present" : "absent"
        let expires = creds.expiresAtMs.map { String(Int($0)) } ?? "nil"
        print("keychain: ok — token \(prefix)… (len \(creds.accessToken.count)), refresh \(refresh), expiresAt \(expires)")

        let client = UsageClient(userAgent: AppDelegate.userAgent())
        let outcome = await client.fetchUsage(accessToken: creds.accessToken)
        switch outcome {
        case .success(let r):
            let snap = UsageSnapshot.from(r)
            print("GET /usage: 200")
            print("  session : \(fmt(snap.sessionPercent))  \(countdownString(to: snap.sessionResetsAt))")
            print("  weekly  : \(fmt(snap.weeklyPercent))  \(countdownString(to: snap.weeklyResetsAt))")
            print("  bar shows: \(bindingMetric(snap).kind)")
        case .unauthorized:
            print("GET /usage: 401 unauthorized")
        case .rateLimited(let ra):
            let retry = ra.map { "\($0)" } ?? "nil"
            print("GET /usage: 429 rate-limited (retryAfter=\(retry))")
        case .server(let code):
            print("GET /usage: HTTP \(code)")
        case .transport(let e):
            print("GET /usage: transport error — \(e)")
        case .decode(let e):
            print("GET /usage: decode error — \(e)")
        }
    }

    static func fmt(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "—" }
}
