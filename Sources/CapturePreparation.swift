import Foundation

/// One cancellable settling period shared by screen and hardware shutter taps.
@MainActor
final class CapturePreparation {
    static let delayNanoseconds: UInt64 = 1_500_000_000
    private var task: Task<Void, Never>?

    @discardableResult
    func start(ready: @escaping @MainActor () -> Void) -> Bool {
        guard task == nil else { return false }
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.delayNanoseconds) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            ready()
        }
        return true
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
