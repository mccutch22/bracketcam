import Foundation

@main struct BracketStoreChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bracket-store-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BracketStore(root: root)
        let empty = try store.all()
        precondition(empty.isEmpty)
        let data = [Data([1,2]), Data([3,4]), Data([5,6]), Data([7,8])]
        let saved = try store.save(imageDatas: data, setName: "Same timestamp", isRaw: false)
        let second = try store.save(imageDatas: data, setName: "Same timestamp", isRaw: false)
        precondition(saved.id != second.id)
        let reopened = BracketStore(root: root)
        let stacks = try reopened.all()
        precondition(stacks.count == 2 && stacks.contains(where: { $0.id == saved.id }))
        for (file, original) in zip(reopened.files(for: saved), data) {
            let disk = try Data(contentsOf: file)
            precondition(disk == original)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".pending-interrupted"), withIntermediateDirectories: false)
        let published = try store.all()
        precondition(published.count == 2)
        do { _ = try store.save(imageDatas: [Data()], setName: "Invalid", isRaw: false); fatalError("Accepted incomplete capture") } catch {}
        do { _ = try store.stack("../../outside"); fatalError("Accepted unsafe stack ID") } catch {}
        let raw = try store.save(imageDatas: data, setName: "RAW", isRaw: true)
        precondition(raw.isRaw && raw.filenames.allSatisfy { $0.hasSuffix(".dng") })
        let corrupt = StoredBracket(id: saved.id, title: "Corrupt", date: Date(), filenames: ["../outside.jpg", "other.jpg"], isRaw: false)
        try JSONEncoder().encode(corrupt).write(to: root.appendingPathComponent(saved.id).appendingPathComponent("stack.json"))
        do { _ = try store.stack(saved.id); fatalError("Accepted invalid manifest paths") } catch {}
        print("Private brackets: durable restart, byte preservation, unique IDs, incomplete captures hidden, RAW, safe paths passed.")
    }
}
