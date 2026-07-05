import SwiftUI
import AVFoundation
import AVKit

/// Live camera preview. Handles tap-to-focus (converted to device coordinates)
/// and, on iOS 17.2+, the hardware volume-button shutter via
/// AVCaptureEventInteraction so the tripod never has to be touched on screen.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let onTap: (CGPoint) -> Void
    let onHardwareShutter: () -> Void
    let onPinchBegan: () -> Void
    let onPinchChanged: (CGFloat) -> Void

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90   // portrait-locked UI
        }

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .began {
                    context.coordinator.parent.onHardwareShutter()
                }
            }
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: CameraPreviewView
        init(parent: CameraPreviewView) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PreviewUIView else { return }
            let layerPoint = gesture.location(in: view)
            let devicePoint = view.previewLayer
                .captureDevicePointConverted(fromLayerPoint: layerPoint)
            parent.onTap(devicePoint)
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:   parent.onPinchBegan()
            case .changed: parent.onPinchChanged(gesture.scale)
            default:       break
            }
        }
    }
}
