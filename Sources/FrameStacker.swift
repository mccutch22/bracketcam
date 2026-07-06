import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers

/// Aligned mean-stack of N same-exposure JPEG frames into one low-noise JPEG.
///
/// Plain averaging softens: even on a tripod the frames are shifted by
/// fractions of a pixel (structure settling, and the iPhone's OIS drifting
/// between shots), and averaging unregistered frames blurs. So each frame is
/// first aligned to the reference (frame 0) by a small translational search,
/// then averaged. This preserves detail while still cutting noise by ~√N and
/// dithering out the ISP's posterization contours (the ceiling-light rings).
///
/// The search always includes zero shift as a candidate and keeps whichever
/// shift best matches the reference, so alignment can never soften a frame
/// below the unaligned result — a safe default given this can't be profiled
/// on the authoring machine.
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

    /// Max integer pixels of drift searched in each direction. Tripod motion
    /// (incl. OIS) is small; beyond this the reference simply wins.
    private static let searchRadius = 4

    static func averageJPEGs(_ datas: [Data], jpegQuality: Double = 0.95) throws -> Data {
        guard let first = datas.first else { throw StackError.decodeFailed }
        if datas.count == 1 { return first }

        guard let (refBuffer, width, height) = decodeRGBA8(first) else {
            throw StackError.decodeFailed
        }
        let count = width * height * 4

        var accumulator = [Float](repeating: 0, count: count)
        accumulate(refBuffer, into: &accumulator, width: width, height: height,
                   shiftX: 0, shiftY: 0)
        var used = 1

        for data in datas.dropFirst() {
            guard let (buffer, w, h) = decodeRGBA8(data),
                  w == width, h == height else { continue }
            let (sx, sy) = refBuffer.withUnsafeBufferPointer { ref in
                buffer.withUnsafeBufferPointer { cur in
                    bestShift(ref.baseAddress!, cur.baseAddress!,
                              width: width, height: height)
                }
            }
            accumulate(buffer, into: &accumulator, width: width, height: height,
                       shiftX: sx, shiftY: sy)
            used += 1
        }

        var divisor = Float(used)
        var pixels = [UInt8](repeating: 0, count: count)
        vDSP_vsdiv(accumulator, 1, &divisor, &accumulator, 1, vDSP_Length(count))
        vDSP_vfixru8(accumulator, 1, &pixels, 1, vDSP_Length(count))

        guard let outImage = makeImage(from: pixels, width: width, height: height) else {
            throw StackError.encodeFailed
        }
        return try encodeJPEG(outImage, quality: jpegQuality, copyingMetadataFrom: first)
    }

    // MARK: - Alignment

    /// Sub-pixel shift (sx, sy) such that sampling `cur` at (x+sx, y+sy) best
    /// matches `ref`. Coarse integer search then a half-pixel refine. Because
    /// the sign of the shift is decided by the search (not assumed), this is
    /// robust to coordinate-convention mistakes.
    private static func bestShift(_ ref: UnsafePointer<UInt8>,
                                  _ cur: UnsafePointer<UInt8>,
                                  width: Int, height: Int) -> (Double, Double) {
        let step = max(2, min(width, height) / 200)   // subsampled SAD grid
        var best = (x: 0.0, y: 0.0)
        var bestSAD = sad(ref, cur, width: width, height: height,
                          shiftX: 0, shiftY: 0, step: step)

        let r = searchRadius
        for dy in -r...r {
            for dx in -r...r where !(dx == 0 && dy == 0) {
                let s = sad(ref, cur, width: width, height: height,
                            shiftX: Double(dx), shiftY: Double(dy), step: step)
                if s < bestSAD { bestSAD = s; best = (Double(dx), Double(dy)) }
            }
        }

        let baseX = best.x, baseY = best.y
        for hy in [-0.5, 0.0, 0.5] {
            for hx in [-0.5, 0.0, 0.5] where !(hx == 0 && hy == 0) {
                let s = sad(ref, cur, width: width, height: height,
                            shiftX: baseX + hx, shiftY: baseY + hy, step: step)
                if s < bestSAD { bestSAD = s; best = (baseX + hx, baseY + hy) }
            }
        }
        return (best.x, best.y)
    }

    /// Sum of absolute RGB differences over a subsampled grid, sampling `cur`
    /// bilinearly at the given shift.
    private static func sad(_ ref: UnsafePointer<UInt8>,
                            _ cur: UnsafePointer<UInt8>,
                            width: Int, height: Int,
                            shiftX: Double, shiftY: Double, step: Int) -> Double {
        var sum = 0.0
        var y = step
        while y < height - step {
            var x = step
            while x < width - step {
                let (r, g, b) = bilinear(cur, width: width, height: height,
                                         fx: Double(x) + shiftX, fy: Double(y) + shiftY)
                let i = (y * width + x) * 4
                sum += abs(Double(r) - Double(ref[i]))
                     + abs(Double(g) - Double(ref[i + 1]))
                     + abs(Double(b) - Double(ref[i + 2]))
                x += step
            }
            y += step
        }
        return sum
    }

    private static func accumulate(_ buffer: [UInt8],
                                   into accumulator: inout [Float],
                                   width: Int, height: Int,
                                   shiftX: Double, shiftY: Double) {
        buffer.withUnsafeBufferPointer { src in
            let p = src.baseAddress!
            accumulator.withUnsafeMutableBufferPointer { acc in
                let a = acc.baseAddress!
                if shiftX == 0 && shiftY == 0 {
                    // Exact pixels, no resampling — keeps the reference crisp.
                    for i in 0..<(width * height * 4) { a[i] += Float(p[i]) }
                    return
                }
                for y in 0..<height {
                    for x in 0..<width {
                        let (r, g, b) = bilinear(p, width: width, height: height,
                                                 fx: Double(x) + shiftX,
                                                 fy: Double(y) + shiftY)
                        let i = (y * width + x) * 4
                        a[i] += r; a[i + 1] += g; a[i + 2] += b
                    }
                }
            }
        }
    }

    private static func bilinear(_ p: UnsafePointer<UInt8>,
                                 width: Int, height: Int,
                                 fx: Double, fy: Double) -> (Float, Float, Float) {
        var x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let dx = Float(fx - Double(x0)), dy = Float(fy - Double(y0))
        var x1 = x0 + 1, y1 = y0 + 1
        x0 = min(max(x0, 0), width - 1);  x1 = min(max(x1, 0), width - 1)
        y0 = min(max(y0, 0), height - 1); y1 = min(max(y1, 0), height - 1)
        let i00 = (y0 * width + x0) * 4, i10 = (y0 * width + x1) * 4
        let i01 = (y1 * width + x0) * 4, i11 = (y1 * width + x1) * 4
        func lerp(_ c: Int) -> Float {
            let top = Float(p[i00 + c]) * (1 - dx) + Float(p[i10 + c]) * dx
            let bot = Float(p[i01 + c]) * (1 - dx) + Float(p[i11 + c]) * dx
            return top * (1 - dy) + bot * dy
        }
        return (lerp(0), lerp(1), lerp(2))
    }

    // MARK: - Decode / encode

    private static func decodeRGBA8(_ data: Data) -> ([UInt8], Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? (buffer, width, height) : nil
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
