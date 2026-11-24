#if os(iOS) && canImport(ActivityKit)
import Foundation
import ActivityKit

public struct KarvResetActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var usedPercent: Double
        public var resetsAt: Date
        public var windowTitle: String

        public init(usedPercent: Double, resetsAt: Date, windowTitle: String) {
            self.usedPercent = min(max(usedPercent, 0), 1)
            self.resetsAt = resetsAt
            self.windowTitle = windowTitle
        }
    }

    public var providerRawValue: String
    public var providerName: String
    public var planName: String

    public init(provider: AIProvider, planName: String) {
        self.providerRawValue = provider.rawValue
        self.providerName = provider.displayName
        self.planName = planName
    }
}
#endif
