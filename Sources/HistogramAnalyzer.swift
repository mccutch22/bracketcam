import AVFoundation
import CoreVideo

/// 256-bin luma histogram of a preview frame.
struct Histogram {
    let bins: [Int]     // 256 entries
    let total: Int

    /// The 8-bit luma value at the given cumulative percentile (0...1).
    func value(atPercentile p: Double) -> Double {
        guard total > 0 else { return 0 }
        let target = Double(total) * p
        var cumulative = 0
        for i in 0..<bins.count {
            cumulative += bins[i]
            if Double(cumulative) >= target { return Double(i) }
        }
        return 255
    }

    /// Fraction of pixels at or above the clip point (for the UI readout).
    var clippedFraction: Double {
        guard total > 0 else { return 0 }
        let clipBin = Int(Tuning.clipValue)
        let clipped = bins[clipBin...].reduce(0, +)
        return Double(clipped) / Double(total)
    }
}

/// Consumes video frames from AVCaptureVideoDataOutput and keeps a current
/// luma histogram. Works on the Y plane of 420f frames, subsampling every
/// 4th pixel in both dimensions, throttled to ~6 updates/sec.
final class HistogramAnalyzer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let lock = NSLock()
    private var _latest: Histogram?
    private var lastUpdate: CFAbsoluteTime = 0

    /// Most recent histogram, safe to read from any thread.
    var latest: Histogram? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    /// Called on the video queue after each new histogram.
    var onUpdate: ((Histogram) -> Void)?

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastUpdate > 0.15 else { return }
        lastUpdate = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var bins = [Int](repeating: 0, count: 256)
        var total = 0
        var y = 0
        while y < height {
            let row = ptr + y * rowBytes
            var x = 0
            while x < width {
                bins[Int(row[x])] += 1
                total += 1
                x += 4
            }
            y += 4
        }

        let histogram = Histogram(bins: bins, total: total)
        lock.lock()
        _latest = histogram
        lock.unlock()
        onUpdate?(histogram)
    }
}
