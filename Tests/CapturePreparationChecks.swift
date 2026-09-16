import Foundation

@main
struct CapturePreparationChecks {
    @MainActor
    static func main() async throws {
        let preparation = CapturePreparation()
        var calls = 0
        let started = ContinuousClock.now
        precondition(preparation.start {
            precondition(started.duration(to: .now) >= .milliseconds(1500), "Capture started early")
            calls += 1
        })
        precondition(!preparation.start { calls += 100 }, "Repeated taps must not schedule another shot")
        try await Task.sleep(nanoseconds: 1_750_000_000)
        precondition(calls == 1)
        precondition(started.duration(to: .now) >= .milliseconds(1500))
        precondition(preparation.start { calls += 100 })
        preparation.cancel()
        precondition(preparation.start { calls += 1 })
        try await Task.sleep(nanoseconds: 1_750_000_000)
        precondition(calls == 2, "A cancelled delay must not fire or cancel its replacement")
        precondition(preparation.start { calls += 100 })
        preparation.cancel()
        try await Task.sleep(nanoseconds: 1_750_000_000)
        precondition(calls == 2, "Backgrounding must cancel the pending capture")
        print("Capture preparation checks passed: timing, repeat taps, cancellation and restart.")
    }
}
