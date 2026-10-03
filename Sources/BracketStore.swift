import Foundation

struct StoredBracket: Codable, Identifiable {
    let id: String
    let title: String
    let date: Date
    let filenames: [String]
    let isRaw: Bool
}

/// Durable, app-private originals. Publish the directory only after every frame
/// and its manifest are on disk, so a failed save never looks like a complete stack.
struct BracketStore {
    let root: URL
    static let shared = BracketStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Brackets", isDirectory: true))

    @discardableResult
    func save(imageDatas: [Data], setName: String, isRaw: Bool) throws -> StoredBracket {
        guard (2...7).contains(imageDatas.count), imageDatas.allSatisfy({ !$0.isEmpty }) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let id = "local-" + UUID().uuidString.lowercased()
        let pending = root.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: pending, withIntermediateDirectories: false)
        do {
            let names = imageDatas.indices.map { "exposure-\($0 + 1).\(isRaw ? "dng" : "jpg")" }
            var options: Data.WritingOptions = .atomic
            #if os(iOS)
            options.insert(.completeFileProtectionUntilFirstUserAuthentication)
            #endif
            for (name, data) in zip(names, imageDatas) {
                try data.write(to: pending.appendingPathComponent(name), options: options)
            }
            let bracket = StoredBracket(id: id, title: setName, date: Date(), filenames: names, isRaw: isRaw)
            try JSONEncoder().encode(bracket).write(to: pending.appendingPathComponent("stack.json"), options: options)
            try fm.moveItem(at: pending, to: root.appendingPathComponent(id, isDirectory: true))
            return bracket
        } catch {
            try? fm.removeItem(at: pending)
            throw error
        }
    }

    func stack(_ id: String) throws -> StoredBracket {
        guard id.hasPrefix("local-"), UUID(uuidString: String(id.dropFirst(6))) != nil else { throw CocoaError(.fileReadInvalidFileName) }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let stack = try JSONDecoder().decode(StoredBracket.self, from: Data(contentsOf: directory.appendingPathComponent("stack.json")))
        guard stack.id == id, (2...7).contains(stack.filenames.count),
              stack.filenames == stack.filenames.indices.map({ "exposure-\($0 + 1).\(stack.isRaw ? "dng" : "jpg")" }) else { throw CocoaError(.fileReadCorruptFile) }
        return stack
    }

    func files(for stack: StoredBracket) -> [URL] {
        stack.filenames.map { root.appendingPathComponent(stack.id, isDirectory: true).appendingPathComponent($0) }
    }

    func diagnostics(for stack: StoredBracket) -> Data? {
        let url = root.appendingPathComponent(stack.id).appendingPathComponent("capture-diagnostics.json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 256 * 1024 else { return nil }
        return try? Data(contentsOf: url)
    }

    func saveDiagnostics(_ data: Data, for bracket: StoredBracket) throws {
        let validated = try stack(bracket.id)
        guard data.count <= 256 * 1024 else { throw CocoaError(.fileWriteInvalidFileName) }
        var options: Data.WritingOptions = .atomic
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        try data.write(to: root.appendingPathComponent(validated.id).appendingPathComponent("capture-diagnostics.json"), options: options)
    }

    func all() throws -> [StoredBracket] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .filter { $0.lastPathComponent.hasPrefix("local-") }
            .map { try stack($0.lastPathComponent) }
            .sorted { $0.date > $1.date }
    }
}
