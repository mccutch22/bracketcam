import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import UniformTypeIdentifiers

/// Aligned mean-stack of N same-exposure JPEG frames into one low-noise JPEG.
///
/// Two alignment paths:
///
/// **Tripod** (verified working): frames drift by fractions of a pixel
/// (structure settling, OIS repositioning), so one global translational
/// search per frame (±4 px + half-pixel refine) before averaging. The search
/// always includes zero shift, so alignment can never do worse than the
/// unaligned average.
///
/// **Handheld** (HDR+-style): hand motion adds rotation, perspective and
/// rolling-shutter wobble that no single global shift can fix. Each frame
/// gets: (1) a coarse-to-fine global search over a generous radius, (2) a
/// per-tile refinement around the global shift — local translations
/// approximate rotation/parallax well, and since a rotation is a *linearly
/// varying* shift field, bilinearly interpolating the per-tile shifts
/// reproduces it exactly — and (3) robust merging: tiles whose residual vs
/// the reference stays high after alignment (something moved, or alignment
/// failed) are rejected rather than averaged in, so worst case a region
/// falls back to the reference frame instead of ghosting. The reference is
/// the *sharpest* frame of the burst (gradient energy on thumbnails), not
/// blindly frame 0, which may carry shutter-press wobble.
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

    /// Tripod: max integer pixels of drift searched in each direction.
    private static let searchRadius = 4
    /// Handheld: global drift between shots can reach dozens of pixels.
    private static let handheldGlobalRadius = 16
    /// Handheld: per-tile search radius around the global shift (covers the
    /// shift variation across the frame from small rotations).
    private static let handheldTileRadius = 5

    static func averageJPEGs(_ datas: [Data],
                             jpegQuality: Double = 0.95,
                             handheld: Bool = false) throws -> Data {
        guard let first = datas.first else { throw StackError.decodeFailed }
        if datas.count == 1 { return first }

        if handheld {
            return try handheldStack(datas, jpegQuality: jpegQuality)
        }

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

    // MARK: - Handheld stacking (tile-aligned, motion-robust)

    private static func handheldStack(_ datas: [Data], jpegQuality: Double) throws -> Data {
        // Reference = sharpest frame of the burst, judged on cheap thumbnails.
        let refIndex = sharpestIndex(of: datas)
        guard let (ref, width, height) = decodeRGBA8(datas[refIndex]) else {
            throw StackError.decodeFailed
        }
        let count = width * height * 4
        let pixelCount = width * height

        // Per-pixel weights (shared across channels) let rejected tiles simply
        // not contribute: each pixel divides by its own accumulated weight.
        var acc = [Float](repeating: 0, count: count)
        var wacc = [Float](repeating: 0, count: pixelCount)
        ref.withUnsafeBufferPointer { src in
            let p = src.baseAddress!
            acc.withUnsafeMutableBufferPointer { ab in
                let a = ab.baseAddress!
                for i in 0..<count { a[i] += Float(p[i]) }   // unresampled: stays crisp
            }
        }
        wacc.withUnsafeMutableBufferPointer { wb in
            let wp = wb.baseAddress!
            for i in 0..<pixelCount { wp[i] = 1 }
        }

        let nx = max(3, min(10, width / 500))
        let ny = max(3, min(10, height / 500))

        for (index, data) in datas.enumerated() where index != refIndex {
            guard let (buf, w, h) = decodeRGBA8(data), w == width, h == height else { continue }

            var shiftX = [Double](repeating: 0, count: nx * ny)
            var shiftY = [Double](repeating: 0, count: nx * ny)
            var score = [Double](repeating: 0, count: nx * ny)

            ref.withUnsafeBufferPointer { rb in
                buf.withUnsafeBufferPointer { cb in
                    let rp = rb.baseAddress!, cp = cb.baseAddress!
                    let g = coarseFineShift(rp, cp, width: width, height: height)
                    for ty in 0..<ny {
                        for tx in 0..<nx {
                            let x0 = tx * width / nx,  x1 = (tx + 1) * width / nx
                            let y0 = ty * height / ny, y1 = (ty + 1) * height / ny
                            let t = tileShift(rp, cp, width: width, height: height,
                                              globalX: g.0, globalY: g.1,
                                              x0: x0, x1: x1, y0: y0, y1: y1)
                            let i = ty * nx + tx
                            shiftX[i] = t.0
                            shiftY[i] = t.1
                            score[i] = t.2
                        }
                    }
                }
            }

            // Robust merge: a tile whose best residual is way above this
            // frame's median residual is a mover or a failed alignment —
            // rejecting it costs a little noise reduction there, averaging
            // it in would cost a ghost.
            let sorted = score.sorted()
            let median = sorted[sorted.count / 2]
            let threshold = max(median * 2.5, 3.0)   // mean abs diff per sample (0–255)
            var tileW = [Float](repeating: 1, count: nx * ny)
            var rejected = 0
            for i in 0..<(nx * ny) where score[i] > threshold {
                tileW[i] = 0
                rejected += 1
            }
            if rejected * 10 > nx * ny * 6 { continue }   // >60% bad: skip the frame

            accumulateWarped(buf, into: &acc, weights: &wacc,
                             width: width, height: height,
                             shiftX: shiftX, shiftY: shiftY, tileWeights: tileW,
                             nx: nx, ny: ny)
        }

        var pixels = [UInt8](repeating: 0, count: count)
        acc.withUnsafeBufferPointer { ab in
            wacc.withUnsafeBufferPointer { wb in
                pixels.withUnsafeMutableBufferPointer { pb in
                    let a = ab.baseAddress!, wp = wb.baseAddress!, px = pb.baseAddress!
                    for p in 0..<pixelCount {
                        let inv = 1.0 / max(wp[p], 0.001)
                        let i = p * 4
                        px[i]     = clamp8(a[i] * inv)
                        px[i + 1] = clamp8(a[i + 1] * inv)
                        px[i + 2] = clamp8(a[i + 2] * inv)
                    }
                }
            }
        }

        guard let outImage = makeImage(from: pixels, width: width, height: height) else {
            throw StackError.encodeFailed
        }
        return try encodeJPEG(outImage, quality: jpegQuality,
                              copyingMetadataFrom: datas[refIndex])
    }

    private static func clamp8(_ v: Float) -> UInt8 {
        UInt8(min(255, max(0, v.rounded())))
    }

    /// Index of the burst frame with the highest gradient energy, measured on
    /// ~512 px thumbnails — a blurry reference caps the whole stack's
    /// sharpness, and frame 0 often carries shutter-press wobble.
    private static func sharpestIndex(of datas: [Data]) -> Int {
        var best = 0
        var bestScore = -1.0
        for (i, data) in datas.enumerated() {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 512,
                  ] as CFDictionary),
                  let (buf, w, h) = decodeRGBA8(image: thumb) else { continue }
            var s = 0.0
            buf.withUnsafeBufferPointer { bp in
                let p = bp.baseAddress!
                var y = 1
                while y < h - 1 {
                    var x = 1
                    while x < w - 1 {
                        let i = (y * w + x) * 4 + 1   // green channel
                        s += abs(Double(p[i]) - Double(p[i - 4]))
                           + abs(Double(p[i]) - Double(p[i - w * 4]))
                        x += 2
                    }
                    y += 2
                }
            }
            if s > bestScore {
                bestScore = s
                best = i
            }
        }
        return best
    }

    /// Global translation over the handheld radius: coarse pass every 4 px,
    /// fine pass at 1 px around the winner, then half-pixel refine. Uses a
    /// coarser sample grid than the tile searches — the tiles do the precise
    /// work; this only needs to get them into range.
    private static func coarseFineShift(_ ref: UnsafePointer<UInt8>,
                                        _ cur: UnsafePointer<UInt8>,
                                        width: Int, height: Int) -> (Double, Double) {
        let step = max(4, min(width, height) / 120)
        func eval(_ sx: Double, _ sy: Double) -> Double {
            meanSAD(ref, cur, width: width, height: height,
                    shiftX: sx, shiftY: sy,
                    x0: 0, x1: width, y0: 0, y1: height, step: step)
        }
        var best = (x: 0.0, y: 0.0)
        var bestScore = eval(0, 0)

        let r = handheldGlobalRadius
        for dy in stride(from: -r, through: r, by: 4) {
            for dx in stride(from: -r, through: r, by: 4) where !(dx == 0 && dy == 0) {
                let s = eval(Double(dx), Double(dy))
                if s < bestScore { bestScore = s; best = (Double(dx), Double(dy)) }
            }
        }
        let cx = best.x, cy = best.y
        for dy in -3...3 {
            for dx in -3...3 where !(dx == 0 && dy == 0) {
                let s = eval(cx + Double(dx), cy + Double(dy))
                if s < bestScore { bestScore = s; best = (cx + Double(dx), cy + Double(dy)) }
            }
        }
        let hx = best.x, hy = best.y
        for fy in [-0.5, 0.0, 0.5] {
            for fx in [-0.5, 0.0, 0.5] where !(fx == 0 && fy == 0) {
                let s = eval(hx + fx, hy + fy)
                if s < bestScore { bestScore = s; best = (hx + fx, hy + fy) }
            }
        }
        return (best.x, best.y)
    }

    /// Best shift for one tile, searched around the global shift. Returns
    /// (shiftX, shiftY, residual) where residual is the mean abs difference
    /// per sample at the best shift — the rejection signal.
    private static func tileShift(_ ref: UnsafePointer<UInt8>,
                                  _ cur: UnsafePointer<UInt8>,
                                  width: Int, height: Int,
                                  globalX: Double, globalY: Double,
                                  x0: Int, x1: Int, y0: Int, y1: Int) -> (Double, Double, Double) {
        let step = max(2, min(x1 - x0, y1 - y0) / 30)
        func eval(_ sx: Double, _ sy: Double) -> Double {
            meanSAD(ref, cur, width: width, height: height,
                    shiftX: sx, shiftY: sy,
                    x0: x0, x1: x1, y0: y0, y1: y1, step: step)
        }
        let baseX = globalX.rounded(), baseY = globalY.rounded()
        var best = (x: baseX, y: baseY)
        var bestScore = eval(baseX, baseY)

        let r = handheldTileRadius
        for dy in -r...r {
            for dx in -r...r where !(dx == 0 && dy == 0) {
                let s = eval(baseX + Double(dx), baseY + Double(dy))
                if s < bestScore { bestScore = s; best = (baseX + Double(dx), baseY + Double(dy)) }
            }
        }
        let hx = best.x, hy = best.y
        for fy in [-0.5, 0.0, 0.5] {
            for fx in [-0.5, 0.0, 0.5] where !(fx == 0 && fy == 0) {
                let s = eval(hx + fx, hy + fy)
                if s < bestScore { bestScore = s; best = (hx + fx, hy + fy) }
            }
        }
        return (best.x, best.y, bestScore)
    }

    /// Warp `buffer` by the bilinearly interpolated per-tile shift field and
    /// accumulate with the interpolated per-tile weights (smooth interpolation
    /// of both prevents seams at tile boundaries).
    private static func accumulateWarped(_ buffer: [UInt8],
                                         into acc: inout [Float],
                                         weights wacc: inout [Float],
                                         width: Int, height: Int,
                                         shiftX: [Double], shiftY: [Double],
                                         tileWeights: [Float],
                                         nx: Int, ny: Int) {
        // Precompute each pixel's position in tile-grid space.
        var gxIndex = [Int](repeating: 0, count: width)
        var gxFrac = [Double](repeating: 0, count: width)
        for x in 0..<width {
            var g = (Double(x) + 0.5) / Double(width) * Double(nx) - 0.5
            g = min(max(g, 0), Double(nx - 1))
            let i = min(Int(g), max(nx - 2, 0))
            gxIndex[x] = i
            gxFrac[x] = nx > 1 ? min(max(g - Double(i), 0), 1) : 0
        }
        var gyIndex = [Int](repeating: 0, count: height)
        var gyFrac = [Double](repeating: 0, count: height)
        for y in 0..<height {
            var g = (Double(y) + 0.5) / Double(height) * Double(ny) - 0.5
            g = min(max(g, 0), Double(ny - 1))
            let i = min(Int(g), max(ny - 2, 0))
            gyIndex[y] = i
            gyFrac[y] = ny > 1 ? min(max(g - Double(i), 0), 1) : 0
        }

        buffer.withUnsafeBufferPointer { src in
            let p = src.baseAddress!
            acc.withUnsafeMutableBufferPointer { ab in
                wacc.withUnsafeMutableBufferPointer { wb in
                    let a = ab.baseAddress!, wp = wb.baseAddress!
                    for y in 0..<height {
                        let iy = gyIndex[y], fy = gyFrac[y]
                        let rowLo = iy * nx, rowHi = min(iy + 1, ny - 1) * nx
                        for x in 0..<width {
                            let ix = gxIndex[x], fx = gxFrac[x]
                            let ixHi = min(ix + 1, nx - 1)
                            let w00 = (1 - fx) * (1 - fy), w10 = fx * (1 - fy)
                            let w01 = (1 - fx) * fy,       w11 = fx * fy

                            let wgt = Double(tileWeights[rowLo + ix]) * w00
                                    + Double(tileWeights[rowLo + ixHi]) * w10
                                    + Double(tileWeights[rowHi + ix]) * w01
                                    + Double(tileWeights[rowHi + ixHi]) * w11
                            if wgt < 0.01 { continue }

                            let sx = shiftX[rowLo + ix] * w00 + shiftX[rowLo + ixHi] * w10
                                   + shiftX[rowHi + ix] * w01 + shiftX[rowHi + ixHi] * w11
                            let sy = shiftY[rowLo + ix] * w00 + shiftY[rowLo + ixHi] * w10
                                   + shiftY[rowHi + ix] * w01 + shiftY[rowHi + ixHi] * w11

                            let (r, g, b) = bilinear(p, width: width, height: height,
                                                     fx: Double(x) + sx, fy: Double(y) + sy)
                            let i = (y * width + x) * 4
                            let wf = Float(wgt)
                            a[i] += wf * r
                            a[i + 1] += wf * g
                            a[i + 2] += wf * b
                            wp[y * width + x] += wf
                        }
                    }
                }
            }
        }
    }

    /// Mean absolute RGB difference per sample over a subsampled grid within
    /// the given region, sampling `cur` bilinearly at the given shift.
    private static func meanSAD(_ ref: UnsafePointer<UInt8>,
                                _ cur: UnsafePointer<UInt8>,
                                width: Int, height: Int,
                                shiftX: Double, shiftY: Double,
                                x0: Int, x1: Int, y0: Int, y1: Int,
                                step: Int) -> Double {
        var sum = 0.0
        var samples = 0
        let xMin = max(x0, step), xMax = min(x1, width - step)
        let yMin = max(y0, step), yMax = min(y1, height - step)
        var y = yMin
        while y < yMax {
            var x = xMin
            while x < xMax {
                let (r, g, b) = bilinear(cur, width: width, height: height,
                                         fx: Double(x) + shiftX, fy: Double(y) + shiftY)
                let i = (y * width + x) * 4
                sum += abs(Double(r) - Double(ref[i]))
                     + abs(Double(g) - Double(ref[i + 1]))
                     + abs(Double(b) - Double(ref[i + 2]))
                samples += 1
                x += step
            }
            y += step
        }
        return samples > 0 ? sum / (3.0 * Double(samples)) : .greatestFiniteMagnitude
    }

    // MARK: - Tripod alignment (unchanged, verified working)

    /// Sub-pixel shift (sx, sy) such that sampling `cur` at (x+sx, y+sy) best
    /// matches `ref`. Coarse integer search then a half-pixel refine. Because
    /// the sign of the shift is decided by the search (not assumed), this is
    /// robust to coordinate-convention mistakes.
    private static func bestShift(_ ref: UnsafePointer<UInt8>,
                                  _ cur: UnsafePointer<UInt8>,
                                  width: Int, height: Int) -> (Double, Double) {
        let step = max(2, min(width, height) / 200)
        func eval(_ sx: Double, _ sy: Double) -> Double {
            meanSAD(ref, cur, width: width, height: height,
                    shiftX: sx, shiftY: sy,
                    x0: 0, x1: width, y0: 0, y1: height, step: step)
        }
        var best = (x: 0.0, y: 0.0)
        var bestScore = eval(0, 0)

        let r = searchRadius
        for dy in -r...r {
            for dx in -r...r where !(dx == 0 && dy == 0) {
                let s = eval(Double(dx), Double(dy))
                if s < bestScore { bestScore = s; best = (Double(dx), Double(dy)) }
            }
        }

        let baseX = best.x, baseY = best.y
        for hy in [-0.5, 0.0, 0.5] {
            for hx in [-0.5, 0.0, 0.5] where !(hx == 0 && hy == 0) {
                let s = eval(baseX + hx, baseY + hy)
                if s < bestScore { bestScore = s; best = (baseX + hx, baseY + hy) }
            }
        }
        return (best.x, best.y)
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
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return decodeRGBA8(image: image)
    }

    private static func decodeRGBA8(image: CGImage) -> ([UInt8], Int, Int)? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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
    /// capture) and carries over the reference frame's EXIF/orientation.
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
