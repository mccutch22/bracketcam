import SwiftUI

@MainActor
final class SubmissionModel: ObservableObject {
    @Published var account: DashAccount?
    @Published var homes: [DashHome] = []
    @Published var chosenSlug = ""
    @Published var busy = false
    @Published var status = ""
    @Published var error: String?
    @Published var finished = false
    @Published var history: [SavedUpload] = []
    let api = PhotoDashAPI()
    private let auth = CameraSignIn()

    var chosenHome: DashHome? { homes.first { $0.slug == chosenSlug } }
    func load() async {
        guard DashKeychain.read() != nil else { account = nil; return }
        busy = true; error = nil
        defer { busy = false }
        do { try await loadAccount() } catch { show(error) }
    }
    private func loadAccount() async throws {
        let loaded: DashAccount = try await api.request("me")
        account = loaded
        await PhotoDashCredits.shared.load()
        let reply: HomesReply = try await api.request("homes")
        homes = reply.homes
        if !homes.contains(where: { $0.slug == chosenSlug }) { chosenSlug = homes.first?.slug ?? "" }
        history = try UploadJournal.load().filter { $0.userID == loaded.user.id }
    }
    func signIn() async {
        busy = true; error = nil
        defer { busy = false }
        do { try await auth.signIn(api: api); try await loadAccount() } catch { show(error) }
    }
    func signOut() async {
        busy = true; error = nil
        defer { busy = false }
        do { try await api.signOut(); PhotoDashCredits.shared.clear(); account = nil; homes = []; history = []; finished = false; status = "" } catch { show(error) }
    }
    func createHome(_ fields: [String: String]) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let reply: HomeReply = try await api.request("homes", method: "POST", body: fields)
            try await loadAccount(); chosenSlug = reply.home.slug
        } catch { show(error) }
    }
    func submit(_ stacks: [StackItem]) async {
        guard let account, account.processingAvailable, let home = chosenHome else { return }
        busy = true; error = nil; finished = false
        UIApplication.shared.isIdleTimerDisabled = true
        defer { busy = false; UIApplication.shared.isIdleTimerDisabled = false }
        do {
            var journal = try UploadJournal.load()
            for stack in stacks where !journal.contains(where: { $0.userID == account.user.id && $0.albumID == stack.id && $0.home.id == home.id }) {
                journal.append(SavedUpload(id: UUID().uuidString.lowercased(), userID: account.user.id, albumID: stack.id, home: home, title: stack.title, status: "pending"))
            }
            // Persist IDs before the first network request; retries reuse the same IDs.
            try UploadJournal.save(journal)
            let remote: JobsReply = try await api.request("homes/\(home.slug)/brackets")
            let remaining = stacks.filter { stack in
                guard let saved = journal.first(where: { $0.userID == account.user.id && $0.albumID == stack.id && $0.home.id == home.id }), let job = remote.jobs.first(where: { $0.id == saved.id }) else { return true }
                return (job.status == "ready" || job.canRetry == true) && job.creditReserved != true
            }.count
            let balance: DashWallet = try await api.request("credits")
            guard balance.balance >= remaining else { throw DashFailure(message: "You need \(remaining) credits and have \(balance.balance). Tap Buy credits, then return here to send your saved selection.") }
            for (number, stack) in stacks.enumerated() {
                guard let index = journal.firstIndex(where: { $0.userID == account.user.id && $0.albumID == stack.id && $0.home.id == home.id }) else { continue }
                let entry = journal[index]
                status = "Stack \(number + 1) of \(stacks.count): checking saved progress…"
                var job = remote.jobs.first { $0.id == entry.id }
                if job == nil {
                    let multipart = try await BracketUpload.multipart(for: entry) { [weak self] detail in
                        await MainActor.run { self?.status = "Stack \(number + 1) of \(stacks.count): \(detail)" }
                    }
                    defer { try? FileManager.default.removeItem(at: multipart.directory) }
                    status = "Uploading stack \(number + 1) of \(stacks.count)… Keep PhotoDash open."
                    job = try await api.upload(multipart.file, boundary: multipart.boundary, slug: home.slug)
                }
                guard var saved = job else { throw DashFailure(message: "Could not confirm this upload. Retry to check its saved status.") }
                if saved.status == "ready" || saved.canRetry == true {
                    status = "Sending stack \(number + 1) of \(stacks.count) for editing…"
                    let reply: JobReply = try await api.request("homes/\(home.slug)/brackets/\(entry.id)", method: "POST", body: ["action": "process"])
                    saved = reply.job
                }
                journal[index].status = saved.status
                try UploadJournal.save(journal)
                history = journal.filter { $0.userID == account.user.id }
                guard ["processing", "completed", "submitting"].contains(saved.status) else {
                    throw DashFailure(message: saved.message ?? "This stack needs attention. Check it on the website before retrying.")
                }
            }
            finished = true
            status = "\(stacks.count) \(stacks.count == 1 ? "stack is" : "stacks are") saved to \(home.street). Check processing and retrieve finished photos on the website."
        } catch { show(error) }
        await PhotoDashCredits.shared.load()
    }
    private func show(_ failure: Error) {
        error = failure.localizedDescription
        if DashKeychain.read() == nil { account = nil; homes = []; history = [] }
    }
}

struct PhotoDashSubmissionView: View {
    let stacks: [StackItem]
    @StateObject private var model = SubmissionModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showNewHome = false
    @State private var showCredits = false
    @ObservedObject private var credits = PhotoDashCredits.shared
    @AppStorage("photodash.pendingHomeRequestID") private var homeRequestID = UUID().uuidString.lowercased()
    @StateObject private var addressSearch = AddressSearchModel { fields in
        try await PhotoDashAPI().request("address", method: "POST", body: fields)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let account = model.account {
                    Section("Photo credits") {
                        Text("\(credits.wallet?.balance ?? account.credits?.balance ?? 0) credits available")
                        Button("Buy credits") { showCredits = true }.disabled(model.busy)
                    }
                    if !account.processingAvailable && !stacks.isEmpty {
                        Text("Camera processing is currently available to the PhotoDash pilot account. Your captured photos remain in Photos.")
                    } else {
                        submissionSections(account)
                    }
                } else {
                    Section {
                        Text("Sign in with the same Google account you use on the PhotoDash website.")
                        Button("Sign in to PhotoDash") { Task { await model.signIn() } }.disabled(model.busy)
                    }
                }
                if model.busy { Section { ProgressView(model.status.isEmpty ? "Connecting…" : model.status) } }
                else if !model.status.isEmpty { Section { Text(model.status) } }
                if let error = model.error { Section("Needs attention") { Text(error).foregroundStyle(.orange) } }
            }
            .navigationTitle(stacks.isEmpty ? "Your Homes and Account" : "Send to PhotoDash")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Back") { dismiss() }.disabled(model.busy) }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.account != nil { Menu { Button("Sign out", role: .destructive) { Task { await model.signOut() } } } label: { Image(systemName: "person.crop.circle") }.accessibilityLabel("Account").disabled(model.busy) }
                }
            }
            .task { await model.load() }
            .interactiveDismissDisabled(model.busy)
            .sheet(isPresented: $showCredits) { PhotoDashCreditsView() }
            .onDisappear { addressSearch.cancel() }
            .onChange(of: model.account?.user.id) { _, _ in addressSearch.reset(); showNewHome = false }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private func submissionSections(_ account: DashAccount) -> some View {
        Section {
            if !model.homes.isEmpty {
                Picker("Home", selection: $model.chosenSlug) {
                    ForEach(model.homes) { home in Text("\(home.street), \(home.locality)").tag(home.slug) }
                }.disabled(model.busy || model.finished)
            }
            if let home = model.chosenHome {
                Link("View photo gallery for this address", destination: PhotoDashConfig.website(home.slug))
            }
            if showNewHome {
                HomeAddressFields(search: addressSearch).disabled(model.busy)
                Button("Save home") {
                    // AppStorage defaults are not persisted until written. Save before
                    // the request so a force-quit cannot create a second draft on retry.
                    UserDefaults.standard.set(homeRequestID, forKey: "photodash.pendingHomeRequestID")
                    Task {
                        var fields = addressSearch.address.fields
                        fields["requestId"] = homeRequestID
                        await model.createHome(fields)
                        if model.error == nil { showNewHome = false; homeRequestID = UUID().uuidString.lowercased(); addressSearch.reset() }
                    }
                }.disabled(model.busy || addressSearch.loading || !addressSearch.address.isComplete)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Choose a home")
                Spacer(minLength: 8)
                Button(showNewHome ? "Cancel new home" : "+ Create a new home") {
                    showNewHome.toggle()
                    addressSearch.reset()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.vertical, 8)
                .disabled(model.busy || model.finished)
            }
            .textCase(nil)
        }
        if !stacks.isEmpty { Section {
            Text("\(stacks.count) selected \(stacks.count == 1 ? "stack" : "stacks") · one finished photo per stack")
            Text("Costs 1 credit per photo sent for processing. Previously submitted photos are not charged again.").font(.caption).foregroundStyle(.secondary)
            if credits.wallet?.mode == "test" { Text("Test credits · Esoft development processing").font(.caption).foregroundStyle(.orange) }
            Button { Task { await model.submit(stacks) } } label: {
                Text(model.finished ? "Sent to PhotoDash" : model.busy ? "Uploading…" : "Upload & process photos")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
            }
                .buttonStyle(.borderedProminent).tint(.blue).controlSize(.large)
                .disabled(model.busy || model.finished || model.chosenHome == nil || stacks.isEmpty || showNewHome)
            Text("Keep the app open while uploading. Originals stay in your Photos library and private PhotoDash storage.").font(.caption).foregroundStyle(.secondary)
        } }
    }
}
