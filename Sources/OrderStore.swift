import Foundation

/// A processing order placed from the Library screen. Phase 0 stores orders
/// locally on the phone; uploading, accounts, and payment state arrive with
/// the backend. $1/stack, paid at photodash.com when photos are delivered.
struct Order: Codable, Identifiable {
    let id: UUID
    let shootName: String
    let createdAt: Date
    /// Photos album localIdentifiers — one per selected stack.
    let stackAlbumIDs: [String]
    let pricePerStackUSD: Int
    /// "placed" for now; upload/delivery/payment states come with the backend.
    var status: String
}

enum OrderStore {

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("orders.json")
    }

    static func loadAll() -> [Order] {
        guard let data = try? Data(contentsOf: fileURL),
              let orders = try? JSONDecoder().decode([Order].self, from: data) else {
            return []
        }
        return orders
    }

    static func append(_ order: Order) throws {
        var orders = loadAll()
        orders.append(order)
        let data = try JSONEncoder().encode(orders)
        try data.write(to: fileURL, options: .atomic)
    }
}
