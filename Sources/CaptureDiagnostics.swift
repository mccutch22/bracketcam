import Foundation
import ImageIO
import CryptoKit

// Only named camera/exposure fields are collected: no GPS, maker notes, device
// identifiers, full EXIF dump, or image content in the diagnostic report.
struct ImageMetadataSnapshot: Codable {
    let fields: [String: String]
    let sha256: String?
    let byteCount: Int?

    static func metadata(_ properties: [String: Any]) -> ImageMetadataSnapshot {
        var fields: [String: String] = [:]
        let groups: [(String, [String])] = [
            ("{TIFF}", ["Make", "Model", "Software", "Orientation"]),
            ("{Exif}", ["ExposureTime", "FNumber", "ISOSpeedRatings", "ShutterSpeedValue",
                          "ApertureValue", "ExposureBiasValue", "FocalLength", "LensModel",
                          "PixelXDimension", "PixelYDimension", "ExposureMode", "WhiteBalance"])
        ]
        for (group, names) in groups {
            let dictionary = properties[group] as? [String: Any] ?? [:]
            for name in names {
                if let value = dictionary[name] {
                    fields[name] = String(String(describing: value).prefix(256))
                }
            }
        }
        for name in ["PixelWidth", "PixelHeight", "Orientation"] {
            if let value = properties[name] { fields[name] = String(String(describing: value).prefix(256)) }
        }
        return ImageMetadataSnapshot(fields: fields, sha256: nil, byteCount: nil)
    }

    static func file(_ data: Data) -> ImageMetadataSnapshot {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any] } ?? [:]
        return ImageMetadataSnapshot(fields: metadata(properties).fields,
                                     sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                     byteCount: data.count)
    }
}

struct CaptureSample: Codable {
    let live: ImageMetadataSnapshot
    let encoded: ImageMetadataSnapshot
}

struct CapturedPhoto {
    let data: Data
    let diagnostic: CaptureSample
}

struct FrameDiagnostic: Codable {
    let index: Int
    let requestedSeconds: Double
    let requestedISO: Double
    let deviceSeconds: Double
    let deviceISO: Double
    let plannedStackCount: Int
    let usedRetry: Bool
    let captures: [CaptureSample]
    let beforeSave: ImageMetadataSnapshot
    var saved: ImageMetadataSnapshot?
    var savedBytesMatch: Bool?
}

struct CaptureDiagnosticReport: Codable {
    var schemaVersion: Int = 1
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let mode: String
    let lens: String
    var frames: [FrameDiagnostic]

    // Best effort: a failed diagnostic must never lose or block a saved bracket.
    func save(for bracket: StoredBracket, in store: BracketStore) {
        var report = self
        let files = store.files(for: bracket)
        for i in report.frames.indices where i < files.count {
            if let data = try? Data(contentsOf: files[i]) {
                let saved = ImageMetadataSnapshot.file(data)
                report.frames[i].saved = saved
                report.frames[i].savedBytesMatch = saved.sha256 == report.frames[i].beforeSave.sha256
            }
        }
        if let data = try? JSONEncoder().encode(report), data.count <= 256 * 1024 {
            try? store.saveDiagnostics(data, for: bracket)
        }
    }
}
