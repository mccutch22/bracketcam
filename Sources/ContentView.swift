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
                onHardwareShutter: { camera.triggerCapture() }
            )
            .ignoresSafeArea()

            VStack(spacing: 8) {
                topReadout
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

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
            HistogramView(histogram: camera.histogram)
                .frame(height: 64)

            if let plan = camera.plan {
                HStack(spacing: 8) {
                    if plan.allAtBaseISO {
                        badge("BASE ISO \(Int(plan.limits.minISO))", color: .green)
                    }
                    if plan.plusFourUnderexposed {
                        badge("VERY DARK: +4 limited even at max ISO — deep shadows may stay underexposed",
                              color: .orange)
                    }
                    if let h = camera.histogram, h.clippedFraction > 0.001 {
                        badge(String(format: "%.1f%% clipped", h.clippedFraction * 100),
                              color: .red)
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
            if let plan = camera.plan {
                planStrip(plan)
            }

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
                .padding(.bottom, 6)
        }
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func planStrip(_ plan: BracketPlan) -> some View {
        HStack(spacing: 4) {
            ForEach(plan.frames) { frame in
                VStack(spacing: 3) {
                    Text(frame.isHighlight ? "HL ★" : frame.label)
                        .font(.caption.bold())
                        .foregroundStyle(frame.isHighlight ? .yellow : .white)
                    Text(shutterString(frame.duration))
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white)
                    Text("ISO \(Int(frame.iso))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(frame.iso <= plan.limits.minISO ? .green : .orange)
                    if frame.isUnderexposed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color.white.opacity(frame.isHighlight ? 0.12 : 0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 8)
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
                ? "Tap shutter to fire 5-frame bracket • HL ★ measured at capture"
                : "Tap the preview to set focus & metering point"
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
