import SwiftUI
import WebKit
import ImageIO

@MainActor
final class GalleryDownloadState: ObservableObject {
    @Published var busy = false
    @Published var message = ""
    @Published var failure: String?
    @Published var share: DownloadFile?
    @Published var fallback: URL?
    @Published var needsReconnect = false
    @Published var pageFailed = false
    @Published var loadingPage = true
    var temporaryDirectories: [URL] = []
    deinit { for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) } }
}
struct DownloadFile: Identifiable { let id = UUID(); let url: URL }

struct FinishedGalleryView: View {
    let home: DashHome
    let onReconnect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = GalleryDownloadState()
    @State private var pageID = UUID()
    private func reload() {
        state.failure = nil; state.needsReconnect = false; state.pageFailed = false
        state.loadingPage = true; pageID = UUID()
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if state.loadingPage { ProgressView("Opening PhotoDash.com…").padding() }
                GalleryWebView(home: home, state: state).id(pageID)
                if state.pageFailed || state.needsReconnect {
                    VStack(spacing: 12) {
                        Text(state.needsReconnect ? "Sign in again to reconnect this app to PhotoDash.com. Your saved photo stacks will stay in the app." : "The gallery could not open. Try again, or reconnect using your PhotoDash account.")
                            .font(.callout).multilineTextAlignment(.center)
                        Button("Try again") { reload() }.buttonStyle(.bordered)
                        Button("Reconnect to PhotoDash.com", action: onReconnect).buttonStyle(.borderedProminent)
                    }.padding()
                }
                if !state.message.isEmpty {
                    HStack { if state.busy { ProgressView() }; Text(state.message).font(.footnote) }.padding(10)
                }
                if let fallback = state.fallback {
                    Button("Share or save this download") { state.share = DownloadFile(url: fallback) }.padding(8)
                }
            }
            .navigationTitle(home.street).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() }.disabled(state.busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Reload gallery") { reload() }
                        Button("Reconnect to PhotoDash.com", action: onReconnect)
                        Link("Open in Safari", destination: PhotoDashConfig.website(home.slug))
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Gallery options").disabled(state.busy)
                }
            }
            .alert("PhotoDash", isPresented: Binding(get: { state.failure != nil }, set: { if !$0 { state.failure = nil } })) {
                Button("OK", role: .cancel) { state.failure = nil }
                if state.needsReconnect || state.pageFailed {
                    Button("Reconnect", action: onReconnect)
                } else if state.fallback != nil {
                    Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
            } message: { Text(state.failure ?? "") }
            .sheet(item: $state.share) { file in DownloadShareSheet(url: file.url) }
        }
        .preferredColorScheme(.light)
        .interactiveDismissDisabled(state.busy)
    }
}

private struct DownloadShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct GalleryWebView: UIViewRepresentable {
    let home: DashHome
    @ObservedObject var state: GalleryDownloadState
    func makeCoordinator() -> Coordinator { Coordinator(state: state) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // A gallery never inherits another account's browser cookies. Closing it
        // releases its isolated session; reopening authenticates with Keychain.
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.connect(web, home: home)
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.connection?.cancel(); web.stopLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let state: GalleryDownloadState
        var connection: Task<Void, Never>?
        var files: [ObjectIdentifier: URL] = [:]
        init(state: GalleryDownloadState) { self.state = state }
        func connect(_ web: WKWebView, home: DashHome) {
            connection = Task {
                do {
                    let cookies = try await PhotoDashAPI().galleryCookies(home.slug)
                    for cookie in cookies { await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) }
                    guard !Task.isCancelled else { return }
                    web.load(URLRequest(url: PhotoDashConfig.website(home.slug)))
                } catch {
                    guard !Task.isCancelled else { return }
                    state.loadingPage = false; state.pageFailed = true
                    state.needsReconnect = DashKeychain.read() == nil
                    state.failure = error.localizedDescription
                }
            }
        }
        private func isOurs(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.scheme == "https" && url.host == PhotoDashConfig.origin.host && (url.port == nil || url.port == 443)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.targetFrame?.isMainFrame != false, isOurs(action.request.url), action.request.url?.path == "/signin" {
                state.loadingPage = false; state.needsReconnect = true
                decisionHandler(.cancel); return
            }
            if action.shouldPerformDownload {
                guard action.sourceFrame.isMainFrame, isOurs(action.sourceFrame.request.url), isOurs(action.request.url), !state.busy else { decisionHandler(.cancel); return }
                state.busy = true; state.message = "Downloading…"; state.fallback = nil
                decisionHandler(.download); return
            }
            if action.targetFrame?.isMainFrame != false, let url = action.request.url, !isOurs(url) {
                decisionHandler(.cancel)
                if ["https", "http", "mailto", "tel"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                state.busy = false; state.message = ""; state.loadingPage = false; state.pageFailed = true
                state.needsReconnect = http.statusCode == 401
                state.failure = http.statusCode == 401 ? "Your connection to PhotoDash expired. Tap Reconnect and sign in with your PhotoDash account." : http.statusCode == 403 ? "This account cannot open this gallery, or the request was blocked. You can reconnect with the account that owns this home." : "This page could not load (\(http.statusCode)). Please try again."
                decisionHandler(.cancel); return
            }
            if !response.canShowMIMEType && response.isForMainFrame && isOurs(response.response.url) {
                guard !state.busy else { decisionHandler(.cancel); return }
                state.busy = true; state.message = "Downloading…"; state.fallback = nil
                decisionHandler(.download)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            do {
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw DashFailure(message: "The photo could not download. Please try again.") }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photodash-finished-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                state.temporaryDirectories.append(directory)
                let name = (suggestedFilename as NSString).lastPathComponent
                let file = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "PhotoDash-download" : name)
                files[ObjectIdentifier(download)] = file
                completionHandler(file)
            } catch { state.busy = false; state.message = ""; state.failure = error.localizedDescription; completionHandler(nil) }
        }
        func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
            decisionHandler(isOurs(request.url) ? .allow : .cancel)
        }
        func downloadDidFinish(_ download: WKDownload) {
            guard let file = files.removeValue(forKey: ObjectIdentifier(download)) else { state.busy = false; return }
            Task {
                defer { state.busy = false }
                if CGImageSourceCreateWithURL(file as CFURL, nil) != nil {
                    state.message = "Saving to Photos…"
                    do { try await PhotoLibrarySaver.saveFinishedPhoto(at: file); state.message = "Saved to Photos" }
                    catch { state.message = "Photo downloaded; not saved to Photos."; state.fallback = file; state.failure = error.localizedDescription }
                } else {
                    state.message = "Download ready"; state.share = DownloadFile(url: file)
                }
            }
        }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let file = files.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: file) }
            state.busy = false; state.message = ""; state.failure = "Download failed. Please try again."
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { state.loadingPage = false }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            state.loadingPage = false; state.pageFailed = true
        }
        private func navigationFailed(_ error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { state.busy = false; state.loadingPage = false; state.pageFailed = true; state.failure = "Could not connect to PhotoDash. Check your connection and try again." }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url {
                if isOurs(url) { webView.load(action.request) }
                else if ["https", "http"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
            }
            return nil
        }
    }
}
