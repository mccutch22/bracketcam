import Foundation

@main struct TutorialOnboardingChecks {
    static func main() {
        let suite = "PhotoDash.TutorialTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        precondition(TutorialOnboarding.shouldPresent(defaults: defaults))
        precondition(TutorialOnboarding.shouldPresent(defaults: defaults), "Opening without watching or confirming skip must not mark it handled")
        precondition(TutorialOnboarding.needsSkipConfirmation(firstLaunch: true, watched: false))
        precondition(!TutorialOnboarding.needsSkipConfirmation(firstLaunch: true, watched: true))
        precondition(!TutorialOnboarding.needsSkipConfirmation(firstLaunch: false, watched: false))
        TutorialOnboarding.finish(defaults: defaults)
        precondition(!TutorialOnboarding.shouldPresent(defaults: defaults))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "BracketCam.raw")
        precondition(!TutorialOnboarding.shouldPresent(defaults: defaults), "Existing installs should not be treated as new users")
        precondition(defaults.bool(forKey: TutorialOnboarding.handledKey))
        precondition(TutorialOnboarding.swipedStep(0, horizontal: 100, vertical: 0) == 1)
        precondition(TutorialOnboarding.swipedStep(1, horizontal: -100, vertical: 0) == 0)
        precondition(TutorialOnboarding.swipedStep(3, horizontal: 100, vertical: 0) == 3)
        precondition(TutorialOnboarding.swipedStep(0, horizontal: -100, vertical: 0) == 0)
        precondition(TutorialOnboarding.swipedStep(1, horizontal: 100, vertical: 200) == 1)
        precondition(TutorialOnboarding.swipedStep(1, horizontal: 20, vertical: 0) == 1)
        print("Tutorial onboarding, skip confirmation, legacy installs and swipe navigation passed")
    }
}
