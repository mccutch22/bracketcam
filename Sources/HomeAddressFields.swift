import SwiftUI

struct HomeAddressFields: View {
    @ObservedObject var search: AddressSearchModel

    var body: some View {
        if search.manual {
            TextField("Street address / unit", text: $search.address.street).textContentType(.streetAddressLine1)
            TextField("City", text: $search.address.city).textContentType(.addressCity)
            TextField("State", text: $search.address.state).textContentType(.addressState)
            TextField("ZIP code", text: $search.address.postalCode).textContentType(.postalCode).keyboardType(.numbersAndPunctuation)
            Button("Use address search") { search.reset() }
        } else {
            TextField("Search home address", text: Binding(get: { search.query }, set: { search.updateQuery($0) }))
                .textContentType(.fullStreetAddress)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { if !search.address.isComplete { search.updateQuery(search.query) } }
            if search.loading { ProgressView("Finding address…") }
            if !search.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.suggestions) { suggestion in
                        Button { search.select(suggestion) } label: {
                            Label(suggestion.text, systemImage: "mappin.circle")
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .padding(.vertical, 6)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                    Text("Google Maps").font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white).padding(.top, 10)
                }
            }
            if search.address.isComplete {
                Label("Address selected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Button(search.address.isComplete ? "Edit address details / add unit" : "Enter address manually") { search.useManualEntry() }
                .font(.subheadline)
        }
        if let message = search.message { Text(message).font(.caption).foregroundStyle(.secondary) }
    }
}
