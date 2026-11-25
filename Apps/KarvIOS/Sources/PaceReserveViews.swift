import SwiftUI
import KarvCore

private extension QuotaPace.State {
    var tint: Color {
        switch self {
        case .underPace: QuotaStatus.nominal.tintColor
        case .onPace: KarvTheme.textSecondary
        case .overPace: QuotaStatus.critical.tintColor
        }
    }

    var symbol: String {
        switch self {
        case .underPace: "arrow.up.right"
        case .onPace: "equal"
        case .overPace: "arrow.down.right"
        }
    }
}

/// Compact one-line reserve indicator for the dashboard window tiles, e.g.
/// "▲ 15% reserve · 45m" or "▼ 8% over · out in 1h 10m".
struct PaceReserveLine: View {
    let window: QuotaWindow
    let isSecondary: Bool
    let now: Date

    var body: some View {
        if window.isRolling {
            rollingBody
        } else {
            pacedBody
        }
    }

    /// Rolling windows have no reset to pace against; show when usage starts easing.
    private var rollingBody: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .bold))
            Text(window.reserveSummary(at: now, isSecondary: isSecondary).text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(KarvTheme.textSecondary)
    }

    private var pacedBody: some View {
        let pace = window.pace(at: now, isSecondary: isSecondary)
        return HStack(spacing: 4) {
            Image(systemName: pace.state.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(window.reserveSummary(at: now, isSecondary: isSecondary).text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(pace.state.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText(for: pace))
    }

    private func accessibilityText(for pace: QuotaPace) -> String {
        switch pace.state {
        case .onPace: "On pace"
        case .underPace: "\(KarvFormatting.percentString(pace.reserve)) in reserve, about \(KarvFormatting.durationString(pace.reserveTime)) ahead of an even pace"
        case .overPace: "\(KarvFormatting.percentString(-pace.reserve)) over pace"
        }
    }
}

/// Fuller explanation used in the provider detail sheet.
struct PaceReserveDetail: View {
    let window: QuotaWindow
    let isSecondary: Bool
    var isEstimate: Bool = false
    let now: Date

    var body: some View {
        if window.isRolling {
            rollingBody
        } else {
            pacedBody
        }
    }

    private var rollingBody: some View {
        var parts: [String] = []
        if isEstimate {
            parts.append("Estimated from local prompt history against your budget, not the provider's real quota.")
        }
        if let detail = window.detailText {
            parts.append(detail + ".")
        }
        parts.append("This is a rolling window: usage ages out continuously instead of resetting.")
        if window.usedPercent > 0, window.resetsAt > now {
            parts.append("The oldest counted prompt drops out in \(KarvFormatting.durationString(window.resetsAt.timeIntervalSince(now))).")
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .bold))
                Text("\(KarvFormatting.percentString(window.remainingPercent)) headroom")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(KarvTheme.textPrimary)

            Text(parts.joined(separator: " "))
                .font(.system(size: 12))
                .foregroundStyle(KarvTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pacedBody: some View {
        let pace = window.pace(at: now, isSecondary: isSecondary)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: pace.state.symbol)
                    .font(.system(size: 11, weight: .bold))
                Text(headline(for: pace))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(pace.state.tint)

            Text(explanation(for: pace))
                .font(.system(size: 12))
                .foregroundStyle(KarvTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            // Even-pace marker on a thin bar: fill = used, tick = where an even burn would be.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(pace.state.tint.opacity(0.8))
                        .frame(width: geo.size.width * pace.usedFraction)
                    Rectangle()
                        .fill(KarvTheme.textPrimary)
                        .frame(width: 2, height: 10)
                        .offset(x: max(0, geo.size.width * pace.elapsedFraction - 1))
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
        }
    }

    private func headline(for pace: QuotaPace) -> String {
        switch pace.state {
        case .underPace: "\(KarvFormatting.percentString(pace.reserve)) in reserve"
        case .onPace: "Right on pace"
        case .overPace: "\(KarvFormatting.percentString(-pace.reserve)) over pace"
        }
    }

    private func explanation(for pace: QuotaPace) -> String {
        let elapsed = KarvFormatting.percentString(pace.elapsedFraction)
        let used = KarvFormatting.percentString(pace.usedFraction)
        var parts = ["\(elapsed) of the window has passed and you've used \(used)."]

        switch pace.state {
        case .underPace:
            parts.append("That's about \(KarvFormatting.durationString(pace.reserveTime)) of headroom ahead of an even burn.")
        case .onPace:
            break
        case .overPace:
            if let empty = pace.projectedExhaustion(now: now) {
                parts.append("At this rate you'll run out in \(KarvFormatting.durationString(empty.timeIntervalSince(now))), \(KarvFormatting.durationString(pace.resetsAt.timeIntervalSince(empty))) before the reset.")
            } else {
                parts.append("You've used about \(KarvFormatting.durationString(-pace.reserveTime)) worth more than an even burn would by now.")
            }
        }
        if pace.state != .overPace || pace.projectedExhaustion(now: now) == nil,
           let projected = pace.projectedUsageAtReset {
            parts.append("Current rate lands at ~\(KarvFormatting.percentString(min(projected, 1))) by reset.")
        }
        return parts.joined(separator: " ")
    }
}

/// Status of each way data reaches the phone, plus the Claude token.
struct SyncHealthCard: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 10)) { context in
            let health = KarvSyncHealth.load()
            let token = KarvKeychain.loadClaudeTokenInfo()

            VStack(alignment: .leading, spacing: 12) {
                Text("SYNC HEALTH")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(KarvTheme.textTertiary)

                ForEach(KarvSyncChannel.allCases, id: \.self) { channel in
                    row(
                        title: channel.displayName,
                        entry: health[channel] ?? KarvSyncHealthEntry(),
                        now: context.date
                    )
                }

                tokenRow(token, now: context.date)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .karvCard(cornerRadius: 22)
        }
    }

    private func row(title: String, entry: KarvSyncHealthEntry, now: Date) -> some View {
        let status = entry.status(now: now)
        let color: Color = switch status {
        case .healthy: QuotaStatus.nominal.tintColor
        case .stale: QuotaStatus.elevated.tintColor
        case .failing: QuotaStatus.critical.tintColor
        case .unknown: KarvTheme.textTertiary
        }
        let detail: String = switch status {
        case .unknown: "Not used yet"
        case .failing: entry.lastMessage ?? "Failing"
        case .healthy, .stale:
            "OK \(entry.lastSuccess.map { KarvFormatting.relativeSyncString(from: $0, now: now) } ?? "")"
                + (entry.lastMessage.map { " · \($0)" } ?? "")
        }
        return healthRow(color: color, title: title, detail: detail)
    }

    private func tokenRow(_ token: ClaudeTokenInfo?, now: Date) -> some View {
        guard let token else {
            return healthRow(color: KarvTheme.textTertiary, title: "Claude token", detail: "None — turn on token sync in KarvMac")
        }
        let origin = token.source == .mac ? "from KarvMac" : "paired manually"
        if let expires = token.expiresAt {
            if expires <= now {
                return healthRow(
                    color: QuotaStatus.critical.tintColor,
                    title: "Claude token",
                    detail: "Expired \(KarvFormatting.relativeSyncString(from: expires, now: now)) · open Claude Code on your Mac"
                )
            }
            return healthRow(
                color: QuotaStatus.nominal.tintColor,
                title: "Claude token",
                detail: "Valid \(KarvFormatting.durationString(expires.timeIntervalSince(now))) · \(origin)"
            )
        }
        return healthRow(color: QuotaStatus.nominal.tintColor, title: "Claude token", detail: "Saved · \(origin)")
    }

    private func healthRow(color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(KarvTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(KarvTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

extension ProviderUsageSnapshot {
    /// Older than this and the reading is shown as stale.
    static let staleAfter: TimeInterval = 15 * 60

    func isStale(now: Date) -> Bool {
        now.timeIntervalSince(lastSyncedAt) > Self.staleAfter
    }
}
