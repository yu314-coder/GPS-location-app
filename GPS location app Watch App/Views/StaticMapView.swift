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

    /// The route, thinned to at most 500 points so a long flight draws quickly on a watch.
    private var routeCoordinates: [CLLocationCoordinate2D] {
        let step = max(1, locations.count / 500)
        var coords = stride(from: 0, to: locations.count, by: step).map { locations[$0].toCLLocation().coordinate }
        if let last = locations.last, step > 1 { coords.append(last.toCLLocation().coordinate) }
        return coords
    }

    var body: some View {
        // Static, as the name says (build 82): a map that takes drags swallowed the swipe meant for
        // the page, so on the Flights tab the summary could not be scrolled past it.
        Map(position: $position, interactionModes: []) {
            if locations.count > 1 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(.purple, lineWidth: 3)
            }
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
