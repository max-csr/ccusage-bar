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
