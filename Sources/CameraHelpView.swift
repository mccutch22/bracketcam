import SwiftUI

struct CameraHelpView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var orientation = OrientationObserver()
    @State private var step = 0

    private let descriptions = [
        "Clean your lens. Phone lenses are often dirty. Wipe them before shooting.",
        "Shoot from the perimeter. Stand near a wall or corner to capture more of the room.",
        "Keep your phone level. Hold it between chest and waist height and avoid tilting it down.",
        "Hold the camera steady. Brace your hands. If you shoot often, a sturdy tripod is a good investment."
    ]

    var body: some View {
        GeometryReader { geometry in
            let width = orientation.isLandscape ? geometry.size.height : geometry.size.width
            let height = orientation.isLandscape ? geometry.size.width : geometry.size.height
            VStack(spacing: 12) {
                HStack {
                    Text("Photo tips · \(step + 1) of 4")
                        .font(.headline)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close photo tips")
                }
                Image("CameraTip\(step + 1)")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(descriptions[step])
                    .id(step)
                HStack(spacing: 16) {
                    if step > 0 {
                        Button("Back") { step -= 1 }
                            .frame(minWidth: 64, minHeight: 48)
                    }
                    Button(step == 3 ? "Done" : "Next") {
                        if step < 3 { step += 1 } else { dismiss() }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color(red: 0.10, green: 0.24, blue: 0.18))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(16)
            .frame(width: width, height: height)
            .rotationEffect(orientation.angle)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.white.ignoresSafeArea())
        .foregroundStyle(Color(red: 0.02, green: 0.08, blue: 0.18))
        .preferredColorScheme(.light)
    }
}
