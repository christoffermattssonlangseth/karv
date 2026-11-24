import Foundation
import Security
import KarvCore

/// Scans local CLI directories (~/.claude, ~/.codex, ~/.gemini) and local Claude Code OAuth
/// on macOS to build a KarvSnapshot suitable for syncing to iPhone via iCloud.
struct LocalUsageCollector: Sendable {
    private let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    func collectSnapshot(geminiSessionBudget: Double = 100.0) async -> KarvSnapshot {
        let now = Date()
        let hostName = Host.current().localizedName ?? "Mac"

        let claude = await collectClaude(now: now)
        let codex = collectCodex(now: now)
        let gemini = collectGemini(now: now, sessionBudget: geminiSessionBudget)

        return KarvSnapshot(
            providers: [claude, codex, gemini],
            sourceDeviceName: hostName,
            updatedAt: now,
            isDemoData: false
        )
    }

    /// Reads the local Claude Code OAuth token from macOS Keychain or ~/.claude/.credentials.json
    /// so KarvMac can also offer one-tap QR pairing for Direct Claude 5G Sync on iPhone.
    func readCurrentClaudeOAuthToken() -> String? {
        readClaudeOAuthToken()
    }

    // MARK: - Claude (~/.claude + Claude Code OAuth)

    private func collectClaude(now: Date) async -> ProviderUsageSnapshot {
        let claudeDir = homeDirectory.appendingPathComponent(".claude")
        let historyFile = claudeDir.appendingPathComponent("history.jsonl")
        let projectsDir = claudeDir.appendingPathComponent("projects")
        let exists = FileManager.default.fileExists(atPath: claudeDir.path)

        let timestamps = parseClaudeHistoryTimestamps(fileURL: historyFile)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)
        let historyPoints: [UsageHistoryPoint] = !timestamps.isEmpty
            ? bucketTimestampsByDay(timestamps.filter { $0 >= sevenDaysAgo }, now: now, dailyScale: 80.0, prefix: "claude")
            : dailyActivityHistory(in: projectsDir, now: now, dailyScale: 320.0, prefix: "claude")

        // 1. Try exact live usage from Anthropic's Claude Code OAuth usage endpoint
        if let token = readClaudeOAuthToken(),
           let live = await fetchClaudeOAuthUsage(token: token, now: now) {
            var updatedHistory = historyPoints
            if !updatedHistory.isEmpty {
                let last = updatedHistory.removeLast()
                updatedHistory.append(UsageHistoryPoint(id: last.id, date: now, usedPercent: live.fiveHourUsed))
            }

            return ProviderUsageSnapshot(
                provider: .claude,
                planName: live.planName ?? AIProvider.claude.defaultPlanName,
                isConnected: true,
                primaryWindow: QuotaWindow(
                    id: "claude-5h",
                    title: "5h Session",
                    subtitle: "Live Claude subscription limit",
                    usedPercent: live.fiveHourUsed,
                    resetsAt: live.fiveHourResetsAt,
                    detailText: "\(Int((live.fiveHourUsed * 100).rounded()))% of 5-hour window"
                ),
                secondaryWindow: QuotaWindow(
                    id: "claude-weekly",
                    title: "Weekly Cap",
                    subtitle: "7-day all-models limit",
                    usedPercent: live.sevenDayUsed,
                    resetsAt: live.sevenDayResetsAt,
                    detailText: "\(Int((live.sevenDayUsed * 100).rounded()))% of weekly cap"
                ),
                history: updatedHistory,
                lastSyncedAt: now,
                source: .claudeCLI,
                statusNote: "Live from Claude OAuth API"
            )
        }

        // 2. Fallback to local ~/.claude/history.jsonl activity estimate
        guard exists else {
            return disconnectedSnapshot(provider: .claude, now: now, note: "~/.claude not found")
        }

        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let recent5h: Int
        let recent7d: Int
        let oldestIn5h: Date?

        if !timestamps.isEmpty {
            let in5h = timestamps.filter { $0 >= fiveHoursAgo }
            let in7d = timestamps.filter { $0 >= sevenDaysAgo }
            recent5h = in5h.count
            recent7d = in7d.count
            oldestIn5h = in5h.min()
        } else {
            recent5h = countRecentJSONLEntries(in: projectsDir, since: fiveHoursAgo)
            recent7d = countRecentJSONLEntries(in: projectsDir, since: sevenDaysAgo)
            oldestIn5h = nil
        }

        let fiveHourUsed = min(Double(recent5h) / 60.0, 1.0)
        let weeklyUsed = min(Double(recent7d) / 500.0, 1.0)
        let fiveHourReset = oldestIn5h?.addingTimeInterval(5 * 3600) ?? now.addingTimeInterval(5 * 3600)

        return ProviderUsageSnapshot(
            provider: .claude,
            planName: AIProvider.claude.defaultPlanName,
            isConnected: true,
            primaryWindow: QuotaWindow(
                id: "claude-5h",
                title: "5h Session",
                subtitle: "Claude Code rolling 5h activity",
                usedPercent: fiveHourUsed,
                resetsAt: fiveHourReset,
                detailText: "\(recent5h) prompts in last 5h"
            ),
            secondaryWindow: QuotaWindow(
                id: "claude-weekly",
                title: "Weekly Cap",
                subtitle: "7-day rolling activity",
                usedPercent: weeklyUsed,
                resetsAt: now.addingTimeInterval(7 * 86400),
                detailText: "\(recent7d) prompts in last 7d"
            ),
            history: historyPoints,
            lastSyncedAt: now,
            source: .claudeCLI,
            statusNote: "Local estimate from ~/.claude/history.jsonl"
        )
    }

    private struct ClaudeLiveUsage {
        let fiveHourUsed: Double
        let fiveHourResetsAt: Date
        let sevenDayUsed: Double
        let sevenDayResetsAt: Date
        let planName: String?
    }

    private func readClaudeOAuthToken() -> String? {
        // 1. Check macOS Keychain ("Claude Code-credentials")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let token = extractAccessToken(from: data) {
            return token
        }

        // 2. Fallback to ~/.claude/.credentials.json
        let credFile = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credFile),
           let token = extractAccessToken(from: data) {
            return token
        }
        return nil
    }

    private func extractAccessToken(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let access = oauth["accessToken"] as? String, !access.isEmpty {
            return access
        }
        if let access = json["accessToken"] as? String, !access.isEmpty {
            return access
        }
        return nil
    }

    private func fetchClaudeOAuthUsage(token: String, now: Date) async -> ClaudeLiveUsage? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        func parseDate(_ str: String?) -> Date? {
            guard let str else { return nil }
            return isoWithFrac.date(from: str) ?? isoBasic.date(from: str)
        }

        let fiveHour = json["five_hour"] as? [String: Any]
        let sevenDay = json["seven_day"] as? [String: Any]

        guard let fiveUtil = fiveHour?["utilization"] as? Double else { return nil }
        let sevenUtil = (sevenDay?["utilization"] as? Double) ?? 0

        let fiveReset = parseDate(fiveHour?["resets_at"] as? String) ?? now.addingTimeInterval(5 * 3600)
        let sevenReset = parseDate(sevenDay?["resets_at"] as? String) ?? now.addingTimeInterval(7 * 86400)

        return ClaudeLiveUsage(
            fiveHourUsed: min(max(fiveUtil / 100.0, 0), 1),
            fiveHourResetsAt: fiveReset,
            sevenDayUsed: min(max(sevenUtil / 100.0, 0), 1),
            sevenDayResetsAt: sevenReset,
            planName: nil
        )
    }

    private func parseClaudeHistoryTimestamps(fileURL: URL) -> [Date] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var dates: [Date] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = json["timestamp"] as? Double else {
                continue
            }
            let seconds = ts > 1_000_000_000_000 ? ts / 1000.0 : ts
            dates.append(Date(timeIntervalSince1970: seconds))
        }
        return dates
    }

    private func bucketTimestampsByDay(_ dates: [Date], now: Date, dailyScale: Double, prefix: String) -> [UsageHistoryPoint] {
        let cal = Calendar.current
        var buckets = Array(repeating: 0, count: 7)
        let todayStart = cal.startOfDay(for: now)
        for d in dates {
            let diff = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: todayStart).day ?? 99
            if (0..<7).contains(diff) {
                buckets[6 - diff] += 1
            }
        }
        return buckets.enumerated().map { idx, count in
            let daysAgo = 6 - idx
            let date = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return UsageHistoryPoint(
                id: "\(prefix)-day-\(idx)",
                date: date,
                usedPercent: min(Double(count) / dailyScale, 1.0)
            )
        }
    }

    // MARK: - Codex (~/.codex)

    private func collectCodex(now: Date) -> ProviderUsageSnapshot {
        let codexDir = homeDirectory.appendingPathComponent(".codex")
        let sessionsDir = codexDir.appendingPathComponent("sessions")
        let exists = FileManager.default.fileExists(atPath: codexDir.path)

        guard exists else {
            return disconnectedSnapshot(provider: .codex, now: now, note: "~/.codex not found")
        }

        // First attempt to parse Codex CLI's native rate_limits payload from the newest session JSONL.
        if let parsed = parseLatestCodexRateLimits(in: sessionsDir, now: now) {
            return ProviderUsageSnapshot(
                provider: .codex,
                planName: AIProvider.codex.defaultPlanName,
                isConnected: true,
                primaryWindow: QuotaWindow(
                    id: "codex-5h",
                    title: "5h Window",
                    subtitle: "Codex CLI rate limit",
                    usedPercent: parsed.primaryUsedPercent,
                    resetsAt: parsed.primaryResetsAt,
                    detailText: "Read from Codex session telemetry"
                ),
                secondaryWindow: QuotaWindow(
                    id: "codex-weekly",
                    title: "Weekly Limit",
                    subtitle: "7-day rolling quota",
                    usedPercent: parsed.secondaryUsedPercent,
                    resetsAt: parsed.secondaryResetsAt,
                    detailText: "Read from Codex session telemetry"
                ),
                history: dailyActivityHistory(in: sessionsDir, now: now, dailyScale: 240.0, prefix: "codex"),
                lastSyncedAt: now,
                source: .codexCLI,
                statusNote: "Live rate limits from ~/.codex/sessions"
            )
        }

        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)
        let recent5h = countRecentJSONLEntries(in: sessionsDir, since: fiveHoursAgo)
        let recent7d = countRecentJSONLEntries(in: sessionsDir, since: sevenDaysAgo)

        return ProviderUsageSnapshot(
            provider: .codex,
            planName: AIProvider.codex.defaultPlanName,
            isConnected: true,
            primaryWindow: QuotaWindow(
                id: "codex-5h",
                title: "5h Window",
                subtitle: "Codex CLI activity",
                usedPercent: min(Double(recent5h) / 200.0, 1.0),
                resetsAt: now.addingTimeInterval(5 * 3600),
                detailText: "\(recent5h) events in last 5h"
            ),
            secondaryWindow: QuotaWindow(
                id: "codex-weekly",
                title: "Weekly Limit",
                subtitle: "7-day rolling estimate",
                usedPercent: min(Double(recent7d) / 1800.0, 1.0),
                resetsAt: now.addingTimeInterval(7 * 86400),
                detailText: "\(recent7d) events in last 7d"
            ),
            history: dailyActivityHistory(in: sessionsDir, now: now, dailyScale: 240.0, prefix: "codex"),
            lastSyncedAt: now,
            source: .codexCLI,
            statusNote: "Connected via ~/.codex"
        )
    }

    // MARK: - Gemini (~/.gemini)

    private func collectGemini(now: Date, sessionBudget: Double) -> ProviderUsageSnapshot {
        let geminiDir = homeDirectory.appendingPathComponent(".gemini")
        let exists = FileManager.default.fileExists(atPath: geminiDir.path)

        guard exists else {
            return disconnectedSnapshot(provider: .gemini, now: now, note: "~/.gemini not found")
        }

        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)

        let agBrainDir = geminiDir.appendingPathComponent("antigravity-cli/brain")
        let cliTmpDir = geminiDir.appendingPathComponent("tmp")

        let (recent5h, recent7d, historyPoints): (Int, Int, [UsageHistoryPoint])
        if FileManager.default.fileExists(atPath: agBrainDir.path) {
            let turnDates = collectAntigravityTurnDates(in: agBrainDir, since: sevenDaysAgo)
            let in5h = turnDates.filter { $0 >= fiveHoursAgo }
            recent5h = in5h.count
            recent7d = turnDates.count
            historyPoints = bucketTimestampsByDay(turnDates, now: now, dailyScale: max(20.0, sessionBudget), prefix: "gemini")
        } else {
            recent5h = countRecentJSONLEntries(in: cliTmpDir, since: fiveHoursAgo)
            recent7d = countRecentJSONLEntries(in: cliTmpDir, since: sevenDaysAgo)
            historyPoints = dailyActivityHistory(in: cliTmpDir, now: now, dailyScale: max(20.0, sessionBudget), prefix: "gemini")
        }

        let safeBudget = max(20.0, sessionBudget)
        let sessionUsed = min(Double(recent5h) / safeBudget, 1.0)
        let weeklyUsed = min(Double(recent7d) / (safeBudget * 7.0), 1.0)
        let nextMidnight = Calendar.current.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(12 * 3600)

        return ProviderUsageSnapshot(
            provider: .gemini,
            planName: AIProvider.gemini.defaultPlanName,
            isConnected: true,
            primaryWindow: QuotaWindow(
                id: "gemini-session",
                title: "5h Session",
                subtitle: "Estimated local activity",
                usedPercent: sessionUsed,
                resetsAt: nextMidnight,
                detailText: "\(recent5h) prompts in last 5h"
            ),
            secondaryWindow: QuotaWindow(
                id: "gemini-weekly",
                title: "Weekly Cap",
                subtitle: "Estimated 7-day activity",
                usedPercent: weeklyUsed,
                resetsAt: now.addingTimeInterval(7 * 86400),
                detailText: "\(recent7d) prompts in last 7d"
            ),
            history: historyPoints,
            lastSyncedAt: now,
            source: .geminiCLI,
            statusNote: "Estimated from ~/.gemini"
        )
    }

    private func collectAntigravityTurnDates(in brainDir: URL, since cutoff: Date) -> [Date] {
        let fm = FileManager.default
        guard let conversations = try? fm.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let isoWithFrac = ISO8601DateFormatter()
        isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        var dates: [Date] = []
        for convo in conversations {
            let transcript = convo.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            guard let modified = try? transcript.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= cutoff,
                  let text = try? String(contentsOf: transcript, encoding: .utf8) else {
                continue
            }

            for line in text.split(separator: "\n") {
                // Count actual user prompts sent rather than internal tool-call steps
                guard line.contains("\"USER_INPUT\""),
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      (json["type"] as? String) == "USER_INPUT" else {
                    continue
                }
                if let ts = (json["created_at"] as? String) ?? (json["timestamp"] as? String),
                   let parsed = isoWithFrac.date(from: ts) ?? isoBasic.date(from: ts) {
                    if parsed >= cutoff {
                        dates.append(parsed)
                    }
                } else {
                    dates.append(modified)
                }
            }
        }
        return dates
    }

    // MARK: - Helpers

    private func disconnectedSnapshot(provider: AIProvider, now: Date, note: String) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: provider,
            planName: provider.defaultPlanName,
            isConnected: false,
            primaryWindow: QuotaWindow(
                id: "\(provider.rawValue)-primary",
                title: "Primary Window",
                subtitle: "Not connected",
                usedPercent: 0,
                resetsAt: now.addingTimeInterval(5 * 3600)
            ),
            secondaryWindow: nil,
            history: [],
            lastSyncedAt: now,
            source: .manual,
            statusNote: note
        )
    }

    private struct ParsedCodexRateLimits {
        let primaryUsedPercent: Double
        let primaryResetsAt: Date
        let secondaryUsedPercent: Double
        let secondaryResetsAt: Date
    }

    private func parseLatestCodexRateLimits(in directory: URL, now: Date) -> ParsedCodexRateLimits? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            candidates.append((fileURL, modified))
        }

        let recentFiles = candidates.sorted(by: { $0.modified > $1.modified }).prefix(5)
        for candidate in recentFiles {
            guard let text = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() {
                guard line.contains("rate_limits"),
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }

                let payload = (json["payload"] as? [String: Any]) ?? json
                guard let rateLimits = payload["rate_limits"] as? [String: Any] else { continue }

                let primary = rateLimits["primary"] as? [String: Any]
                let secondary = rateLimits["secondary"] as? [String: Any]

                if let pUsed = primary?["used_percent"] as? Double {
                    let pReset = (primary?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(5 * 3600)
                    let sUsed = (secondary?["used_percent"] as? Double) ?? 0
                    let sReset = (secondary?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? now.addingTimeInterval(7 * 86400)

                    return ParsedCodexRateLimits(
                        primaryUsedPercent: min(max(pUsed / 100.0, 0), 1),
                        primaryResetsAt: pReset,
                        secondaryUsedPercent: min(max(sUsed / 100.0, 0), 1),
                        secondaryResetsAt: sReset
                    )
                }
            }
        }
        return nil
    }

    private func countRecentJSONLEntries(in directory: URL, since cutoff: Date) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" || fileURL.pathExtension == "json" {
            guard let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= cutoff else {
                continue
            }
            if let data = try? Data(contentsOf: fileURL) {
                let newlines = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
                count += max(1, newlines)
            }
        }
        return count
    }

    private func dailyActivityHistory(in directory: URL, now: Date, dailyScale: Double, prefix: String) -> [UsageHistoryPoint] {
        let cal = Calendar.current
        var buckets = Array(repeating: 0, count: 7)

        let fm = FileManager.default
        if let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" || fileURL.pathExtension == "json" {
                guard let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                    continue
                }
                let dayDiff = cal.dateComponents([.day], from: cal.startOfDay(for: modified), to: cal.startOfDay(for: now)).day ?? 99
                if (0..<7).contains(dayDiff), let data = try? Data(contentsOf: fileURL) {
                    let lines = max(1, data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) })
                    buckets[6 - dayDiff] += lines
                }
            }
        }

        return buckets.enumerated().map { idx, count in
            let daysAgo = 6 - idx
            let date = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
            return UsageHistoryPoint(
                id: "\(prefix)-day-\(idx)",
                date: date,
                usedPercent: min(Double(count) / dailyScale, 1.0)
            )
        }
    }
}
