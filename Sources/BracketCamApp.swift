import SwiftUI

@main
struct BracketCamApp: App {
    @StateObject private var credits = PhotoDashCredits.shared
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { if DashKeychain.read() != nil { await credits.sync() } }
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
