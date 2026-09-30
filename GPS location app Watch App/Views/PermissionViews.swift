import SwiftUI
import CoreLocation
import CoreMotion
import HealthKit

/// The three permissions the watch records with, read from the system each time Settings is shown
/// (build 83). The rows used to be fixed text that nothing updated, so they said "Not Determined"
/// even with everything allowed.
final class PermissionStatusModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case allowed(String)   // what was allowed, e.g. "While using"
        case denied
        case notAsked
        case unavailable

        var label: String {
            switch self {
            case .allowed(let detail): return detail
            case .denied: return "Off"
            case .notAsked: return "Not asked yet"
            case .unavailable: return "Not on this watch"
            }
        }
        var symbol: String {
            switch self {
            case .allowed: return "checkmark.circle.fill"
            case .denied: return "xmark.circle.fill"
            case .notAsked: return "questionmark.circle.fill"
            case .unavailable: return "minus.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .allowed: return .green
            case .denied: return .red
            case .notAsked: return .orange
            case .unavailable: return .gray
            }
        }
    }

    @Published private(set) var location: State = .notAsked
    @Published private(set) var health: State = .notAsked
    @Published private(set) var motion: State = .notAsked

    private let locationManager = CLLocationManager()
    private let healthStore = HKHealthStore()

    override init() {
        super.init()
        locationManager.delegate = self
        refresh()
    }

    var anyNotAsked: Bool { [location, health, motion].contains(.notAsked) }

    func refresh() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways: location = .allowed("Always")
        case .authorizedWhenInUse: location = .allowed("While using")
        case .denied: location = .denied
        case .restricted: location = .unavailable
        case .notDetermined: location = .notAsked
        @unknown default: location = .notAsked
        }

        // Whether the app may save workouts: the one HealthKit permission an app can read back.
        if HKHealthStore.isHealthDataAvailable() {
            switch healthStore.authorizationStatus(for: HKObjectType.workoutType()) {
            case .sharingAuthorized: health = .allowed("Saving workouts")
            case .sharingDenied: health = .denied
            case .notDetermined: health = .notAsked
            @unknown default: health = .notAsked
            }
        } else {
            health = .unavailable
        }

        if CMPedometer.isStepCountingAvailable() {
            switch CMPedometer.authorizationStatus() {
            case .authorized: motion = .allowed("Allowed")
            case .denied: motion = .denied
            case .restricted: motion = .unavailable
            case .notDetermined: motion = .notAsked
            @unknown default: motion = .notAsked
            }
        } else {
            motion = .unavailable
        }
    }

    /// Ask for whatever has not been asked yet. Each prompt appears once; after a refusal the
    /// system will not show it again, and the setting has to be changed in Settings.
    func requestMissing() {
        if location == .notAsked { locationManager.requestWhenInUseAuthorization() }
        if health == .notAsked {
            HealthKitManager().requestAuthorization { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        if motion == .notAsked {
            // A step query is what shows the Motion & Fitness prompt.
            let pedometer = CMPedometer()
            pedometer.queryPedometerData(from: Date().addingTimeInterval(-60), to: Date()) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refresh() }
                _ = pedometer
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { self.refresh() }
    }
}

/// One permission: its name on the first line, what is allowed on the second.
struct PermissionRow: View {
    let title: String
    let symbol: String
    let state: PermissionStatusModel.State

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(state.tint.opacity(0.35)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Label(state.label, systemImage: state.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(state.tint)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
