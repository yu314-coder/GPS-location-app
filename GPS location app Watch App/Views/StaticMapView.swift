import SwiftUI
import MapKit
import CoreLocation

struct StaticMapView: View {
    let locations: [FlightLocation]

    @State private var position: MapCameraPosition

    init(locations: [FlightLocation]) {
        self.locations = locations

        // Calculate initial region to fit all locations
        if let first = locations.first {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: first.toCLLocation().coordinate,
                span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
            )))
        } else {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 1.0, longitudeDelta: 1.0)
            )))
        }
    }

    var body: some View {
        Map(position: $position) {
            // Start marker (green)
            if let first = locations.first {
                Marker("Start", coordinate: first.toCLLocation().coordinate)
                    .tint(.green)
            }

            // End marker (red)
            if let last = locations.last, locations.count > 1 {
                Marker("End", coordinate: last.toCLLocation().coordinate)
                    .tint(.red)
            }
        }
        .onAppear {
            fitRegionToRoute()
        }
    }

    private func fitRegionToRoute() {
        guard !locations.isEmpty else { return }

        let coordinates = locations.map { $0.toCLLocation().coordinate }

        let minLat = coordinates.map { $0.latitude }.min() ?? 0
        let maxLat = coordinates.map { $0.latitude }.max() ?? 0
        let minLon = coordinates.map { $0.longitude }.min() ?? 0
        let maxLon = coordinates.map { $0.longitude }.max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let span = MKCoordinateSpan(
            latitudeDelta: (maxLat - minLat) * 1.2,
            longitudeDelta: (maxLon - minLon) * 1.2
        )

        position = .region(MKCoordinateRegion(center: center, span: span))
    }
}
