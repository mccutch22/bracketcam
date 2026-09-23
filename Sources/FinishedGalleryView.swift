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
    var temporaryDirectories: [URL] = []
    deinit { for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) } }
}
struct DownloadFile: Identifiable { let id = UUID(); let url: URL }

struct FinishedGalleryView: View {
    let home: DashHome
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = GalleryDownloadState()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GalleryWebView(home: home, state: state)
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
                ToolbarItem(placement: .topBarTrailing) { Link(destination: PhotoDashConfig.website(home.slug)) { Image(systemName: "safari") }.accessibilityLabel("Open in Safari") }
            }
            .alert("PhotoDash", isPresented: Binding(get: { state.failure != nil }, set: { if !$0 { state.failure = nil } })) {
                Button("OK", role: .cancel) { state.failure = nil }
                Button("Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
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
        var request = URLRequest(url: PhotoDashConfig.origin.appendingPathComponent("api/v1/mobile/web-session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = DashKeychain.read() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONEncoder().encode(["slug": home.slug])
        web.load(request)
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let state: GalleryDownloadState
        var files: [ObjectIdentifier: URL] = [:]
        init(state: GalleryDownloadState) { self.state = state }
        private func isOurs(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.scheme == "https" && url.host == PhotoDashConfig.origin.host && (url.port == nil || url.port == 443)
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
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
                state.busy = false; state.message = ""
                state.failure = http.statusCode == 401 ? "Sign in again in PhotoDash, then reopen this gallery." : "This page could not load. Please try again."
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
        private func navigationFailed(_ error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { state.busy = false; state.failure = "Could not connect to PhotoDash. Check your connection and reopen the gallery." }
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
