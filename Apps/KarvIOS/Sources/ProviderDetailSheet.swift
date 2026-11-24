import SwiftUI
import Charts
import KarvCore

struct ProviderDetailSheet: View {
    @Environment(KarvSyncStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let provider: AIProvider

    @State private var isEditingManual = false
    @State private var isShowingWebAuth = false
    @State private var manualPrimaryUsed: Double = 0.5
    @State private var manualSecondaryUsed: Double = 0.3
    @State private var manualPlanName: String = ""

    private var snapshot: ProviderUsageSnapshot? {
        store.snapshot.snapshot(for: provider)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                KarvTheme.background.ignoresSafeArea()

                if let snapshot {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        ScrollView {
                            VStack(spacing: 16) {
                                heroGaugeCard(snapshot: snapshot, now: context.date)
                                windowsBreakdownCard(snapshot: snapshot, now: context.date)
                                historyChartCard(snapshot: snapshot)
                                sourceMetadataCard(snapshot: snapshot, now: context.date)

                                if isEditingManual {
                                    manualOverrideCard(snapshot: snapshot)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                        }
                    }
                }
            }
            .navigationTitle(provider.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isEditingManual ? "Cancel" : "Adjust") {
                        if let snap = snapshot, !isEditingManual {
                            manualPrimaryUsed = snap.primaryWindow.usedPercent
                            manualSecondaryUsed = snap.secondaryWindow?.usedPercent ?? 0
                            manualPlanName = snap.planName
                        }
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isEditingManual.toggle()
                        }
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(KarvTheme.textSecondary)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isShowingWebAuth = true
                    } label: {
                        Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(provider.accentColor)

                    Button("Done") { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KarvTheme.textPrimary)
                }
            }
            .sheet(isPresented: $isShowingWebAuth) {
                ProviderWebAuthSheet(provider: provider)
                    .presentationDetents([.large])
                    .presentationBackground(KarvTheme.background)
            }
        }
    }

    private func heroGaugeCard(snapshot: ProviderUsageSnapshot, now: Date) -> some View {
        let showRemaining = store.preferences.showRemainingPercentage
        let displayPercent = showRemaining ? snapshot.primaryWindow.remainingPercent : snapshot.primaryWindow.usedPercent

        return VStack(spacing: 18) {
            HStack {
                ProviderBadge(provider: snapshot.provider, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(snapshot.provider.vendorName) · \(snapshot.planName)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(KarvTheme.textPrimary)
                    Text(snapshot.primaryWindow.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(KarvTheme.textSecondary)
                }
                Spacer()
            }

            ZStack {
                Circle()
                    .trim(from: 0.14, to: 0.86)
                    .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(90))

                Circle()
                    .trim(from: 0.14, to: 0.14 + (0.72 * snapshot.primaryWindow.usedPercent))
                    .stroke(
                        AngularGradient(
                            colors: [snapshot.provider.accentColor, snapshot.provider.secondaryAccentColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(90))
                    .shadow(color: snapshot.provider.accentColor.opacity(0.45), radius: 10)

                VStack(spacing: 4) {
                    Text(KarvFormatting.percentString(displayPercent))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(KarvTheme.textPrimary)

                    Text(showRemaining ? "REMAINING" : "USED")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(KarvTheme.textTertiary)

                    Text("Resets in \(KarvFormatting.countdownString(until: snapshot.primaryWindow.resetsAt, from: now))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(snapshot.provider.accentColor)
                        .padding(.top, 4)
                }
            }
            .frame(width: 196, height: 196)
            .padding(.vertical, 4)
        }
        .padding(20)
        .karvCard(glow: snapshot.provider.accentColor, cornerRadius: 24)
    }

    private func windowsBreakdownCard(snapshot: ProviderUsageSnapshot, now: Date) -> some View {
        let windows = [snapshot.primaryWindow] + (snapshot.secondaryWindow.map { [$0] } ?? [])

        return VStack(alignment: .leading, spacing: 14) {
            Text("QUOTA WINDOWS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(KarvTheme.textTertiary)

            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(KarvTheme.textPrimary)
                            Text(window.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(KarvTheme.textSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(KarvFormatting.percentString(window.usedPercent)) used")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(KarvTheme.textPrimary)
                            Text("Resets in \(KarvFormatting.countdownString(until: window.resetsAt, from: now))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(KarvTheme.textTertiary)
                        }
                    }

                    PrecisionMeterBar(
                        progress: window.usedPercent,
                        accent: snapshot.provider.accentColor,
                        secondaryAccent: snapshot.provider.secondaryAccentColor,
                        warningThreshold: store.preferences.warningThreshold,
                        height: 6
                    )
                }
                .padding(14)
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

    private func historyChartCard(snapshot: ProviderUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("7-DAY UTILIZATION")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(KarvTheme.textTertiary)
                Spacer()
                if let peak = snapshot.history.map(\.usedPercent).max() {
                    Text("Peak \(KarvFormatting.percentString(peak))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(snapshot.provider.accentColor)
                }
            }

            Chart(snapshot.history) { point in
                AreaMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Usage", point.usedPercent * 100)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [snapshot.provider.accentColor.opacity(0.32), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Usage", point.usedPercent * 100)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .foregroundStyle(snapshot.provider.accentColor)

                PointMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Usage", point.usedPercent * 100)
                )
                .symbolSize(24)
                .foregroundStyle(snapshot.provider.secondaryAccentColor)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
                        .foregroundStyle(Color.white.opacity(0.08))
                    AxisValueLabel {
                        if let intVal = value.as(Int.self) {
                            Text("\(intVal)%")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(KarvTheme.textTertiary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(KarvTheme.textTertiary)
                }
            }
            .frame(height: 165)
        }
        .padding(18)
        .karvCard(cornerRadius: 22)
    }

    private func sourceMetadataCard(snapshot: ProviderUsageSnapshot, now: Date) -> some View {
        VStack(spacing: 10) {
            metadataRow(label: "Source", value: snapshot.source.rawValue)
            Divider().overlay(KarvTheme.hairline)
            metadataRow(label: "Last Synced", value: KarvFormatting.relativeSyncString(from: snapshot.lastSyncedAt, now: now))
            if let note = snapshot.statusNote {
                Divider().overlay(KarvTheme.hairline)
                metadataRow(label: "Collector", value: note)
            }
        }
        .padding(18)
        .karvCard(cornerRadius: 20)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(KarvTheme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(KarvTheme.textPrimary)
        }
    }

    private func manualOverrideCard(snapshot: ProviderUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MANUAL OVERRIDE")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(KarvTheme.textTertiary)

            TextField("Plan name", text: $manualPlanName)
                .textFieldStyle(.plain)
                .padding(12)
                .background(KarvTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(KarvTheme.hairline, lineWidth: 1))

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(snapshot.primaryWindow.title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(KarvFormatting.percentString(manualPrimaryUsed)) used")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(snapshot.provider.accentColor)
                }
                Slider(value: $manualPrimaryUsed, in: 0...1)
                    .tint(snapshot.provider.accentColor)
            }

            if let secondary = snapshot.secondaryWindow {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(secondary.title)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(KarvFormatting.percentString(manualSecondaryUsed)) used")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(snapshot.provider.accentColor)
                    }
                    Slider(value: $manualSecondaryUsed, in: 0...1)
                        .tint(snapshot.provider.accentColor)
                }
            }

            Button {
                store.updateProviderManually(
                    provider: provider,
                    primaryUsedPercent: manualPrimaryUsed,
                    secondaryUsedPercent: snapshot.secondaryWindow == nil ? nil : manualSecondaryUsed,
                    planName: manualPlanName.isEmpty ? snapshot.planName : manualPlanName
                )
                withAnimation {
                    isEditingManual = false
                }
            } label: {
                Text("Save Snapshot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(18)
        .karvCard(glow: snapshot.provider.accentColor, cornerRadius: 20)
    }
}
