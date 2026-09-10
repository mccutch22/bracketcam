import Foundation
import Security
import AuthenticationServices
import CryptoKit
import UIKit

enum PhotoDashConfig {
    // Public web origin only. Provider, storage and Google secrets stay on the server.
    static let origin = URL(string: "https://orangered-armadillo-437592.hostingersite.com")!
    static func website(_ slug: String) -> URL {
        origin.appendingPathComponent("homes").appendingPathComponent(slug).appendingPathComponent("gallery")
    }
}

struct DashUser: Codable { let id: String; let email: String; let displayName: String? }
struct DashAccount: Decodable { let user: DashUser; let processingAvailable: Bool; let environment: String }
struct DashHome: Codable, Identifiable, Hashable { let id: String; let slug: String; let street: String; let locality: String }
struct DashJob: Decodable, Identifiable {
    let id: String; let status: String; let message: String?; let canRetry: Bool?
}
struct HomesReply: Decodable { let homes: [DashHome] }
struct HomeReply: Decodable { let home: DashHome }
struct JobsReply: Decodable { let jobs: [DashJob] }
struct JobReply: Decodable { let job: DashJob }
struct SessionReply: Decodable { let token: String; let expiresAt: String }
struct DashFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum DashKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.photodash.app.session", kSecAttrAccount as String: "photodash"]
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw DashFailure(message: "Could not securely save sign-in on this phone.") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

// Refuse HTTP redirects on authenticated API requests, including to another origin.
private final class DashTransport: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class PhotoDashAPI {
    private let transport = DashTransport()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config, delegate: transport, delegateQueue: nil)
    }()
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: String]? = nil, token: String? = DashKeychain.read()) async throws -> T {
        var req = makeRequest(path, method: method, token: token)
        if let body { req.httpBody = try JSONEncoder().encode(body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: req)
        try validate(data, response)
        return try JSONDecoder().decode(T.self, from: data)
    }
    func upload(_ file: URL, boundary: String, slug: String) async throws -> DashJob {
        var req = makeRequest("homes/\(slug)/brackets", method: "POST", token: DashKeychain.read())
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, fromFile: file)
        try validate(data, response)
        return try JSONDecoder().decode(JobReply.self, from: data).job
    }
    func signOut() async throws {
        let (data, response) = try await session.data(for: makeRequest("session", method: "DELETE", token: DashKeychain.read()))
        try validate(data, response)
        DashKeychain.clear()
    }
    private func makeRequest(_ path: String, method: String, token: String?) -> URLRequest {
        var req = URLRequest(url: PhotoDashConfig.origin.appendingPathComponent("api/v1/mobile/" + path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }
    private func validate(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw DashFailure(message: "PhotoDash did not respond. Please try again.") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { DashKeychain.clear() }
            let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw DashFailure(message: error?["error"] as? String ?? "PhotoDash could not finish this request (\(http.statusCode)). Your upload progress is saved.")
        }
    }
}

@MainActor
final class CameraSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func signIn(api: PhotoDashAPI) async throws {
        let verifier = try randomString()
        let state = try randomString()
        let digest = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = digest.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(url: PhotoDashConfig.origin.appendingPathComponent("mobile/connect"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "challenge", value: challenge), URLQueryItem(name: "state", value: state)]
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "com.photodash.app") { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: DashFailure(message: "Sign-in was cancelled.")) }
            }
            auth.presentationContextProvider = self
            session = auth
            if !auth.start() { continuation.resume(throwing: DashFailure(message: "Could not open sign-in. Please try again.")) }
        }
        session = nil
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.scheme == "com.photodash.app", callback.host == "auth",
              query.first(where: { $0.name == "state" })?.value == state,
              let code = query.first(where: { $0.name == "code" })?.value else { throw DashFailure(message: "Could not verify sign-in. Please try again.") }
        let reply: SessionReply = try await api.request("session", method: "POST", body: ["code": code, "verifier": verifier], token: nil)
        try DashKeychain.save(reply.token)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DashFailure(message: "Could not start secure sign-in.") }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
