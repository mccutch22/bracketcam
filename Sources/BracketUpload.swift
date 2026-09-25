import Foundation
import Photos
import UniformTypeIdentifiers

struct SavedUpload: Codable, Identifiable {
    let id: String
    let userID: String
    let albumID: String
    let home: DashHome
    let title: String
    var status: String
}

enum UploadJournal {
    private static var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("photodash-uploads.json") }
    static func load() throws -> [SavedUpload] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        // A damaged journal must not silently turn existing orders into new orders.
        return try JSONDecoder().decode([SavedUpload].self, from: Data(contentsOf: url))
    }
    static func save(_ entries: [SavedUpload]) throws {
        try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

enum BracketUpload {
    static func multipart(for entry: SavedUpload, progress: @escaping (String) async -> Void) async throws -> (file: URL, boundary: String, directory: URL) {
        let local = entry.albumID.hasPrefix("local-") ? try BracketStore.shared.stack(entry.albumID) : nil
        let assets: PHFetchResult<PHAsset>?
        if let local {
            guard !local.isRaw else { throw DashFailure(message: "This stack contains RAW exposures. Capture a JPEG bracket set for processing.") }
            assets = nil
        } else {
            let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [entry.albumID], options: nil)
            guard let collection = album.firstObject else { throw DashFailure(message: "This older stack is no longer available in Photos. Restore it or allow Photos access before retrying.") }
            assets = PHAsset.fetchAssets(in: collection, options: nil)
        }
        let count = local?.filenames.count ?? assets?.count ?? 0
        guard (2...7).contains(count) else { throw DashFailure(message: "Each stack must contain 2–7 JPEG exposures of the same view.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photodash-upload-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let boundary = "PhotoDash" + UUID().uuidString
            let file = directory.appendingPathComponent("body.multipart")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            func text(_ value: String) throws { try output.write(contentsOf: Data(value.utf8)) }
            try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"requestId\"\r\n\r\n\(entry.id)\r\n")
            let label = entry.title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"label\"\r\n\r\n\(label)\r\n")
            if let local, let diagnostics = BracketStore.shared.diagnostics(for: local) {
                try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"captureDiagnostics\"\r\nContent-Type: application/json\r\n\r\n")
                try output.write(contentsOf: diagnostics)
                try text("\r\n")
            }
            var total = 0
            for index in 0..<count {
                try Task.checkCancellation()
                await progress("Preparing exposure \(index + 1) of \(count)…")
                let original = directory.appendingPathComponent("exposure-\(index + 1).jpg")
                if let local {
                    try FileManager.default.copyItem(at: BracketStore.shared.files(for: local)[index], to: original)
                } else if let assets {
                    let resources = PHAssetResource.assetResources(for: assets.object(at: index))
                    guard let resource = resources.first(where: { $0.type == .photo && UTType($0.uniformTypeIdentifier)?.conforms(to: .jpeg) == true }) else {
                        throw DashFailure(message: "This stack contains a non-JPEG exposure. Capture a new JPEG bracket set.")
                    }
                    let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        PHAssetResourceManager.default().writeData(for: resource, toFile: original, options: options) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
                let size = (try FileManager.default.attributesOfItem(atPath: original.path)[.size] as? NSNumber)?.intValue ?? 0
                total += size
                guard size > 0, size <= 25 * 1024 * 1024, total <= 100 * 1024 * 1024 else { throw DashFailure(message: "Exposures must be under 25 MB each and 100 MB per stack.") }
                try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"images\"; filename=\"exposure-\(index + 1).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
                let input = try FileHandle(forReadingFrom: original)
                do {
                    while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
                    try input.close()
                } catch { try? input.close(); throw error }
                try text("\r\n")
                try FileManager.default.removeItem(at: original)
            }
            try text("--\(boundary)--\r\n")
            return (file, boundary, directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
}
