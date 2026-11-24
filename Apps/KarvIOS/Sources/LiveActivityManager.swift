import Foundation
import ActivityKit
import KarvCore

enum LiveActivityManager {
    static func isPinned(provider: AIProvider) -> Bool {
        Activity<KarvResetActivityAttributes>.activities.contains {
            $0.attributes.providerRawValue == provider.rawValue
        }
    }

    static func togglePin(for snapshot: ProviderUsageSnapshot) async -> Bool {
        if isPinned(provider: snapshot.provider) {
            await endActivity(for: snapshot.provider)
            return false
        } else {
            return await startOrUpdate(for: snapshot)
        }
    }

    @discardableResult
    static func startOrUpdate(for snapshot: ProviderUsageSnapshot) async -> Bool {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }

        let state = KarvResetActivityAttributes.ContentState(
            usedPercent: snapshot.primaryWindow.usedPercent,
            resetsAt: snapshot.primaryWindow.resetsAt,
            windowTitle: snapshot.primaryWindow.title,
            weeklyUsedPercent: snapshot.secondaryWindow?.usedPercent,
            weeklyResetsAt: snapshot.secondaryWindow?.resetsAt
        )
        let content = ActivityContent(state: state, staleDate: snapshot.primaryWindow.resetsAt)

        if let existing = Activity<KarvResetActivityAttributes>.activities.first(where: {
            $0.attributes.providerRawValue == snapshot.provider.rawValue
        }) {
            await existing.update(content)
            return true
        }

        let attrs = KarvResetActivityAttributes(provider: snapshot.provider, planName: snapshot.planName)
        do {
            _ = try Activity<KarvResetActivityAttributes>.request(
                attributes: attrs,
                content: content,
                pushType: nil
            )
            return true
        } catch {
            return false
        }
    }

    static func endActivity(for provider: AIProvider) async {
        for activity in Activity<KarvResetActivityAttributes>.activities where activity.attributes.providerRawValue == provider.rawValue {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    static func refreshActiveActivities(from snapshot: KarvSnapshot) async {
        for activity in Activity<KarvResetActivityAttributes>.activities {
            guard let provider = AIProvider(rawValue: activity.attributes.providerRawValue),
                  let snap = snapshot.snapshot(for: provider) else { continue }
            let state = KarvResetActivityAttributes.ContentState(
                usedPercent: snap.primaryWindow.usedPercent,
                resetsAt: snap.primaryWindow.resetsAt,
                windowTitle: snap.primaryWindow.title,
                weeklyUsedPercent: snap.secondaryWindow?.usedPercent,
                weeklyResetsAt: snap.secondaryWindow?.resetsAt
            )
            await activity.update(ActivityContent(state: state, staleDate: snap.primaryWindow.resetsAt))
        }
    }
}
