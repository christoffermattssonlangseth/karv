import Foundation
import UserNotifications

/// Schedules deduplicated local notifications for quota window resets
/// and high-utilization warnings on both iOS and macOS.
public enum KarvNotificationScheduler {
    private static let warnedCyclesKey = "karv.warnedResetCycles.v1"

    public static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public static func scheduleAlerts(for snapshot: KarvSnapshot, preferences: KarvPreferences) {
        let center = UNUserNotificationCenter.current()
        guard preferences.notificationsEnabled, !snapshot.isDemoData else {
            center.removeAllPendingNotificationRequests()
            return
        }

        let now = Date()
        var warnedMap = (UserDefaults.standard.dictionary(forKey: warnedCyclesKey) as? [String: Double]) ?? [:]

        for item in snapshot.providers where item.isConnected && preferences.isEnabled(item.provider) {
            let window = item.primaryWindow
            let resetID = "karv.reset.\(item.provider.rawValue)"
            center.removePendingNotificationRequests(withIdentifiers: [resetID])

            // 1. Schedule reset alert if usage is meaningful (>= 25%) and reset is in the future
            let secondsUntilReset = window.resetsAt.timeIntervalSince(now)
            if window.usedPercent >= 0.25 && secondsUntilReset > 120 && secondsUntilReset < 7 * 86400 {
                let content = UNMutableNotificationContent()
                content.title = "\(item.provider.displayName) Reset"
                content.body = "Your \(window.title.lowercased()) window just reset — back to 100% headroom."
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: secondsUntilReset, repeats: false)
                let request = UNNotificationRequest(identifier: resetID, content: content, trigger: trigger)
                center.add(request)
            }

            // 2. Fire a one-time warning per reset cycle when crossing warningThreshold
            let cycleBucket = (window.resetsAt.timeIntervalSince1970 / 600.0).rounded()
            let lastWarned = warnedMap[item.provider.rawValue]
            if window.usedPercent >= preferences.warningThreshold && lastWarned != cycleBucket {
                let warnID = "karv.warn.\(item.provider.rawValue)"
                let content = UNMutableNotificationContent()
                content.title = "\(item.provider.displayName) at \(KarvFormatting.percentString(window.usedPercent))"
                content.body = "\(window.title) resets in \(KarvFormatting.countdownString(until: window.resetsAt, from: now))."
                content.sound = .default

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let request = UNNotificationRequest(identifier: warnID, content: content, trigger: trigger)
                center.add(request)

                warnedMap[item.provider.rawValue] = cycleBucket
            }
        }

        UserDefaults.standard.set(warnedMap, forKey: warnedCyclesKey)
    }
}
