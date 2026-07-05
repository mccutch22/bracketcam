import AVFoundation
import UIKit

enum CameraError: LocalizedError {
    case noCamera
    case cannotAddIO
    case noImageData
    case captureTimedOut

    var errorDescription: String? {
        switch self {
        case .noCamera:        return "No back camera found."
        case .cannotAddIO:     return "Could not configure the capture session."
        case .noImageData:     return "The captured photo contained no image data."
        case .captureTimedOut: return "The camera did not deliver the photo in time."
        }
    }
}

/// Guards a continuation against being resumed twice when a completion
/// handler races a watchdog timeout.
private final class ResumeGuard {
    private let lock = NSLock()
    private var resumed = false
    func tryResume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if resumed { return false }
        resumed = true
        return true
    }
}

/// The physical back cameras the user can pick from. Real estate work almost
/// always wants the ultra wide, so it is the default when the phone has one.
enum Lens: String, CaseIterable, Identifiable {
    case ultraWide = "0.5×"
    case wide = "1×"
    case tele = "Tele"   // 2×/2.5×/3×/5× depending on the phone

    var id: String { rawValue }
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide:      return .builtInWideAngleCamera
        case .tele:      return .builtInTelephotoCamera
        }
    }
}

final class CameraManager: NSObject, ObservableObject {

    enum Status: Equatable {
        case initializing
        case denied
        case failed(String)
        case ready
        case capturing(String)
        case saving
    }

    // MARK: - Published UI state (main thread only)
    @Published var status: Status = .initializing
    @Published var plan: BracketPlan?
    @Published var focusLocked = false
    @Published var selfTimerEnabled = false
    @Published var countdown: Int?
    @Published var lastSavedAlbum: String?
    @Published var errorMessage: String?
    @Published var availableLenses: [Lens] = []
    @Published var currentLens: Lens = .wide
    @Published var zoomFactor: CGFloat = 1.0

    /// RAW (DNG) skips the ISP entirely — no processing banding, 12-bit
    /// gradients, true long exposures — at ~25 MB/frame and a Lightroom
    /// conversion step. Default OFF: stacked JPG mode covers normal work.
    @Published var rawEnabled: Bool = UserDefaults.standard.object(forKey: "BracketCam.raw") as? Bool ?? false {
        didSet { UserDefaults.standard.set(rawEnabled, forKey: "BracketCam.raw") }
    }

    let session = AVCaptureSession()

    // MARK: - Private
    private let sessionQueue = DispatchQueue(label: "BracketCam.session")
    private var device: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var pinchStartZoom: CGFloat = 1.0
    private let photoOutput = AVCapturePhotoOutput()
    private var limits: DeviceExposureLimits?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var planTimer: Timer?
    private var isCapturing = false

    private let inflightLock = NSLock()
    private var inflight: [Int64: CheckedContinuation<Data, Error>] = [:]

    private static let setNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    // MARK: - Lifecycle

    func start() {
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else {
                await MainActor.run { self.status = .denied }
                return
            }
            do {
                try await configureSession()
                await MainActor.run {
                    self.status = .ready
                    // The live plan readout is driven by a simple timer now
                    // (it only needs the current auto-exposure meter values).
                    self.planTimer = Timer.scheduledTimer(withTimeInterval: 0.5,
                                                          repeats: true) { [weak self] _ in
                        self?.refreshLivePlan()
                    }
                }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    private func configureSession() async throws {
        try await onSessionQueue { [self] in
            // Discover which back lenses this phone has.
            let lenses = Lens.allCases.filter {
                AVCaptureDevice.default($0.deviceType, for: .video, position: .back) != nil
            }
            // Ultra wide is the real-estate default when available.
            guard let startLens = lenses.first,
                  let device = AVCaptureDevice.default(startLens.deviceType,
                                                       for: .video,
                                                       position: .back) else {
                throw CameraError.noCamera
            }
            self.device = device

            session.beginConfiguration()
            session.sessionPreset = .inputPriority

            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.cannotAddIO }
            session.addInput(input)
            self.videoInput = input

            guard session.canAddOutput(photoOutput) else { throw CameraError.cannotAddIO }
            session.addOutput(photoOutput)

            session.commitConfiguration()

            // Zero-shutter-lag assembles the "photo" from recently buffered
            // preview frames instead of doing a fresh exposure — poison for
            // manual bracketing, where each shot must be exposed with the
            // exact committed shutter/ISO. Force a real exposure per frame.
            if photoOutput.isZeroShutterLagSupported {
                photoOutput.isZeroShutterLagEnabled = false
            }

            try configureActiveDevice()

            session.startRunning()

            DispatchQueue.main.async {
                self.availableLenses = lenses
                self.currentLens = startLens
            }
        }
    }

    /// Format selection, default modes, limits, and photo-output setup for the
    /// current `device`. Runs on the session queue; used at startup and after
    /// every lens switch.
    private func configureActiveDevice() throws {
        guard let device else { return }

        // Format selection. The shutter cap is min(1 s, device max), so any
        // format reaching the cap is exposure-equivalent for our purposes —
        // among those, pick by photo resolution, then field of view, then
        // video (preview) resolution. v2 picked purely by maxExposureDuration,
        // which landed on a tiny cropped video format: pixelated, soft,
        // narrow preview. Queried at runtime, never hardcoded.
        func maxPhotoPixels(_ f: AVCaptureDevice.Format) -> Int {
            f.supportedMaxPhotoDimensions
                .map { Int($0.width) * Int($0.height) }
                .max() ?? 0
        }
        func videoPixels(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Int(d.width) * Int(d.height)
        }
        // A photo's exposure can never exceed one video frame, so the real
        // shutter ceiling of a format is min(maxExposureDuration, longest
        // supported frame duration). Ignoring the frame bound silently capped
        // every exposure at the streaming frame rate (~1/15 s) in v3.
        func maxFrameDuration(_ f: AVCaptureDevice.Format) -> Double {
            f.videoSupportedFrameRateRanges
                .map { $0.maxFrameDuration.seconds }
                .max() ?? (1.0 / 30.0)
        }
        func effectiveMaxExposure(_ f: AVCaptureDevice.Format) -> Double {
            // 5% under the frame bound: the sensor needs readout time between
            // frames, and demanding exposure == frame duration starved the
            // pipeline (hangs / failed captures in v5).
            min(f.maxExposureDuration.seconds, maxFrameDuration(f) * 0.95)
        }
        let deviceMaxExposure = device.formats
            .map { effectiveMaxExposure($0) }
            .max() ?? 0
        let neededExposure = min(Tuning.exposureCapSeconds, deviceMaxExposure) - 0.001
        let reachingCap = device.formats.filter {
            effectiveMaxExposure($0) >= neededExposure
        }
        let pool = reachingCap.isEmpty ? device.formats : reachingCap
        let best = pool.max { a, b in
            if maxPhotoPixels(a) != maxPhotoPixels(b) {
                return maxPhotoPixels(a) < maxPhotoPixels(b)
            }
            if a.videoFieldOfView != b.videoFieldOfView {
                return a.videoFieldOfView < b.videoFieldOfView
            }
            return videoPixels(a) < videoPixels(b)
        }

        try device.lockForConfiguration()
        if let best { device.activeFormat = best }
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.videoZoomFactor = 1.0
        device.unlockForConfiguration()

        let format = device.activeFormat
        self.limits = DeviceExposureLimits(minISO: format.minISO,
                                           maxISO: format.maxISO,
                                           minDuration: format.minExposureDuration.seconds,
                                           maxDuration: effectiveMaxExposure(format))

        // Full processing: .speed produced visible banding in bright
        // gradients (simpler tone pipeline). With custom exposure iOS skips
        // the multi-frame merges anyway, and the capture watchdogs + fast
        // retry protect against slow processing at 1 fps.
        photoOutput.maxPhotoQualityPrioritization = .quality
        if let dims = format.supportedMaxPhotoDimensions
            .max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = dims
        }

        self.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device,
                                                                       previewLayer: nil)

        DispatchQueue.main.async {
            self.zoomFactor = 1.0
            self.focusLocked = false
        }
    }

    // MARK: - Lens switching & zoom

    func selectLens(_ lens: Lens) {
        guard lens != currentLens, !isCapturing else { return }
        sessionQueue.async { [self] in
            guard let newDevice = AVCaptureDevice.default(lens.deviceType,
                                                          for: .video,
                                                          position: .back) else { return }
            let oldInput = videoInput
            var switched = false

            session.beginConfiguration()
            if let oldInput { session.removeInput(oldInput) }
            if let input = try? AVCaptureDeviceInput(device: newDevice),
               session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
                device = newDevice
                switched = true
            } else if let oldInput, session.canAddInput(oldInput) {
                session.addInput(oldInput)   // roll back
            }
            session.commitConfiguration()

            if switched {
                try? configureActiveDevice()
                DispatchQueue.main.async { self.currentLens = lens }
            } else {
                DispatchQueue.main.async { self.errorMessage = "Could not switch lens." }
            }
        }
    }

    /// Digital zoom (a crop — it applies to the saved photos too).
    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [self] in
            guard let device else { return }
            let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 10)
            let clamped = min(max(factor, 1), maxZoom)
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.zoomFactor = clamped }
            } catch { }
        }
    }

    func pinchBegan() { pinchStartZoom = zoomFactor }
    func pinchChanged(_ scale: CGFloat) { setZoom(pinchStartZoom * scale) }

    // MARK: - Live plan (preview readout)

    /// Recomputes the displayed plan from the current auto-exposure meter.
    private func refreshLivePlan() {
        guard !isCapturing, let device, let limits else { return }
        let meterProduct = device.exposureDuration.seconds * Double(device.iso)
        guard meterProduct > 0 else { return }
        plan = BracketPlanner.plan(meterProduct: meterProduct,
                                   limits: limits,
                                   stacked: !rawEnabled)
    }

    // MARK: - Tap to focus / meter

    /// point is in capture-device coordinates (0...1), from the preview layer.
    func focusAndMeter(at point: CGPoint) {
        sessionQueue.async { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                }
                // Single-scan AF: the lens converges once, then holds position.
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.focusLocked = true }
            } catch { }
        }
    }

    func resetFocus() {
        sessionQueue.async { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                let center = CGPoint(x: 0.5, y: 0.5)
                if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.focusLocked = false }
            } catch { }
        }
    }

    // MARK: - Capture trigger

    func triggerCapture() {
        guard status == .ready, !isCapturing else { return }
        Task { await runCaptureSequence() }
    }

    // MARK: - The 5-frame sequence

    private func runCaptureSequence() async {
        guard let device, let limits else { return }
        isCapturing = true
        defer { isCapturing = false }

        // Optional 2 s self-timer so a screen tap can't shake the tripod.
        if selfTimerEnabled {
            for i in [2, 1] {
                await MainActor.run { self.countdown = i }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await MainActor.run { self.countdown = nil }
        }

        await MainActor.run { self.status = .capturing("Metering…") }

        // 0. Let focus/exposure/WB finish converging before we lock anything —
        //    locking mid-AF-hunt is how out-of-focus brackets happen.
        await waitForConvergence()

        // 1. Read the scene meter (current continuous AE solution).
        let meterProduct = device.exposureDuration.seconds * Double(device.iso)
        guard meterProduct > 0 else {
            await finishWithError("Could not read the exposure meter.")
            return
        }
        let useRaw = rawEnabled
        let capturePlan = BracketPlanner.plan(meterProduct: meterProduct,
                                              limits: limits,
                                              stacked: !useRaw)
        await MainActor.run { self.plan = capturePlan }

        // 2. Lock focus and white balance so only exposure changes across frames.
        await onSessionQueueVoid {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                device.unlockForConfiguration()
            } catch { }
        }

        // 3. Fire the ladder, darkest to brightest: -6 … +4.
        var images: [Data] = []
        let total = capturePlan.frames.count
        for (index, frame) in capturePlan.frames.enumerated() {
            await MainActor.run {
                self.status = .capturing("Frame \(index + 1)/\(total)  (\(frame.label) EV)…")
            }
            await setCustomExposure(duration: frame.duration, iso: frame.iso)
            try? await Task.sleep(nanoseconds: UInt64(Tuning.settleSeconds * 1_000_000_000))

            // Show what the sensor ACTUALLY accepted — ground truth on screen,
            // no EXIF archaeology needed to see if a fix worked.
            let actualShutter = device.exposureDuration.seconds
            let actualISO = device.iso

            // Hybrid processing: full quality pipeline for short exposures
            // (the dark frames, which carry the window/highlight gradients),
            // fast pipeline for long ones (quality starves and times out at
            // ~1 fps, and those frames' highlights are blown anyway).
            let prioritization: AVCapturePhotoOutput.QualityPrioritization =
                frame.duration <= Tuning.qualityProcessingMaxExposure ? .quality : .speed

            let baseStatus = "Frame \(index + 1)/\(total)  (\(frame.label) EV) — "
                + "\(shutterString(actualShutter)) ISO \(Int(actualISO))"

            do {
                if frame.stackCount > 1 {
                    // Burst of identical exposures, mean-stacked into one
                    // low-noise JPEG. No exposure change between shots, so
                    // no settle wait is needed inside the burst.
                    var burst: [Data] = []
                    for shot in 0..<frame.stackCount {
                        await MainActor.run {
                            self.status = .capturing(
                                baseStatus + " • stack \(shot + 1)/\(frame.stackCount)")
                        }
                        burst.append(try await capturePhoto(raw: false,
                                                            prioritization: .speed))
                    }
                    await MainActor.run {
                        self.status = .capturing(
                            "Frame \(index + 1)/\(total) — averaging \(burst.count) shots…")
                    }
                    images.append(try FrameStacker.averageJPEGs(burst))
                } else {
                    await MainActor.run {
                        self.status = .capturing(baseStatus
                            + (useRaw ? " • RAW"
                               : (prioritization == .quality ? " • HQ" : " • fast")))
                    }
                    images.append(try await capturePhoto(raw: useRaw,
                                                         prioritization: prioritization))
                }
            } catch {
                // One fast-mode, single-shot retry so a stubborn frame can't
                // kill the whole set.
                await MainActor.run {
                    self.status = .capturing(
                        "Frame \(index + 1)/\(total) — retrying (fast mode)")
                }
                do {
                    images.append(try await capturePhoto(raw: useRaw,
                                                         prioritization: .speed))
                } catch {
                    await restoreContinuousModes()
                    await finishWithError("Capture failed: \(error.localizedDescription)")
                    return
                }
            }
        }

        await restoreContinuousModes()

        // 5. Save the set to its own album inside the "RE Brackets" folder.
        await MainActor.run { self.status = .saving }
        let setName = "Bracket " + Self.setNameFormatter.string(from: Date())
        do {
            try await PhotoLibrarySaver.save(imageDatas: images,
                                             setName: setName,
                                             isRaw: useRaw)
            await MainActor.run {
                self.lastSavedAlbum = setName
                self.status = .ready
            }
        } catch {
            await finishWithError("Save failed: \(error.localizedDescription)")
        }
    }

    private func finishWithError(_ message: String) async {
        await MainActor.run {
            self.errorMessage = message
            self.status = .ready
        }
    }

    /// After a bracket (or a failed one), hand exposure, white balance AND
    /// focus back to their continuous modes. Focus was previously left locked
    /// forever here, which froze it at a stale distance for every later shot.
    private func restoreContinuousModes() async {
        await onSessionQueueVoid { [self] in
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                // Give the preview its normal frame rate back (.invalid
                // resets to the format's defaults).
                device.activeVideoMaxFrameDuration = .invalid
                device.activeVideoMinFrameDuration = .invalid
                device.unlockForConfiguration()
            } catch { }
        }
        await MainActor.run { self.focusLocked = false }
    }

    /// Polls until AF/AE/AWB have all stopped adjusting (or 2.5 s passes).
    private func waitForConvergence() async {
        guard let device else { return }
        let deadline = Date().addingTimeInterval(2.5)
        while (device.isAdjustingFocus
               || device.isAdjustingExposure
               || device.isAdjustingWhiteBalance),
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Exposure + capture primitives

    /// Commits a custom duration/ISO and returns once the device reports the
    /// settings applied. Values are clamped to the active format's limits.
    private func setCustomExposure(duration: Double, iso: Float) async {
        guard let device, let limits else { return }
        let d = min(max(duration, limits.minDuration), limits.maxDuration)
        let i = min(max(iso, limits.minISO), limits.maxISO)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let guardFlag = ResumeGuard()
            // Watchdog: if the device never confirms the new exposure (seen
            // when the pipeline is starved), carry on rather than hang.
            sessionQueue.asyncAfter(deadline: .now() + 6) {
                if guardFlag.tryResume() { cont.resume() }
            }
            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    // An exposure can never outlast one video frame, so pin
                    // the stream's frame length to the exposure — but with
                    // ~5% slack for sensor readout. v5 pinned frame duration
                    // EXACTLY equal to the exposure, which left no readout
                    // time and stalled the pipeline on the long frames.
                    // restoreContinuousModes resets both after the bracket.
                    if let range = device.activeFormat.videoSupportedFrameRateRanges
                        .max(by: { $0.maxFrameDuration.seconds < $1.maxFrameDuration.seconds }) {
                        let needed = CMTime(seconds: max(d / 0.95, 1.0 / 30.0),
                                            preferredTimescale: 1_000_000_000)
                        let frameDuration = CMTimeClampToRange(
                            needed,
                            range: CMTimeRange(start: range.minFrameDuration,
                                               end: range.maxFrameDuration))
                        device.activeVideoMinFrameDuration = frameDuration
                        device.activeVideoMaxFrameDuration = frameDuration
                    }
                    device.setExposureModeCustom(
                        duration: CMTime(seconds: d, preferredTimescale: 1_000_000_000),
                        iso: i
                    ) { _ in
                        if guardFlag.tryResume() { cont.resume() }
                    }
                    device.unlockForConfiguration()
                } catch {
                    if guardFlag.tryResume() { cont.resume() }
                }
            }
        }
    }

    private func capturePhoto(
        raw: Bool,
        prioritization: AVCapturePhotoOutput.QualityPrioritization = .quality
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async { [self] in
                let settings: AVCapturePhotoSettings
                if raw, let rawType = photoOutput.availableRawPhotoPixelFormatTypes.first {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
                    // RAW is straight sensor data — the quality pipeline
                    // doesn't apply, and .speed avoids stalls at slow rates.
                    settings.photoQualityPrioritization = .speed
                    // Embedded JPEG thumbnail so Photos/Windows show previews.
                    if let thumbCodec = settings.availableRawEmbeddedThumbnailPhotoCodecTypes.first {
                        settings.rawEmbeddedThumbnailPhotoFormat = [AVVideoCodecKey: thumbCodec]
                    }
                } else {
                    // Fallback also covers a lens without RAW support.
                    settings = AVCapturePhotoSettings(
                        format: [AVVideoCodecKey: AVVideoCodecType.jpeg]
                    )
                    settings.photoQualityPrioritization = prioritization
                    settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
                }
                settings.flashMode = .off

                if let coordinator = rotationCoordinator,
                   let connection = photoOutput.connection(with: .video) {
                    let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                    if connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                }

                let photoID = settings.uniqueID
                inflightLock.lock()
                inflight[photoID] = cont
                inflightLock.unlock()

                // Watchdog: at ~1 fps a still can legitimately take several
                // seconds, but if it never arrives, fail the frame instead of
                // hanging the whole bracket (v5 hung here for minutes).
                sessionQueue.asyncAfter(deadline: .now() + 20) { [self] in
                    inflightLock.lock()
                    let stale = inflight.removeValue(forKey: photoID)
                    inflightLock.unlock()
                    stale?.resume(throwing: CameraError.captureTimedOut)
                }

                photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    // MARK: - Queue helpers

    private func onSessionQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            sessionQueue.async {
                do { cont.resume(returning: try body()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private func onSessionQueueVoid(_ body: @escaping () -> Void) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                body()
                cont.resume()
            }
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        inflightLock.lock()
        let cont = inflight.removeValue(forKey: photo.resolvedSettings.uniqueID)
        inflightLock.unlock()

        if let error {
            cont?.resume(throwing: error)
        } else if let data = photo.fileDataRepresentation() {
            cont?.resume(returning: data)
        } else {
            cont?.resume(throwing: CameraError.noImageData)
        }
    }
}
