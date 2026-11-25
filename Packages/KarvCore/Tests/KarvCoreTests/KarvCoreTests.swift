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

private func provider(_ p: AIProvider, used: Double, at date: Date) -> ProviderUsageSnapshot {
    ProviderUsageSnapshot(
        provider: p,
        planName: "Test",
        isConnected: true,
        primaryWindow: QuotaWindow(id: "\(p)", title: "5h", subtitle: "", usedPercent: used, resetsAt: date.addingTimeInterval(3600)),
        lastSyncedAt: date,
        source: .claudeCLI
    )
}

@Test func mergeKeepsNewerReadingPerProvider() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let t1 = t0.addingTimeInterval(60)
    // Phone has a fresh direct-OAuth Claude reading; Mac's payload has older Claude but newer Gemini.
    let phone = KarvSnapshot(providers: [provider(.claude, used: 0.40, at: t1), provider(.gemini, used: 0.10, at: t0)],
                             sourceDeviceName: "iPhone", updatedAt: t1)
    let mac = KarvSnapshot(providers: [provider(.claude, used: 0.20, at: t0), provider(.gemini, used: 0.30, at: t1)],
                           sourceDeviceName: "Mac", updatedAt: t1.addingTimeInterval(5))

    let merged = phone.merged(with: mac)
    #expect(merged.snapshot(for: .claude)?.primaryWindow.usedPercent == 0.40)
    #expect(merged.snapshot(for: .gemini)?.primaryWindow.usedPercent == 0.30)
    #expect(merged.sourceDeviceName == "Mac")
    #expect(merged.updatedAt == t1.addingTimeInterval(5))
}

@Test func mergeIgnoresLateStalePayloadAndIsIdempotent() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let fresh = KarvSnapshot(providers: [provider(.claude, used: 0.5, at: t0.addingTimeInterval(600))], sourceDeviceName: "Mac", updatedAt: t0.addingTimeInterval(600))
    let stale = KarvSnapshot(providers: [provider(.claude, used: 0.1, at: t0)], sourceDeviceName: "Mac", updatedAt: t0)
    #expect(fresh.merged(with: stale) == fresh)
    #expect(stale.merged(with: fresh) == fresh)
    #expect(fresh.merged(with: fresh) == fresh)
}

@Test func mergeUnionsProvidersAndPrefersRealOverDemo() {
    let now = Date()
    let real = KarvSnapshot(providers: [provider(.gemini, used: 0.2, at: now)], sourceDeviceName: "Mac", updatedAt: now)
    let other = KarvSnapshot(providers: [provider(.claude, used: 0.3, at: now)], sourceDeviceName: "iPhone", updatedAt: now)
    #expect(real.merged(with: other).providers.map(\.provider) == [.claude, .gemini])

    let demo = KarvDemoData.makeSnapshot()
    #expect(demo.merged(with: real) == real)
    #expect(real.merged(with: demo) == real)
}

@Test func paceReserveUnderAndOver() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    // 5h window, 2h elapsed (40%), 25% used → 15% reserve ≈ 45 min.
    let under = QuotaWindow(id: "s", title: "5h Session", subtitle: "", usedPercent: 0.25, resetsAt: now.addingTimeInterval(3 * 3600))
    let p1 = under.pace(at: now, isSecondary: false)
    #expect(abs(p1.reserve - 0.15) < 0.0001)
    #expect(abs(p1.reserveTime - 45 * 60) < 1)
    #expect(p1.state == .underPace)
    #expect(p1.projectedExhaustion(now: now) == nil)

    // Weekly, 1 day elapsed (~14%), 50% used → over pace, runs out before reset.
    let over = QuotaWindow(id: "w", title: "Weekly Cap", subtitle: "", usedPercent: 0.5, resetsAt: now.addingTimeInterval(6 * 86400))
    let p2 = over.pace(at: now, isSecondary: true)
    #expect(p2.state == .overPace)
    let empty = try! #require(p2.projectedExhaustion(now: now))
    #expect(abs(empty.timeIntervalSince(now) - 86400) < 1) // same rate for one more day
}

@Test func paceClampsStaleWindows() {
    let now = Date()
    let expired = QuotaWindow(id: "s", title: "5h Session", subtitle: "", usedPercent: 0.3, resetsAt: now.addingTimeInterval(-600))
    #expect(expired.pace(at: now, isSecondary: false).elapsedFraction == 1)
}

@Test func healthStatus() {
    let now = Date()
    #expect(KarvSyncHealthEntry().status(now: now) == .unknown)
    #expect(KarvSyncHealthEntry(lastSuccess: now.addingTimeInterval(-60)).status(now: now) == .healthy)
    #expect(KarvSyncHealthEntry(lastSuccess: now.addingTimeInterval(-3600)).status(now: now) == .stale)
    #expect(KarvSyncHealthEntry(lastSuccess: now.addingTimeInterval(-120), lastFailure: now.addingTimeInterval(-60)).status(now: now) == .failing)
}

@Test func realReadingBeatsNewerEstimate() {
    let now = Date()
    var real = provider(.gemini, used: 0.6, at: now.addingTimeInterval(-600))
    real.source = .webSession
    var estimate = provider(.gemini, used: 0.1, at: now)
    estimate.isEstimate = true

    let phone = KarvSnapshot(providers: [real], sourceDeviceName: "iPhone", updatedAt: real.lastSyncedAt)
    let mac = KarvSnapshot(providers: [estimate], sourceDeviceName: "Mac", updatedAt: now)
    #expect(phone.merged(with: mac).snapshot(for: .gemini)?.primaryWindow.usedPercent == 0.6)
    #expect(mac.merged(with: phone).snapshot(for: .gemini)?.primaryWindow.usedPercent == 0.6)

    // After the priority period, the newer estimate takes over again.
    var oldReal = real
    oldReal.lastSyncedAt = now.addingTimeInterval(-2 * 3600)
    let stalePhone = KarvSnapshot(providers: [oldReal], sourceDeviceName: "iPhone", updatedAt: oldReal.lastSyncedAt)
    #expect(stalePhone.merged(with: mac).snapshot(for: .gemini)?.primaryWindow.usedPercent == 0.1)
}

@Test func rollingWindowIsNeverOverPace() {
    let now = Date()
    let w = QuotaWindow(id: "g", title: "5h Session", subtitle: "", usedPercent: 0.7, resetsAt: now.addingTimeInterval(4 * 3600), isRolling: true)
    #expect(w.pace(at: now, isSecondary: false).state == .onPace)
    #expect(w.resetVerb == "frees up")
}

@Test func oldSnapshotsWithoutNewFieldsStillDecode() throws {
    // Payload as written by the previous app version (no isRolling / isEstimate keys).
    var snap = KarvDemoData.makeSnapshot()
    snap.isDemoData = false
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap)) as! [String: Any]
    var providers = json["providers"] as! [[String: Any]]
    for i in providers.indices {
        providers[i].removeValue(forKey: "isEstimate")
        var pw = providers[i]["primaryWindow"] as! [String: Any]
        pw.removeValue(forKey: "isRolling")
        providers[i]["primaryWindow"] = pw
    }
    json["providers"] = providers
    let decoded = try JSONDecoder().decode(KarvSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.providers.allSatisfy { !$0.isEstimate && !$0.primaryWindow.isRolling })
}
