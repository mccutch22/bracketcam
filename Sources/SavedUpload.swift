import Foundation

struct DashHome: Codable, Identifiable, Hashable { let id: String; let slug: String; let street: String; let locality: String }

struct SavedUpload: Codable, Identifiable {
    let id: String
    let userID: String
    let albumID: String
    let home: DashHome
    let title: String
    var status: String
    var provider: String? = nil
    var processingProvider: String { provider ?? "esoft" }
}

