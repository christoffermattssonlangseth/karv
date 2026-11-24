import Foundation

public enum KarvDemoData {
    public static func makeSnapshot(referenceDate: Date = Date()) -> KarvSnapshot {
        let cal = Calendar.current

        func history(_ values: [Double], prefix: String) -> [UsageHistoryPoint] {
            values.enumerated().map { idx, val in
                let daysAgo = (values.count - 1) - idx
                let date = cal.date(byAdding: .day, value: -daysAgo, to: referenceDate) ?? referenceDate
                return UsageHistoryPoint(id: "\(prefix)-\(idx)", date: date, usedPercent: val)
            }
        }

        let claude = ProviderUsageSnapshot(
            provider: .claude,
            planName: "Max 5x",
            isConnected: true,
            primaryWindow: QuotaWindow(
                id: "claude-5h",
                title: "5h Session",
                subtitle: "Opus & Sonnet rolling window",
                usedPercent: 0.64,
                resetsAt: referenceDate.addingTimeInterval(2 * 3600 + 18 * 60),
                detailText: "64% of 5-hour burst window"
            ),
            secondaryWindow: QuotaWindow(
                id: "claude-weekly",
                title: "Weekly Cap",
                subtitle: "All models combined",
                usedPercent: 0.41,
                resetsAt: referenceDate.addingTimeInterval(3 * 86400 + 11 * 3600),
                detailText: "41% of 7-day allocation"
            ),
            history: history([0.32, 0.48, 0.71, 0.54, 0.83, 0.61, 0.64], prefix: "claude"),
            lastSyncedAt: referenceDate.addingTimeInterval(-90),
            source: .claudeCLI,
            statusNote: "Synced from ~/.claude"
        )

        let codex = ProviderUsageSnapshot(
            provider: .codex,
            planName: "Pro",
            isConnected: true,
            primaryWindow: QuotaWindow(
                id: "codex-5h",
                title: "5h Window",
                subtitle: "Codex CLI & Cloud tasks",
                usedPercent: 0.28,
                resetsAt: referenceDate.addingTimeInterval(3 * 3600 + 44 * 60),
                detailText: "28% of 5-hour rate limit"
            ),
            secondaryWindow: QuotaWindow(
                id: "codex-weekly",
                title: "Weekly Limit",
                subtitle: "7-day rolling quota",
                usedPercent: 0.53,
                resetsAt: referenceDate.addingTimeInterval(4 * 86400 + 5 * 3600),
                detailText: "53% of weekly allocation"
            ),
            history: history([0.45, 0.52, 0.39, 0.67, 0.49, 0.35, 0.28], prefix: "codex"),
            lastSyncedAt: referenceDate.addingTimeInterval(-90),
            source: .codexCLI,
            statusNote: "Synced from ~/.codex/sessions"
        )

        let gemini = ProviderUsageSnapshot(
            provider: .gemini,
            planName: "AI Ultra",
            isConnected: true,
            primaryWindow: QuotaWindow(
                id: "gemini-daily",
                title: "Daily Quota",
                subtitle: "Gemini Pro & Flash CLI",
                usedPercent: 0.84,
                resetsAt: referenceDate.addingTimeInterval(5 * 3600 + 12 * 60),
                detailText: "84% of daily request allowance"
            ),
            secondaryWindow: QuotaWindow(
                id: "gemini-weekly",
                title: "Weekly Context",
                subtitle: "High-thinking tier usage",
                usedPercent: 0.37,
                resetsAt: referenceDate.addingTimeInterval(2 * 86400 + 19 * 3600),
                detailText: "37% of weekly deep-reasoning cap"
            ),
            history: history([0.19, 0.31, 0.44, 0.62, 0.58, 0.76, 0.84], prefix: "gemini"),
            lastSyncedAt: referenceDate.addingTimeInterval(-90),
            source: .geminiCLI,
            statusNote: "Synced from ~/.gemini"
        )

        return KarvSnapshot(
            providers: [claude, codex, gemini],
            sourceDeviceName: "Christoffer’s MacBook Pro",
            updatedAt: referenceDate.addingTimeInterval(-90),
            isDemoData: true
        )
    }

    public static func makeSimulatedRefresh(from current: KarvSnapshot) -> KarvSnapshot {
        let now = Date()
        let updatedProviders = current.providers.map { item -> ProviderUsageSnapshot in
            var copy = item
            let delta = Double.random(in: -0.05...0.08)
            let nextUsed = min(max(item.primaryWindow.usedPercent + delta, 0.05), 0.96)
            copy.primaryWindow = QuotaWindow(
                id: item.primaryWindow.id,
                title: item.primaryWindow.title,
                subtitle: item.primaryWindow.subtitle,
                usedPercent: nextUsed,
                resetsAt: item.primaryWindow.resetsAt,
                detailText: item.primaryWindow.detailText
            )
            copy.lastSyncedAt = now
            if !copy.history.isEmpty {
                var hist = copy.history
                let last = hist.removeLast()
                hist.append(UsageHistoryPoint(id: last.id, date: now, usedPercent: nextUsed))
                copy.history = hist
            }
            return copy
        }

        return KarvSnapshot(
            providers: updatedProviders,
            sourceDeviceName: current.sourceDeviceName,
            updatedAt: now,
            isDemoData: current.isDemoData
        )
    }
}
