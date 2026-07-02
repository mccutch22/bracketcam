import Foundation

/// All tunable constants in one place. See CLAUDE.md for the reasoning behind each.
enum Tuning {
    /// Hard ceiling on shutter time. Actual cap = min(this, device max exposure duration).
    static let exposureCapSeconds: Double = 1.0

    /// Percentile of the luma histogram treated as the "diffuse highlight" level.
    /// Everything above this (speculars, light sources) is allowed to clip.
    static let highlightPercentile: Double = 0.995

    /// Safety margin (stops) the diffuse highlights are kept below the clip point.
    static let highlightMarginStops: Double = 1.0 / 3.0

    /// 8-bit luma value treated as "clipped". Slightly under 255 because the
    /// tone-curve shoulder compresses the top few code values.
    static let clipValue: Double = 250.0

    /// Approximate encoding gamma of the preview frames. Used to convert a
    /// histogram-value ratio into stops of linear exposure.
    static let displayGamma: Double = 2.2

    /// Wait after committing a new exposure before metering or firing, so the
    /// sensor and the video pipeline have settled (~10 frames at 30 fps).
    static let settleSeconds: Double = 0.35

    /// When the highlight percentile is pinned at the clip point we can't tell
    /// how far over it is, so we step the metering exposure down 1 stop and
    /// re-measure, at most this many times.
    static let maxHighlightSearchStops = 4

    /// A frame is flagged "underexposed" if it falls short of its target
    /// exposure product by more than this many stops (device limits reached).
    static let underexposureToleranceStops: Double = 0.34
}

/// Exposure limits of the active format, queried at runtime — never hardcoded.
struct DeviceExposureLimits {
    let minISO: Float
    let maxISO: Float
    let minDuration: Double   // seconds
    let maxDuration: Double   // seconds

    /// The working shutter ceiling for every frame in the bracket.
    var cap: Double { min(Tuning.exposureCapSeconds, maxDuration) }
}

/// One planned frame of the bracket.
struct FramePlan: Identifiable {
    let label: String            // "-2", "0", "+2", "+4", "HL"
    let evFromMeter: Double?     // nil for the highlight frame (it floats)
    let duration: Double         // seconds
    let iso: Float
    let isHighlight: Bool
    /// The exposure product (seconds x ISO) this frame was asked to reach.
    let targetProduct: Double

    var id: String { label }
    var achievedProduct: Double { duration * Double(iso) }
    /// Positive when the frame could not reach its target (hit ISO/shutter limits).
    var shortfallStops: Double {
        guard achievedProduct > 0, targetProduct > 0 else { return 0 }
        return log2(targetProduct / achievedProduct)
    }
    var isUnderexposed: Bool { shortfallStops > Tuning.underexposureToleranceStops }
}

/// The full 5-frame plan, in capture order (darkest first).
struct BracketPlan {
    let frames: [FramePlan]           // [HL, -2, 0, +2, +4]
    let meterProduct: Double          // seconds x ISO from the scene meter
    let limits: DeviceExposureLimits

    var allAtBaseISO: Bool { frames.allSatisfy { $0.iso <= limits.minISO } }
    var plusFourUnderexposed: Bool {
        frames.first(where: { $0.label == "+4" })?.isUnderexposed ?? false
    }
}

enum BracketPlanner {

    /// Lowest-noise solution for a target exposure product P (seconds x ISO):
    /// stretch the shutter as long as the cap allows first, then raise ISO only
    /// for whatever exposure the shutter alone can't deliver. Tripod assumed.
    static func frame(label: String,
                      ev: Double?,
                      product: Double,
                      limits: DeviceExposureLimits,
                      isHighlight: Bool = false) -> FramePlan {
        // Longest shutter this product needs at base ISO, clamped to the device.
        var duration = product / Double(limits.minISO)
        duration = min(max(duration, limits.minDuration), limits.cap)
        // ISO needed to make up the remainder, clamped to the device.
        var iso = Float(product / duration)
        iso = min(max(iso, limits.minISO), limits.maxISO)
        return FramePlan(label: label,
                         evFromMeter: ev,
                         duration: duration,
                         iso: iso,
                         isHighlight: isHighlight,
                         targetProduct: product)
    }

    /// The four meter-anchored frames at fixed 2-stop spacing, darkest first.
    /// meterProduct is the scene meter's T x ISO ("0 EV").
    static func anchoredFrames(meterProduct: Double,
                               limits: DeviceExposureLimits) -> [FramePlan] {
        [
            frame(label: "-2", ev: -2, product: meterProduct / 4, limits: limits),
            frame(label: "0",  ev: 0,  product: meterProduct,      limits: limits),
            frame(label: "+2", ev: 2,  product: meterProduct * 4,  limits: limits),
            frame(label: "+4", ev: 4,  product: meterProduct * 16, limits: limits),
        ]
    }

    /// Stops of exposure change that would put the measured highlight percentile
    /// exactly at (clip point − safety margin). Positive = highlights have
    /// headroom, negative = they must come down. The histogram is gamma-encoded,
    /// so the value ratio is converted to linear stops via displayGamma.
    static func highlightShiftStops(percentileValue v: Double) -> Double {
        guard v >= 1 else { return 0 }   // empty/black histogram: no adjustment
        let stopsToClip = Tuning.displayGamma * log2(Tuning.clipValue / v)
        return stopsToClip - Tuning.highlightMarginStops
    }

    /// The highlight-protected frame. `measuredProduct` is the exposure product
    /// of the frame the histogram was taken at; `shiftStops` comes from
    /// highlightShiftStops. CLAMP: never brighter than the -2 EV frame.
    static func highlightFrame(measuredProduct: Double,
                               shiftStops: Double,
                               meterProduct: Double,
                               limits: DeviceExposureLimits) -> FramePlan {
        var product = measuredProduct * pow(2.0, shiftStops)
        product = min(product, meterProduct / 4)   // the clamp
        return frame(label: "HL", ev: nil, product: product, limits: limits, isHighlight: true)
    }

    /// Full plan in capture order (darkest first) for display or capture.
    static func plan(meterProduct: Double,
                     highlightFrame hl: FramePlan,
                     limits: DeviceExposureLimits) -> BracketPlan {
        BracketPlan(frames: [hl] + anchoredFrames(meterProduct: meterProduct, limits: limits),
                    meterProduct: meterProduct,
                    limits: limits)
    }
}

/// Human-readable shutter time, photography style.
func shutterString(_ t: Double) -> String {
    guard t > 0 else { return "—" }
    if t >= 0.4 { return String(format: "%.1fs", t) }
    return "1/\(Int((1.0 / t).rounded()))"
}
