import Foundation
import Synchronization

/// When in the day you typically use your quota, learned on the Mac from how real weekly
/// readings rise hour by hour. Pacing for daily/weekly windows follows this curve instead
/// of a straight line, so quiet evenings and nights don't make you look "over".
///
/// Learned per hour of day, separately for weekdays and weekends (48 buckets), with
/// exponential decay so it follows changes in habits. Until there is enough data, each
/// bucket leans on a prior built from the configured active hours.
public struct UsageRhythm: Codable, Hashable, Sendable {
    public static let bucketCount = 48
    /// Days of learning before the curve is considered "learned" (only affects labels;
    /// the curve blends in data from the first reading).
    public static let learningDays = 7
    /// Pseudo-hours of prior per bucket: how much evidence it takes to move away from it.
    static let priorStrength = 2.0
    /// Learned data halves in weight every three weeks.
    static let halfLife: TimeInterval = 21 * 86400
    /// Longest gap between two readings that is still spread over the hours in between.
    /// Longer gaps (Mac asleep) are skipped, since we can't tell when that usage happened.
    static let maxSampleGap: TimeInterval = 2 * 3600
    /// Quiet hours never count for less than this share of an average hour, so the pace
    /// marker still creeps forward overnight.
    static let minimumWeight = 0.08
    /// Weight of hours outside the active hours in the prior, relative to active hours.
    static let quietPriorWeight = 0.2

    public var isEnabled: Bool
    /// Active hours (local time) used as the starting assumption, e.g. 8 and 20.
    public var activeStartHour: Int
    public var activeEndHour: Int
    /// Decayed quota fraction used during each bucket.
    public var usage: [Double]
    /// Decayed hours observed in each bucket.
    public var observed: [Double]
    public var learningSince: Date?
    public var lastDecayAt: Date
    public var updatedAt: Date
    /// Last real reading per provider window, to compute the next delta.
    public var lastSamples: [String: Sample]

    public struct Sample: Codable, Hashable, Sendable {
        public var at: Date
        public var used: Double
        public var resetsAt: Date
    }

    public init(isEnabled: Bool = true, activeStartHour: Int = 8, activeEndHour: Int = 20, now: Date = Date()) {
        self.isEnabled = isEnabled
        self.activeStartHour = activeStartHour
        self.activeEndHour = activeEndHour
        self.usage = Array(repeating: 0, count: Self.bucketCount)
        self.observed = Array(repeating: 0, count: Self.bucketCount)
        self.learningSince = nil
        self.lastDecayAt = now
        self.updatedAt = now
        self.lastSamples = [:]
    }

    // MARK: Buckets

    static func bucket(for date: Date, calendar: Calendar) -> Int {
        let hour = calendar.component(.hour, from: date)
        return (calendar.isDateInWeekend(date) ? 24 : 0) + hour
    }

    func isActiveHour(_ hour: Int) -> Bool {
        if activeStartHour == activeEndHour { return true }
        if activeStartHour < activeEndHour {
            return hour >= activeStartHour && hour < activeEndHour
        }
        return hour >= activeStartHour || hour < activeEndHour // spans midnight
    }

    /// Relative activity per bucket (mean ≈ 1 across the week).
    public func weights() -> [Double] {
        let prior = (0..<Self.bucketCount).map { isActiveHour($0 % 24) ? 1.0 : Self.quietPriorWeight }
        let totalUsage = usage.reduce(0, +)
        let totalObserved = observed.reduce(0, +)
        // Prior expressed in the same unit as the data (quota per hour).
        let priorMean = prior.reduce(0, +) / Double(prior.count)
        let scale = totalUsage > 0 && totalObserved > 0 ? (totalUsage / totalObserved) / priorMean : 1.0
        let usesData = totalUsage > 0 && totalObserved > 0

        var raw = (0..<Self.bucketCount).map { b -> Double in
            let p = prior[b] * scale
            guard usesData else { return p }
            return (usage[b] + Self.priorStrength * p) / (observed[b] + Self.priorStrength)
        }
        // Weekdays are 5/7 of the week, weekends 2/7.
        let weekdaySum: Double = raw[0..<24].reduce(0, +)
        let weekendSum: Double = raw[24..<48].reduce(0, +)
        let mean: Double = (weekdaySum * 5 + weekendSum * 2) / (24 * 7)
        guard mean > 0 else { return Array(repeating: 1, count: Self.bucketCount) }
        raw = raw.map { max($0 / mean, Self.minimumWeight) }
        return raw
    }

    // MARK: Cumulative activity

    /// Expected activity between two dates, in "average hours".
    public func activity(from start: Date, to end: Date, calendar: Calendar = .current) -> Double {
        activity(from: start, to: end, weights: weights(), calendar: calendar)
    }

    func activity(from start: Date, to end: Date, weights w: [Double], calendar: Calendar) -> Double {
        guard end > start else { return 0 }
        var t = start
        var sum = 0.0
        while t < end {
            let next = min(Self.nextHourBoundary(after: t, calendar: calendar), end)
            sum += w[Self.bucket(for: t, calendar: calendar)] * next.timeIntervalSince(t) / 3600
            t = next
        }
        return sum
    }

    /// The moment the cumulative activity since `start` reaches `target`, or nil if not
    /// before `limit`.
    func date(reaching target: Double, from start: Date, limit: Date, weights w: [Double], calendar: Calendar) -> Date? {
        if target <= 0 { return start }
        var t = start
        var sum = 0.0
        while t < limit {
            let next = min(Self.nextHourBoundary(after: t, calendar: calendar), limit)
            let rate = w[Self.bucket(for: t, calendar: calendar)] / 3600
            let chunk = rate * next.timeIntervalSince(t)
            if sum + chunk >= target {
                return t.addingTimeInterval((target - sum) / rate)
            }
            sum += chunk
            t = next
        }
        return nil
    }

    static func nextHourBoundary(after date: Date, calendar: Calendar) -> Date {
        let start = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        let next = start.addingTimeInterval(3600)
        return next > date ? next : date.addingTimeInterval(3600)
    }

    // MARK: Learning

    /// Folds new real readings of fixed weekly windows into the curve. Call with each
    /// published snapshot; readings that aren't new are ignored, so calling often is fine.
    public mutating func learn(from snapshot: KarvSnapshot, now: Date = Date(), calendar: Calendar = .current) {
        guard !snapshot.isDemoData else { return }
        decay(now: now)
        for item in snapshot.providers where !item.isEstimate && item.isConnected {
            guard let window = item.secondaryWindow, !window.isRolling else { continue }
            let key = "\(item.provider.rawValue)-\(window.id)"
            let sample = Sample(at: item.lastSyncedAt, used: window.usedPercent, resetsAt: window.resetsAt)
            defer { if sample.at >= (lastSamples[key]?.at ?? .distantPast) { lastSamples[key] = sample } }

            guard let previous = lastSamples[key], sample.at > previous.at else { continue }
            let gap = sample.at.timeIntervalSince(previous.at)
            // A new window (reset) or a long gap: start over from this reading.
            guard abs(sample.resetsAt.timeIntervalSince(previous.resetsAt)) < 3600,
                  gap <= Self.maxSampleGap else { continue }
            let delta = sample.used - previous.used
            guard delta > -0.005 else { continue }
            record(delta: max(delta, 0), from: previous.at, to: sample.at, calendar: calendar)
        }
        if learningSince == nil, observed.contains(where: { $0 > 0 }) {
            learningSince = now
        }
        updatedAt = now
    }

    mutating func record(delta: Double, from start: Date, to end: Date, calendar: Calendar) {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return }
        var t = start
        while t < end {
            let next = min(Self.nextHourBoundary(after: t, calendar: calendar), end)
            let seconds = next.timeIntervalSince(t)
            let b = Self.bucket(for: t, calendar: calendar)
            usage[b] += delta * seconds / total
            observed[b] += seconds / 3600
            t = next
        }
    }

    mutating func decay(now: Date) {
        let elapsed = now.timeIntervalSince(lastDecayAt)
        guard elapsed > 3600 else { return }
        let factor = pow(0.5, elapsed / Self.halfLife)
        usage = usage.map { $0 * factor }
        observed = observed.map { $0 * factor }
        lastDecayAt = now
    }

    // MARK: Status

    public func daysLearned(now: Date = Date()) -> Int {
        guard let since = learningSince else { return 0 }
        return max(0, Int(now.timeIntervalSince(since) / 86400))
    }

    public func isLearned(now: Date = Date()) -> Bool {
        daysLearned(now: now) >= Self.learningDays
    }

    /// Short label for the UI, e.g. "Pace follows your rhythm" or "learning 3/7 days".
    public func statusText(now: Date = Date()) -> String {
        guard isEnabled else { return "Even pace" }
        if isLearned(now: now) { return "Pace follows your rhythm" }
        return "Pace by active hours \(Self.hourLabel(activeStartHour))–\(Self.hourLabel(activeEndHour)) · learning \(daysLearned(now: now))/\(Self.learningDays) days"
    }

    static func hourLabel(_ hour: Int) -> String {
        String(format: "%02d", ((hour % 24) + 24) % 24)
    }

    // MARK: Shared instance

    private static let storage = Mutex<UsageRhythm?>(nil)

    /// The rhythm from the latest snapshot this process has loaded (set by KarvSyncStore
    /// and the widget), used by `QuotaWindow.pace` unless a rhythm is passed explicitly.
    public static var current: UsageRhythm? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// `current`, if pacing by rhythm is switched on.
    public static var active: UsageRhythm? {
        guard let rhythm = current, rhythm.isEnabled else { return nil }
        return rhythm
    }
}
