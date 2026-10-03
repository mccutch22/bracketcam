import Foundation
import CoreLocation
import Combine

@MainActor
final class NearbyAddressLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Fix: Equatable { let latitude: Double; let longitude: Double }
    @Published private(set) var fix: Fix?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let manager = CLLocationManager()
    private var timeout: Task<Void, Never>?
    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    func request() {
        busy = true; message = nil
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, let self, busy else { return }
            finishFailure()
        }
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        default: finishFailure()
        }
    }
    func clear() { busy = false; timeout?.cancel(); manager.stopUpdatingLocation(); fix = nil; message = nil }
    private func finishFailure() {
        busy = false; timeout?.cancel(); manager.stopUpdatingLocation()
        message = "Location is unavailable. You can still search by address and city."
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard busy else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finishFailure()
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard busy else { return }
        guard let location = locations.last, location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 600 else { finishFailure(); return }
        busy = false; timeout?.cancel(); manager.stopUpdatingLocation()
        fix = Fix(latitude: (location.coordinate.latitude * 100).rounded() / 100,
                  longitude: (location.coordinate.longitude * 100).rounded() / 100)
        message = "Nearby addresses are prioritized. Other areas are still searchable."
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if busy { finishFailure() }
    }
}
