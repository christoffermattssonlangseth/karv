import SwiftUI
import WidgetKit
import KarvCore

struct SettingsView: View {
    @Environment(KarvSyncStore.self) private var store
    @Environment(MacBonjourSyncClient.self) private var macSync
    @State private var webAuthProvider: AIProvider?
    @State private var claudeTokenInput: String = ""
    @State private var hasSavedClaudeToken: Bool = KarvKeychain.loadClaudeToken() != nil
    @State private var directClaudeStatus: String?
    @State private var isTestingClaudeToken: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                KarvTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        header
                        macSyncCard
                        directClaudeCard
                        visiblePlatformsCard
                        connectAccountsCard
                        displayPreferencesCard
                        setupChecklistCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 10)
                    .padding(.bottom, 32)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $webAuthProvider) { provider in
                ProviderWebAuthSheet(provider: provider)
                    .presentationDetents([.large])
                    .presentationBackground(KarvTheme.background)
            }
        }
    }

    private var directClaudeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("DIRECT CLAUDE (WORKS ON 5G)")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(KarvTheme.textTertiary)
                Spacer()
                if hasSavedClaudeToken {
                    Text("Keychain Ready")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AIProvider.codex.accentColor)
                }
            }

            Text("Save your Claude Code OAuth token in iOS Keychain to fetch live 5h & weekly Claude usage anywhere, even when your Mac is closed.")
                .font(.system(size: 12))
                .foregroundStyle(KarvTheme.textSecondary)

            HStack(spacing: 8) {
                SecureField("Paste Claude OAuth token", text: $claudeTokenInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(10)
                    .background(KarvTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(KarvTheme.hairline, lineWidth: 1))

                Button {
                    let tokenToSave = claudeTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tokenToSave.isEmpty else { return }
                    KarvKeychain.saveClaudeToken(tokenToSave)
                    hasSavedClaudeToken = true
                    claudeTokenInput = ""
                    Task { await testDirectClaude(token: tokenToSave) }
                } label: {
                    if isTestingClaudeToken {
                        ProgressView().tint(.black).scaleEffect(0.75)
                    } else {
                        Text("Save")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .disabled(claudeTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingClaudeToken)
            }

            if hasSavedClaudeToken {
                HStack {
                    Button {
                        if let saved = KarvKeychain.loadClaudeToken() {
                            Task { await testDirectClaude(token: saved) }
                        }
                    } label: {
                        Text("Fetch Live Claude Now")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AIProvider.claude.accentColor)
                    }

                    Spacer()

                    Button("Remove Token", role: .destructive) {
                        KarvKeychain.clearClaudeToken()
                        hasSavedClaudeToken = false
                        directClaudeStatus = "Token removed from Keychain."
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }

            if let directClaudeStatus {
                Text(directClaudeStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(KarvTheme.textSecondary)
            }
        }
        .padding(18)
        .karvCard(glow: AIProvider.claude.accentColor, cornerRadius: 22)
    }

    private func testDirectClaude(token: String) async {
        isTestingClaudeToken = true
        if let live = await ClaudeOAuthUsageClient.fetchUsage(token: token) {
            store.updateClaudeFromDirectOAuth(live)
            WidgetCenter.shared.reloadAllTimelines()
            directClaudeStatus = "Live Claude synced (\(Int((live.fiveHourUsed * 100).rounded()))% 5h · \(Int((live.sevenDayUsed * 100).rounded()))% weekly)"
        } else {
            directClaudeStatus = "Could not fetch Claude usage — check token validity."
        }
        isTestingClaudeToken = false
    }

    private var visiblePlatformsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("VISIBLE PLATFORMS")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(KarvTheme.textTertiary)

            ForEach(AIProvider.allCases) { provider in
                Toggle(isOn: Binding(
                    get: { store.preferences.isEnabled(provider) },
                    set: { isOn in
                        store.setProvider(provider, enabled: isOn)
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                )) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(provider.accentColor)
                            .frame(width: 8, height: 8)
                        Text(provider.displayName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(KarvTheme.textPrimary)
                    }
                }
                .tint(provider.accentColor)
            }

            Text("Hidden or disconnected platforms are automatically omitted from your dashboard and Home Screen widgets.")
                .font(.system(size: 12))
                .foregroundStyle(KarvTheme.textTertiary)
        }
        .padding(18)
        .karvCard(cornerRadius: 22)
    }

    private var connectAccountsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("CONNECT ACCOUNTS ON IPHONE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(KarvTheme.textTertiary)
                Spacer()
                Text("Web Session")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(KarvTheme.textSecondary)
            }

            ForEach(AIProvider.allCases) { provider in
                let snap = store.snapshot.snapshot(for: provider)
                let isWebConnected = snap?.source == .webSession

                Button {
                    webAuthProvider = provider
                } label: {
                    HStack(spacing: 12) {
                        ProviderBadge(provider: provider, size: 34)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(KarvTheme.textPrimary)
                            Text(isWebConnected
                                 ? "Connected · Tap to refresh"
                                 : "Sign in to fetch \(provider.displayName) usage")
                                .font(.system(size: 12))
                                .foregroundStyle(isWebConnected ? provider.accentColor : KarvTheme.textSecondary)
                        }

                        Spacer()

                        Text(isWebConnected ? "Sync" : "Sign In")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isWebConnected ? KarvTheme.textPrimary : .black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isWebConnected ? KarvTheme.surface : Color.white,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().strokeBorder(KarvTheme.hairlineStrong, lineWidth: isWebConnected ? 1 : 0)
                            )
                    }
                    .padding(12)
                    .background(KarvTheme.surfaceElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(KarvTheme.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(CardPressButtonStyle())
            }
        }
        .padding(18)
        .karvCard(glow: AIProvider.claude.accentColor, cornerRadius: 22)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sync & Preferences")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .tracking(-0.6)
                    .foregroundStyle(KarvTheme.textPrimary)
                Text("Mac companion bridge & display controls")
                    .font(.system(size: 13))
                    .foregroundStyle(KarvTheme.textSecondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    private var macSyncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: macSync.isConnectedToMac ? "wifi" : "icloud.and.arrow.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(macSync.isConnectedToMac ? AIProvider.codex.accentColor : AIProvider.gemini.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        (macSync.isConnectedToMac ? AIProvider.codex.accentColor : AIProvider.gemini.accentColor).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 10)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(macSync.isConnectedToMac
                         ? "KarvMac Connected"
                         : (store.snapshot.isDemoData ? "Demo Preview Active" : "Synced from Mac"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(KarvTheme.textPrimary)
                    Text(macSync.statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(KarvTheme.textSecondary)
                }

                Spacer()

                Button {
                    if macSync.isConnectedToMac {
                        macSync.pullNow()
                    } else {
                        macSync.start(store: store)
                        store.refresh()
                    }
                } label: {
                    Text("Sync")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.white, in: Capsule())
                }
            }

            if let error = store.lastSyncError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(QuotaStatus.elevated.tintColor)
            }
        }
        .padding(18)
        .karvCard(glow: macSync.isConnectedToMac ? AIProvider.codex.accentColor : AIProvider.gemini.accentColor, cornerRadius: 22)
    }

    private var displayPreferencesCard: some View {
        @Bindable var bindableStore = store
        return VStack(alignment: .leading, spacing: 16) {
            Text("DISPLAY")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(KarvTheme.textTertiary)

            Toggle(isOn: $bindableStore.preferences.showRemainingPercentage) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show remaining %")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(KarvTheme.textPrimary)
                    Text("Turn off to display used percentage instead")
                        .font(.system(size: 12))
                        .foregroundStyle(KarvTheme.textSecondary)
                }
            }
            .tint(AIProvider.codex.accentColor)

            Divider().overlay(KarvTheme.hairline)

            Toggle(isOn: $bindableStore.preferences.useDemoMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Demo preview mode")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(KarvTheme.textPrimary)
                    Text("Use realistic sample data until KarvMac syncs")
                        .font(.system(size: 12))
                        .foregroundStyle(KarvTheme.textSecondary)
                }
            }
            .tint(AIProvider.claude.accentColor)

            Divider().overlay(KarvTheme.hairline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Warning threshold")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(KarvTheme.textPrimary)
                    Spacer()
                    Text(KarvFormatting.percentString(store.preferences.warningThreshold))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(KarvTheme.textSecondary)
                }
                Slider(value: $bindableStore.preferences.warningThreshold, in: 0.50...0.95, step: 0.05)
                    .tint(.white)
            }
        }
        .padding(18)
        .karvCard(cornerRadius: 22)
    }

    private var setupChecklistCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MAC COMPANION SETUP")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(KarvTheme.textTertiary)

            setupStep(number: "1", title: "Select your Apple Team in Xcode", detail: "Enable iCloud Key-Value Storage & App Group on Karv, KarvWidget, and KarvMac.")
            setupStep(number: "2", title: "Run KarvMac in your menu bar", detail: "KarvMac reads local ~/.claude, ~/.codex, and ~/.gemini usage logs every 5 minutes.")
            setupStep(number: "3", title: "Turn off Demo mode above", detail: "Your iPhone dashboard & Home Screen widgets will update automatically via iCloud.")
        }
        .padding(18)
        .karvCard(cornerRadius: 22)
    }

    private func setupStep(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(KarvTheme.textPrimary)
                .frame(width: 24, height: 24)
                .background(KarvTheme.surfaceElevated, in: Circle())
                .overlay(Circle().strokeBorder(KarvTheme.hairlineStrong, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(KarvTheme.textPrimary)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(KarvTheme.textSecondary)
            }
        }
    }
}
