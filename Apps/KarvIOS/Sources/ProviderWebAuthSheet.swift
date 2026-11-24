import SwiftUI
import WebKit
import WidgetKit
import KarvCore

extension AIProvider {
    var usagePortalURL: URL {
        switch self {
        case .claude:
            URL(string: "https://claude.ai/settings/usage")!
        case .codex:
            URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .gemini:
            URL(string: "https://one.google.com/ai")!
        }
    }

    var portalHint: String {
        switch self {
        case .claude:
            "Sign in with Email (Google blocks in-app WebView OAuth), open Settings → Usage, then tap Extract."
        case .codex:
            "Sign in to ChatGPT, view Codex Usage limits, then tap Extract Usage."
        case .gemini:
            "Sign in to Google AI Plan (or switch to AI Studio in •••), then tap Extract Usage."
        }
    }
}

struct ExtractedUsagePayload: Sendable {
    let primaryUsedPercent: Double
    let primaryResetsAt: Date?
    let secondaryUsedPercent: Double?
    let secondaryResetsAt: Date?
    let planName: String?
    let summary: String
}

@MainActor
@Observable
final class ProviderWebController: NSObject, WKNavigationDelegate, WKUIDelegate {
    let provider: AIProvider
    let webView: WKWebView

    var currentURLString: String = ""
    var isLoading: Bool = true
    var estimatedProgress: Double = 0
    var canGoBack: Bool = false
    var statusBanner: String?
    var didSyncSuccessfully: Bool = false

    private var progressObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?

    init(provider: AIProvider) {
        self.provider = provider
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = true
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in
                self?.estimatedProgress = view.estimatedProgress
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
            Task { @MainActor in
                self?.currentURLString = view.url?.host ?? ""
                self?.canGoBack = view.canGoBack
            }
        }

        loadUsagePortal()
    }

    func loadUsagePortal() {
        load(url: provider.usagePortalURL)
    }

    func load(url: URL) {
        statusBanner = nil
        didSyncSuccessfully = false
        webView.load(URLRequest(url: url))
    }

    func reload() {
        webView.reload()
    }

    func goBack() {
        webView.goBack()
    }

    func clearSessionCookies() {
        let store = WKWebsiteDataStore.default()
        let hostMatch: String = switch provider {
        case .claude: "claude.ai"
        case .codex: "chatgpt.com"
        case .gemini: "google.com"
        }

        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let matching = records.filter { $0.displayName.localizedCaseInsensitiveContains(hostMatch) }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching) {
                Task { @MainActor in
                    self.statusBanner = "Cleared \(self.provider.displayName) session. You can sign in again."
                    self.loadUsagePortal()
                }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        // Block custom app schemes (e.g., googlegemini://, claude://, chatgpt://, itms-apps://)
        // so sites cannot kick the user out to native apps.
        if scheme != "http" && scheme != "https" && scheme != "about" && scheme != "data" && scheme != "blob" {
            decisionHandler(.cancel)
            return
        }

        // Open target="_blank" popups in the same WebView.
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        // Only intercept link-activated Universal Links for Gemini's native app host
        // so we don't break SPA auth/login redirects on Claude or ChatGPT.
        if navigationAction.navigationType == .linkActivated {
            let host = url.host?.lowercased() ?? ""
            if host == "gemini.google.com" || host.hasSuffix(".gemini.google.com") {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = true
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.isLoading = false
            self.canGoBack = webView.canGoBack
            self.currentURLString = webView.url?.host ?? ""
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            self.isLoading = false
        }
    }

    /// Reads visible usage percentages & reset countdowns from the active signed-in page.
    func extractUsageFromCurrentPage() async -> ExtractedUsagePayload? {
        let js = """
        (() => {
            const text = (document.body && document.body.innerText) ? document.body.innerText : '';
            const lines = text.split('\\n').map(l => l.trim()).filter(Boolean);

            const percentMatches = [];
            const regex = /(\\d{1,3}(?:\\.\\d+)?)\\s*%\\s*(used|remaining|left)?/gi;
            for (const line of lines) {
                let m;
                while ((m = regex.exec(line)) !== null) {
                    const num = parseFloat(m[1]);
                    if (num >= 0 && num <= 100) {
                        const kind = (m[2] || '').toLowerCase();
                        const lineLower = line.toLowerCase();
                        const isRemaining = kind === 'remaining' || kind === 'left'
                            || (kind === '' && (lineLower.includes('remaining') || lineLower.includes('left')));
                        const usedPct = isRemaining ? (100 - num) : num;
                        percentMatches.push({ usedPct, line });
                    }
                }
            }

            const resetMatches = [];
            const resetRegex = /resets?\\s+in\\s+(?:(\\d+)\\s*d(?:ays?)?)?\\s*(?:(\\d+)\\s*h(?:r|ours?)?)?\\s*(?:(\\d+)\\s*m(?:in|ins|inutes?)?)?/gi;
            let rm;
            while ((rm = resetRegex.exec(text)) !== null) {
                const days = parseInt(rm[1] || '0', 10);
                const hours = parseInt(rm[2] || '0', 10);
                const mins = parseInt(rm[3] || '0', 10);
                const totalSec = days * 86400 + hours * 3600 + mins * 60;
                if (totalSec > 0) resetMatches.push(totalSec);
            }

            let plan = null;
            if (/\\bMax\\b/i.test(text)) plan = 'Max';
            else if (/\\bUltra\\b/i.test(text)) plan = 'AI Ultra';
            else if (/\\bPro\\b/i.test(text)) plan = 'Pro';
            else if (/\\bPlus\\b/i.test(text)) plan = 'Plus';

            return {
                url: window.location.href,
                percentages: percentMatches.slice(0, 4).map(p => p.usedPct),
                resetsInSeconds: resetMatches.slice(0, 2),
                plan: plan
            };
        })();
        """

        do {
            let raw = try await webView.evaluateJavaScript(js)
            guard let dict = raw as? [String: Any] else {
                statusBanner = "Could not read page content yet. Wait for the usage page to finish loading."
                return nil
            }

            let percentages = (dict["percentages"] as? [Double]) ?? []
            let resets = (dict["resetsInSeconds"] as? [Double]) ?? []
            let plan = dict["plan"] as? String

            guard let primaryRaw = percentages.first else {
                statusBanner = "No usage % found on this page yet. Sign in and open your Usage page, then tap Extract."
                return nil
            }

            let now = Date()
            let primaryUsed = min(max(primaryRaw / 100.0, 0), 1)
            let primaryReset = resets.first.map { now.addingTimeInterval($0) }
            let secondaryUsed = percentages.count > 1 ? min(max(percentages[1] / 100.0, 0), 1) : nil
            let secondaryReset = resets.count > 1 ? now.addingTimeInterval(resets[1]) : nil

            let summary = "Synced \(Int(primaryRaw.rounded()))% used from \(provider.displayName) web"
            statusBanner = summary
            didSyncSuccessfully = true

            return ExtractedUsagePayload(
                primaryUsedPercent: primaryUsed,
                primaryResetsAt: primaryReset,
                secondaryUsedPercent: secondaryUsed,
                secondaryResetsAt: secondaryReset,
                planName: plan,
                summary: summary
            )
        } catch {
            statusBanner = "Unable to inspect page: \(error.localizedDescription)"
            return nil
        }
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ProviderWebAuthSheet: View {
    @Environment(KarvSyncStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let provider: AIProvider
    @State private var controller: ProviderWebController
    @State private var isExtracting = false

    init(provider: AIProvider) {
        self.provider = provider
        self._controller = State(initialValue: ProviderWebController(provider: provider))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if controller.isLoading && controller.estimatedProgress < 1.0 {
                    ProgressView(value: controller.estimatedProgress)
                        .tint(provider.accentColor)
                        .scaleEffect(y: 0.6)
                }

                WebViewContainer(webView: controller.webView)
                    .ignoresSafeArea(edges: .horizontal)

                bottomActionBar
            }
            .background(KarvTheme.background)
            .navigationTitle("Connect \(provider.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(KarvTheme.textSecondary)
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if controller.canGoBack {
                        Button {
                            controller.goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                    }

                    Menu {
                        Button("Open Usage Page", systemImage: "gauge.with.dots.needle.67percent") {
                            controller.loadUsagePortal()
                        }
                        if provider == .gemini {
                            Button("Google AI Studio Usage", systemImage: "chart.bar") {
                                controller.load(url: URL(string: "https://aistudio.google.com/usage")!)
                            }
                        }
                        Button("Reload Page", systemImage: "arrow.clockwise") {
                            controller.reload()
                        }
                        Divider()
                        Button("Sign Out & Clear Cookies", systemImage: "trash", role: .destructive) {
                            controller.clearSessionCookies()
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(KarvTheme.textPrimary)
                    }
                }
            }
        }
    }

    private var bottomActionBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.didSyncSuccessfully ? AIProvider.codex.accentColor : provider.accentColor)
                    .frame(width: 7, height: 7)

                Text(controller.statusBanner ?? provider.portalHint)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(controller.didSyncSuccessfully ? KarvTheme.textPrimary : KarvTheme.textSecondary)
                    .lineLimit(2)

                Spacer()
            }

            Button {
                Task {
                    isExtracting = true
                    if let payload = await controller.extractUsageFromCurrentPage() {
                        store.updateProviderFromWebSession(
                            provider: provider,
                            primaryUsedPercent: payload.primaryUsedPercent,
                            primaryResetsAt: payload.primaryResetsAt,
                            secondaryUsedPercent: payload.secondaryUsedPercent,
                            secondaryResetsAt: payload.secondaryResetsAt,
                            planName: payload.planName,
                            statusNote: payload.summary
                        )
                        WidgetCenter.shared.reloadAllTimelines()
                    }
                    isExtracting = false
                }
            } label: {
                HStack(spacing: 8) {
                    if isExtracting {
                        ProgressView()
                            .tint(.black)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: controller.didSyncSuccessfully ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Text(controller.didSyncSuccessfully ? "Usage Synced — Extract Again" : "Extract Usage from Page")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(isExtracting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(KarvTheme.surface)
        .overlay(alignment: .top) {
            Divider().overlay(KarvTheme.hairline)
        }
    }
}
