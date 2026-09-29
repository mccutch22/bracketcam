import SwiftUI
import AVKit

@MainActor
final class TutorialPlayback: ObservableObject {
    let player: AVPlayer
    @Published var started = false
    @Published var watched = false
    @Published var error: String?
    private var ended: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    init() {
        if let url = Bundle.main.url(forResource: "CameraTutorial", withExtension: "mp4") {
            player = AVPlayer(url: url)
            ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.watched = true }
            }
            statusObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed { Task { @MainActor in self?.error = "The tutorial could not play. You can close it and try again from Photo tips." } }
            }
        } else {
            player = AVPlayer()
            error = "The tutorial is unavailable. You can still use the photo tips from the question mark button."
        }
    }
    func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        started = true
        player.play()
    }
    func stop() {
        player.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    deinit { if let ended { NotificationCenter.default.removeObserver(ended) } }
}

struct CameraTutorialView: View {
    var firstLaunch = false
    var onWatched: () -> Void = {}
    let onClose: () -> Void
    @StateObject private var playback = TutorialPlayback()
    @StateObject private var orientation = OrientationObserver()
    @State private var confirmSkip = false
    @Environment(\.scenePhase) private var scenePhase

    private func close() {
        playback.player.pause()
        if TutorialOnboarding.needsSkipConfirmation(firstLaunch: firstLaunch, watched: playback.watched) { confirmSkip = true }
        else { onClose() }
    }
    var body: some View {
        GeometryReader { geometry in
            let width = orientation.isLandscape ? geometry.size.height : geometry.size.width
            let height = orientation.isLandscape ? geometry.size.width : geometry.size.height
            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    Text("PhotoDash Camera Tutorial: 60 seconds to Shooting like a Pro")
                        .font(orientation.isLandscape ? .headline : .title2.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2).frame(width: 44, height: 44) }
                        .accessibilityLabel("Close tutorial")
                }
                if let error = playback.error {
                    Spacer(); Text(error).multilineTextAlignment(.center); Spacer()
                } else if playback.started {
                    VideoPlayer(player: playback.player)
                        .aspectRatio(4.0 / 3.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Button { playback.play() } label: {
                        ZStack {
                            Image("TutorialPoster").resizable().scaledToFit()
                            Label("Play tutorial", systemImage: "play.circle.fill")
                                .font(.title3.bold()).padding(18)
                                .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }.buttonStyle(.plain)
                }
                if playback.watched {
                    Button(firstLaunch ? "Start taking photos" : "Back to photo tips", action: onClose)
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
            .padding(16).frame(width: width, height: height)
            .rotationEffect(orientation.angle)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.white.ignoresSafeArea()).foregroundStyle(Color(red: 0.02, green: 0.08, blue: 0.18))
        .preferredColorScheme(.light).interactiveDismissDisabled()
        .alert("Skip the tutorial?", isPresented: $confirmSkip) {
            Button("Keep watching", role: .cancel) { if playback.started { playback.play() } }
            Button("Skip tutorial", role: .destructive, action: onClose)
        } message: { Text("You can watch it anytime from the question mark button on the camera.") }
        .onChange(of: playback.watched) { _, watched in if watched { onWatched() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.player.pause() } }
        .onDisappear { playback.stop() }
    }
}
