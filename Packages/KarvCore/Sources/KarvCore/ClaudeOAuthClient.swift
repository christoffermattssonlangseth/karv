import Foundation
import Security

public struct ClaudeOAuthUsageResult: Sendable {
    public let fiveHourUsed: Double
    public let fiveHourResetsAt: Date
    public let sevenDayUsed: Double
    public let sevenDayResetsAt: Date
}

/// Shared Anthropic OAuth usage client used by both KarvMac and Karv iOS (standalone 5G sync).
public enum ClaudeOAuthUsageClient {
    public static func fetchUsage(token: String, now: Date = Date()) async -> ClaudeOAuthUsageResult? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
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

        return ClaudeOAuthUsageResult(
            fiveHourUsed: min(max(fiveUtil / 100.0, 0), 1),
            fiveHourResetsAt: fiveReset,
            sevenDayUsed: min(max(sevenUtil / 100.0, 0), 1),
            sevenDayResetsAt: sevenReset
        )
    }
}

/// Secure Keychain storage for standalone provider tokens on iOS/macOS.
public enum KarvKeychain {
    private static let service = "com.cml.karv.tokens"
    private static let claudeAccount = "claude-oauth-token"

    public static func saveClaudeToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: claudeAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !trimmed.isEmpty else { return }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: claudeAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public static func loadClaudeToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: claudeAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    public static func clearClaudeToken() {
        saveClaudeToken("")
    }
}
