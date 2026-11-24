import WidgetKit
import SwiftUI
import ActivityKit
import KarvCore

struct KarvWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: KarvSnapshot
}

struct KarvTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> KarvWidgetEntry {
        KarvWidgetEntry(date: Date(), snapshot: KarvDemoData.makeSnapshot())
    }

    func getSnapshot(in context: Context, completion: @escaping (KarvWidgetEntry) -> Void) {
        let snap = KarvSyncStore.readLatestSnapshotForWidget()
        completion(KarvWidgetEntry(date: Date(), snapshot: snap))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KarvWidgetEntry>) -> Void) {
        let now = Date()
        let snap = KarvSyncStore.readLatestSnapshotForWidget()

        // Generate 6 timeline entries spaced every 5 minutes so pacing needles
        // and reset countdowns stay accurate on the Home & Lock Screen.
        var entries: [KarvWidgetEntry] = []
        for step in 0..<6 {
            let entryDate = now.addingTimeInterval(Double(step) * 300)
            entries.append(KarvWidgetEntry(date: entryDate, snapshot: snap))
        }
        let nextRefresh = now.addingTimeInterval(300)
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }
}

// MARK: - Pacing Ring Gauge (S / W)

/// Minimalist circular ring showing:
/// - Crisp white arc: current usage %
/// - Radial green/red pacing tick: elapsed time through the window
///   (green = under pace / healthy, red = over pace / burning fast)
/// - Bold center letter: "S" (Session/Daily) or "W" (Weekly)
struct PacingRingGauge: View {
    let letter: String
    let usedPercent: Double
    let elapsedPercent: Double
    var size: CGFloat = 44
    var lineWidth: CGFloat = 5.5

    private var isOverPace: Bool {
        usedPercent > elapsedPercent + 0.02
    }

    private var paceColor: Color {
        isOverPace
            ? Color(red: 1.0, green: 0.25, blue: 0.22)   // vivid red when ahead of pace
            : Color(red: 0.18, green: 0.84, blue: 0.36)  // vivid green when under pace
    }

    var body: some View {
        let clampedUsed = min(max(usedPercent, 0.0), 1.0)
        let clampedElapsed = min(max(elapsedPercent, 0.02), 0.98)
        let radius = (size - lineWidth) / 2
        let tickAngleDegrees = clampedElapsed * 360.0

        ZStack {
            // Subtle dark translucent track
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
                .frame(width: size - lineWidth, height: size - lineWidth)

            // Crisp white usage fill starting from 12 o'clock
            if clampedUsed > 0.005 {
                Circle()
                    .trim(from: 0, to: max(0.03, clampedUsed))
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: size - lineWidth, height: size - lineWidth)
            }

            // Radial pacing tick mark at elapsed-time angle
            Capsule(style: .continuous)
                .fill(paceColor)
                .frame(width: max(2.6, lineWidth * 0.52), height: lineWidth + 4.5)
                .offset(y: -radius)
                .rotationEffect(.degrees(tickAngleDegrees))

            // Bold center letter
            Text(letter)
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private extension QuotaWindow {
    /// Estimates fraction of the current quota window that has elapsed (0...1)
    /// so the pacing needle sits at the right spot on the ring.
    func elapsedFraction(at now: Date, isSecondary: Bool) -> Double {
        let totalDuration: TimeInterval
        if isSecondary || title.localizedCaseInsensitiveContains("week") {
            totalDuration = 7 * 86400
        } else if title.localizedCaseInsensitiveContains("5h") {
            totalDuration = 5 * 3600
        } else {
            totalDuration = 24 * 3600
        }

        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = totalDuration - remaining
        return min(max(elapsed / totalDuration, 0.04), 0.96)
    }
}

// MARK: - Widget Views

struct KarvWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KarvWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            smallView
        case .systemMedium:
            mediumView
        case .systemLarge:
            largeView
        case .accessoryRectangular:
            accessoryRectangularView
        case .accessoryCircular:
            accessoryCircularView
        default:
            mediumView
        }
    }

    private var widgetBackground: Color {
        Color(red: 0.055, green: 0.055, blue: 0.063)
    }

    // MARK: Small — clean stacked provider sections (full name + S/W rings with %)

    private var smallView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.snapshot.providers.isEmpty {
                Spacer()
                emptyWidgetState
                Spacer()
            } else {
                let items = entry.snapshot.providers
                let isCompact = items.count >= 3

                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                            .overlay(Color.white.opacity(0.08))
                            .padding(.vertical, isCompact ? 4 : 6)
                    }

                    if isCompact {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.provider.accentColor)
                                .frame(width: 6, height: 6)
                            Text(item.provider.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)

                            Spacer(minLength: 4)

                            HStack(spacing: 6) {
                                PacingRingGauge(
                                    letter: "S",
                                    usedPercent: item.primaryWindow.usedPercent,
                                    elapsedPercent: item.primaryWindow.elapsedFraction(at: entry.date, isSecondary: false),
                                    size: 28,
                                    lineWidth: 3.8
                                )
                                if let secondary = item.secondaryWindow {
                                    PacingRingGauge(
                                        letter: "W",
                                        usedPercent: secondary.usedPercent,
                                        elapsedPercent: secondary.elapsedFraction(at: entry.date, isSecondary: true),
                                        size: 28,
                                        lineWidth: 3.8
                                    )
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(item.provider.accentColor)
                                        .frame(width: 6, height: 6)
                                    Text(item.provider.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(KarvFormatting.countdownString(until: item.primaryWindow.resetsAt, from: entry.date))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.45))
                            }

                            HStack(spacing: 10) {
                                HStack(spacing: 5) {
                                    PacingRingGauge(
                                        letter: "S",
                                        usedPercent: item.primaryWindow.usedPercent,
                                        elapsedPercent: item.primaryWindow.elapsedFraction(at: entry.date, isSecondary: false),
                                        size: 36,
                                        lineWidth: 4.5
                                    )
                                    Text(KarvFormatting.percentString(item.primaryWindow.usedPercent))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .minimumScaleFactor(0.8)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if let secondary = item.secondaryWindow {
                                    HStack(spacing: 5) {
                                        PacingRingGauge(
                                            letter: "W",
                                            usedPercent: secondary.usedPercent,
                                            elapsedPercent: secondary.elapsedFraction(at: entry.date, isSecondary: true),
                                            size: 36,
                                            lineWidth: 4.5
                                        )
                                        Text(KarvFormatting.percentString(secondary.usedPercent))
                                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.85))
                                            .minimumScaleFactor(0.8)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .containerBackground(for: .widget) { widgetBackground }
    }

    // MARK: Medium — sleek columns per active platform with W & S rings

    private var mediumView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("karv")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(KarvFormatting.relativeSyncString(from: entry.snapshot.updatedAt, now: entry.date))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if entry.snapshot.providers.isEmpty {
                Spacer()
                emptyWidgetState
                Spacer()
            } else {
                let count = entry.snapshot.providers.count
                let ringSize: CGFloat = count == 1 ? 56 : (count == 2 ? 48 : 38)
                let strokeWidth: CGFloat = count == 1 ? 6.5 : (count == 2 ? 5.8 : 4.8)

                HStack(spacing: 10) {
                    ForEach(entry.snapshot.providers) { item in
                        VStack(spacing: 8) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(item.provider.accentColor)
                                    .frame(width: 6, height: 6)
                                Text(item.provider.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                            }

                            HStack(spacing: count == 3 ? 6 : 12) {
                                if let secondary = item.secondaryWindow {
                                    VStack(spacing: 3) {
                                        PacingRingGauge(
                                            letter: "W",
                                            usedPercent: secondary.usedPercent,
                                            elapsedPercent: secondary.elapsedFraction(at: entry.date, isSecondary: true),
                                            size: ringSize,
                                            lineWidth: strokeWidth
                                        )
                                        Text(KarvFormatting.percentString(secondary.usedPercent))
                                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.65))
                                    }
                                }

                                VStack(spacing: 3) {
                                    PacingRingGauge(
                                        letter: "S",
                                        usedPercent: item.primaryWindow.usedPercent,
                                        elapsedPercent: item.primaryWindow.elapsedFraction(at: entry.date, isSecondary: false),
                                        size: ringSize,
                                        lineWidth: strokeWidth
                                    )
                                    Text(KarvFormatting.percentString(item.primaryWindow.usedPercent))
                                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.65))
                                }
                            }

                            Text("↻ \(KarvFormatting.countdownString(until: item.primaryWindow.resetsAt, from: entry.date))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(14)
        .containerBackground(for: .widget) { widgetBackground }
    }

    // MARK: Large — clean spacious rows with large W & S pacing rings

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("karv")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Text("Updated \(KarvFormatting.relativeSyncString(from: entry.snapshot.updatedAt, now: entry.date))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }

            if entry.snapshot.providers.isEmpty {
                Spacer()
                emptyWidgetState
                Spacer()
            } else {
                VStack(spacing: 10) {
                    ForEach(entry.snapshot.providers) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(item.provider.accentColor)
                                        .frame(width: 7, height: 7)
                                    Text(item.provider.displayName)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(item.planName.uppercased())
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(item.provider.accentColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(item.provider.accentColor.opacity(0.14), in: Capsule())
                                }

                                Text("S resets \(KarvFormatting.countdownString(until: item.primaryWindow.resetsAt, from: entry.date))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.55))

                                if let secondary = item.secondaryWindow {
                                    Text("W resets \(KarvFormatting.countdownString(until: secondary.resetsAt, from: entry.date))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.42))
                                }
                            }

                            Spacer()

                            HStack(spacing: 14) {
                                if let secondary = item.secondaryWindow {
                                    VStack(spacing: 4) {
                                        PacingRingGauge(
                                            letter: "W",
                                            usedPercent: secondary.usedPercent,
                                            elapsedPercent: secondary.elapsedFraction(at: entry.date, isSecondary: true),
                                            size: 52,
                                            lineWidth: 6.2
                                        )
                                        Text(KarvFormatting.percentString(secondary.usedPercent))
                                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.7))
                                    }
                                }

                                VStack(spacing: 4) {
                                    PacingRingGauge(
                                        letter: "S",
                                        usedPercent: item.primaryWindow.usedPercent,
                                        elapsedPercent: item.primaryWindow.elapsedFraction(at: entry.date, isSecondary: false),
                                        size: 52,
                                        lineWidth: 6.2
                                    )
                                    Text(KarvFormatting.percentString(item.primaryWindow.usedPercent))
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxHeight: .infinity)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }
        }
        .padding(16)
        .containerBackground(for: .widget) { widgetBackground }
    }

    // MARK: Lock Screen

    private var accessoryRectangularView: some View {
        let items = Array(entry.snapshot.providers.prefix(2))
        return HStack(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 1, height: 34)
                }

                VStack(spacing: 3) {
                    Text(item.provider.displayName.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        PacingRingGauge(
                            letter: "S",
                            usedPercent: item.primaryWindow.usedPercent,
                            elapsedPercent: item.primaryWindow.elapsedFraction(at: entry.date, isSecondary: false),
                            size: 32,
                            lineWidth: 3.8
                        )

                        if let weekly = item.secondaryWindow {
                            PacingRingGauge(
                                letter: "W",
                                usedPercent: weekly.usedPercent,
                                elapsedPercent: weekly.elapsedFraction(at: entry.date, isSecondary: true),
                                size: 32,
                                lineWidth: 3.8
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var accessoryCircularView: some View {
        Group {
            if let first = entry.snapshot.providers.first {
                PacingRingGauge(
                    letter: first.provider.monogram,
                    usedPercent: first.primaryWindow.usedPercent,
                    elapsedPercent: first.primaryWindow.elapsedFraction(at: entry.date, isSecondary: false),
                    size: 48,
                    lineWidth: 5.5
                )
            } else {
                Text("karv")
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .containerBackground(.clear, for: .widget)
    }

    private var emptyWidgetState: some View {
        VStack(spacing: 4) {
            Text("No active platforms")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("Open Karv to connect")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }
}

@main
struct KarvWidgetBundle: WidgetBundle {
    var body: some Widget {
        KarvUsageWidget()
        KarvResetLiveActivity()
    }
}

struct KarvResetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KarvResetActivityAttributes.self) { context in
            let provider = AIProvider(rawValue: context.attributes.providerRawValue) ?? .claude
            let accent = provider.accentColor
            let now = Date()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                        Text(context.attributes.providerName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Text(context.attributes.planName.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accent.opacity(0.18), in: Capsule())
                    }

                    Spacer()

                    if context.state.resetsAt > now {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                            Text(timerInterval: now...context.state.resetsAt, countsDown: true)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                        }
                    } else {
                        Text("Resetting")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AIProvider.codex.accentColor)
                    }
                }

                HStack(spacing: 10) {
                    Text(context.state.windowTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 68, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.14))
                            Capsule()
                                .fill(accent)
                                .frame(width: max(6, geo.size.width * min(max(context.state.usedPercent, 0.02), 1.0)))
                        }
                    }
                    .frame(height: 6)

                    Text("\(KarvFormatting.percentString(context.state.usedPercent))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 34, alignment: .trailing)
                }

                if let weeklyUsed = context.state.weeklyUsedPercent {
                    HStack(spacing: 10) {
                        Text("Weekly")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 68, alignment: .leading)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule()
                                    .fill(provider.secondaryAccentColor.opacity(0.85))
                                    .frame(width: max(6, geo.size.width * min(max(weeklyUsed, 0.02), 1.0)))
                            }
                        }
                        .frame(height: 5)

                        Text("\(KarvFormatting.percentString(weeklyUsed))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.055, green: 0.055, blue: 0.067))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let provider = AIProvider(rawValue: context.attributes.providerRawValue) ?? .claude
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.providerName)
                        .font(.system(size: 14, weight: .bold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(KarvFormatting.percentString(context.state.usedPercent))")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(provider.accentColor)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.resetsAt > Date() {
                        Text(timerInterval: Date()...context.state.resetsAt, countsDown: true)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }
            } compactLeading: {
                Circle().fill(provider.accentColor).frame(width: 8, height: 8)
            } compactTrailing: {
                Text(KarvFormatting.percentString(context.state.usedPercent))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
            } minimal: {
                Circle().fill(provider.accentColor).frame(width: 8, height: 8)
            }
        }
    }
}

struct KarvUsageWidget: Widget {
    let kind: String = "KarvUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KarvTimelineProvider()) { entry in
            KarvWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Karv Usage")
        .description("Compact Weekly (W) and Session (S) pacing rings for your active AI plans.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular])
        .contentMarginsDisabled()
    }
}
