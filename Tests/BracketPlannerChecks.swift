import Foundation

@main
struct BracketPlannerChecks {
    static func main() {
        let limits = DeviceExposureLimits(minISO: 32, maxISO: 2000,
                                          minDuration: 1.0 / 10000, maxDuration: 1)
        for stacked in [false, true] {
            let tripod = BracketPlanner.plan(meterProduct: 4, limits: limits, stacked: stacked)
            precondition(tripod.frames.map(\.evFromMeter) == [-6, -4, -2, 0, 2],
                         "Remove only the brightest tripod exposure in JPEG and RAW modes")
            precondition(tripod.frames.map(\.targetProduct) == [0.0625, 0.25, 1, 4, 16])
            let normal = tripod.frames[BracketPlanner.representativeIndex(frameCount: tripod.frames.count)]
            precondition(normal.evFromMeter == 0 && normal.targetProduct == tripod.meterProduct,
                         "The five-frame thumbnail must not accidentally use the -2 EV frame")
        }
        let hand = BracketPlanner.plan(meterProduct: 4, limits: limits, stacked: true, handheld: true)
        precondition(hand.frames.map(\.evFromMeter) == [-6, -3, 0, 3])
        precondition(hand.frames.allSatisfy { $0.stackCount == 1 && $0.duration <= 1.0 / 60 })
        precondition(hand.frames[BracketPlanner.representativeIndex(frameCount: 4)].evFromMeter == 0)
        let legacyEVs = [-6, -4, -2, 0, 2, 4]
        precondition(legacyEVs[BracketPlanner.representativeIndex(frameCount: 6)] == 0,
                     "Existing six-frame captures retain their normal-exposure thumbnails")
        let limited = DeviceExposureLimits(minISO: 32, maxISO: 32, minDuration: 0.0001, maxDuration: 0.1)
        let dark = BracketPlanner.plan(meterProduct: 4, limits: limited, stacked: false)
        precondition(dark.brightestUnderexposed, "Dark-scene warning follows the remaining brightest frame")
        print("Bracket planner checks passed: five tripod frames, four handheld frames, normal thumbnails and exposure warning.")
    }
}
