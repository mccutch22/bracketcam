import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraManager()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.status {
            case .denied:
                permissionScreen
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding()
            default:
                cameraScreen
            }
        }
        .onAppear {
            camera.start()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Main camera UI

    private var cameraScreen: some View {
        ZStack {
            CameraPreviewView(
                session: camera.session,
                onTap: { camera.focusAndMeter(at: $0) },
                onHardwareShutter: { camera.triggerCapture() },
                onPinchBegan: { camera.pinchBegan() },
                onPinchChanged: { camera.pinchChanged($0) }
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                topReadout
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if isBusy, camera.countdown == nil {
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.6)
                    Text(busyText)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("Keep the phone still — long exposures in progress")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
                .ignoresSafeArea()
            }

            if let countdown = camera.countdown {
                Text("\(countdown)")
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
            }
        }
    }

    private var topReadout: some View {
        VStack(spacing: 6) {
            if let plan = camera.plan {
                HStack(spacing: 8) {
                    if plan.allAtBaseISO {
                        badge("BASE ISO \(Int(plan.limits.minISO))", color: .green)
                    }
                    if plan.plusFourUnderexposed {
                        badge("VERY DARK: +4 limited even at max ISO — deep shadows may stay underexposed",
                              color: .orange)
                    }
                    Spacer()
                    if camera.focusLocked {
                        badge("AF/AE SET", color: .yellow)
                            .onTapGesture { camera.resetFocus() }
                    }
                }
            }

            if let error = camera.errorMessage {
                badge(error, color: .red)
                    .onTapGesture { camera.errorMessage = nil }
            }

            if let album = camera.lastSavedAlbum {
                badge("Saved: \(album)", color: .blue)
                    .onTapGesture { camera.lastSavedAlbum = nil }
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            lensRow

            HStack {
                Button {
                    camera.selfTimerEnabled.toggle()
                } label: {
                    Image(systemName: camera.selfTimerEnabled ? "timer.circle.fill" : "timer.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(camera.selfTimerEnabled ? .yellow : .white)
                }

                Spacer()

                Button {
                    camera.triggerCapture()
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 4)
                            .frame(width: 76, height: 76)
                        Circle()
                            .fill(isBusy ? Color.gray : Color.white)
                            .frame(width: 62, height: 62)
                    }
                }
                .disabled(isBusy)

                Spacer()

                Button {
                    camera.resetFocus()
                } label: {
                    Image(systemName: "viewfinder.circle")
                        .font(.system(size: 34))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 24)

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))

            if let plan = camera.plan {
                Text("This lens: max shutter \(shutterString(plan.limits.cap)) • base ISO \(Int(plan.limits.minISO)) • max ISO \(Int(plan.limits.maxISO))")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 6)
            }
        }
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var lensRow: some View {
        HStack(spacing: 10) {
            ForEach(camera.availableLenses) { lens in
                Button {
                    camera.selectLens(lens)
                } label: {
                    Text(lens.rawValue)
                        .font(.footnote.bold())
                        .foregroundStyle(camera.currentLens == lens ? .yellow : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(camera.currentLens == lens ? 0.25 : 0.08))
                        .clipShape(Capsule())
                }
                .disabled(isBusy)
            }
            if camera.zoomFactor > 1.01 {
                Text(String(format: "%.1f× crop", camera.zoomFactor))
                    .font(.caption.bold())
                    .foregroundStyle(.yellow)
                    .onTapGesture { camera.setZoom(1.0) }
            }
            Spacer()
            Button {
                camera.rawEnabled.toggle()
            } label: {
                Text(camera.rawEnabled ? "RAW" : "JPG")
                    .font(.footnote.bold())
                    .foregroundStyle(camera.rawEnabled ? .yellow : .white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Capsule())
            }
            .disabled(isBusy)
        }
        .padding(.horizontal, 12)
    }

    private var isBusy: Bool {
        switch camera.status {
        case .capturing, .saving: return true
        default: return false
        }
    }

    private var statusLine: String {
        switch camera.status {
        case .initializing: return "Starting camera…"
        case .capturing(let step): return step
        case .saving: return "Saving to Photos…"
        case .ready:
            return camera.focusLocked
                ? "Tap shutter to fire the 6-frame bracket (-6 to +4 EV)"
                : "Tap to focus • pinch to zoom • tripod essential"
        default: return ""
        }
    }

    private var busyText: String {
        switch camera.status {
        case .capturing(let step): return step
        case .saving: return "Saving to Photos…"
        default: return ""
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.75))
            .clipShape(Capsule())
    }

    private var permissionScreen: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
            Text("BracketCam needs camera access.")
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }
}
