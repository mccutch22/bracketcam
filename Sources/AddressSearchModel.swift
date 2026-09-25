import Foundation
import Combine

struct HomeAddress: Decodable, Equatable {
    var street = ""
    var city = ""
    var state = ""
    var postalCode = ""

    var isComplete: Bool {
        [street, city, state, postalCode].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    var display: String { "\(street), \(city), \(state) \(postalCode)" }
    var fields: [String: String] {
        ["street": street, "city": city, "state": state, "postalCode": postalCode]
    }
}

struct AddressSuggestion: Decodable, Identifiable {
    let id: String
    let text: String
}

struct AddressSearchReply: Decodable {
    var configured: Bool?
    var suggestions: [AddressSuggestion]?
    var address: HomeAddress?
}

@MainActor
final class AddressSearchModel: ObservableObject {
    typealias Lookup = ([String: String]) async throws -> AddressSearchReply
    @Published private(set) var query = ""
    @Published private(set) var suggestions: [AddressSuggestion] = []
    @Published var address = HomeAddress()
    @Published private(set) var manual = false
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    private let lookup: Lookup
    private let debounce: UInt64
    private var sessionToken = UUID().uuidString
    private var revision = 0
    private var task: Task<Void, Never>?

    init(debounce: UInt64 = 300_000_000, lookup: @escaping Lookup) {
        self.debounce = debounce
        self.lookup = lookup
    }

    func cancel() {
        revision += 1
        task?.cancel()
        task = nil
        loading = false
        suggestions = []
    }

    func updateQuery(_ value: String) {
        cancel()
        query = String(value.prefix(250))
        address = HomeAddress()
        message = nil
        guard !manual, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 else { return }
        let version = revision
        let input = query
        let token = sessionToken
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: debounce)
                let reply = try await lookup(["query": input, "sessionToken": token])
                guard !Task.isCancelled, revision == version else { return }
                suggestions = reply.suggestions ?? []
                message = reply.configured == false ? "Address search is unavailable. You can enter the address manually." : suggestions.isEmpty ? "No matches. Try adding the city or enter the address manually." : nil
            } catch {
                guard !Task.isCancelled, revision == version else { return }
                message = "Couldn't search addresses. Try again or enter the address manually."
            }
            if revision == version { loading = false }
        }
    }

    func select(_ suggestion: AddressSuggestion) {
        cancel()
        address = HomeAddress()
        query = suggestion.text
        message = nil
        loading = true
        let version = revision
        let token = sessionToken
        // Details terminate this Google session. Any later search gets a fresh token.
        sessionToken = UUID().uuidString
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await lookup(["placeId": suggestion.id, "sessionToken": token])
                guard !Task.isCancelled, revision == version else { return }
                guard let resolved = reply.address else { throw URLError(.badServerResponse) }
                address = resolved
                query = resolved.display
                if !resolved.isComplete {
                    manual = true
                    message = "Please complete the missing address details."
                }
            } catch {
                guard !Task.isCancelled, revision == version else { return }
                message = "Couldn't load that address. Select it again or enter it manually."
            }
            if revision == version { loading = false }
        }
    }

    func useManualEntry() { cancel(); manual = true; message = nil }
    func reset() {
        cancel()
        query = ""; address = HomeAddress(); manual = false; message = nil
        sessionToken = UUID().uuidString
    }
    // Allows deterministic checks of asynchronous search completion in CI.
    func waitForSearch() async { await task?.value }
}
