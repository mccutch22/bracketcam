import Photos

/// Saves each 5-shot set as its own album ("Bracket yyyy-MM-dd HH.mm.ss")
/// inside a top-level "RE Brackets" folder, so every set is identifiable.
enum PhotoLibrarySaver {

    static let folderName = "RE Brackets"

    enum SaveError: LocalizedError {
        case notAuthorized
        case folderCreationFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Photos access denied. Allow Full Access in Settings > Privacy > Photos."
            case .folderCreationFailed:
                return "Could not create the RE Brackets folder in Photos."
            }
        }
    }

    static func save(imageDatas: [Data], setName: String) async throws {
        let auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard auth == .authorized else { throw SaveError.notAuthorized }

        let folder = try await findOrCreateFolder()

        try await PHPhotoLibrary.shared().performChanges {
            guard let folderRequest = PHCollectionListChangeRequest(for: folder) else { return }

            let albumRequest = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: setName)

            var placeholders: [PHObjectPlaceholder] = []
            for data in imageDatas {
                let assetRequest = PHAssetCreationRequest.forAsset()
                assetRequest.addResource(with: .photo, data: data, options: nil)
                if let placeholder = assetRequest.placeholderForCreatedAsset {
                    placeholders.append(placeholder)
                }
            }
            albumRequest.addAssets(placeholders as NSArray)
            folderRequest.addChildCollections(
                [albumRequest.placeholderForCreatedAssetCollection] as NSArray
            )
        }
    }

    private static func findOrCreateFolder() async throws -> PHCollectionList {
        let existing = PHCollectionList.fetchCollectionLists(with: .folder,
                                                             subtype: .regularFolder,
                                                             options: nil)
        var found: PHCollectionList?
        existing.enumerateObjects { list, _, stop in
            if list.localizedTitle == folderName {
                found = list
                stop.pointee = true
            }
        }
        if let found { return found }

        var placeholderID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHCollectionListChangeRequest
                .creationRequestForCollectionList(withTitle: folderName)
            placeholderID = request.placeholderForCreatedCollectionList.localIdentifier
        }
        guard let placeholderID,
              let list = PHCollectionList
                  .fetchCollectionLists(withLocalIdentifiers: [placeholderID], options: nil)
                  .firstObject else {
            throw SaveError.folderCreationFailed
        }
        return list
    }
}
