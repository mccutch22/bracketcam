import SwiftUI
import UIKit

/// Publishes the physical device orientation as a counter-rotation angle so
/// text and icons can rotate in place to stay upright while the interface
/// itself stays portrait-locked — the same trick Apple's Camera app uses.
/// The layout never moves; only the content of each element spins.
final class OrientationObserver: ObservableObject {
    /// Rotation to apply to on-screen elements so they read upright.
    @Published var angle: Angle = .degrees(0)
    /// True when the phone is held in either landscape direction.
    @Published var isLandscape = false

    private var observer: NSObjectProtocol?

    init() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.update() }
        update()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    private func update() {
        // The screen stays portrait, so content must counter-rotate:
        // device turned counterclockwise (landscapeLeft, home indicator right)
        // → content rotates clockwise, and vice versa. Flat on the tripod
        // mount (faceUp/faceDown) or unknown keeps the last known angle.
        switch UIDevice.current.orientation {
        case .portrait:           set(.degrees(0), landscape: false)
        case .landscapeLeft:      set(.degrees(90), landscape: true)
        case .landscapeRight:     set(.degrees(-90), landscape: true)
        case .portraitUpsideDown: set(.degrees(180), landscape: false)
        default:                  break
        }
    }

    private func set(_ newAngle: Angle, landscape: Bool) {
        guard newAngle != angle || landscape != isLandscape else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            angle = newAngle
            isLandscape = landscape
        }
    }
}
