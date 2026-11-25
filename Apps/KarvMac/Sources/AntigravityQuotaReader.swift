import Foundation
import Security

/// Reads the user's real Antigravity (Gemini) model quota.
///
/// Opt-in. Uses the Google sign-in Antigravity keeps in the login Keychain
/// (service "gemini", account "antigravity"; macOS asks the user once) to make the same
/// read-only `fetchAvailableModels` call Antigravity itself makes. The token is never
/// refreshed, stored, logged or sent anywhere else: if it has expired (Antigravity not
/// running) the caller keeps the last reading until its reset time. Quota only moves
/// while Antigravity is in use, which is exactly when the token is fresh.
enum AntigravityQuotaReader {
    struct ModelQuota: Sendable, Equatable {
        let id: String
        let name: String
        /// 0...1 share of the quota still available.
        let remaining: Double
        let resetsAt: Date?
    }

    enum Outcome: Sendable {
        case success([ModelQuota])
        /// No Antigravity sign-in found in the Keychain.
        case noCredentials
        /// The user declined the Keychain prompt.
        case accessDenied
        /// Token expired: Antigravity isn't running. Not an error.
        case tokenExpired
        case failed(String)
    }


    static var diagnosticsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Karv/antigravity", isDirectory: true)
    }

    static func fetch(now: Date = Date()) async -> Outcome {
        var diag = Diagnostics()
        defer { diag.write() }

        // 1. Antigravity's sign-in from the login Keychain.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "gemini",
            kSecAttrAccount as String: "antigravity",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        diag.add("keychain status \(status)")
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            return .noCredentials
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            return .accessDenied
        default:
            return .failed("Keychain error \(status)")
        }
        guard let data = result as? Data, let credential = Credential.parse(data) else {
            diag.add("credential format not recognised")
            return .failed("Unrecognised Antigravity sign-in format")
        }
        diag.add("credential format \(credential.format)")
        if let expiry = credential.expiry {
            diag.add("token expires in \(Int(expiry.timeIntervalSince(now) / 60)) min")
            if expiry <= now.addingTimeInterval(30) {
                return .tokenExpired
            }
        }

        // 2. Same read-only call Antigravity makes. The exact host/project combination
        // isn't documented, so try the plausible ones once and remember what works.
        let cachedProject = readDefaultProjectID()
        diag.add("cached project id \(cachedProject == nil ? "absent" : "present")")

        var attempts: [(host: String, project: String?)] = []
        if let remembered = UserDefaults.standard.string(forKey: rememberedHostKey) {
            let project = UserDefaults.standard.string(forKey: rememberedProjectKey)
            attempts.append((remembered, project))
        }
        var assistProject: String?
        if attempts.isEmpty {
            assistProject = await loadCodeAssistProject(token: credential.accessToken, diag: &diag)
            for host in hosts {
                if let assistProject { attempts.append((host, assistProject)) }
                if let cachedProject, cachedProject != assistProject { attempts.append((host, cachedProject)) }
                attempts.append((host, nil))
            }
        }

        var responseData = Data()
        var succeeded = false
        var lastStatus = 0
        for attempt in attempts {
            let label = "\(attempt.host.replacingOccurrences(of: "https://", with: "")) project=\(attempt.project == nil ? "none" : (attempt.project == assistProject ? "loadCodeAssist" : "cached"))"
            guard let (data, status) = await post(
                url: URL(string: attempt.host + "/v1internal:fetchAvailableModels")!,
                token: credential.accessToken,
                body: attempt.project.map { ["project": $0] } ?? [:]
            ) else {
                diag.add("\(label): network error")
                continue
            }
            lastStatus = status
            diag.add("\(label): HTTP \(status)")
            if (200..<300).contains(status) {
                responseData = data
                succeeded = true
                UserDefaults.standard.set(attempt.host, forKey: rememberedHostKey)
                UserDefaults.standard.set(attempt.project, forKey: rememberedProjectKey)
                break
            }
            // Google's error JSON (status/message/reason) explains rejections; no secrets.
            diag.add("  error: " + (String(data: data.prefix(400), encoding: .utf8) ?? "<binary>").replacingOccurrences(of: "\n", with: " "))
            if status == 401 { return .tokenExpired }
        }
        guard succeeded else {
            // A remembered combination may have stopped working; rediscover next time.
            UserDefaults.standard.removeObject(forKey: rememberedHostKey)
            UserDefaults.standard.removeObject(forKey: rememberedProjectKey)
            return lastStatus == 0 ? .failed("Network error") : .failed("Google returned HTTP \(lastStatus)")
        }

        // Keep the raw response (it holds model names and quota, no credentials) so the
        // parsing can be checked against the real shape.
        diag.saveResponse(responseData)

        guard let json = try? JSONSerialization.jsonObject(with: responseData) else {
            return .failed("Unreadable response")
        }
        if let dict = json as? [String: Any] {
            diag.add("top-level keys: \(dict.keys.sorted().joined(separator: ", "))")
        }
        let models = extractQuotas(from: json)
        diag.add("models with quota: \(models.count)")
        for m in models.prefix(40) {
            diag.add("  \(m.id) | \(m.name) | \(Int((m.remaining * 100).rounded()))% left | resets \(m.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "?")")
        }
        guard !models.isEmpty else {
            return .failed("No quota information in response")
        }
        return .success(models)
    }

    private static let hosts = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com"
    ]
    private static let rememberedHostKey = "karv.mac.antigravityHost"
    private static let rememberedProjectKey = "karv.mac.antigravityProject"

    private static func post(url: URL, token: String, body: [String: Any]) async -> (Data, Int)? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }

    /// Asks Google which project the account's quota lives under (Antigravity makes this
    /// same call constantly). Returns nil if the answer doesn't contain one.
    private static func loadCodeAssistProject(token: String, diag: inout Diagnostics) async -> String? {
        for host in hosts {
            guard let (data, status) = await post(
                url: URL(string: host + "/v1internal:loadCodeAssist")!,
                token: token,
                body: ["metadata": ["ideType": "IDE_UNSPECIFIED", "platform": "PLATFORM_UNSPECIFIED", "pluginType": "GEMINI"]]
            ) else {
                diag.add("loadCodeAssist \(host): network error")
                continue
            }
            diag.add("loadCodeAssist \(host.replacingOccurrences(of: "https://", with: "")): HTTP \(status)")
            guard (200..<300).contains(status),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                diag.add("  error: " + (String(data: data.prefix(300), encoding: .utf8) ?? "").replacingOccurrences(of: "\n", with: " "))
                continue
            }
            diag.add("  keys: \(json.keys.sorted().joined(separator: ", "))")
            if let project = json["cloudaicompanionProject"] as? String, !project.isEmpty {
                return project
            }
            if let projectObj = json["cloudaicompanionProject"] as? [String: Any],
               let id = projectObj["id"] as? String, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    // MARK: - Parsing

    /// Finds every object carrying a `quotaInfo`, wherever it sits in the response
    /// (models may come as a map keyed by id or as a list).
    static func extractQuotas(from json: Any) -> [ModelQuota] {
        var found: [ModelQuota] = []

        func visit(_ node: Any, key: String?) {
            if let dict = node as? [String: Any] {
                if let quota = dict["quotaInfo"] as? [String: Any] ?? dict["quota_info"] as? [String: Any] {
                    // proto3 JSON omits zero values: no remainingFraction means 0% left.
                    let remaining = number(quota["remainingFraction"] ?? quota["remaining_fraction"]) ?? 0
                    let reset = (quota["resetTime"] ?? quota["reset_time"]) as? String
                    let id = (dict["model"] as? String) ?? (dict["id"] as? String) ?? key ?? "model"
                    let name = (dict["displayName"] as? String) ?? (dict["label"] as? String) ?? id
                    found.append(ModelQuota(
                        id: id,
                        name: name,
                        remaining: min(max(remaining, 0), 1),
                        resetsAt: reset.flatMap(parseDate)
                    ))
                }
                for (childKey, value) in dict where childKey != "quotaInfo" && childKey != "quota_info" {
                    visit(value, key: childKey)
                }
            } else if let array = node as? [Any] {
                for item in array {
                    visit(item, key: key)
                }
            }
        }

        visit(json, key: nil)
        return found
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func parseDate(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return withFraction.date(from: string) ?? basic.date(from: string)
    }

    private static func readDefaultProjectID() -> String? {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/cache/default_project_id.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Credential

    struct Credential {
        let accessToken: String
        let expiry: Date?
        /// Describes the storage format for diagnostics; never contains token material.
        let format: String

        static func parse(_ data: Data) -> Credential? {
            guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return nil
            }
            var format = "plain"
            // go-keyring wraps values on macOS.
            if text.hasPrefix("go-keyring-base64:"),
               let decoded = Data(base64Encoded: String(text.dropFirst("go-keyring-base64:".count))),
               let decodedText = String(data: decoded, encoding: .utf8) {
                text = decodedText
                format = "go-keyring-base64"
            } else if text.hasPrefix("go-keyring-encoded:"),
                      let decodedText = hexDecode(String(text.dropFirst("go-keyring-encoded:".count))) {
                text = decodedText
                format = "go-keyring-hex"
            }

            if let jsonData = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                let inner = (obj["token"] as? [String: Any]) ?? obj
                guard let token = (inner["access_token"] as? String) ?? (inner["accessToken"] as? String),
                      !token.isEmpty else { return nil }
                var expiry: Date?
                if let s = (inner["expiry"] as? String) ?? (inner["expires_at"] as? String) {
                    expiry = AntigravityQuotaReader.parseDate(s) ?? parseGoTime(s)
                } else if let ms = AntigravityQuotaReader.number(inner["expiry_date"] ?? inner["expiresAt"]) {
                    expiry = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000 : ms)
                }
                return Credential(accessToken: token, expiry: expiry, format: format + "+json")
            }
            if text.hasPrefix("ya29.") {
                return Credential(accessToken: text, expiry: nil, format: format + "+raw-token")
            }
            return nil
        }

        /// Go's RFC 3339 with nanoseconds, e.g. 2026-11-25T10:05:00.123456789+01:00.
        private static func parseGoTime(_ s: String) -> Date? {
            guard let dot = s.firstIndex(of: ".") else { return nil }
            let tzStart = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) ?? s.endIndex
            let trimmed = String(s[..<dot]) + String(s[tzStart...])
            return AntigravityQuotaReader.parseDate(trimmed)
        }

        private static func hexDecode(_ hex: String) -> String? {
            var bytes = [UInt8]()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            return String(bytes: bytes, encoding: .utf8)
        }
    }

    // MARK: - Diagnostics (no secrets)

    private struct Diagnostics {
        private var lines = [ISO8601DateFormatter().string(from: Date())]

        mutating func add(_ line: String) { lines.append(line) }

        func write() {
            let dir = AntigravityQuotaReader.diagnosticsDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = dir.appendingPathComponent("last-api.txt")
            try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }

        func saveResponse(_ data: Data) {
            try? FileManager.default.createDirectory(at: AntigravityQuotaReader.diagnosticsDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = AntigravityQuotaReader.diagnosticsDirectory.appendingPathComponent("fetchAvailableModels.json")
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
}
