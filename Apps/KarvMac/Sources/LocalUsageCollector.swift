import Foundation
import Security
import KarvCore

/// Scans local CLI directories (~/.claude, ~/.codex, ~/.gemini) and local Claude Code OAuth
/// on macOS to build a KarvSnapshot suitable for syncing to iPhone via iCloud.
struct LocalUsageCollector: Sendable {
    /// Marks a Claude reading that came from the live API (vs. the local estimate).
    static let liveClaudeSubtitle = "Live Claude subscription limit"

    private let homeDirectory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    /// - Parameter lastLiveClaude: the most recent reading that came from the Claude API.
    ///   When the API call fails (429, expired token, offline) this is kept instead of
    ///   replacing a real reading with the rough local estimate.
    func collectSnapshot(
        geminiSessionBudget: Double = 100.0,
        lastLiveClaude: ProviderUsageSnapshot? = nil,
        antigravity: AntigravityQuotaReader.Outcome? = nil,
        lastLiveGemini: ProviderUsageSnapshot? = nil
    ) async -> KarvSnapshot {
        let now = Date()
        let hostName = Host.current().localizedName ?? "Mac"

        let claude = await collectClaude(now: now, lastLive: lastLiveClaude)
        let codex = collectCodex(now: now)
        let gemini = collectGemini(now: now, sessionBudget: geminiSessionBudget, antigravity: antigravity, lastLive: lastLiveGemini)

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

    /// Claude Code's current access token plus its expiry, for sharing with the iPhone.
    func readClaudeCredential() -> ClaudeTokenInfo? {
        guard let data = readClaudeCredentialData(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeTokenInfo(token: token, expiresAt: expiresAt, source: .mac)
    }

    // MARK: - Claude (~/.claude + Claude Code OAuth)

    private func collectClaude(now: Date, lastLive: ProviderUsageSnapshot?) async -> ProviderUsageSnapshot {
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
        let outcome: ClaudeOAuthFetchOutcome? = if let token = readClaudeOAuthToken() {
            await ClaudeUsageGate.shared.fetch(token: token, now: now)
        } else {
            nil
        }
        if let live = outcome?.result {
            var updatedHistory = historyPoints
            if !updatedHistory.isEmpty {
                let last = updatedHistory.removeLast()
                updatedHistory.append(UsageHistoryPoint(id: last.id, date: now, usedPercent: live.fiveHourUsed))
            }

            return ProviderUsageSnapshot(
                provider: .claude,
                planName: AIProvider.claude.defaultPlanName,
                isConnected: true,
                primaryWindow: QuotaWindow(
                    id: "claude-5h",
                    title: "5h Session",
                    subtitle: Self.liveClaudeSubtitle,
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

        // 2. Keep the last real reading (with its original timestamp) while its 5h window
        //    is still current, so a transient API failure doesn't publish wrong numbers.
        if var kept = lastLive, kept.primaryWindow.resetsAt > now {
            switch outcome {
            case .throttled?, .success?:
                break // normal cooldown between polls; nothing to report
            case .unauthorized?:
                kept.statusNote = "Claude token expired — open Claude Code on this Mac to refresh it"
            case nil:
                kept.statusNote = "Claude Code token not found on this Mac"
            case let other?:
                kept.statusNote = other.failureNote
            }
            return kept
        }

        // 3. Fallback to local ~/.claude/history.jsonl activity estimate
        guard exists else {
            return disconnectedSnapshot(provider: .claude, now: now, note: "~/.claude not found")
        }

        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let recent5h: Int
        let recent7d: Int
        let oldestIn5h: Date?
        var oldestIn7d: Date?

        if !timestamps.isEmpty {
            let in5h = timestamps.filter { $0 >= fiveHoursAgo }
            let in7d = timestamps.filter { $0 >= sevenDaysAgo }
            recent5h = in5h.count
            recent7d = in7d.count
            oldestIn5h = in5h.min()
            oldestIn7d = in7d.min()
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
                detailText: "\(recent5h)/60 prompts in last 5h",
                isRolling: true
            ),
            secondaryWindow: QuotaWindow(
                id: "claude-weekly",
                title: "Weekly Cap",
                subtitle: "7-day rolling activity",
                usedPercent: weeklyUsed,
                resetsAt: oldestIn7d?.addingTimeInterval(7 * 86400) ?? now.addingTimeInterval(7 * 86400),
                detailText: "\(recent7d)/500 prompts in last 7d",
                isRolling: true
            ),
            history: historyPoints,
            lastSyncedAt: now,
            source: .claudeCLI,
            statusNote: "Local estimate from ~/.claude/history.jsonl",
            isEstimate: true
        )
    }

    private func readClaudeOAuthToken() -> String? {
        readClaudeCredentialData().flatMap(extractAccessToken(from:))
    }

    private func readClaudeCredentialData() -> Data? {
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
           extractAccessToken(from: data) != nil {
            return data
        }

        // 2. Fallback to ~/.claude/.credentials.json
        let credFile = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credFile),
           extractAccessToken(from: data) != nil {
            return data
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
                detailText: "\(recent5h)/200 events in last 5h",
                isRolling: true
            ),
            secondaryWindow: QuotaWindow(
                id: "codex-weekly",
                title: "Weekly Limit",
                subtitle: "7-day rolling estimate",
                usedPercent: min(Double(recent7d) / 1800.0, 1.0),
                resetsAt: now.addingTimeInterval(7 * 86400),
                detailText: "\(recent7d)/1800 events in last 7d",
                isRolling: true
            ),
            history: dailyActivityHistory(in: sessionsDir, now: now, dailyScale: 240.0, prefix: "codex"),
            lastSyncedAt: now,
            source: .codexCLI,
            statusNote: "Estimated from ~/.codex activity",
            isEstimate: true
        )
    }

    // MARK: - Gemini (~/.gemini)

    /// Marks a Gemini reading that came from Antigravity's real quota (vs. the estimate).
    static let liveGeminiSubtitle = "Live from Antigravity"

    private func collectGemini(
        now: Date,
        sessionBudget: Double,
        antigravity: AntigravityQuotaReader.Outcome?,
        lastLive: ProviderUsageSnapshot?
    ) -> ProviderUsageSnapshot {
        let geminiDir = homeDirectory.appendingPathComponent(".gemini")
        let exists = FileManager.default.fileExists(atPath: geminiDir.path)

        // 1. Real quota from Antigravity (opt-in).
        if case let .success(models)? = antigravity,
           let live = geminiFromAntigravity(models, now: now, history: geminiActivityHistory(now: now, sessionBudget: sessionBudget)) {
            return live
        }
        // 2. Last real reading while its window hasn't reset (e.g. Antigravity closed).
        if antigravity != nil, var kept = lastLive, kept.primaryWindow.resetsAt > now {
            switch antigravity {
            case .tokenExpired?:
                kept.statusNote = "Last Antigravity reading · updates when Antigravity runs"
            case .accessDenied?:
                kept.statusNote = "Keychain access to Antigravity denied"
            case .noCredentials?:
                kept.statusNote = "Not signed in to Antigravity"
            case let .failed(message)?:
                kept.statusNote = "Antigravity quota unavailable: \(message)"
            default:
                break
            }
            return kept
        }

        guard exists else {
            return disconnectedSnapshot(provider: .gemini, now: now, note: "~/.gemini not found")
        }

        let fiveHoursAgo = now.addingTimeInterval(-5 * 3600)
        let sevenDaysAgo = now.addingTimeInterval(-7 * 86400)

        let agBrainDir = geminiDir.appendingPathComponent("antigravity-cli/brain")
        let cliTmpDir = geminiDir.appendingPathComponent("tmp")

        let (recent5h, recent7d, historyPoints): (Int, Int, [UsageHistoryPoint])
        var sessionRelief = now.addingTimeInterval(5 * 3600)
        var weeklyRelief = now.addingTimeInterval(7 * 86400)
        if FileManager.default.fileExists(atPath: agBrainDir.path) {
            let turnDates = collectAntigravityTurnDates(in: agBrainDir, since: sevenDaysAgo)
            let in5h = turnDates.filter { $0 >= fiveHoursAgo }
            recent5h = in5h.count
            recent7d = turnDates.count
            sessionRelief = Self.rollingRelief(in5h, window: 5 * 3600, now: now)
            weeklyRelief = Self.rollingRelief(turnDates, window: 7 * 86400, now: now)
            historyPoints = bucketTimestampsByDay(turnDates, now: now, dailyScale: max(20.0, sessionBudget), prefix: "gemini")
        } else {
            recent5h = countRecentJSONLEntries(in: cliTmpDir, since: fiveHoursAgo)
            recent7d = countRecentJSONLEntries(in: cliTmpDir, since: sevenDaysAgo)
            historyPoints = dailyActivityHistory(in: cliTmpDir, now: now, dailyScale: max(20.0, sessionBudget), prefix: "gemini")
        }

        let safeBudget = max(20.0, sessionBudget)
        let weeklyBudget = safeBudget * 7.0
        let sessionUsed = min(Double(recent5h) / safeBudget, 1.0)
        let weeklyUsed = min(Double(recent7d) / weeklyBudget, 1.0)

        return ProviderUsageSnapshot(
            provider: .gemini,
            planName: AIProvider.gemini.defaultPlanName,
            isConnected: true,
            primaryWindow: QuotaWindow(
                id: "gemini-session",
                title: "5h Session",
                subtitle: "Estimated local activity",
                usedPercent: sessionUsed,
                resetsAt: sessionRelief,
                detailText: "\(recent5h)/\(Int(safeBudget)) prompts in last 5h",
                isRolling: true
            ),
            secondaryWindow: QuotaWindow(
                id: "gemini-weekly",
                title: "Weekly Cap",
                subtitle: "Estimated 7-day activity",
                usedPercent: weeklyUsed,
                resetsAt: weeklyRelief,
                detailText: "\(recent7d)/\(Int(weeklyBudget)) prompts in last 7d",
                isRolling: true
            ),
            history: historyPoints,
            lastSyncedAt: now,
            source: .geminiCLI,
            statusNote: "Estimated from ~/.gemini",
            isEstimate: true
        )
    }

    /// 7-day activity chart from local prompt history (same as the estimate uses).
    private func geminiActivityHistory(now: Date, sessionBudget: Double) -> [UsageHistoryPoint] {
        let geminiDir = homeDirectory.appendingPathComponent(".gemini")
        let agBrainDir = geminiDir.appendingPathComponent("antigravity-cli/brain")
        let scale = max(20.0, sessionBudget)
        if FileManager.default.fileExists(atPath: agBrainDir.path) {
            let dates = collectAntigravityTurnDates(in: agBrainDir, since: now.addingTimeInterval(-7 * 86400))
            return bucketTimestampsByDay(dates, now: now, dailyScale: scale, prefix: "gemini")
        }
        return dailyActivityHistory(in: geminiDir.appendingPathComponent("tmp"), now: now, dailyScale: scale, prefix: "gemini")
    }

    /// Maps per-model Antigravity quota to Karv's two windows. The tightest Gemini model
    /// is what limits you, so it drives each window; quotas resetting more than two days
    /// out are treated as the weekly window.
    private func geminiFromAntigravity(_ models: [AntigravityQuotaReader.ModelQuota], now: Date, history: [UsageHistoryPoint]) -> ProviderUsageSnapshot? {
        let gemini = models.filter { ($0.id + " " + $0.name).lowercased().contains("gemini") }
        let pool = gemini.isEmpty ? models : gemini
        guard !pool.isEmpty else { return nil }

        let weeklyHorizon: TimeInterval = 2 * 86400
        let short = pool.filter { ($0.resetsAt ?? now).timeIntervalSince(now) <= weeklyHorizon }
        let long = pool.filter { ($0.resetsAt ?? now).timeIntervalSince(now) > weeklyHorizon }
        func tightest(_ list: [AntigravityQuotaReader.ModelQuota]) -> AntigravityQuotaReader.ModelQuota? {
            list.min { $0.remaining < $1.remaining }
        }
        guard let primarySource = tightest(short) ?? tightest(long) else { return nil }
        let secondarySource = short.isEmpty ? nil : tightest(long)

        func window(_ m: AntigravityQuotaReader.ModelQuota, id: String) -> QuotaWindow {
            let reset = m.resetsAt ?? now.addingTimeInterval(5 * 3600)
            let horizon = reset.timeIntervalSince(now)
            let title = horizon <= 5.5 * 3600 ? "5h Session" : (horizon <= 26 * 3600 ? "Daily Quota" : "Weekly Cap")
            return QuotaWindow(
                id: id,
                title: title,
                subtitle: Self.liveGeminiSubtitle,
                usedPercent: 1 - m.remaining,
                resetsAt: reset,
                detailText: "\(m.name) · tightest of \(pool.count) models"
            )
        }

        var updatedHistory = history
        if !updatedHistory.isEmpty {
            let last = updatedHistory.removeLast()
            updatedHistory.append(UsageHistoryPoint(id: last.id, date: now, usedPercent: 1 - primarySource.remaining))
        }

        return ProviderUsageSnapshot(
            provider: .gemini,
            planName: "Antigravity",
            isConnected: true,
            primaryWindow: window(primarySource, id: "gemini-session"),
            secondaryWindow: secondarySource.map { window($0, id: "gemini-weekly") },
            history: updatedHistory,
            lastSyncedAt: now,
            source: .geminiCLI,
            statusNote: Self.liveGeminiSubtitle
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

    /// For a rolling window: when the oldest counted event ages out, i.e. the next time
    /// usage drops. Falls back to a full window from now when nothing is counted.
    static func rollingRelief(_ dates: [Date], window: TimeInterval, now: Date) -> Date {
        dates.filter { $0 >= now.addingTimeInterval(-window) }.min()?.addingTimeInterval(window)
            ?? now.addingTimeInterval(window)
    }

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
