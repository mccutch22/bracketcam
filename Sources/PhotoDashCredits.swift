import SwiftUI
import StoreKit

struct DashWallet: Decodable {
    let balance: Int
    let mode: String
    let appAccountToken: String
    let appleProducts: [String: Int]
}

@MainActor
final class PhotoDashCredits: ObservableObject {
    static let shared = PhotoDashCredits()
    @Published var wallet: DashWallet?
    @Published var product: Product?
    @Published var busy = false
    @Published var message = ""
    private let api = PhotoDashAPI()
    private var listener: Task<Void, Never>?
    private init() {
        listener = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self, DashKeychain.read() != nil else { continue }
                do { try await self.deliver(result) }
                catch { self.message = "Purchase saved by Apple. Sign in to the account used to buy it and tap Sync purchases to finish adding credits." }
            }
        }
    }
    func load() async {
        guard DashKeychain.read() != nil else { wallet = nil; return }
        do {
            wallet = try await api.request("credits")
            if let wallet { product = try await Product.products(for: Array(wallet.appleProducts.keys)).first }
        } catch { message = error.localizedDescription }
    }
    func sync() async {
        guard !busy else { return }
        busy = true; message = ""
        defer { busy = false }
        do {
            for await result in Transaction.unfinished { try await deliver(result) }
            await load()
            if message.isEmpty { message = "Credit balance is up to date." }
        } catch { message = error.localizedDescription }
    }
    private func deliver(_ result: VerificationResult<Transaction>) async throws {
        guard case .verified(let transaction) = result else { throw DashFailure(message: "Apple could not verify this purchase.") }
        let current: DashWallet = try await api.request("credits")
        guard transaction.appAccountToken?.uuidString.lowercased() == current.appAccountToken.lowercased() else {
            throw DashFailure(message: "Sign in to the PhotoDash account used for this purchase to finish adding its credits.")
        }
        wallet = try await api.request("credits/apple", method: "POST", body: ["signedTransaction": result.jwsRepresentation])
        // Finish only after the server has verified and recorded the credit grant.
        await transaction.finish()
        message = "Credits added. You're ready to process photos."
    }
    func buy(units: Int) async {
        guard !busy, let product, let wallet, let token = UUID(uuidString: wallet.appAccountToken), (1...10).contains(units) else { return }
        busy = true; message = ""
        defer { busy = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(token), .quantity(units)]) {
            case .success(let result): try await deliver(result)
            case .pending: message = "Waiting for Apple purchase approval. Your photos are saved; credits will be added after approval."
            case .userCancelled: break
            @unknown default: message = "Check Sync purchases before trying again."
            }
        } catch { message = "Purchase not yet confirmed: \(error.localizedDescription) Use Sync purchases before buying again." }
    }
    func clear() { wallet = nil; product = nil; message = "" }
}

struct PhotoDashCreditsView: View {
    @ObservedObject private var credits = PhotoDashCredits.shared
    @Environment(\.dismiss) private var dismiss
    @State private var units = 1
    var body: some View {
        NavigationStack {
            Form {
                Section("Available credits") {
                    Text("\(credits.wallet?.balance ?? 0)").font(.system(size: 56, weight: .medium))
                    Text("One credit processes one photo. Credits never expire and your balance is shared with the PhotoDash website.")
                    if credits.wallet?.mode == "test" { Text("Test mode — Apple sandbox purchases do not charge you. Test credits stay separate from your launch balance.").font(.caption).foregroundStyle(.orange) }
                }
                Section("Buy credits") {
                    Picker("Credits", selection: $units) { ForEach(1...10, id: \.self) { n in Text("\(n * 10) credits").tag(n) } }.disabled(credits.busy)
                    if let product = credits.product {
                        Text("Total: \((product.price * Decimal(units)).formatted(product.priceFormatStyle))")
                        Button { Task { await credits.buy(units: units) } } label: { Text("Buy \(units * 10) credits").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12) }.buttonStyle(.borderedProminent).disabled(credits.busy)
                    } else { Text("Apple credit purchases are not available yet. Tap Sync purchases to check again.").font(.callout) }
                    Text("Your photos and selection stay saved while you buy credits.").font(.caption)
                }
                if credits.busy { ProgressView("Checking purchase…") }
                if !credits.message.isEmpty { Section { Text(credits.message) } }
                Section { Button("Sync purchases") { Task { await credits.sync() } }.disabled(credits.busy) }
            }
            .navigationTitle("Photo credits").toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.disabled(credits.busy) } }
            .task { await credits.sync() }.interactiveDismissDisabled(credits.busy)
        }.preferredColorScheme(.dark)
    }
}
