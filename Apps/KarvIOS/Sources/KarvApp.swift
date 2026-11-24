import SwiftUI
import WidgetKit
import KarvCore

@main
struct KarvApp: App {
    @State private var store = KarvSyncStore()
    @State private var macSync = MacBonjourSyncClient()
    @Environment(\.scenePhase) private var scenePhase

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
                    await refreshDirectClaudeIfConfigured()
                    KarvNotificationScheduler.scheduleAlerts(for: store.snapshot, preferences: store.preferences)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        macSync.pullNow()
                        Task {
                            await refreshDirectClaudeIfConfigured()
                            await LiveActivityManager.refreshActiveActivities(from: store.snapshot)
                        }
                    }
                }
                .onChange(of: store.snapshot) { _, updated in
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
            await refreshDirectClaudeIfConfigured()
        }
    }

    private func refreshDirectClaudeIfConfigured() async {
        guard let token = KarvKeychain.loadClaudeToken() else { return }
        if let live = await ClaudeOAuthUsageClient.fetchUsage(token: token) {
            store.updateClaudeFromDirectOAuth(live)
            WidgetCenter.shared.reloadAllTimelines()
        }
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
