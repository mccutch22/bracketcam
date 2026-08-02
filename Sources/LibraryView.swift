import SwiftUI
import Photos

/// One captured bracket stack = one album inside the "RE Brackets" folder.
/// The stack is represented by its 0 EV frame (index 3 of the 6-frame
/// ladder [-6, -4, -2, 0, +2, +4]).
struct StackItem: Identifiable {
    let id: String                 // album localIdentifier
    let title: String
    let date: Date?
    let representative: PHAsset?
    let frameCount: Int
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var stacks: [StackItem] = []
    @Published var selected: Set<String> = []
    @Published var authDenied = false
    @Published var loaded = false

    func load() async {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard auth == .authorized else {
            authDenied = true
            loaded = true
            return
        }

        // The RE Brackets folder is the database: every child album is a stack.
        var folder: PHCollectionList?
        let lists = PHCollectionList.fetchCollectionLists(with: .folder,
                                                          subtype: .regularFolder,
                                                          options: nil)
        lists.enumerateObjects { list, _, stop in
            if list.localizedTitle == PhotoLibrarySaver.folderName {
                folder = list
                stop.pointee = true
            }
        }

        var items: [StackItem] = []
        if let folder {
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            children.enumerateObjects { child, _, _ in
                guard let album = child as? PHAssetCollection else { return }
                let assets = PHAsset.fetchAssets(in: album, options: nil)
                guard assets.count > 0 else { return }
                // Album order is capture order (darkest first) — the 0 EV
                // frame sits at index 3 of a full 6-frame stack.
                let rep = assets.object(at: min(3, assets.count - 1))
                items.append(StackItem(id: album.localIdentifier,
                                       title: album.localizedTitle ?? "Bracket",
                                       date: rep.creationDate,
                                       representative: rep,
                                       frameCount: assets.count))
            }
        }
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        stacks = items
        selected = selected.intersection(Set(items.map(\.id)))
        loaded = true
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func toggleSelectAll() {
        if selected.count == stacks.count {
            selected.removeAll()
        } else {
            selected = Set(stacks.map(\.id))
        }
    }
}

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = LibraryModel()
    @State private var showOrderSheet = false
    @State private var confirmationText: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                if !model.loaded {
                    ProgressView().tint(.white)
                } else if model.authDenied {
                    message("Photo Dash needs Full Photos access to show your stacks.\nAllow it in Settings → Privacy → Photos.")
                } else if model.stacks.isEmpty {
                    message("No stacks yet.\nEvery bracket you shoot appears here as a single photo.")
                } else {
                    grid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.selected.count == model.stacks.count && !model.stacks.isEmpty
                           ? "Deselect All" : "Select All") {
                        model.toggleSelectAll()
                    }
                    .disabled(model.stacks.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { processBar }
        }
        .preferredColorScheme(.dark)
        .task { await model.load() }
        .sheet(isPresented: $showOrderSheet) {
            OrderSheet(stackCount: model.selected.count) { name in
                placeOrder(named: name)
            }
            .presentationDetents([.medium])
        }
        .alert("Order placed", isPresented: .init(
            get: { confirmationText != nil },
            set: { if !$0 { confirmationText = nil } }
        )) {
            Button("OK") { confirmationText = nil }
        } message: {
            Text(confirmationText ?? "")
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(model.stacks) { stack in
                    StackCell(stack: stack,
                              isSelected: model.selected.contains(stack.id))
                        .onTapGesture { model.toggle(stack.id) }
                }
            }
            .padding(4)
        }
    }

    private var processBar: some View {
        VStack(spacing: 6) {
            Button {
                showOrderSheet = true
            } label: {
                Text(model.selected.isEmpty
                     ? "Select stacks to process"
                     : "Process \(model.selected.count) \(model.selected.count == 1 ? "stack" : "stacks") • $\(model.selected.count)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(model.selected.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(model.selected.isEmpty)

            Text("$1 per stack — pay at photodash.com when your photos are ready")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.9))
    }

    private func placeOrder(named name: String) {
        let order = Order(id: UUID(),
                          shootName: name,
                          createdAt: Date(),
                          stackAlbumIDs: Array(model.selected),
                          pricePerStackUSD: 1,
                          status: "placed")
        try? OrderStore.append(order)
        showOrderSheet = false
        confirmationText = "\(order.stackAlbumIDs.count) \(order.stackAlbumIDs.count == 1 ? "stack" : "stacks") queued as “\(name)”. Uploading and delivery switch on once accounts go live — you'll pay at photodash.com when the processed photos are ready."
        model.selected.removeAll()
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white.opacity(0.7))
            .padding(32)
    }
}

// MARK: - Grid cell

private struct StackCell: View {
    let stack: StackItem
    let isSelected: Bool

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                StackThumbnail(asset: stack.representative)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(isSelected ? Color.blue : .clear, lineWidth: 3)
                    )

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.blue : .white.opacity(0.8))
                    .background(Circle().fill(.black.opacity(0.35)))
                    .padding(6)
            }

            Text(stack.date.map { Self.timeFormatter.string(from: $0) } ?? stack.title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
    }
}

// MARK: - Thumbnail loader

private struct StackThumbnail: View {
    let asset: PHAsset?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.white.opacity(0.08)
                    Image(systemName: "photo")
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .onAppear(perform: request)
    }

    private func request() {
        guard image == nil, let asset else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        PHImageManager.default().requestImage(for: asset,
                                              targetSize: CGSize(width: 400, height: 300),
                                              contentMode: .aspectFill,
                                              options: options) { img, _ in
            if let img { image = img }
        }
    }
}

// MARK: - Order sheet

private struct OrderSheet: View {
    let stackCount: Int
    let onPlace: (String) -> Void

    @State private var shootName = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String {
        shootName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("Name this shoot")
                    .font(.headline)

                TextField("e.g. 123 Main St", text: $shootName)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                VStack(alignment: .leading, spacing: 6) {
                    Text("\(stackCount) \(stackCount == 1 ? "stack" : "stacks") × $1 = $\(stackCount)")
                        .font(.title3.bold())
                    Text("Nothing to pay now. Your processed HDR photos will be ready at photodash.com — you pay there to download them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    onPlace(trimmedName)
                } label: {
                    Text("Place order")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(trimmedName.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(trimmedName.isEmpty)
            }
            .padding(20)
            .navigationTitle("Process photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
