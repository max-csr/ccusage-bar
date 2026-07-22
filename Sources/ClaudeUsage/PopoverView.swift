import SwiftUI

@MainActor
final class PopoverModel: ObservableObject {
    @Published var snapshot = UsageSnapshot(status: .loading)
    @Published var launchAtLogin = false
    @Published var update: UpdateInfo?
    @Published var updateCheckState: UpdateCheckState = .idle
    @Published var thresholdEnabled = true
    @Published var thresholdPercent: Double = 90
    @Published var burnRateEnabled = true

    var onRefresh: (() -> Void)?
    var onToggleLogin: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenUpdate: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onQuit: (() -> Void)?
    var onSetThresholdEnabled: ((Bool) -> Void)?
    var onSetThreshold: ((Double) -> Void)?
    var onSetBurnRateEnabled: ((Bool) -> Void)?
}

struct PopoverView: View {
    @ObservedObject var model: PopoverModel

    private var snap: UsageSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let update = model.update {
                UpdateBanner(version: update.version) { model.onOpenUpdate?() }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }

            // TimelineView keeps the countdowns and "updated ago" live while the
            // popover is open, recomputing from the current time — no network calls.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 18) {
                    LimitRow(title: "5-Hour",
                             percent: snap.sessionPercent,
                             resetsAt: snap.sessionResetsAt,
                             now: context.date)

                    weeklySection(now: context.date)

                    extraUsageSection

                    Text(relativeUpdated(snap.lastUpdated, now: context.date))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
            }

            if let banner = bannerText {
                Text(banner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
            }

            footer
        }
        .frame(width: 360)
        .padding(.bottom, 8)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Claude Usage")
                .font(.title3.weight(.semibold))
            Spacer()
            Button(action: { model.onRefresh?() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    // MARK: - Weekly section

    @ViewBuilder
    private func weeklySection(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Weekly Limits")
            LimitRow(title: "All models",
                     percent: snap.weeklyPercent,
                     resetsAt: snap.weeklyResetsAt,
                     now: now)
            if let opus = snap.weeklyOpusPercent, snap.weeklyOpusResetsAt != nil {
                LimitRow(title: "Opus", percent: opus, resetsAt: snap.weeklyOpusResetsAt, now: now)
            }
            if let sonnet = snap.weeklySonnetPercent, snap.weeklySonnetResetsAt != nil {
                LimitRow(title: "Sonnet", percent: sonnet, resetsAt: snap.weeklySonnetResetsAt, now: now)
            }
        }
    }

    // MARK: - Extra usage section

    private var extraUsageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Extra Usage")
            Text(extraUsageText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var extraUsageText: String {
        let amount = snap.extraUsageAmount ?? 0
        guard snap.extraUsageEnabled, amount > 0 else {
            return "No extra usage yet this period."
        }
        let currency = snap.extraUsageCurrency ?? ""
        let places = snap.extraUsageDecimalPlaces ?? 2
        let value = String(format: "%.\(places)f", amount)
        return "\(value) \(currency) used this period.".trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().padding(.vertical, 8)
            MenuButton(title: "Settings…", systemImage: "gearshape") { model.onOpenSettings?() }
            MenuButton(title: "Quit", systemImage: "power") { model.onQuit?() }
        }
        .padding(.horizontal, 8)
    }

    private var bannerText: String? {
        switch snap.status {
        case .noToken:      return "Not signed in. Run Claude Code once to authenticate."
        case .unauthorized: return "Session expired. Open Claude Code to re-authenticate."
        case .rateLimited:  return "Rate-limited by the usage API — backing off."
        case .offline:      return "Offline — showing the last known values."
        case .loading, .ok: return nil
        }
    }
}

// MARK: - Components

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
    }
}

private struct LimitRow: View {
    let title: String
    let percent: Double?
    let resetsAt: Date?
    let now: Date

    private var tier: Tier { Tier.of(percent) }
    private var tint: Color { Color(nsColor: tier.color) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body)
                    .frame(width: 92, alignment: .leading)
                UsageBar(fraction: min((percent ?? 0) / 100, 1.0), tint: tint, known: percent != nil)
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(percent == nil ? Color.secondary : .primary)
                    .frame(width: 44, alignment: .trailing)
            }
            Text(countdownString(to: resetsAt, now: now))
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 104)
        }
    }
}

private struct UsageBar: View {
    let fraction: Double
    let tint: Color
    var known: Bool = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                if known {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, min(fraction, 1)) * geo.size.width)
                }
            }
        }
        .frame(height: 7)
    }
}

private struct UpdateBanner: View {
    let version: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text("Update available — v\(version)")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Get it", action: action)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .systemOrange).opacity(0.12)))
    }
}

private struct MenuButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
