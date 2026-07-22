import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Wire models (api/oauth/usage response)
// Every field is optional on purpose: the endpoint is undocumented, so we
// degrade gracefully instead of failing to decode when the shape shifts.

struct UsageResponse: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
    let sevenDayOpus: Window?
    let sevenDaySonnet: Window?
    let limits: [LimitEntry]?
    let extraUsage: ExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
        case extraUsage = "extra_usage"
    }
}

struct Window: Decodable {
    let utilization: Double?
    let resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct LimitEntry: Decodable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: Date?
    let isActive: Bool?

    enum CodingKeys: String, CodingKey {
        case kind, group, percent
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool?
    let usedCredits: Double?
    let monthlyLimit: Double?
    let currency: String?
    // used_credits / monthly_limit are minor units (e.g. cents); decimal_places
    // says where the point goes: 4402 credits + 2 places -> 44.02 EUR.
    let decimalPlaces: Int?

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
        case currency
        case decimalPlaces = "decimal_places"
    }
}

// MARK: - Date decoding
// resets_at looks like "2026-06-29T12:49:59.673455+00:00" (microsecond fraction).
// The stock .iso8601 strategy rejects fractional seconds, and ISO8601DateFormatter
// is flaky beyond milliseconds — we only need minute precision, so strip the
// fraction and parse the plain internet date-time. resets_at == null -> nil (handled
// by the optional Date, the strategy is never invoked for null).

enum UsageDate {
    private static let isoNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        let cleaned = raw.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        return isoNoFraction.date(from: cleaned) ?? isoWithFraction.date(from: raw)
    }
}

extension JSONDecoder {
    static let usage: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = UsageDate.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unparseable date: \(raw)")
            }
            return date
        }
        return d
    }()
}

// MARK: - Resolved view state

enum UsageStatus: Equatable {
    case loading
    case ok
    case unauthorized   // token rejected and refresh failed -> re-auth in Claude Code
    case rateLimited    // 429, backing off
    case offline        // network/5xx/decode error; showing last good numbers
    case noToken        // no credentials in keychain (or access denied)
}

struct UsageSnapshot {
    var sessionPercent: Double?
    var sessionResetsAt: Date?
    var weeklyPercent: Double?
    var weeklyResetsAt: Date?
    var weeklyOpusPercent: Double?
    var weeklyOpusResetsAt: Date?
    var weeklySonnetPercent: Double?
    var weeklySonnetResetsAt: Date?
    var extraUsageEnabled: Bool
    var extraUsageUsedCredits: Double?
    var extraUsageCurrency: String?
    var extraUsageDecimalPlaces: Int?
    var status: UsageStatus
    var lastUpdated: Date?

    init(sessionPercent: Double? = nil,
         sessionResetsAt: Date? = nil,
         weeklyPercent: Double? = nil,
         weeklyResetsAt: Date? = nil,
         weeklyOpusPercent: Double? = nil,
         weeklyOpusResetsAt: Date? = nil,
         weeklySonnetPercent: Double? = nil,
         weeklySonnetResetsAt: Date? = nil,
         extraUsageEnabled: Bool = false,
         extraUsageUsedCredits: Double? = nil,
         extraUsageCurrency: String? = nil,
         extraUsageDecimalPlaces: Int? = nil,
         status: UsageStatus,
         lastUpdated: Date? = nil) {
        self.sessionPercent = sessionPercent
        self.sessionResetsAt = sessionResetsAt
        self.weeklyPercent = weeklyPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.weeklyOpusPercent = weeklyOpusPercent
        self.weeklyOpusResetsAt = weeklyOpusResetsAt
        self.weeklySonnetPercent = weeklySonnetPercent
        self.weeklySonnetResetsAt = weeklySonnetResetsAt
        self.extraUsageEnabled = extraUsageEnabled
        self.extraUsageUsedCredits = extraUsageUsedCredits
        self.extraUsageCurrency = extraUsageCurrency
        self.extraUsageDecimalPlaces = extraUsageDecimalPlaces
        self.status = status
        self.lastUpdated = lastUpdated
    }

    static func from(_ r: UsageResponse, status: UsageStatus = .ok, now: Date = Date()) -> UsageSnapshot {
        func limit(_ kind: String) -> LimitEntry? { r.limits?.first { $0.kind == kind } }
        return UsageSnapshot(
            sessionPercent: r.fiveHour?.utilization ?? limit("session")?.percent,
            sessionResetsAt: r.fiveHour?.resetsAt ?? limit("session")?.resetsAt,
            weeklyPercent: r.sevenDay?.utilization ?? limit("weekly_all")?.percent,
            weeklyResetsAt: r.sevenDay?.resetsAt ?? limit("weekly_all")?.resetsAt,
            weeklyOpusPercent: r.sevenDayOpus?.utilization,
            weeklyOpusResetsAt: r.sevenDayOpus?.resetsAt,
            weeklySonnetPercent: r.sevenDaySonnet?.utilization,
            weeklySonnetResetsAt: r.sevenDaySonnet?.resetsAt,
            extraUsageEnabled: r.extraUsage?.isEnabled ?? false,
            extraUsageUsedCredits: r.extraUsage?.usedCredits,
            extraUsageCurrency: r.extraUsage?.currency,
            extraUsageDecimalPlaces: r.extraUsage?.decimalPlaces,
            status: status,
            lastUpdated: now)
    }
}

extension UsageSnapshot {
    /// Extra-usage spend in whole currency units. The API reports `used_credits`
    /// in minor units (e.g. cents) alongside `decimal_places`; 4402 credits at
    /// 2 places is 44.02 EUR — NOT 4402. Defaults to 2 places when the API omits
    /// the field (every observed currency response has sent it).
    var extraUsageAmount: Double? {
        guard let credits = extraUsageUsedCredits else { return nil }
        return credits / pow(10.0, Double(extraUsageDecimalPlaces ?? 2))
    }
}

// MARK: - Display logic

enum BarKind { case session, weekly }

struct BarDisplay {
    let kind: BarKind
    let percent: Double?
    let resetsAt: Date?
}

/// Max's rule. Default to the 5-hour session.
/// Switch to weekly only when weekly is dangerous (>= 80% used, i.e. <= 20% left)
/// AND the session is not itself dangerous. If the session is also dangerous it wins,
/// because the 5-hour window is the more immediate wall.
func bindingMetric(_ s: UsageSnapshot, dangerThreshold: Double = 80) -> BarDisplay {
    let session = BarDisplay(kind: .session, percent: s.sessionPercent, resetsAt: s.sessionResetsAt)
    let weekly = BarDisplay(kind: .weekly, percent: s.weeklyPercent, resetsAt: s.weeklyResetsAt)
    if let sv = s.sessionPercent, sv >= dangerThreshold { return session }
    if let wv = s.weeklyPercent, wv >= dangerThreshold { return weekly }
    return session
}

enum Tier {
    case normal, caution, warning, critical

    /// Healthy = green, escalating to red. Matches the inspiration (low usage = green).
    static func of(_ percent: Double?) -> Tier {
        guard let p = percent else { return .normal }
        switch p {
        case ..<50:  return .normal
        case ..<80:  return .caution
        case ..<95:  return .warning
        default:     return .critical
        }
    }

    #if canImport(AppKit)
    /// Concrete, appearance-independent color for the menu-bar ring + popover bars.
    var color: NSColor {
        switch self {
        case .normal:   return .systemGreen
        case .caution:  return .systemYellow
        case .warning:  return .systemOrange
        case .critical: return .systemRed
        }
    }
    #endif
}

// MARK: - Time formatting

/// Compact form for the menu bar, e.g. "1 h 47 m" or "2 d 10 h".
func menuBarTimeString(to date: Date?, now: Date = Date()) -> String {
    guard let date = date else { return "—" }
    let remaining = date.timeIntervalSince(now)
    if remaining <= 0 { return "0 m" }
    let totalMinutes = Int(remaining / 60)
    let days = totalMinutes / 1440
    let hours = (totalMinutes % 1440) / 60
    let minutes = totalMinutes % 60
    if days > 0 { return "\(days) d \(hours) h" }
    return "\(hours) h \(minutes) m"
}

/// Verbose form for the popover, e.g. "Resets in 4h 13m".
func countdownString(to date: Date?, now: Date = Date()) -> String {
    guard let date = date else { return "Resets in --" }
    let remaining = date.timeIntervalSince(now)
    if remaining <= 0 { return "Resetting…" }
    let totalMinutes = Int(remaining / 60)
    let days = totalMinutes / 1440
    let hours = (totalMinutes % 1440) / 60
    let minutes = totalMinutes % 60
    if days > 0 { return "Resets in \(days)d \(hours)h" }
    if hours > 0 { return "Resets in \(hours)h \(minutes)m" }
    return "Resets in \(minutes)m"
}

/// "Updated 31s ago" footer text.
func relativeUpdated(_ date: Date?, now: Date = Date()) -> String {
    guard let date = date else { return "Not updated yet" }
    let secs = max(0, Int(now.timeIntervalSince(date)))
    if secs < 5 { return "Updated just now" }
    if secs < 60 { return "Updated \(secs)s ago" }
    let mins = secs / 60
    if mins < 60 { return "Updated \(mins)m ago" }
    let hrs = mins / 60
    return "Updated \(hrs)h ago"
}
