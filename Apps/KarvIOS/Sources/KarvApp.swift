import SwiftUI
import WidgetKit
import BackgroundTasks
import KarvCore

@main
struct KarvApp: App {
    private static let bgRefreshTaskID = "com.cml.karv.refresh"

    @State private var store = KarvSyncStore()
    @State private var macSync = MacBonjourSyncClient()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        Self.registerBackgroundRefresh()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .environment(macSync)
                .preferredColorScheme(.dark)
                .tint(.white)
                .task {
                    macSync.start(store: store)
                    _ = await KarvNotificationScheduler.requestPermission()
                    await refreshAllSources()
                    KarvNotificationScheduler.scheduleAlerts(for: store.snapshot, preferences: store.preferences)

                    // Live foreground refresh loop every 30 seconds while app is open
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(30))
                        if scenePhase == .active {
                            await refreshAllSources()
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task {
                            await refreshAllSources()
                        }
                    } else if phase == .background {
                        Self.scheduleBackgroundRefresh()
                    }
                }
                .onChange(of: store.snapshot) { _, updated in
                    WidgetCenter.shared.reloadAllTimelines()
                    KarvNotificationScheduler.scheduleAlerts(for: updated, preferences: store.preferences)
                    Task {
                        await LiveActivityManager.refreshActiveActivities(from: updated)
                    }
                }
                .onOpenURL { url in
                    handleIncomingDeepLink(url)
                }
        }
    }

    private func refreshAllSources() async {
        macSync.restartIfNeeded()
        macSync.pullNow()
        if !store.preferences.useDemoMode {
            store.refresh()
        }
        await refreshDirectClaudeIfConfigured()
        await LiveActivityManager.refreshActiveActivities(from: store.snapshot)
    }

    private func handleIncomingDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "karv",
              url.host?.lowercased() == "claude-token",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "t" })?.value,
              !token.isEmpty else {
            return
        }
        KarvKeychain.saveClaudeToken(token)
        Task {
            await store.refreshClaudeDirect(token: token, force: true)
        }
    }

    private func refreshDirectClaudeIfConfigured() async {
        guard let token = KarvKeychain.loadClaudeToken() else { return }
        await store.refreshClaudeDirect(token: token)
    }

    private static func registerBackgroundRefresh() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgRefreshTaskID, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            scheduleBackgroundRefresh()
            let work = Task {
                let store = await MainActor.run { KarvSyncStore(enableCloudSync: true) }
                await MainActor.run {
                    if !store.preferences.useDemoMode {
                        store.refresh()
                    }
                }
                if let token = KarvKeychain.loadClaudeToken() {
                    _ = await store.refreshClaudeDirect(token: token)
                }
                let latest = await MainActor.run { store.snapshot }
                WidgetCenter.shared.reloadAllTimelines()
                await LiveActivityManager.refreshActiveActivities(from: latest)
                refreshTask.setTaskCompleted(success: true)
            }
            refreshTask.expirationHandler = {
                work.cancel()
                refreshTask.setTaskCompleted(success: false)
            }
        }
    }

    private static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: bgRefreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

struct RootTabView: View {
    @State private var selectedTab: Tab = .overview

    enum Tab: Hashable {
        case overview
        case trends
        case settings
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tabItem {
                    Label("Overview", systemImage: "square.grid.2x2")
                }
                .tag(Tab.overview)

            TrendsView()
                .tabItem {
                    Label("Trends", systemImage: "chart.xyaxis.line")
                }
                .tag(Tab.trends)

            SettingsView()
                .tabItem {
                    Label("Sync", systemImage: "icloud")
                }
                .tag(Tab.settings)
        }
        .toolbarBackground(KarvTheme.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}
