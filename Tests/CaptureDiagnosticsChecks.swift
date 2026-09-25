import Foundation
import ImageIO
import CoreGraphics

@main struct CaptureDiagnosticsChecks {
    static func main() throws {
        let properties: [String: Any] = ["{TIFF}": ["Make": "Apple", "Model": "iPhone", "Private": "omit"],
            "{Exif}": ["ExposureTime": 0.01, "FNumber": 2.4, "ISOSpeedRatings": [80], "MakerNote": "omit"],
            "{GPS}": ["Latitude": 40.0]]
        let live = ImageMetadataSnapshot.metadata(properties)
        precondition(live.fields["ExposureTime"] == "0.01")
        precondition(live.fields["Make"] == "Apple")
        precondition(live.fields["Latitude"] == nil && live.fields["MakerNote"] == nil)
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        let data = output as Data
        let encoded = ImageMetadataSnapshot.file(data)
        precondition(encoded.fields["ExposureTime"] == "0.01")
        precondition(encoded.sha256?.count == 64 && encoded.byteCount == data.count)
        precondition(encoded.sha256 == ImageMetadataSnapshot.file(data).sha256)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BracketStore(root: root)
        let stack = try store.save(imageDatas: [data, data], setName: "Diagnostic", isRaw: false)
        let frames = (1...2).map { FrameDiagnostic(index: $0, requestedSeconds: 0.01, requestedISO: 80,
            deviceSeconds: 0.01, deviceISO: 80, plannedStackCount: 1, usedRetry: false,
            captures: [CaptureSample(live: live, encoded: encoded)], beforeSave: encoded) }
        let report = CaptureDiagnosticReport(appVersion: "test", appBuild: "test", osVersion: "test", mode: "handheld", lens: "0.5x", frames: frames)
        report.save(for: stack, in: store)
        let reloaded = try JSONDecoder().decode(CaptureDiagnosticReport.self, from: store.diagnostics(for: stack)!)
        precondition(reloaded.frames.allSatisfy { $0.savedBytesMatch == true })
        let original = try Data(contentsOf: store.files(for: stack)[0])
        precondition(original == data)
        try Data([0,1,2]).write(to: store.files(for: stack)[0])
        report.save(for: stack, in: store)
        let changed = try JSONDecoder().decode(CaptureDiagnosticReport.self, from: store.diagnostics(for: stack)!)
        precondition(changed.frames[0].savedBytesMatch == false && changed.frames[1].savedBytesMatch == true)
        precondition(ImageMetadataSnapshot.file(Data([0])).fields.isEmpty)
        print("Capture diagnostics: metadata selection, JPEG reading, original preservation, persisted reports, and changed-byte detection passed.")
    }
}
