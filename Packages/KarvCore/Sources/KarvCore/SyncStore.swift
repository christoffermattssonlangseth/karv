import Foundation
import Observation

public enum KarvIdentifiers {
    public static let appGroupID = "group.com.cml.karv.shared"
    public static let snapshotStorageKey = "karv.latestSnapshot.v1"
    public static let preferencesStorageKey = "karv.preferences.v1"
}

public struct KarvPreferences: Codable, Equatable, Sendable {
    public var showRemainingPercentage: Bool
    public var useDemoMode: Bool
    public var warningThreshold: Double
    public var enabledProviders: [AIProvider]
    public var notificationsEnabled: Bool

    public init(
        showRemainingPercentage: Bool = true,
        useDemoMode: Bool = true,
        warningThreshold: Double = 0.80,
        enabledProviders: [AIProvider] = [.claude, .gemini],
        notificationsEnabled: Bool = true
    ) {
        self.showRemainingPercentage = showRemainingPercentage
        self.useDemoMode = useDemoMode
        self.warningThreshold = warningThreshold
        self.enabledProviders = enabledProviders
        self.notificationsEnabled = notificationsEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.showRemainingPercentage = try container.decodeIfPresent(Bool.self, forKey: .showRemainingPercentage) ?? true
        self.useDemoMode = try container.decodeIfPresent(Bool.self, forKey: .useDemoMode) ?? true
        self.warningThreshold = try container.decodeIfPresent(Double.self, forKey: .warningThreshold) ?? 0.80
        self.enabledProviders = try container.decodeIfPresent([AIProvider].self, forKey: .enabledProviders) ?? [.claude, .gemini]
        self.notificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
    }

    public func isEnabled(_ provider: AIProvider) -> Bool {
        enabledProviders.contains(provider)
    }
}

/// Manages persistence across local App Group UserDefaults (for Widgets)
/// and iCloud Key-Value Store (for Mac -> iPhone sync).
@MainActor
@Observable
public final class KarvSyncStore {
    public private(set) var snapshot: KarvSnapshot {
        didSet { UsageRhythm.current = snapshot.rhythm }
    }
    public var preferences: KarvPreferences {
        didSet {
            savePreferences()
            if preferences.useDemoMode && !snapshot.isDemoData {
                snapshot = KarvDemoData.makeSnapshot()
                persistToAppGroup(snapshot)
            } else if !preferences.useDemoMode {
                loadFromCloudOrLocal()
            }
        }
    }

    public private(set) var isSyncing: Bool = false
    public private(set) var lastSyncError: String?

    private let appGroupDefaults: UserDefaults?
    private let localDefaults: UserDefaults
    private let cloudStore: NSUbiquitousKeyValueStore?
    private var cloudObserver: NSObjectProtocol?

    public init(enableCloudSync: Bool = true) {
        self.appGroupDefaults = UserDefaults(suiteName: KarvIdentifiers.appGroupID)
        self.localDefaults = .standard
        self.cloudStore = enableCloudSync ? .default : nil

        let loadedPrefs = Self.loadPreferences(from: UserDefaults(suiteName: KarvIdentifiers.appGroupID) ?? .standard)
        self.preferences = loadedPrefs

        if let saved = Self.loadSavedSnapshot(
            cloudStore: enableCloudSync ? .default : nil,
            appGroup: UserDefaults(suiteName: KarvIdentifiers.appGroupID),
            local: .standard
        ), !loadedPrefs.useDemoMode {
            self.snapshot = saved
        } else {
            let demo = KarvDemoData.makeSnapshot()
            self.snapshot = demo
            Self.writeSnapshot(demo, to: UserDefaults(suiteName: KarvIdentifiers.appGroupID), local: .standard)
        }

        UsageRhythm.current = snapshot.rhythm

        if enableCloudSync {
            startObservingCloud()
        }
    }

    public func refresh() {
        isSyncing = true
        lastSyncError = nil

        if preferences.useDemoMode {
            let updated = KarvDemoData.makeSimulatedRefresh(from: snapshot)
            snapshot = updated
            persistToAppGroup(updated)
            isSyncing = false
            return
        }

        cloudStore?.synchronize()
        loadFromCloudOrLocal()
        isSyncing = false
    }

    /// Merges a snapshot received from a peer (Bonjour from KarvMac, iCloud) without
    /// letting an older payload overwrite newer readings. Does not re-broadcast to iCloud,
    /// since the sender already did, which also avoids Mac <-> iPhone ping-pong.
    public func merge(_ incoming: KarvSnapshot) {
        if incoming.isDemoData && !snapshot.isDemoData { return }
        if !incoming.isDemoData && preferences.useDemoMode {
            // Note: didSet reloads cached snapshots, so compute the merge afterwards.
            preferences.useDemoMode = false
        }
        let combined = snapshot.merged(with: incoming)
        guard combined != snapshot else { return }
        snapshot = combined
        persistToAppGroup(combined)
    }

    /// Updates a provider's status note without touching its reading or timestamp,
    /// e.g. to explain why it has stopped updating.
    public func annotateProvider(_ provider: AIProvider, note: String?) {
        guard let index = snapshot.providers.firstIndex(where: { $0.provider == provider }),
              snapshot.providers[index].statusNote != note else { return }
        var updated = snapshot
        updated.providers[index].statusNote = note
        snapshot = updated
        persistToAppGroup(updated)
    }

    /// Called by KarvMac (or manual entry on iPhone) to publish a fresh snapshot to iCloud + local cache.
    public func publish(_ newSnapshot: KarvSnapshot) {
        snapshot = newSnapshot
        persistToAppGroup(newSnapshot)

        if let data = try? JSONEncoder().encode(newSnapshot) {
            cloudStore?.set(data, forKey: KarvIdentifiers.snapshotStorageKey)
            cloudStore?.synchronize()
        }
    }

    public func updateProviderManually(
        provider: AIProvider,
        primaryUsedPercent: Double,
        secondaryUsedPercent: Double?,
        planName: String
    ) {
        var updated = snapshot
        guard let index = updated.providers.firstIndex(where: { $0.provider == provider }) else { return }
        var item = updated.providers[index]
        item.planName = planName
        item.primaryWindow = QuotaWindow(
            id: item.primaryWindow.id,
            title: item.primaryWindow.title,
            subtitle: item.primaryWindow.subtitle,
            usedPercent: primaryUsedPercent,
            resetsAt: item.primaryWindow.resetsAt,
            detailText: item.primaryWindow.detailText,
            isRolling: item.primaryWindow.isRolling
        )
        if let sec = item.secondaryWindow, let secUsed = secondaryUsedPercent {
            item.secondaryWindow = QuotaWindow(
                id: sec.id,
                title: sec.title,
                subtitle: sec.subtitle,
                usedPercent: secUsed,
                resetsAt: sec.resetsAt,
                detailText: sec.detailText,
                isRolling: sec.isRolling
            )
        }
        item.lastSyncedAt = Date()
        item.source = .manual
        item.isEstimate = false
        updated.providers[index] = item
        updated.updatedAt = Date()
        publish(updated)
    }

    public func updateProviderFromWebSession(
        provider: AIProvider,
        primaryUsedPercent: Double,
        primaryResetsAt: Date?,
        secondaryUsedPercent: Double?,
        secondaryResetsAt: Date?,
        planName: String?,
        statusNote: String
    ) {
        var updated = snapshot
        guard let index = updated.providers.firstIndex(where: { $0.provider == provider }) else { return }
        var item = updated.providers[index]
        let now = Date()

        if let planName, !planName.isEmpty {
            item.planName = planName
        }
        item.isConnected = true
        item.primaryWindow = QuotaWindow(
            id: item.primaryWindow.id,
            title: item.primaryWindow.title,
            subtitle: item.primaryWindow.subtitle,
            usedPercent: primaryUsedPercent,
            resetsAt: primaryResetsAt ?? item.primaryWindow.resetsAt,
            detailText: statusNote,
            isRolling: primaryResetsAt == nil && item.primaryWindow.isRolling
        )
        if let sec = item.secondaryWindow, let secUsed = secondaryUsedPercent {
            item.secondaryWindow = QuotaWindow(
                id: sec.id,
                title: sec.title,
                subtitle: sec.subtitle,
                usedPercent: secUsed,
                resetsAt: secondaryResetsAt ?? sec.resetsAt,
                detailText: sec.detailText,
                isRolling: secondaryResetsAt == nil && sec.isRolling
            )
        }
        item.lastSyncedAt = now
        item.source = .webSession
        item.isEstimate = false
        item.statusNote = statusNote

        if !item.history.isEmpty {
            var hist = item.history
            let last = hist.removeLast()
            hist.append(UsageHistoryPoint(id: last.id, date: now, usedPercent: primaryUsedPercent))
            item.history = hist
        }

        updated.providers[index] = item
        updated.updatedAt = now
        updated.sourceDeviceName = "This iPhone"

        // When transitioning from Demo Preview to real web data for the first time,
        // mark other providers as not-yet-connected so only real connected platforms show up.
        if updated.isDemoData {
            for idx in updated.providers.indices where updated.providers[idx].provider != provider {
                updated.providers[idx].isConnected = false
                updated.providers[idx].statusNote = "Not connected yet"
            }
        }
        updated.isDemoData = false

        if !preferences.isEnabled(provider) {
            setProvider(provider, enabled: true)
        }
        if preferences.useDemoMode {
            preferences.useDemoMode = false
        }
        publish(updated)
    }

    public func updateClaudeFromDirectOAuth(_ live: ClaudeOAuthUsageResult) {
        let updated = snapshot.applyingClaudeOAuth(live)
        if !preferences.isEnabled(.claude) {
            setProvider(.claude, enabled: true)
        }
        if preferences.useDemoMode {
            preferences.useDemoMode = false
        }
        publish(updated)
    }

    /// Providers that should be shown in the dashboard, trends, and widgets.
    /// Respects user toggles and hides disconnected providers when live data is active.
    public var activeProviders: [ProviderUsageSnapshot] {
        snapshot.providers.filter { item in
            preferences.isEnabled(item.provider) && (snapshot.isDemoData || item.isConnected)
        }
    }

    public func setProvider(_ provider: AIProvider, enabled: Bool) {
        var list = preferences.enabledProviders
        if enabled {
            if !list.contains(provider) {
                list.append(provider)
            }
        } else {
            list.removeAll { $0 == provider }
        }
        preferences.enabledProviders = AIProvider.allCases.filter { list.contains($0) }
    }

    public func disconnectProvider(_ provider: AIProvider) {
        var updated = snapshot
        guard let index = updated.providers.firstIndex(where: { $0.provider == provider }) else { return }
        updated.providers[index].isConnected = false
        updated.providers[index].statusNote = "Disconnected"
        updated.providers[index].lastSyncedAt = Date()
        updated.updatedAt = Date()
        publish(updated)
    }

    /// Static helper for WidgetKit timelines to read the latest snapshot without spinning up cloud observers.
    public nonisolated static func readLatestSnapshotForWidget() -> KarvSnapshot {
        let defaults = UserDefaults(suiteName: KarvIdentifiers.appGroupID) ?? .standard
        let prefs = loadPreferences(from: defaults)
        let raw = loadSavedSnapshot(
            cloudStore: nil,
            appGroup: UserDefaults(suiteName: KarvIdentifiers.appGroupID),
            local: .standard
        ) ?? KarvDemoData.makeSnapshot()
        UsageRhythm.current = raw.rhythm

        let filtered = raw.providers.filter { item in
            prefs.isEnabled(item.provider) && (raw.isDemoData || item.isConnected)
        }
        return KarvSnapshot(
            providers: filtered,
            sourceDeviceName: raw.sourceDeviceName,
            updatedAt: raw.updatedAt,
            isDemoData: raw.isDemoData,
            rhythm: raw.rhythm
        )
    }

    /// Called from the widget extension's timeline provider. If the cached Claude reading
    /// is getting old and a token is available (synced from KarvMac via iCloud Keychain),
    /// fetches fresh usage directly so the widget stays current even when the app hasn't
    /// run, then writes it back to the App Group for the app to pick up.
    public nonisolated static func refreshForWidget(maxClaudeAge: TimeInterval = 4 * 60) async -> KarvSnapshot {
        let appGroup = UserDefaults(suiteName: KarvIdentifiers.appGroupID)
        let prefs = loadPreferences(from: appGroup ?? .standard)

        if !prefs.useDemoMode,
           prefs.isEnabled(.claude),
           let raw = loadSavedSnapshot(cloudStore: nil, appGroup: appGroup, local: .standard),
           !raw.isDemoData,
           let token = KarvKeychain.loadClaudeToken() {
            let claudeAge = raw.snapshot(for: .claude).map { Date().timeIntervalSince($0.lastSyncedAt) } ?? .infinity
            if claudeAge > maxClaudeAge {
                let outcome = await ClaudeOAuthUsageClient.fetch(token: token)
                if let live = outcome.result {
                    let updated = raw.applyingClaudeOAuth(live)
                    writeSnapshotMerging(updated, to: appGroup, local: .standard)
                    KarvSyncHealth.recordSuccess(.widget)
                } else {
                    KarvSyncHealth.recordFailure(.widget, message: outcome.failureNote)
                }
            }
        }
        return readLatestSnapshotForWidget()
    }

    private func startObservingCloud() {
        cloudStore?.synchronize()
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloudStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleCloudUpdate()
            }
        }
    }

    private func handleCloudUpdate() {
        guard let cloudData = cloudStore?.data(forKey: KarvIdentifiers.snapshotStorageKey),
              let decoded = try? JSONDecoder().decode(KarvSnapshot.self, from: cloudData) else {
            return
        }
        if !decoded.isDemoData {
            KarvSyncHealth.recordSuccess(.iCloud, message: "From \(decoded.sourceDeviceName)")
        }
        merge(decoded)
    }

    private func loadFromCloudOrLocal() {
        if let loaded = Self.loadSavedSnapshot(cloudStore: cloudStore, appGroup: appGroupDefaults, local: localDefaults) {
            merge(loaded)
        } else {
            lastSyncError = "Waiting for first sync from KarvMac on iCloud."
        }
    }

    private func persistToAppGroup(_ snap: KarvSnapshot) {
        Self.writeSnapshotMerging(snap, to: appGroupDefaults, local: localDefaults)
    }

    /// Writes a snapshot, first merging with the copy already in the App Group so that a
    /// newer reading written by another process (the widget) is never rolled back.
    /// Demo snapshots are written as-is so toggling demo mode still works.
    private nonisolated static func writeSnapshotMerging(_ snap: KarvSnapshot, to appGroup: UserDefaults?, local: UserDefaults) {
        var toWrite = snap
        if !snap.isDemoData,
           let data = appGroup?.data(forKey: KarvIdentifiers.snapshotStorageKey),
           let existing = try? JSONDecoder().decode(KarvSnapshot.self, from: data),
           !existing.isDemoData {
            toWrite = snap.merged(with: existing)
        }
        writeSnapshot(toWrite, to: appGroup, local: local)
    }

    private func savePreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        appGroupDefaults?.set(data, forKey: KarvIdentifiers.preferencesStorageKey)
        localDefaults.set(data, forKey: KarvIdentifiers.preferencesStorageKey)
    }

    private nonisolated static func loadPreferences(from defaults: UserDefaults) -> KarvPreferences {
        guard let data = defaults.data(forKey: KarvIdentifiers.preferencesStorageKey),
              let decoded = try? JSONDecoder().decode(KarvPreferences.self, from: data) else {
            return KarvPreferences()
        }
        return decoded
    }

    private nonisolated static func writeSnapshot(_ snap: KarvSnapshot, to appGroup: UserDefaults?, local: UserDefaults) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        appGroup?.set(data, forKey: KarvIdentifiers.snapshotStorageKey)
        local.set(data, forKey: KarvIdentifiers.snapshotStorageKey)
    }

    private nonisolated static func loadSavedSnapshot(
        cloudStore: NSUbiquitousKeyValueStore?,
        appGroup: UserDefaults?,
        local: UserDefaults
    ) -> KarvSnapshot? {
        let sources: [Data?] = [
            cloudStore?.data(forKey: KarvIdentifiers.snapshotStorageKey),
            appGroup?.data(forKey: KarvIdentifiers.snapshotStorageKey),
            local.data(forKey: KarvIdentifiers.snapshotStorageKey)
        ]
        // Merge every source instead of trusting the first one: the iCloud copy is often
        // older than the local cache, because KVS delivers external changes lazily.
        let decoded = sources.compactMap { data in
            data.flatMap { try? JSONDecoder().decode(KarvSnapshot.self, from: $0) }
        }
        guard var best = decoded.first else { return nil }
        for next in decoded.dropFirst() {
            best = best.merged(with: next)
        }
        return best
    }
}

extension KarvSyncStore {
    /// Direct Claude fetch (iPhone 5G path), routed through the shared throttle.
    /// Skips the network when another source (e.g. KarvMac) delivered a Claude reading
    /// very recently, and explains in the status note why data has gone stale.
    @discardableResult
    public func refreshClaudeDirect(token: String, force: Bool = false) async -> ClaudeOAuthFetchOutcome? {
        let now = Date()
        if force {
            await ClaudeUsageGate.shared.reset()
        } else if let claude = snapshot.snapshot(for: .claude),
                  !snapshot.isDemoData,
                  claude.isConnected,
                  now.timeIntervalSince(claude.lastSyncedAt) < 90 {
            return nil
        }

        let outcome = await ClaudeUsageGate.shared.fetch(token: token)
        switch outcome {
        case .success:
            KarvSyncHealth.recordSuccess(.claudeAPI)
        case .throttled:
            break
        default:
            KarvSyncHealth.recordFailure(.claudeAPI, message: outcome.failureNote)
        }
        if let live = outcome.result {
            updateClaudeFromDirectOAuth(live)
        } else if let note = outcome.failureNote,
                  let claude = snapshot.snapshot(for: .claude),
                  Date().timeIntervalSince(claude.lastSyncedAt) > 10 * 60 {
            annotateProvider(.claude, note: note)
        }
        return outcome
    }
}
