import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers

/// Mean-stacks N same-exposure JPEG frames into one low-noise JPEG.
/// Tripod assumed, so no alignment pass. Averaging cuts noise by √N, and the
/// frame-to-frame noise dithers the ISP's tone-curve contours, so the
/// re-encoded gradients come out smoother than any single input frame
/// (this is what fixes the concentric-ring banding around lights).
enum FrameStacker {

    enum StackError: LocalizedError {
        case decodeFailed, encodeFailed
        var errorDescription: String? {
            switch self {
            case .decodeFailed: return "Could not decode frames for stacking."
            case .encodeFailed: return "Could not encode the stacked frame."
            }
        }
    }

    /// Chunk size (in Float elements) for the u8→float→accumulate loop, to
    /// keep peak memory modest on a 12 MP image.
    private static let chunk = 4_000_000

    static func averageJPEGs(_ datas: [Data], jpegQuality: Double = 0.95) throws -> Data {
        guard let first = datas.first else { throw StackError.decodeFailed }
        if datas.count == 1 { return first }

        guard let firstImage = decode(first) else { throw StackError.decodeFailed }
        let width = firstImage.width
        let height = firstImage.height
        let count = width * height * 4

        var accumulator = [Float](repeating: 0, count: count)
        var pixels = [UInt8](repeating: 0, count: count)
        var floatChunk = [Float](repeating: 0, count: min(chunk, count))

        var used = 0
        for data in datas {
            guard let image = decode(data),
                  image.width == width, image.height == height,
                  render(image, into: &pixels, width: width, height: height) else { continue }

            var offset = 0
            while offset < count {
                let n = min(chunk, count - offset)
                pixels.withUnsafeBufferPointer { src in
                    vDSP_vfltu8(src.baseAddress! + offset, 1,
                                &floatChunk, 1, vDSP_Length(n))
                }
                accumulator.withUnsafeMutableBufferPointer { acc in
                    vDSP_vadd(acc.baseAddress! + offset, 1,
                              floatChunk, 1,
                              acc.baseAddress! + offset, 1, vDSP_Length(n))
                }
                offset += n
            }
            used += 1
        }
        guard used > 0 else { throw StackError.decodeFailed }

        var divisor = Float(used)
        vDSP_vsdiv(accumulator, 1, &divisor, &accumulator, 1, vDSP_Length(count))
        vDSP_vfixru8(accumulator, 1, &pixels, 1, vDSP_Length(count))

        guard let outImage = makeImage(from: pixels, width: width, height: height) else {
            throw StackError.encodeFailed
        }
        return try encodeJPEG(outImage, quality: jpegQuality, copyingMetadataFrom: first)
    }

    // MARK: - Helpers

    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func render(_ image: CGImage,
                               into buffer: inout [UInt8],
                               width: Int, height: Int) -> Bool {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
        return buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
    }

    private static func makeImage(from buffer: [UInt8],
                                  width: Int, height: Int) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(buffer) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Encodes at a quality WE control (Apple never exposed this for direct
    /// capture) and carries over the first frame's EXIF/orientation.
    private static func encodeJPEG(_ image: CGImage,
                                   quality: Double,
                                   copyingMetadataFrom original: Data) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw StackError.encodeFailed
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        if let source = CGImageSourceCreateWithData(original as CFData, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for (key, value) in metadata
            where key != kCGImagePropertyPixelWidth && key != kCGImagePropertyPixelHeight {
                properties[key] = value
            }
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw StackError.encodeFailed }
        return output as Data
    }
}
