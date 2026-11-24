import SwiftUI
import Charts
import KarvCore

struct TrendsView: View {
    @Environment(KarvSyncStore.self) private var store

    private struct FlattenedPoint: Identifiable {
        let id: String
        let provider: AIProvider
        let date: Date
        let usedPercent: Double
    }

    private var allPoints: [FlattenedPoint] {
        store.activeProviders.flatMap { snap in
            snap.history.map { point in
                FlattenedPoint(
                    id: "\(snap.provider.rawValue)-\(point.id)",
                    provider: snap.provider,
                    date: point.date,
                    usedPercent: point.usedPercent * 100
                )
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                KarvTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        header
                        comparisonChartCard
                        providerAveragesCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Trends")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(-0.6)
                    .foregroundStyle(KarvTheme.textPrimary)
                Text("7-day rolling utilization across subscriptions")
                    .font(.system(size: 13))
                    .foregroundStyle(KarvTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var comparisonChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ForEach(store.activeProviders) { snap in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(snap.provider.accentColor)
                            .frame(width: 7, height: 7)
                        Text(snap.provider.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(KarvTheme.textSecondary)
                    }
                }
            }

            Chart(allPoints) { point in
                LineMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Used", point.usedPercent)
                )
                .foregroundStyle(by: .value("Provider", point.provider.displayName))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
            .chartForegroundStyleScale([
                AIProvider.claude.displayName: AIProvider.claude.accentColor,
                AIProvider.codex.displayName: AIProvider.codex.accentColor,
                AIProvider.gemini.displayName: AIProvider.gemini.accentColor
            ])
            .chartLegend(.hidden)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                        .foregroundStyle(Color.white.opacity(0.08))
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(KarvTheme.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(KarvTheme.textTertiary)
                }
            }
            .frame(height: 220)
        }
        .padding(18)
        .karvCard(cornerRadius: 22)
    }

    private var providerAveragesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("7-DAY AVERAGES")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(KarvTheme.textTertiary)

            ForEach(store.activeProviders) { snap in
                let avg = snap.history.isEmpty
                    ? snap.primaryWindow.usedPercent
                    : snap.history.map(\.usedPercent).reduce(0, +) / Double(snap.history.count)

                HStack(spacing: 12) {
                    ProviderBadge(provider: snap.provider, size: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(snap.provider.displayName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(KarvTheme.textPrimary)
                        Text(snap.planName)
                            .font(.system(size: 12))
                            .foregroundStyle(KarvTheme.textSecondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(KarvFormatting.percentString(avg)) avg")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(KarvTheme.textPrimary)
                        PrecisionMeterBar(
                            progress: avg,
                            accent: snap.provider.accentColor,
                            secondaryAccent: snap.provider.secondaryAccentColor,
                            warningThreshold: store.preferences.warningThreshold,
                            height: 4
                        )
                        .frame(width: 84)
                    }
                }
                .padding(12)
                .background(KarvTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(KarvTheme.hairline, lineWidth: 1)
                )
            }
        }
        .padding(18)
        .karvCard(cornerRadius: 22)
    }
}
