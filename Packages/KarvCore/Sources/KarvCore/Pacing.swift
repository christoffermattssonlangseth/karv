import Foundation

/// How a quota window is tracking against an even burn rate across the window.
///
/// "Reserve" is the share of the quota you are *under* an even pace: if 40% of the
/// window has elapsed and you've used 25%, you have 15% in reserve (≈ 15% of the window
/// length in time). Negative reserve means you are burning faster than the window allows.
public struct QuotaPace: Sendable, Equatable {
    /// Fraction of the window that has elapsed, 0...1.
    public let elapsedFraction: Double
    /// Fraction of the quota used, 0...1.
    public let usedFraction: Double
    public let windowDuration: TimeInterval
    public let resetsAt: Date
    /// When set, "elapsed" is the share of your typical activity for this window that has
    /// passed, rather than the share of clock time.
    public let rhythm: UsageRhythm?

    public init(
        elapsedFraction: Double,
        usedFraction: Double,
        windowDuration: TimeInterval,
        resetsAt: Date,
        rhythm: UsageRhythm? = nil
    ) {
        self.elapsedFraction = elapsedFraction
        self.usedFraction = usedFraction
        self.windowDuration = windowDuration
        self.resetsAt = resetsAt
        self.rhythm = rhythm
    }

    public var isRhythmAdjusted: Bool { rhythm != nil }

    var windowStart: Date { resetsAt.addingTimeInterval(-windowDuration) }

    /// elapsed − used. Positive = reserve, negative = over pace.
    public var reserve: Double { elapsedFraction - usedFraction }

    /// Reserve expressed as time ahead of (positive) or behind (negative) the expected pace:
    /// how long ago (or from now) a typical window would have reached today's usage.
    public var reserveTime: TimeInterval {
        guard let rhythm else { return reserve * windowDuration }
        let calendar = Calendar.current
        let w = rhythm.weights()
        let total = rhythm.activity(from: windowStart, to: resetsAt, weights: w, calendar: calendar)
        let now = rhythm.date(reaching: elapsedFraction * total, from: windowStart, limit: resetsAt, weights: w, calendar: calendar) ?? resetsAt
        let reached = rhythm.date(reaching: usedFraction * total, from: windowStart, limit: resetsAt, weights: w, calendar: calendar) ?? resetsAt
        return now.timeIntervalSince(reached)
    }

    /// Treat anything within ±2% as on pace, matching the ring tick colouring.
    public var state: State {
        if reserve > 0.02 { return .underPace }
        if reserve < -0.02 { return .overPace }
        return .onPace
    }

    public enum State: Sendable, Equatable {
        case underPace
        case onPace
        case overPace
    }

    /// Share of the quota you'd have used at reset if you keep the current average rate.
    /// nil when it's too early in the window to say anything meaningful.
    public var projectedUsageAtReset: Double? {
        guard elapsedFraction >= 0.05 else { return nil }
        return usedFraction / elapsedFraction
    }

    /// When the quota runs out at the current average rate, if that is before the reset.
    public func projectedExhaustion(now: Date = Date()) -> Date? {
        if let rhythm {
            // Keep the quota-per-activity rate so far, and let quiet hours stay quiet.
            guard usedFraction > 0, usedFraction < 1, elapsedFraction > 0,
                  now.timeIntervalSince(windowStart) >= 60 else { return nil }
            let calendar = Calendar.current
            let w = rhythm.weights()
            let total = rhythm.activity(from: windowStart, to: resetsAt, weights: w, calendar: calendar)
            let needed = elapsedFraction * total / usedFraction
            guard needed < total else { return nil }
            return rhythm.date(reaching: needed, from: windowStart, limit: resetsAt, weights: w, calendar: calendar)
        }
        let elapsedSeconds = elapsedFraction * windowDuration
        guard usedFraction > 0, usedFraction < 1, elapsedSeconds >= 60 else { return nil }
        let ratePerSecond = usedFraction / elapsedSeconds
        let exhaustion = now.addingTimeInterval((1 - usedFraction) / ratePerSecond)
        return exhaustion < resetsAt ? exhaustion : nil
    }
}

extension QuotaWindow {
    /// Nominal length of this window, inferred from its title (5h / daily / weekly).
    public func windowDuration(isSecondary: Bool) -> TimeInterval {
        if isSecondary || title.localizedCaseInsensitiveContains("week") {
            return 7 * 86400
        } else if title.localizedCaseInsensitiveContains("5h") {
            return 5 * 3600
        } else {
            return 24 * 3600
        }
    }

    /// - Parameter rhythm: your usage rhythm; defaults to the one synced from KarvMac.
    ///   Only used for windows of a day or longer; a 5h session keeps an even pace.
    public func pace(at now: Date = Date(), isSecondary: Bool, rhythm: UsageRhythm? = UsageRhythm.active) -> QuotaPace {
        let duration = windowDuration(isSecondary: isSecondary)
        if !isRolling, let rhythm, duration >= 24 * 3600 {
            let start = resetsAt.addingTimeInterval(-duration)
            let calendar = Calendar.current
            let w = rhythm.weights()
            let total = rhythm.activity(from: start, to: resetsAt, weights: w, calendar: calendar)
            let done = rhythm.activity(from: start, to: min(max(now, start), resetsAt), weights: w, calendar: calendar)
            if total > 0 {
                return QuotaPace(
                    elapsedFraction: min(max(done / total, 0), 1),
                    usedFraction: usedPercent,
                    windowDuration: duration,
                    resetsAt: resetsAt,
                    rhythm: rhythm
                )
            }
        }
        // A rolling window never "resets", so there is no elapsed share to pace against.
        // Treat it as on pace; callers show headroom for these instead.
        let elapsed: Double
        if isRolling {
            elapsed = usedPercent
        } else {
            let remaining = resetsAt.timeIntervalSince(now)
            elapsed = min(max((duration - remaining) / duration, 0), 1)
        }
        return QuotaPace(
            elapsedFraction: elapsed,
            usedFraction: usedPercent,
            windowDuration: duration,
            resetsAt: resetsAt
        )
    }
}

extension QuotaWindow {
    /// "resets" for fixed windows, "frees up" for rolling ones (usage ages out).
    public var resetVerb: String { isRolling ? "frees up" : "resets" }

    public enum ReserveTone: Sendable {
        case good, neutral, bad
    }

    /// One-line reserve summary shared by the iPhone tiles and the Mac popover, e.g.
    /// "15% reserve · 45m", "8% over · out in 1h 10m", "Rolling · frees up in 23m".
    public func reserveSummary(at now: Date = Date(), isSecondary: Bool, rhythm: UsageRhythm? = UsageRhythm.active) -> (text: String, tone: ReserveTone) {
        if isRolling {
            if usedPercent > 0, resetsAt > now {
                return ("Rolling · frees up in \(KarvFormatting.durationString(resetsAt.timeIntervalSince(now)))", .neutral)
            }
            return ("Rolling · no recent use", .neutral)
        }
        let pace = pace(at: now, isSecondary: isSecondary, rhythm: rhythm)
        let pct = KarvFormatting.percentString(abs(pace.reserve))
        switch pace.state {
        case .onPace:
            return ("On pace", .neutral)
        case .underPace:
            return ("\(pct) reserve · \(KarvFormatting.durationString(pace.reserveTime))", .good)
        case .overPace:
            if let empty = pace.projectedExhaustion(now: now) {
                return ("\(pct) over · out in \(KarvFormatting.durationString(empty.timeIntervalSince(now)))", .bad)
            }
            return ("\(pct) over pace", .bad)
        }
    }
}

extension KarvFormatting {
    /// Compact duration, e.g. "45m", "2h 10m", "3d 4h".
    public static func durationString(_ seconds: TimeInterval) -> String {
        let now = Date()
        let text = countdownString(until: now.addingTimeInterval(abs(seconds)), from: now)
        return text == "Resetting" ? "<1m" : text
    }
}
