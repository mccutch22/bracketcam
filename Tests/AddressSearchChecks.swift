import Foundation

@main struct AddressSearchChecks {
    @MainActor static func main() async {
        var calls: [[String: String]] = []
        let complete = HomeAddress(street: "123 Main St", city: "Columbus", state: "OH", postalCode: "43215")
        let model = AddressSearchModel(debounce: 1_000_000) { fields in
            calls.append(fields)
            if fields["placeId"] != nil { return AddressSearchReply(address: complete) }
            return AddressSearchReply(configured: true, suggestions: [AddressSuggestion(id: "place-one", text: "123 Main St")])
        }
        model.updateQuery("1")
        await model.waitForSearch()
        precondition(calls.isEmpty)
        model.updateQuery("123")
        model.updateQuery("123 Main")
        await model.waitForSearch()
        precondition(calls.count == 1 && calls[0]["query"] == "123 Main")
        precondition(!model.address.isComplete)
        model.select(model.suggestions[0])
        await model.waitForSearch()
        precondition(model.address == complete && model.suggestions.isEmpty)
        precondition(calls[0]["sessionToken"] == calls[1]["sessionToken"])
        model.updateQuery("456 New")
        precondition(!model.address.isComplete)
        await model.waitForSearch()
        precondition(calls[2]["sessionToken"] != calls[0]["sessionToken"])

        var pending: CheckedContinuation<AddressSearchReply, Error>?
        let delayed = AddressSearchModel(debounce: 0) { _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        delayed.select(AddressSuggestion(id: "old-place", text: "Old address"))
        while pending == nil { await Task.yield() }
        delayed.updateQuery("")
        pending?.resume(returning: AddressSearchReply(address: complete))
        for _ in 0..<10 { await Task.yield() }
        precondition(!delayed.address.isComplete && delayed.query.isEmpty && !delayed.loading)

        let incomplete = AddressSearchModel(debounce: 0) { _ in
            AddressSearchReply(address: HomeAddress(street: "1 New Road", city: "Columbus", state: "OH"))
        }
        incomplete.select(AddressSuggestion(id: "new-place", text: "1 New Road"))
        await incomplete.waitForSearch()
        precondition(incomplete.manual && !incomplete.address.isComplete)
        incomplete.address.postalCode = "43215"
        precondition(incomplete.address.isComplete)
        incomplete.reset()
        precondition(!incomplete.manual && !incomplete.address.isComplete && incomplete.query.isEmpty)

        let offline = AddressSearchModel(debounce: 0) { _ in throw URLError(.notConnectedToInternet) }
        offline.updateQuery("123 Main")
        await offline.waitForSearch()
        precondition(offline.message != nil && !offline.loading && !offline.address.isComplete)
        offline.useManualEntry()
        offline.address = complete
        precondition(offline.manual && offline.address.isComplete)
        print("Address checks passed: debounce, selection, session reuse/rotation, stale details, missing ZIP, offline/manual fallback.")
    }
}
