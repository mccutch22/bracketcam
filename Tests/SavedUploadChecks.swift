import Foundation

@main struct SavedUploadChecks {
    static func main() throws {
        let old = #"{"id":"old-job","userID":"owner","albumID":"local-stack","home":{"id":"home","slug":"home","street":"1 Main","locality":"Columbus"},"title":"Room","status":"processing"}"#
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(SavedUpload.self, from: Data(old.utf8))
        precondition(legacy.processingProvider == "esoft")
        let gpt = SavedUpload(id: "gpt-job", userID: legacy.userID, albumID: legacy.albumID, home: legacy.home, title: legacy.title, status: "pending", provider: "gpt")
        let journal = try decoder.decode([SavedUpload].self, from: JSONEncoder().encode([legacy, gpt]))
        precondition(journal.count == 2)
        precondition(journal.filter { $0.albumID == legacy.albumID && $0.processingProvider == "gpt" }.map(\.id) == ["gpt-job"])
        precondition(journal.filter { $0.albumID == legacy.albumID && $0.processingProvider == "esoft" }.map(\.id) == ["old-job"])
        print("Provider journal migration and separate request IDs passed.")
    }
}
