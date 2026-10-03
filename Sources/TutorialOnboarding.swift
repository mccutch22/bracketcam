import Foundation

enum TutorialOnboarding {
    static let handledKey = "photodash.cameraTutorial.handled"
    static func shouldPresent(defaults: UserDefaults = .standard) -> Bool {
        if defaults.bool(forKey: handledKey) { return false }
        // Earlier versions wrote this setting on their first camera appearance.
        // Existing users can still watch through Photo tips, without onboarding again.
        if defaults.object(forKey: "BracketCam.raw") != nil {
            finish(defaults: defaults)
            return false
        }
        return true
    }
    static func finish(defaults: UserDefaults = .standard) { defaults.set(true, forKey: handledKey) }
    static func needsSkipConfirmation(firstLaunch: Bool, watched: Bool) -> Bool { firstLaunch && !watched }
    static func swipedStep(_ current: Int, horizontal: Double, vertical: Double, count: Int = 4) -> Int {
        guard abs(horizontal) >= 45, abs(horizontal) > abs(vertical) else { return current }
        return min(max(current + (horizontal > 0 ? 1 : -1), 0), count - 1)
    }
}
