import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import ServiceManagement
import KarvCore

@main
struct KarvMacApp: App {
    @State private var coordinator = MacSyncCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(coordinator: coordinator)
                .preferredColorScheme(.dark)
        } label: {
            Image(nsImage: MenuBarRingRenderer.render(snapshot: coordinator.snapshot))
        }
        .menuBarExtraStyle(.window)
    }
}

/// Renders crisp Retina `W` (Weekly) and `S` (Session/Daily) pacing rings
/// for every connected provider (e.g., Claude & Gemini) directly in the macOS menu bar.
@MainActor
enum MenuBarRingRenderer {
    static func render(snapshot: KarvSnapshot) -> NSImage {
        let now = Date()
        let connected = snapshot.providers.filter(\.isConnected)
        let items = connected.isEmpty ? Array(snapshot.providers.prefix(1)) : connected

        let ringSize: CGFloat = 17
        let dotSize: CGFloat = 5
        let dotToRingGap: CGFloat = 4
        let intraPairGap: CGFloat = 4
        let dividerBlockWidth: CGFloat = 11 // 5px pad + 1px hairline + 5px pad
        let horizontalPad: CGFloat = 3
        let totalHeight: CGFloat = 22

        let groupWidth = dotSize + dotToRingGap + ringSize + intraPairGap + ringSize
        let totalWidth = horizontalPad * 2
            + CGFloat(items.count) * groupWidth
            + CGFloat(max(0, items.count - 1)) * dividerBlockWidth

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let ringY = (totalHeight - ringSize) / 2
            var cursorX = horizontalPad

            for (index, item) in items.enumerated() {
                if index > 0 {
                    // Subtle vertical hairline separator between providers
                    let dividerX = cursorX + dividerBlockWidth / 2
                    ctx.saveGState()
                    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.24).cgColor)
                    ctx.setLineWidth(1.0)
                    ctx.move(to: CGPoint(x: dividerX, y: 5))
                    ctx.addLine(to: CGPoint(x: dividerX, y: totalHeight - 5))
                    ctx.strokePath()
                    ctx.restoreGState()
                    cursorX += dividerBlockWidth
                }

                // Provider accent dot (terracotta = Claude, emerald = Codex, sapphire = Gemini)
                let dotRect = CGRect(
                    x: cursorX,
                    y: (totalHeight - dotSize) / 2,
                    width: dotSize,
                    height: dotSize
                )
                ctx.saveGState()
                ctx.setFillColor(providerNSColor(item.provider).cgColor)
                ctx.fillEllipse(in: dotRect)
                ctx.restoreGState()
                cursorX += dotSize + dotToRingGap

                let weeklyUsed = item.secondaryWindow?.usedPercent ?? 0
                // Shared pacing logic (KarvCore) so the menu bar, app and widgets agree;
                // rolling/estimated windows get a neutral tick instead of a false red one.
                let weeklyElapsed = clampTick(item.secondaryWindow?.pace(at: now, isSecondary: true).elapsedFraction ?? 0)
                let sessionUsed = item.primaryWindow.usedPercent
                let sessionElapsed = clampTick(item.primaryWindow.pace(at: now, isSecondary: false).elapsedFraction)

                drawRing(
                    letter: "W",
                    used: weeklyUsed,
                    elapsed: weeklyElapsed,
                    rect: CGRect(x: cursorX, y: ringY, width: ringSize, height: ringSize)
                )
                cursorX += ringSize + intraPairGap

                drawRing(
                    letter: "S",
                    used: sessionUsed,
                    elapsed: sessionElapsed,
                    rect: CGRect(x: cursorX, y: ringY, width: ringSize, height: ringSize)
                )
                cursorX += ringSize
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func providerNSColor(_ provider: AIProvider) -> NSColor {
        switch provider {
        case .claude: NSColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 1.0)
        case .codex:  NSColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 1.0)
        case .gemini: NSColor(red: 0.376, green: 0.647, blue: 0.980, alpha: 1.0)
        }
    }

    private static func clampTick(_ elapsed: Double) -> Double {
        min(max(elapsed, 0.04), 0.96)
    }

    private static func drawRing(letter: String, used: Double, elapsed: Double, rect: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lineWidth: CGFloat = 2.4
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = (rect.width - lineWidth) / 2

        // Track
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        // White usage arc clockwise from 12 o'clock (in non-flipped CoreGraphics, 12 o'clock is +pi/2, clockwise is `clockwise: true`)
        let clampedUsed = min(max(used, 0.0), 1.0)
        if clampedUsed > 0.01 {
            let startAngle = CGFloat.pi / 2
            let endAngle = startAngle - CGFloat(max(0.04, clampedUsed)) * 2 * .pi
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
            ctx.strokePath()
        }

        // Radial green/red pacing tick
        let isOverPace = used > elapsed + 0.02
        let tickColor = isOverPace
            ? NSColor(red: 1.0, green: 0.25, blue: 0.22, alpha: 1.0)
            : NSColor(red: 0.18, green: 0.84, blue: 0.36, alpha: 1.0)
        let tickAngle = CGFloat.pi / 2 - CGFloat(elapsed) * 2 * .pi
        let innerR = radius - lineWidth * 0.7
        let outerR = radius + lineWidth * 0.75
        let p1 = CGPoint(x: center.x + cos(tickAngle) * innerR, y: center.y + sin(tickAngle) * innerR)
        let p2 = CGPoint(x: center.x + cos(tickAngle) * outerR, y: center.y + sin(tickAngle) * outerR)

        ctx.setStrokeColor(tickColor.cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        ctx.move(to: p1)
        ctx.addLine(to: p2)
        ctx.strokePath()
        ctx.restoreGState()

        // Center letter
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: letter, attributes: attrs)
        let strSize = str.size()
        let textPoint = CGPoint(
            x: center.x - strSize.width / 2,
            y: center.y - strSize.height / 2 - 0.3
        )
        str.draw(at: textPoint)
    }
}

@MainActor
@Observable
final class MacSyncCoordinator {
    /// What the menu bar and popover show: the merged view of this Mac's own readings and
    /// anything newer/real that arrived from the iPhone via iCloud. Showing only the Mac's
    /// own collection made a failed Mac fetch (estimate) hide a correct phone reading.
    var snapshot: KarvSnapshot { store.snapshot }
    var isSyncing = false
    var autoSyncEnabled = true
    var launchAtLogin: Bool {
        didSet {
            updateLaunchAtLogin(enabled: launchAtLogin)
        }
    }
    var geminiSessionBudget: Double {
        didSet {
            UserDefaults.standard.set(geminiSessionBudget, forKey: "karv.mac.geminiBudget")
            syncNow()
        }
    }
    var pairingFeedback: String?
    /// Keep the iPhone's Claude token current via iCloud Keychain (end-to-end encrypted,
    /// only your own devices), so it never needs manual re-pairing.
    var shareClaudeTokenWithIPhone: Bool {
        didSet {
            UserDefaults.standard.set(shareClaudeTokenWithIPhone, forKey: "karv.mac.shareClaudeToken")
            if shareClaudeTokenWithIPhone {
                shareClaudeTokenIfChanged()
            } else {
                // Only remove what the Mac put there; leave a manually paired token alone.
                if KarvKeychain.loadSharedClaudeToken()?.source == .mac {
                    KarvKeychain.clearSharedClaudeToken()
                }
                tokenShareStatus = "Not sharing Claude token"
            }
        }
    }
    var tokenShareStatus: String?

    /// Opt-in: read real Gemini quota using Antigravity's sign-in (see AntigravityQuotaReader).
    var useAntigravityQuota: Bool {
        didSet {
            UserDefaults.standard.set(useAntigravityQuota, forKey: "karv.mac.useAntigravityQuota")
            antigravityAccessDenied = false
            antigravityPausedUntil = .distantPast
            if !useAntigravityQuota {
                lastLiveGemini = nil
                antigravityStatus = nil
            }
            syncNow()
        }
    }
    var antigravityStatus: String?

    /// Pace daily/weekly windows by when you usually work (learned from real readings)
    /// instead of an even burn around the clock.
    var paceByRhythm: Bool {
        didSet {
            UserDefaults.standard.set(paceByRhythm, forKey: "karv.mac.paceByRhythm")
            applyRhythmSettings()
        }
    }
    var activeStartHour: Int {
        didSet {
            UserDefaults.standard.set(activeStartHour, forKey: "karv.mac.activeStartHour")
            applyRhythmSettings()
        }
    }
    var activeEndHour: Int {
        didSet {
            UserDefaults.standard.set(activeEndHour, forKey: "karv.mac.activeEndHour")
            applyRhythmSettings()
        }
    }
    var rhythmStatus: String {
        (store.snapshot.rhythm ?? UsageRhythm(isEnabled: paceByRhythm)).statusText()
    }

    private let store: KarvSyncStore
    private let collector = LocalUsageCollector()
    private let bonjourServer = LocalBonjourSyncServer()
    private var timerTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var lastLiveClaude: ProviderUsageSnapshot?
    private var lastLiveGemini: ProviderUsageSnapshot?
    /// After the user declines the Keychain prompt, stop asking until they toggle again.
    private var antigravityAccessDenied = false
    /// After Google rejects the request, wait before trying again instead of
    /// sending failing requests every minute.
    private var antigravityPausedUntil: Date = .distantPast
    /// A windowless menu-bar app gets App Napped, which stretches the 1-minute
    /// `Task.sleep` to many minutes. Holding this activity opts out (sleep is still allowed).
    private let appNapActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep],
        reason: "Karv periodic usage sync"
    )

    init() {
        let syncStore = KarvSyncStore(enableCloudSync: true)
        self.store = syncStore
        // Seed "last real reading" from what was saved, so a restart doesn't drop the
        // Mac back to the rough estimate until the next successful API call.
        self.lastLiveClaude = Self.realReading(.claude, in: syncStore.snapshot)
        self.lastLiveGemini = Self.realReading(.gemini, in: syncStore.snapshot)
        let savedBudget = UserDefaults.standard.double(forKey: "karv.mac.geminiBudget")
        self.geminiSessionBudget = savedBudget >= 20 ? savedBudget : 100.0
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        self.shareClaudeTokenWithIPhone = UserDefaults.standard.object(forKey: "karv.mac.shareClaudeToken") as? Bool ?? true
        self.useAntigravityQuota = UserDefaults.standard.bool(forKey: "karv.mac.useAntigravityQuota")
        let defaults = UserDefaults.standard
        self.paceByRhythm = defaults.object(forKey: "karv.mac.paceByRhythm") as? Bool ?? true
        self.activeStartHour = defaults.object(forKey: "karv.mac.activeStartHour") as? Int ?? 8
        self.activeEndHour = defaults.object(forKey: "karv.mac.activeEndHour") as? Int ?? 20

        bonjourServer.start(initialSnapshot: syncStore.snapshot)
        Task {
            _ = await KarvNotificationScheduler.requestPermission()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.syncNow()
            }
        }
        startPeriodicSync()
    }

    func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        let budget = geminiSessionBudget
        let lastLive = lastLiveClaude
        let lastGemini = lastLiveGemini
        let readAntigravity = useAntigravityQuota && !antigravityAccessDenied && Date() >= antigravityPausedUntil
        Task {
            let antigravity = readAntigravity ? await AntigravityQuotaReader.fetch() : nil
            if let antigravity {
                updateAntigravityStatus(antigravity)
            }
            let collected = await collector.collectSnapshot(
                geminiSessionBudget: budget,
                lastLiveClaude: lastLive,
                antigravity: antigravity,
                lastLiveGemini: lastGemini
            )
            // Merge rather than replace: a real reading (e.g. the iPhone's direct Claude
            // fetch) beats this Mac's estimate; the newer of two real readings wins.
            var merged = store.snapshot.isDemoData ? collected : store.snapshot.merged(with: collected)
            if !merged.isDemoData {
                merged.rhythm = learnedRhythm(from: merged)
            }
            store.publish(merged)
            lastLiveClaude = Self.realReading(.claude, in: merged) ?? lastLiveClaude
            if useAntigravityQuota {
                lastLiveGemini = Self.realReading(.gemini, in: merged) ?? lastLiveGemini
            }
            shareClaudeTokenIfChanged()
            bonjourServer.update(snapshot: merged)
            KarvNotificationScheduler.scheduleAlerts(for: merged, preferences: store.preferences)
            isSyncing = false
        }
    }

    /// The usage rhythm with the current settings, after folding in this snapshot's readings.
    private func learnedRhythm(from snapshot: KarvSnapshot) -> UsageRhythm {
        var rhythm = snapshot.rhythm ?? UsageRhythm()
        rhythm.isEnabled = paceByRhythm
        rhythm.activeStartHour = activeStartHour
        rhythm.activeEndHour = activeEndHour
        rhythm.learn(from: snapshot)
        return rhythm
    }

    /// Republishes immediately so the pace on all devices follows a settings change.
    private func applyRhythmSettings() {
        var updated = store.snapshot
        guard !updated.isDemoData else { return }
        var rhythm = updated.rhythm ?? UsageRhythm()
        rhythm.isEnabled = paceByRhythm
        rhythm.activeStartHour = activeStartHour
        rhythm.activeEndHour = activeEndHour
        rhythm.updatedAt = Date()
        updated.rhythm = rhythm
        store.publish(updated)
        bonjourServer.update(snapshot: updated)
    }

    /// Claude Code refreshes its access token every few hours; push each new one to the
    /// shared iCloud Keychain item so the iPhone app and widgets pick it up automatically.
    private func shareClaudeTokenIfChanged() {
        guard shareClaudeTokenWithIPhone,
              let info = collector.readClaudeCredential() else { return }
        // Compare with what's actually stored (not a cached copy), so a token removed or
        // replaced on another device is restored on the next sync.
        if let existing = KarvKeychain.loadSharedClaudeToken(), existing.token == info.token {
            tokenShareStatus = "Claude token shared with iPhone"
            return
        }
        if KarvKeychain.saveSharedClaudeToken(info) {
            tokenShareStatus = "Claude token shared with iPhone"
        } else {
            tokenShareStatus = "Couldn't write to iCloud Keychain — use QR pairing"
        }
    }

    /// A provider reading that came from a real quota source and is still current.
    private static func realReading(_ provider: AIProvider, in snapshot: KarvSnapshot) -> ProviderUsageSnapshot? {
        guard !snapshot.isDemoData,
              let item = snapshot.snapshot(for: provider),
              item.isConnected, !item.isEstimate,
              item.primaryWindow.resetsAt > Date() else { return nil }
        return item
    }

    private func updateAntigravityStatus(_ outcome: AntigravityQuotaReader.Outcome) {
        switch outcome {
        case .success:
            antigravityStatus = "Live Gemini quota from Antigravity"
        case .tokenExpired:
            antigravityStatus = "Waiting for Antigravity to run (sign-in expired)"
        case .noCredentials:
            antigravityStatus = "Not signed in to Antigravity"
        case .accessDenied:
            antigravityAccessDenied = true
            antigravityStatus = "Keychain access denied — toggle off and on to ask again"
        case let .failed(message):
            antigravityPausedUntil = Date().addingTimeInterval(3600)
            antigravityStatus = "\(message) — retrying in 1h; showing estimate"
        }
    }

    func claudePairingURLString() -> String? {
        guard let token = collector.readCurrentClaudeOAuthToken(),
              let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        return "karv://claude-token?t=\(encoded)"
    }

    func copyClaudeTokenToClipboard() {
        guard let token = collector.readCurrentClaudeOAuthToken() else {
            pairingFeedback = "No Claude OAuth token found in Keychain."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        pairingFeedback = "Copied Claude token to clipboard!"
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Silently ignore if running from a non-registered debug path
        }
    }

    private func startPeriodicSync() {
        syncNow()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if let self, self.autoSyncEnabled {
                    self.syncNow()
                }
            }
        }
    }
}

enum QRCodeGenerator {
    static func makeImage(from string: String) -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 7, y: 7))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: 170, height: 170))
    }
}

struct MenuBarPopoverView: View {
    @Bindable var coordinator: MacSyncCoordinator
    @State private var showPairingQR = false
    @State private var showCalibration = false

    private let primaryText = Color(red: 0.98, green: 0.98, blue: 0.99)
    private let secondaryText = Color(red: 0.65, green: 0.65, blue: 0.70)

    private var connectedProviders: [ProviderUsageSnapshot] {
        coordinator.snapshot.providers.filter(\.isConnected)
    }

    private var disconnectedNames: [String] {
        coordinator.snapshot.providers.filter { !$0.isConnected }.map(\.provider.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("karv")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(primaryText)
                    Text("Synced \(KarvFormatting.relativeSyncString(from: coordinator.snapshot.updatedAt))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(secondaryText)
                }

                Spacer()

                Button {
                    coordinator.syncNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Divider().overlay(Color.white.opacity(0.10))

            // Remaining quota and reserve per window, front and center. Refreshes every
            // 30s so countdowns and pace stay live between syncs.
            VStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 10) {
                        ForEach(connectedProviders) { item in
                            MacProviderQuotaCard(item: item, now: context.date)
                        }
                        Text(coordinator.rhythmStatus)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(secondaryText.opacity(0.7))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                    }
                }

                if !disconnectedNames.isEmpty {
                    Text("Not installed: \(disconnectedNames.joined(separator: ", "))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondaryText.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
            }

            Divider().overlay(Color.white.opacity(0.10))

            // Quick Actions: Pair iPhone (5G QR) + Gemini Calibration
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPairingQR.toggle()
                        if showPairingQR { showCalibration = false }
                    }
                } label: {
                    Label("Pair iPhone (5G)", systemImage: "qrcode")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showCalibration.toggle()
                        if showCalibration { showPairingQR = false }
                    }
                } label: {
                    Label("Gemini Scale", systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            if showPairingQR {
                VStack(spacing: 8) {
                    Text("Scan with iPhone Camera for Direct Claude 5G Sync")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .multilineTextAlignment(.center)

                    if let urlStr = coordinator.claudePairingURLString(),
                       let qrImage = QRCodeGenerator.makeImage(from: urlStr) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 150, height: 150)
                            .padding(8)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        Text("No Claude OAuth token found in Keychain.")
                            .font(.system(size: 10))
                            .foregroundStyle(secondaryText)
                    }

                    Button("Copy Claude Token Instead") {
                        coordinator.copyClaudeTokenToClipboard()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AIProvider.claude.accentColor)

                    if let feedback = coordinator.pairingFeedback {
                        Text(feedback)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AIProvider.codex.accentColor)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            if showCalibration {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Gemini 5h Prompt Budget")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(primaryText)
                        Spacer()
                        Text("\(Int(coordinator.geminiSessionBudget)) prompts")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(AIProvider.gemini.accentColor)
                    }
                    Slider(value: $coordinator.geminiSessionBudget, in: 30...250, step: 10)
                        .tint(AIProvider.gemini.accentColor)
                }
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }

            Divider().overlay(Color.white.opacity(0.10))

            VStack(spacing: 8) {
                HStack {
                    Toggle(isOn: $coordinator.launchAtLogin) {
                        Text("Launch at login")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    Spacer()

                    Toggle(isOn: $coordinator.autoSyncEnabled) {
                        Text("Auto-sync (1m)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                HStack {
                    Toggle(isOn: $coordinator.shareClaudeTokenWithIPhone) {
                        Text("Keep iPhone's Claude token in sync (iCloud Keychain)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Spacer()
                }
                HStack {
                    Toggle(isOn: $coordinator.useAntigravityQuota) {
                        Text("Real Gemini quota from Antigravity (uses its sign-in, read-only)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Spacer()
                }
                HStack {
                    Toggle(isOn: $coordinator.paceByRhythm) {
                        Text("Pace by my daily rhythm (quiet evenings count less)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Spacer()
                }
                if coordinator.paceByRhythm {
                    HStack(spacing: 6) {
                        Text("Usual active hours")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                        Spacer()
                        Stepper(value: $coordinator.activeStartHour, in: 0...23) {
                            Text(String(format: "%02d:00", coordinator.activeStartHour))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(primaryText)
                        }
                        .controlSize(.mini)
                        Text("–").foregroundStyle(secondaryText)
                        Stepper(value: $coordinator.activeEndHour, in: 0...23) {
                            Text(String(format: "%02d:00", coordinator.activeEndHour))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(primaryText)
                        }
                        .controlSize(.mini)
                    }
                }

                if coordinator.useAntigravityQuota, let status = coordinator.antigravityStatus {
                    Text(status)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondaryText.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let status = coordinator.tokenShareStatus {
                    Text(status)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondaryText.opacity(0.65))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Text("iCloud + Wi-Fi sync active")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(secondaryText.opacity(0.65))
                    Spacer()
                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(secondaryText)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(Color(red: 0.055, green: 0.055, blue: 0.067))
        .environment(\.colorScheme, .dark)
    }
}


// MARK: - Provider quota card

/// One provider in the popover: session/daily and weekly side by side, each with what's
/// left, an even-pace marker, the reserve (or overspend) and the reset countdown.
struct MacProviderQuotaCard: View {
    let item: ProviderUsageSnapshot
    let now: Date

    private let primaryText = Color(red: 0.98, green: 0.98, blue: 0.99)
    private let secondaryText = Color(red: 0.65, green: 0.65, blue: 0.70)

    private var isStale: Bool {
        now.timeIntervalSince(item.lastSyncedAt) > 15 * 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle()
                    .fill(item.provider.accentColor)
                    .frame(width: 7, height: 7)
                Text(item.provider.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text(item.planName.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(item.provider.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(item.provider.accentColor.opacity(0.16), in: Capsule())
                Spacer()
                if item.isEstimate {
                    tag("EST.", color: secondaryText)
                }
                if isStale {
                    tag(KarvFormatting.relativeSyncString(from: item.lastSyncedAt, now: now), color: QuotaStatus.elevated.tintColor)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                MacWindowBlock(window: item.primaryWindow, isSecondary: false, accent: item.provider.accentColor, now: now)
                if let weekly = item.secondaryWindow {
                    MacWindowBlock(window: weekly, isSecondary: true, accent: item.provider.secondaryAccentColor, now: now)
                }
            }
            .opacity(isStale ? 0.6 : 1)

            if let note = item.statusNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(secondaryText.opacity(0.8))
                    .lineLimit(2)
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
    }
}

struct MacWindowBlock: View {
    let window: QuotaWindow
    let isSecondary: Bool
    let accent: Color
    let now: Date

    private let primaryText = Color(red: 0.98, green: 0.98, blue: 0.99)
    private let secondaryText = Color(red: 0.65, green: 0.65, blue: 0.70)

    private var label: String {
        if isSecondary { return "WEEKLY" }
        let title = window.title.lowercased()
        if title.contains("5h") { return "5H SESSION" }
        if title.contains("day") || title.contains("daily") { return "DAILY" }
        return window.title.uppercased()
    }

    var body: some View {
        let summary = window.reserveSummary(at: now, isSecondary: isSecondary)
        let pace = window.pace(at: now, isSecondary: isSecondary)
        let toneColor: Color = switch summary.tone {
        case .good: QuotaStatus.nominal.tintColor
        case .neutral: secondaryText
        case .bad: QuotaStatus.critical.tintColor
        }

        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(secondaryText)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(KarvFormatting.percentString(window.remainingPercent))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(primaryText)
                Text("left")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(secondaryText)
            }

            // Used share, with a tick where an even burn would be by now.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(3, geo.size.width * window.usedPercent))
                    if !window.isRolling {
                        Rectangle()
                            .fill(primaryText)
                            .frame(width: 2, height: 9)
                            .offset(x: max(0, geo.size.width * pace.elapsedFraction - 1))
                    }
                }
            }
            .frame(height: 6)

            Text(summary.text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(toneColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text("\(window.resetVerb.capitalized) in \(KarvFormatting.countdownString(until: window.resetsAt, from: now))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
