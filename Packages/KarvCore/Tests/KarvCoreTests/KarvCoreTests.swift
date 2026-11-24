import Foundation
import Testing
@testable import KarvCore

@Test func demoSnapshotContainsAllThreeProviders() {
    let snapshot = KarvDemoData.makeSnapshot()
    #expect(snapshot.providers.count == 3)
    #expect(snapshot.snapshot(for: .claude) != nil)
    #expect(snapshot.snapshot(for: .codex) != nil)
    #expect(snapshot.snapshot(for: .gemini) != nil)
}

@Test func quotaWindowClampsAndComputesRemaining() {
    let window = QuotaWindow(
        id: "test",
        title: "5h",
        subtitle: "Test",
        usedPercent: 0.65,
        resetsAt: Date().addingTimeInterval(3600)
    )
    #expect(abs(window.remainingPercent - 0.35) < 0.0001)
    #expect(window.status(warningThreshold: 0.80) == .nominal)
    #expect(window.status(warningThreshold: 0.60) == .elevated)
}

@Test func formattingCountdowns() {
    let now = Date()
    #expect(KarvFormatting.countdownString(until: now.addingTimeInterval(2 * 3600 + 15 * 60), from: now) == "2h 15m")
    #expect(KarvFormatting.countdownString(until: now.addingTimeInterval(3 * 86400 + 4 * 3600), from: now) == "3d 4h")
    #expect(KarvFormatting.countdownString(until: now.addingTimeInterval(-10), from: now) == "Resetting")
}

@Test func snapshotRoundTripsJSON() throws {
    let original = KarvDemoData.makeSnapshot()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(KarvSnapshot.self, from: data)
    #expect(decoded.providers.count == original.providers.count)
    #expect(decoded.sourceDeviceName == original.sourceDeviceName)
}
