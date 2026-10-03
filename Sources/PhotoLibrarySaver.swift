import Photos
import ImageIO
import UniformTypeIdentifiers

/// Only explicit downloads of finished images are added to Apple Photos.
enum PhotoLibrarySaver {
    static let folderName = "RE Brackets" // Read-only compatibility with earlier builds.

    static func saveFinishedPhoto(at url: URL) async throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              UTType(type as String)?.conforms(to: .image) == true else {
            throw DashFailure(message: "This download is not a photo. Use Share to save the file instead.")
        }
        let auth = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard auth == .authorized || auth == .limited else {
            throw DashFailure(message: "To save finished photos, allow PhotoDash to add photos in Settings. You can also use Share to save this download.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = url.lastPathComponent
            options.uniformTypeIdentifier = type as String
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
        }
    }
}
