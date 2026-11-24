import Foundation
import SwiftUI

public enum AIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }

    public var vendorName: String {
        switch self {
        case .claude: "Anthropic"
        case .codex: "OpenAI"
        case .gemini: "Google"
        }
    }

    public var defaultPlanName: String {
        switch self {
        case .claude: "Max 5x"
        case .codex: "Pro"
        case .gemini: "AI Pro"
        }
    }

    public var monogram: String {
        switch self {
        case .claude: "C"
        case .codex: "O"
        case .gemini: "G"
        }
    }

    public var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "terminal"
        case .gemini: "diamond.fill"
        }
    }

    public var accentColor: Color {
        switch self {
        case .claude: Color(red: 0.851, green: 0.467, blue: 0.341) // #D97757 terracotta
        case .codex: Color(red: 0.063, green: 0.725, blue: 0.506)  // #10B981 emerald
        case .gemini: Color(red: 0.376, green: 0.647, blue: 0.980) // #60A5FA electric blue
        }
    }

    public var secondaryAccentColor: Color {
        switch self {
        case .claude: Color(red: 0.949, green: 0.635, blue: 0.451)
        case .codex: Color(red: 0.204, green: 0.827, blue: 0.600)
        case .gemini: Color(red: 0.506, green: 0.549, blue: 0.973)
        }
    }
}

public enum QuotaStatus: String, Codable, Sendable {
    case nominal
    case elevated
    case critical
    case exhausted

    public static func from(usedPercent: Double, warningThreshold: Double = 0.80) -> QuotaStatus {
        if usedPercent >= 0.995 { return .exhausted }
        if usedPercent >= 0.90 { return .critical }
        if usedPercent >= warningThreshold { return .elevated }
        return .nominal
    }

    public var label: String {
        switch self {
        case .nominal: "Healthy"
        case .elevated: "Elevated"
        case .critical: "Near Limit"
        case .exhausted: "Limit Reached"
        }
    }

    public var tintColor: Color {
        switch self {
        case .nominal: Color(red: 0.204, green: 0.827, blue: 0.600)
        case .elevated: Color(red: 0.961, green: 0.620, blue: 0.043)
        case .critical: Color(red: 0.957, green: 0.247, blue: 0.369)
        case .exhausted: Color(red: 0.937, green: 0.267, blue: 0.267)
        }
    }
}

public struct QuotaWindow: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    /// Normalized 0.0 ... 1.0 representing used portion of the quota.
    public let usedPercent: Double
    public let resetsAt: Date
    public let detailText: String?

    public init(
        id: String,
        title: String,
        subtitle: String,
        usedPercent: Double,
        resetsAt: Date,
        detailText: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.usedPercent = min(max(usedPercent, 0), 1)
        self.resetsAt = resetsAt
        self.detailText = detailText
    }

    public var remainingPercent: Double {
        max(0, 1.0 - usedPercent)
    }

    public func status(warningThreshold: Double = 0.80) -> QuotaStatus {
        QuotaStatus.from(usedPercent: usedPercent, warningThreshold: warningThreshold)
    }
}

public struct UsageHistoryPoint: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let date: Date
    /// Peak or daily utilization (0.0 ... 1.0)
    public let usedPercent: Double

    public init(id: String = UUID().uuidString, date: Date, usedPercent: Double) {
        self.id = id
        self.date = date
        self.usedPercent = min(max(usedPercent, 0), 1)
    }
}

public enum SyncSource: String, Codable, Sendable {
    case claudeCLI = "Claude Code CLI"
    case codexCLI = "Codex CLI"
    case geminiCLI = "Gemini CLI"
    case webSession = "In-App Web Session"
    case manual = "Manual Entry"
    case demo = "Demo Preview"
}

public struct ProviderUsageSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: AIProvider { provider }
    public let provider: AIProvider
    public var planName: String
    public var isConnected: Bool
    public var primaryWindow: QuotaWindow
    public var secondaryWindow: QuotaWindow?
    public var history: [UsageHistoryPoint]
    public var lastSyncedAt: Date
    public var source: SyncSource
    public var statusNote: String?

    public init(
        provider: AIProvider,
        planName: String,
        isConnected: Bool,
        primaryWindow: QuotaWindow,
        secondaryWindow: QuotaWindow? = nil,
        history: [UsageHistoryPoint] = [],
        lastSyncedAt: Date = Date(),
        source: SyncSource = .demo,
        statusNote: String? = nil
    ) {
        self.provider = provider
        self.planName = planName
        self.isConnected = isConnected
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
        self.history = history
        self.lastSyncedAt = lastSyncedAt
        self.source = source
        self.statusNote = statusNote
    }

    public var highestUsedPercent: Double {
        max(primaryWindow.usedPercent, secondaryWindow?.usedPercent ?? 0)
    }
}

public struct KarvSnapshot: Codable, Hashable, Sendable {
    public var providers: [ProviderUsageSnapshot]
    public var sourceDeviceName: String
    public var updatedAt: Date
    public var isDemoData: Bool

    public init(
        providers: [ProviderUsageSnapshot],
        sourceDeviceName: String,
        updatedAt: Date = Date(),
        isDemoData: Bool = false
    ) {
        self.providers = providers
        self.sourceDeviceName = sourceDeviceName
        self.updatedAt = updatedAt
        self.isDemoData = isDemoData
    }

    public func snapshot(for provider: AIProvider) -> ProviderUsageSnapshot? {
        providers.first(where: { $0.provider == provider })
    }

    public var averageRemainingPercent: Double {
        guard !providers.isEmpty else { return 0 }
        let total = providers.reduce(0.0) { $0 + $1.primaryWindow.remainingPercent }
        return total / Double(providers.count)
    }

    public var soonestReset: (provider: AIProvider, date: Date)? {
        providers
            .map { ($0.provider, $0.primaryWindow.resetsAt) }
            .min(by: { $0.1 < $1.1 })
    }
}
