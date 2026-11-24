import SwiftUI
import WidgetKit
import KarvCore

struct DashboardView: View {
    @Environment(KarvSyncStore.self) private var store
    @Environment(MacBonjourSyncClient.self) private var macSync
    @State private var selectedProvider: ProviderUsageSnapshot?
    @State private var isSpinning = false

    var body: some View {
        NavigationStack {
            ZStack {
                KarvTheme.background.ignoresSafeArea()

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        VStack(spacing: 16) {
                            headerBar(now: context.date)
                            heroSummaryCard(now: context.date)

                            VStack(spacing: 14) {
                                if store.activeProviders.isEmpty {
                                    emptyProvidersCard
                                } else {
                                    ForEach(store.activeProviders) { providerSnapshot in
                                        Button {
                                            selectedProvider = providerSnapshot
                                        } label: {
                                            ProviderCardView(
                                                snapshot: providerSnapshot,
                                                showRemaining: store.preferences.showRemainingPercentage,
                                                warningThreshold: store.preferences.warningThreshold,
                                                now: context.date
                                            )
                                        }
                                        .buttonStyle(CardPressButtonStyle())
                                    }
                                }
                            }

                            footerSyncHint(now: context.date)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 32)
                    }
                    .refreshable {
                        triggerRefresh()
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedProvider) { snapshot in
                ProviderDetailSheet(provider: snapshot.provider)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(KarvTheme.background)
            }
        }
    }

    private func headerBar(now: Date) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 3) {
                Text("karv")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(KarvTheme.textPrimary)

                HStack(spacing: 6) {
                    Circle()
                        .fill(store.snapshot.isDemoData ? Color.amberIndicator : Color.emeraldIndicator)
                        .frame(width: 6, height: 6)
                        .shadow(
                            color: (store.snapshot.isDemoData ? Color.amberIndicator : Color.emeraldIndicator).opacity(0.8),
                            radius: 4
                        )

                    Text(store.snapshot.isDemoData
                         ? "Demo preview · \(KarvFormatting.relativeSyncString(from: store.snapshot.updatedAt, now: now))"
                         : "\(store.snapshot.sourceDeviceName) · \(KarvFormatting.relativeSyncString(from: store.snapshot.updatedAt, now: now))"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KarvTheme.textSecondary)
                }
            }

            Spacer()

            Button {
                triggerRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KarvTheme.textPrimary)
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .frame(width: 36, height: 36)
                    .background(KarvTheme.surfaceElevated, in: Circle())
                    .overlay(Circle().strokeBorder(KarvTheme.hairline, lineWidth: 1))
            }
            .accessibilityLabel("Refresh usage")
        }
        .padding(.bottom, 4)
    }

    private func heroSummaryCard(now: Date) -> some View {
        let active = store.activeProviders
        let avgRemaining = active.isEmpty
            ? 0
            : active.reduce(0.0) { $0 + $1.primaryWindow.remainingPercent } / Double(active.count)
        let averageValue = store.preferences.showRemainingPercentage ? avgRemaining : (1.0 - avgRemaining)
        let soonest = active.map { ($0.provider, $0.primaryWindow.resetsAt) }.min(by: { $0.1 < $1.1 })

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.preferences.showRemainingPercentage ? "OVERALL HEADROOM" : "AVERAGE UTILIZATION")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(KarvTheme.textTertiary)

                    Text(active.isEmpty ? "—" : KarvFormatting.percentString(averageValue))
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(KarvTheme.textPrimary)
                }

                Spacer()

                if let next = soonest {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("NEXT RESET")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.0)
                            .foregroundStyle(KarvTheme.textTertiary)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(next.0.accentColor)
                                .frame(width: 6, height: 6)
                            Text("\(next.0.displayName) · \(KarvFormatting.countdownString(until: next.1, from: now))")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(KarvTheme.textPrimary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(KarvTheme.surfaceElevated, in: Capsule())
                        .overlay(Capsule().strokeBorder(KarvTheme.hairline, lineWidth: 1))
                    }
                }
            }

            if !active.isEmpty {
                HStack(spacing: 8) {
                    ForEach(active) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.provider.displayName)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(KarvTheme.textSecondary)
                                Spacer()
                                Text(KarvFormatting.percentString(
                                    store.preferences.showRemainingPercentage
                                        ? item.primaryWindow.remainingPercent
                                        : item.primaryWindow.usedPercent
                                ))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(KarvTheme.textPrimary)
                            }

                            PrecisionMeterBar(
                                progress: item.primaryWindow.usedPercent,
                                accent: item.provider.accentColor,
                                secondaryAccent: item.provider.secondaryAccentColor,
                                warningThreshold: store.preferences.warningThreshold,
                                height: 4
                            )
                        }
                    }
                }
            }
        }
        .padding(18)
        .karvCard(cornerRadius: 22)
    }

    private var emptyProvidersCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 24))
                .foregroundStyle(KarvTheme.textSecondary)
            Text("No active subscriptions")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KarvTheme.textPrimary)
            Text("Connect Claude, Codex, or Gemini in the Sync tab to track your usage.")
                .font(.system(size: 13))
                .foregroundStyle(KarvTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .karvCard(cornerRadius: 22)
    }

    private func footerSyncHint(now: Date) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "macbook.and.iphone")
                .font(.system(size: 12))
                .foregroundStyle(KarvTheme.textTertiary)

            Text("Tap any subscription for 7-day charts, window breakdowns, or manual adjustments.")
                .font(.system(size: 12))
                .foregroundStyle(KarvTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private func triggerRefresh() {
        withAnimation(.easeInOut(duration: 0.55)) {
            isSpinning = true
        }
        if macSync.isConnectedToMac {
            macSync.pullNow()
        } else {
            store.refresh()
        }
        Task {
            if let token = KarvKeychain.loadClaudeToken(),
               let live = await ClaudeOAuthUsageClient.fetchUsage(token: token) {
                store.updateClaudeFromDirectOAuth(live)
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            isSpinning = false
        }
    }
}

struct ProviderCardView: View {
    let snapshot: ProviderUsageSnapshot
    let showRemaining: Bool
    let warningThreshold: Double
    let now: Date

    private var status: QuotaStatus {
        snapshot.primaryWindow.status(warningThreshold: warningThreshold)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ProviderBadge(provider: snapshot.provider, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(snapshot.provider.displayName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(KarvTheme.textPrimary)

                        Text(snapshot.planName.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(snapshot.provider.accentColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(snapshot.provider.accentColor.opacity(0.14), in: Capsule())
                    }

                    Text(snapshot.statusNote ?? snapshot.source.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(KarvTheme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                if status != .nominal {
                    Text(status.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(status.tintColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(status.tintColor.opacity(0.14), in: Capsule())
                } else {
                    MiniSparkline(points: snapshot.history, color: snapshot.provider.accentColor)
                        .frame(width: 52, height: 18)
                }
            }

            HStack(spacing: 12) {
                windowTile(
                    tag: "S",
                    window: snapshot.primaryWindow,
                    accent: snapshot.provider.accentColor,
                    secondaryAccent: snapshot.provider.secondaryAccentColor
                )

                if let weekly = snapshot.secondaryWindow {
                    windowTile(
                        tag: "W",
                        window: weekly,
                        accent: snapshot.provider.secondaryAccentColor,
                        secondaryAccent: snapshot.provider.accentColor
                    )
                }
            }
        }
        .padding(16)
        .karvCard(glow: snapshot.provider.accentColor, cornerRadius: 22)
    }

    private func windowTile(
        tag: String,
        window: QuotaWindow,
        accent: Color,
        secondaryAccent: Color
    ) -> some View {
        let displayValue = showRemaining ? window.remainingPercent : window.usedPercent

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(tag)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
                    .frame(width: 18, height: 18)
                    .background(accent.opacity(0.16), in: Circle())

                Text(window.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KarvTheme.textSecondary)
                    .lineLimit(1)

                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(KarvFormatting.percentString(displayValue))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(KarvTheme.textPrimary)

                Text(showRemaining ? "left" : "used")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(KarvTheme.textTertiary)
            }

            PrecisionMeterBar(
                progress: window.usedPercent,
                accent: accent,
                secondaryAccent: secondaryAccent,
                warningThreshold: warningThreshold,
                height: 6
            )

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(KarvTheme.textTertiary)
                Text("Resets \(KarvFormatting.countdownString(until: window.resetsAt, from: now))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(KarvTheme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KarvTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(KarvTheme.hairline, lineWidth: 1)
        )
    }
}

struct CardPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .opacity(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: configuration.isPressed)
    }
}

private extension Color {
    static let emeraldIndicator = Color(red: 0.204, green: 0.827, blue: 0.600)
    static let amberIndicator = Color(red: 0.961, green: 0.620, blue: 0.043)
}
