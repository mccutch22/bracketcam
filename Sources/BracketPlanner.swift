import Foundation

/// All tunable constants in one place. See CLAUDE.md for the reasoning.
enum Tuning {
    /// Hard ceiling on shutter time. Actual cap = min(this, device max).
    static let exposureCapSeconds: Double = 1.0

    /// Wait after committing a new exposure before firing, so the sensor and
    /// pipeline have settled.
    static let settleSeconds: Double = 0.35

    /// A frame is flagged "underexposed" if it falls short of its target
    /// exposure product by more than this many stops (device limits reached).
    static let underexposureToleranceStops: Double = 0.34

    /// Frames with exposures at or below this use .quality photo processing
    /// (full tone pipeline — no banding). Above it the stream runs too slowly
    /// for quality processing (it starves and times out), so those frames use
    /// .speed. The dark frames carry the window/highlight detail and are
    /// always short, so the frames that matter get the good pipeline.
    static let qualityProcessingMaxExposure: Double = 0.1

    /// The fixed exposure ladder, in EV relative to the scene meter, darkest
    /// first. -6 stands in for highlight protection: deep enough that window
    /// highlights survive in any realistic interior.
    static let ladderEVs: [Int] = [-6, -4, -2, 0, 2, 4]
}

/// Exposure limits of the active format, queried at runtime — never hardcoded.
struct DeviceExposureLimits {
    let minISO: Float
    let maxISO: Float
    let minDuration: Double   // seconds
    let maxDuration: Double   // seconds (already includes the frame-duration bound)

    /// The working shutter ceiling for every frame in the bracket.
    var cap: Double { min(Tuning.exposureCapSeconds, maxDuration) }
}

/// One planned frame of the bracket.
struct FramePlan: Identifiable {
    let label: String            // "-6" … "+4"
    let evFromMeter: Int
    let duration: Double         // seconds
    let iso: Float
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

/// The full plan, in capture order (darkest first).
struct BracketPlan {
    let frames: [FramePlan]
    let meterProduct: Double          // seconds x ISO from the scene meter
    let limits: DeviceExposureLimits

    var allAtBaseISO: Bool { frames.allSatisfy { $0.iso <= limits.minISO } }
    var plusFourUnderexposed: Bool {
        frames.first(where: { $0.evFromMeter == 4 })?.isUnderexposed ?? false
    }
}

enum BracketPlanner {

    /// Lowest-noise solution for a target exposure product P (seconds x ISO):
    /// stretch the shutter as long as the cap allows first, then raise ISO only
    /// for whatever exposure the shutter alone can't deliver. Tripod assumed.
    static func frame(ev: Int,
                      product: Double,
                      limits: DeviceExposureLimits) -> FramePlan {
        var duration = product / Double(limits.minISO)
        duration = min(max(duration, limits.minDuration), limits.cap)
        var iso = Float(product / duration)
        iso = min(max(iso, limits.minISO), limits.maxISO)
        let label = ev > 0 ? "+\(ev)" : "\(ev)"
        return FramePlan(label: label,
                         evFromMeter: ev,
                         duration: duration,
                         iso: iso,
                         targetProduct: product)
    }

    /// The fixed ladder, darkest first. meterProduct is the scene meter's
    /// T x ISO ("0 EV").
    static func plan(meterProduct: Double,
                     limits: DeviceExposureLimits) -> BracketPlan {
        let frames = Tuning.ladderEVs.map { ev in
            frame(ev: ev,
                  product: meterProduct * pow(2.0, Double(ev)),
                  limits: limits)
        }
        return BracketPlan(frames: frames,
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
