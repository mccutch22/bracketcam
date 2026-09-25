import SwiftUI
import Photos
import ImageIO

/// New stacks live privately in the app; legacy Photos albums remain readable.
/// The stack is represented by its 0 EV frame (the middle of the ladder).
struct StackItem: Identifiable {
    let id: String                 // album localIdentifier
    let title: String
    let date: Date?
    let representative: PHAsset?
    let localRepresentative: URL?
    let frameCount: Int
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var stacks: [StackItem] = []
    @Published var selected: Set<String> = []
    @Published var canImportLegacy = false
    @Published var loadError: String?
    @Published var loaded = false

    func load() async {
        var items: [StackItem] = []
        loadError = nil
        do {
            let stored = try await Task.detached { try BracketStore.shared.all() }.value
            items = stored.map { stack in
                let files = BracketStore.shared.files(for: stack)
                return StackItem(id: stack.id, title: stack.title, date: stack.date,
                                 representative: nil, localRepresentative: files[files.count / 2], frameCount: files.count)
            }
        } catch { loadError = "Could not read saved stacks. Your files have not been removed. \(error.localizedDescription)" }
        let auth = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        canImportLegacy = auth != .authorized
        // Reading old albums is optional. Never request Photos access for new captures.
        if auth == .authorized || auth == .limited {
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

        if let folder {
            let children = PHCollection.fetchCollections(in: folder, options: nil)
            children.enumerateObjects { child, _, _ in
                guard let album = child as? PHAssetCollection else { return }
                let assets = PHAsset.fetchAssets(in: album, options: nil)
                guard assets.count > 0 else { return }
                // Album order is capture order (darkest first). The 0 EV
                // frame sits at index 3 of the 6-frame tripod ladder
                // (-6,-4,-2,0,+2,+4) and index 2 of the 4-frame handheld
                // ladder (-6,-3,0,+3) — count/2 lands on it in both.
                let rep = assets.object(at: min(assets.count / 2, assets.count - 1))
                items.append(StackItem(id: album.localIdentifier,
                                       title: album.localizedTitle ?? "Bracket",
                                       date: rep.creationDate,
                                       representative: rep,
                                       localRepresentative: nil,
                                       frameCount: assets.count))
            }
        }
        }
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        stacks = items
        selected = selected.intersection(Set(items.map(\.id)))
        loaded = true
    }

    func showOlderStacks() async {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await load()
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
    @State private var accountOnly = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 4)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Select photos for processing").font(.title2.bold()).multilineTextAlignment(.center).padding(.horizontal)
                if let error = model.loadError { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
                if model.canImportLegacy {
                    Button("Show older stacks from Photos") { Task { await model.showOlderStacks() } }.font(.caption)
                }
            Group {
                if !model.loaded {
                    ProgressView().tint(.white)

                } else if model.stacks.isEmpty {
                    message("No stacks yet.\nEvery bracket you shoot appears here as a single photo.")
                } else {
                    grid
                }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Your Homes and Account") { accountOnly = true; showOrderSheet = true }
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
            PhotoDashSubmissionView(stacks: accountOnly ? [] : model.stacks.filter { model.selected.contains($0.id) })
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
                accountOnly = false
                showOrderSheet = true
            } label: {
                Text("Next")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(model.selected.isEmpty ? Color.gray.opacity(0.4) : Color.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(model.selected.isEmpty)

            Text("Select complete stacks. Retrieve finished photos on the PhotoDash website.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.9))
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
                StackThumbnail(asset: stack.representative, localURL: stack.localRepresentative)
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
    let localURL: URL?
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
        guard image == nil else { return }
        if let localURL {
            Task {
                let thumbnail = await Task.detached {
                    guard let source = CGImageSourceCreateWithURL(localURL as CFURL, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary)
                }.value
                if let thumbnail { image = UIImage(cgImage: thumbnail) }
            }
            return
        }
        guard let asset else { return }
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
