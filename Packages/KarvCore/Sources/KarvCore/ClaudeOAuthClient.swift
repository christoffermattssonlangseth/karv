import Foundation
import Security

public struct ClaudeOAuthUsageResult: Sendable {
    public let fiveHourUsed: Double
    public let fiveHourResetsAt: Date
    public let sevenDayUsed: Double
    public let sevenDayResetsAt: Date
}

public enum ClaudeOAuthFetchOutcome: Sendable {
    case success(ClaudeOAuthUsageResult)
    /// Token rejected (expired or revoked). Retrying with the same token will not help.
    case unauthorized
    /// HTTP 429. `retryAfter` comes from the Retry-After header when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// Skipped locally because the gate is cooling down (min interval or backoff).
    case throttled(until: Date)
    case failed

    public var result: ClaudeOAuthUsageResult? {
        if case let .success(r) = self { return r }
        return nil
    }

    /// Short human-readable reason for a non-success outcome.
    public var failureNote: String? {
        switch self {
        case .success, .throttled: nil
        case .unauthorized: "Claude token expired — re-pair from KarvMac"
        case .rateLimited: "Claude API rate-limited — retrying shortly"
        case .failed: "Claude API unreachable — retrying shortly"
        }
    }
}

/// Process-wide throttle for the Claude usage endpoint. Both the Mac poller and the iOS
/// foreground loop hit the same account, so without this they easily trip HTTP 429.
public actor ClaudeUsageGate {
    public static let shared = ClaudeUsageGate()

    private var nextAllowed: Date = .distantPast
    private var backoff: TimeInterval = 0
    private var lastToken: String?

    public init() {}

    public func fetch(token: String, minInterval: TimeInterval = 55, now: Date = Date()) async -> ClaudeOAuthFetchOutcome {
        if token != lastToken {
            // A new token (e.g. just synced from KarvMac) shouldn't inherit the old one's
            // "unauthorized" cooldown.
            lastToken = token
            nextAllowed = .distantPast
            backoff = 0
        }
        if now < nextAllowed {
            return .throttled(until: nextAllowed)
        }
        // Reserve the slot before awaiting so concurrent callers don't double-fire.
        nextAllowed = now.addingTimeInterval(minInterval)

        let outcome = await ClaudeOAuthUsageClient.fetch(token: token, now: now)
        switch outcome {
        case .success:
            backoff = 0
        case let .rateLimited(retryAfter):
            backoff = min(max(backoff * 2, 120), 15 * 60)
            nextAllowed = Date().addingTimeInterval(max(retryAfter ?? 0, backoff))
        case .unauthorized:
            // Token won't fix itself; check again occasionally in case it was re-paired.
            nextAllowed = Date().addingTimeInterval(5 * 60)
        case .failed, .throttled:
            break
        }
        return outcome
    }

    /// Clears cooldown, e.g. right after the user pairs a new token.
    public func reset() {
        nextAllowed = .distantPast
        backoff = 0
    }
}

/// Shared Anthropic OAuth usage client used by both KarvMac and Karv iOS (standalone 5G sync).
public enum ClaudeOAuthUsageClient {
    public static func fetchUsage(token: String, now: Date = Date()) async -> ClaudeOAuthUsageResult? {
        await fetch(token: token, now: now).result
    }

    public static func fetch(token: String, now: Date = Date()) async -> ClaudeOAuthFetchOutcome {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return .unauthorized
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            return .failed
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            return .unauthorized
        case 429:
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .failed
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failed
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

        // `five_hour` is null when no session is active — that means 0%, not an error.
        guard fiveHour != nil || sevenDay != nil else { return .failed }
        let fiveUtil = (fiveHour?["utilization"] as? Double) ?? 0
        let sevenUtil = (sevenDay?["utilization"] as? Double) ?? 0

        let fiveReset = parseDate(fiveHour?["resets_at"] as? String) ?? now.addingTimeInterval(5 * 3600)
        let sevenReset = parseDate(sevenDay?["resets_at"] as? String) ?? now.addingTimeInterval(7 * 86400)

        return .success(ClaudeOAuthUsageResult(
            fiveHourUsed: min(max(fiveUtil / 100.0, 0), 1),
            fiveHourResetsAt: fiveReset,
            sevenDayUsed: min(max(sevenUtil / 100.0, 0), 1),
            sevenDayResetsAt: sevenReset
        ))
    }
}

/// A Claude OAuth access token plus what we know about it.
public struct ClaudeTokenInfo: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        /// Pushed automatically by KarvMac from Claude Code's own credentials.
        case mac
        /// Pasted or QR-paired by hand on the iPhone.
        case manual
    }

    public var token: String
    public var expiresAt: Date?
    public var updatedAt: Date
    public var source: Source

    public init(token: String, expiresAt: Date?, updatedAt: Date = Date(), source: Source) {
        self.token = token
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
        self.source = source
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// Secure Keychain storage for standalone provider tokens on iOS/macOS.
///
/// The token lives in a shared access group that syncs through iCloud Keychain
/// (end-to-end encrypted, only between the user's own devices). KarvMac keeps it
/// current from Claude Code's credentials, so the iPhone app and its widgets never
/// need manual re-pairing. If the shared group is unavailable (missing entitlement),
/// everything falls back to the original device-only item.
public enum KarvKeychain {
    /// `<TeamID>.com.cml.karv.shared`, must match `keychain-access-groups` in all targets.
    public static let sharedAccessGroup = "7R6QL53THM.com.cml.karv.shared"

    private static let service = "com.cml.karv.tokens"
    private static let claudeAccount = "claude-oauth-token"
    private static let sharedClaudeAccount = "claude-oauth-shared"

    // MARK: Shared (iCloud Keychain) token

    private static func sharedBaseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sharedClaudeAccount,
            kSecAttrAccessGroup as String: sharedAccessGroup,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// Writes the token to the iCloud-synced item. Returns false if the keychain refused
    /// (e.g. the access-group entitlement is missing in this build).
    @discardableResult
    public static func saveSharedClaudeToken(_ info: ClaudeTokenInfo) -> Bool {
        guard let data = try? JSONEncoder().encode(info) else { return false }

        var match = sharedBaseQuery()
        match[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(match as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var add = sharedBaseQuery()
        add[kSecAttrSynchronizable as String] = true
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func loadSharedClaudeToken() -> ClaudeTokenInfo? {
        var query = sharedBaseQuery()
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let info = try? JSONDecoder().decode(ClaudeTokenInfo.self, from: data),
              !info.token.isEmpty else {
            return nil
        }
        return info
    }

    public static func clearSharedClaudeToken() {
        var query = sharedBaseQuery()
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Public API used by the apps

    /// Best available token info: the shared one, else the legacy device-only token.
    public static func loadClaudeTokenInfo() -> ClaudeTokenInfo? {
        if let shared = loadSharedClaudeToken() {
            return shared
        }
        return loadLegacyToken().map { ClaudeTokenInfo(token: $0, expiresAt: nil, updatedAt: .distantPast, source: .manual) }
    }

    public static func loadClaudeToken() -> String? {
        loadClaudeTokenInfo()?.token
    }

    /// Saves a manually pasted / QR-paired token.
    public static func saveClaudeToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearClaudeToken()
            return
        }
        if saveSharedClaudeToken(ClaudeTokenInfo(token: trimmed, expiresAt: nil, source: .manual)) {
            deleteLegacyToken()
        } else {
            saveLegacyToken(trimmed)
        }
    }

    public static func clearClaudeToken() {
        clearSharedClaudeToken()
        deleteLegacyToken()
    }

    // MARK: Legacy device-only item

    private static func legacyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: claudeAccount
        ]
    }

    private static func saveLegacyToken(_ token: String) {
        deleteLegacyToken()
        var add = legacyQuery()
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func deleteLegacyToken() {
        SecItemDelete(legacyQuery() as CFDictionary)
    }

    private static func loadLegacyToken() -> String? {
        var query = legacyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }
}
