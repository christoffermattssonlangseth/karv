import Foundation

/// The independent ways fresh usage data can reach the iPhone.
public enum KarvSyncChannel: String, Codable, CaseIterable, Sendable {
    case macWiFi
    case iCloud
    case claudeAPI
    case widget

    public var displayName: String {
        switch self {
        case .macWiFi: "KarvMac over Wi-Fi"
        case .iCloud: "iCloud relay"
        case .claudeAPI: "Claude API (this iPhone)"
        case .widget: "Widget background fetch"
        }
    }
}

public struct KarvSyncHealthEntry: Codable, Sendable, Equatable {
    public var lastSuccess: Date?
    public var lastFailure: Date?
    public var lastMessage: String?

    public init(lastSuccess: Date? = nil, lastFailure: Date? = nil, lastMessage: String? = nil) {
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.lastMessage = lastMessage
    }

    public enum Status: Sendable {
        case healthy
        case stale
        case failing
        case unknown
    }

    /// healthy: succeeded within `freshWindow` and nothing failed since.
    public func status(now: Date = Date(), freshWindow: TimeInterval = 15 * 60) -> Status {
        switch (lastSuccess, lastFailure) {
        case (nil, nil):
            return .unknown
        case let (success?, failure?) where failure > success:
            return .failing
        case (nil, _?):
            return .failing
        case let (success?, _):
            return now.timeIntervalSince(success) <= freshWindow ? .healthy : .stale
        }
    }
}

/// Small persisted log of the last success/failure per sync channel, kept in the
/// App Group so the app and the widget extension both contribute to it.
public enum KarvSyncHealth {
    private static let storageKey = "karv.syncHealth.v1"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: KarvIdentifiers.appGroupID) ?? .standard
    }

    public static func load() -> [KarvSyncChannel: KarvSyncHealthEntry] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: KarvSyncHealthEntry].self, from: data) else {
            return [:]
        }
        var result: [KarvSyncChannel: KarvSyncHealthEntry] = [:]
        for (key, value) in decoded {
            if let channel = KarvSyncChannel(rawValue: key) {
                result[channel] = value
            }
        }
        return result
    }

    public static func recordSuccess(_ channel: KarvSyncChannel, message: String? = nil, at date: Date = Date()) {
        update(channel) { entry in
            entry.lastSuccess = date
            entry.lastMessage = message
        }
    }

    public static func recordFailure(_ channel: KarvSyncChannel, message: String?, at date: Date = Date()) {
        update(channel) { entry in
            entry.lastFailure = date
            entry.lastMessage = message
        }
    }

    private static func update(_ channel: KarvSyncChannel, _ mutate: (inout KarvSyncHealthEntry) -> Void) {
        var all = load()
        var entry = all[channel] ?? KarvSyncHealthEntry()
        mutate(&entry)
        all[channel] = entry
        let encodable = Dictionary(uniqueKeysWithValues: all.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
