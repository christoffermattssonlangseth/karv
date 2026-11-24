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
                let weeklyElapsed = elapsedFraction(
                    resetsAt: item.secondaryWindow?.resetsAt ?? now.addingTimeInterval(7 * 86400),
                    duration: 7 * 86400,
                    now: now
                )

                let sessionDuration: TimeInterval = item.primaryWindow.title.localizedCaseInsensitiveContains("5h")
                    ? 5 * 3600
                    : 24 * 3600
                let sessionUsed = item.primaryWindow.usedPercent
                let sessionElapsed = elapsedFraction(
                    resetsAt: item.primaryWindow.resetsAt,
                    duration: sessionDuration,
                    now: now
                )

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

    private static func elapsedFraction(resetsAt: Date, duration: TimeInterval, now: Date) -> Double {
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = duration - remaining
        return min(max(elapsed / duration, 0.04), 0.96)
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
    var snapshot: KarvSnapshot
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

    private let store: KarvSyncStore
    private let collector = LocalUsageCollector()
    private let bonjourServer = LocalBonjourSyncServer()
    private var timerTask: Task<Void, Never>?

    init() {
        let syncStore = KarvSyncStore(enableCloudSync: true)
        self.store = syncStore
        self.snapshot = syncStore.snapshot
        let savedBudget = UserDefaults.standard.double(forKey: "karv.mac.geminiBudget")
        self.geminiSessionBudget = savedBudget >= 20 ? savedBudget : 100.0
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)

        bonjourServer.start(initialSnapshot: syncStore.snapshot)
        Task {
            _ = await KarvNotificationScheduler.requestPermission()
        }
        startPeriodicSync()
    }

    func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        let budget = geminiSessionBudget
        Task {
            let collected = await collector.collectSnapshot(geminiSessionBudget: budget)
            store.publish(collected)
            bonjourServer.update(snapshot: collected)
            KarvNotificationScheduler.scheduleAlerts(for: collected, preferences: store.preferences)
            snapshot = collected
            isSyncing = false
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
                try? await Task.sleep(for: .seconds(300))
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

            VStack(spacing: 10) {
                ForEach(connectedProviders) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
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

                            Text("\(KarvFormatting.percentString(item.primaryWindow.remainingPercent)) left")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(primaryText)
                        }

                        ProgressView(value: item.primaryWindow.usedPercent)
                            .tint(item.provider.accentColor)

                        HStack {
                            Text(item.primaryWindow.title)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(secondaryText)
                            Spacer()
                            Text("Resets \(KarvFormatting.countdownString(until: item.primaryWindow.resetsAt))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(secondaryText)
                        }

                        if let secondary = item.secondaryWindow {
                            Divider().overlay(Color.white.opacity(0.08))
                            HStack(spacing: 8) {
                                Text(secondary.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(secondaryText)
                                ProgressView(value: secondary.usedPercent)
                                    .tint(item.provider.secondaryAccentColor.opacity(0.85))
                                    .frame(maxWidth: 80)
                                Spacer()
                                Text("\(KarvFormatting.percentString(secondary.remainingPercent)) left")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(primaryText)
                                Text("· \(KarvFormatting.countdownString(until: secondary.resetsAt))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(secondaryText)
                            }
                        }

                        if let note = item.statusNote {
                            Text(note)
                                .font(.system(size: 10))
                                .foregroundStyle(secondaryText.opacity(0.8))
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
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
                        Text("Auto-sync")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
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
        .frame(width: 320)
        .background(Color(red: 0.055, green: 0.055, blue: 0.067))
        .environment(\.colorScheme, .dark)
    }
}
