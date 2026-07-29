import CoreLocation
import Observation
import ReparaCore

/// The GPS fix, from CoreLocation rather than photo EXIF.
///
/// The app has a live, more accurate position than the EXIF would give it, and
/// avoids the several ways EXIF gets silently stripped between capture and use.
///
/// The caveat that applies to EXIF applies here too, and it is the reason the
/// Review screen has a draggable pin: **the fix is where the photographer is
/// standing, not where the problem is.** Someone standing in the road to
/// photograph a pavement gets a street match, and a street match has never been
/// successfully submitted.
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    private(set) var coordinate: LatLng?
    private(set) var accuracy: CLLocationAccuracy?
    private(set) var authorization: CLAuthorizationStatus
    private(set) var failure: String?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    /// True when the fix is good enough to place a pin without apologising for
    /// it. Anything looser and the Review screen should nudge harder.
    var isPrecise: Bool {
        guard let accuracy else { return false }
        return accuracy > 0 && accuracy <= 20
    }

    func start() {
        failure = nil
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            failure = """
                Location is off for Repara. Turn it on in Settings, or drag the pin to the \
                problem yourself.
                """
        default:
            manager.startUpdatingLocation()
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.failure = nil
                manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let last = locations.last else { return }
        let fix = LatLng(lat: last.coordinate.latitude, lng: last.coordinate.longitude)
        let accuracy = last.horizontalAccuracy
        Task { @MainActor in
            self.coordinate = fix
            self.accuracy = accuracy
            self.failure = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error)
    {
        let message = error.localizedDescription
        Task { @MainActor in
            // Only surface a failure if there is nothing usable yet; a dropped
            // update with a good last fix is not worth alarming anyone about.
            if self.coordinate == nil { self.failure = message }
        }
    }
}
