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
                center: first.toCLLocation().coordinate.forAppleBasemap,
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
        GeometryReader { geometry in
            Map(position: $position) {
                // Draw route polyline
                if locations.count > 1 {
                    MapPolyline(coordinates: locations.map { $0.toCLLocation().coordinate.forAppleBasemap })
                        .stroke(.blue, lineWidth: 3)
                }

                // Start marker (green)
                if let first = locations.first {
                    Annotation("Start", coordinate: first.toCLLocation().coordinate.forAppleBasemap) {
                        ZStack {
                            Circle()
                                .fill(.green)
                                .frame(width: 30, height: 30)
                            Image(systemName: "figure.walk")
                                .foregroundColor(.white)
                                .font(.caption)
                        }
                    }
                }

                // End marker (red)
                if let last = locations.last, locations.count > 1 {
                    Annotation("End", coordinate: last.toCLLocation().coordinate.forAppleBasemap) {
                        ZStack {
                            Circle()
                                .fill(.red)
                                .frame(width: 30, height: 30)
                            Image(systemName: "flag.fill")
                                .foregroundColor(.white)
                                .font(.caption)
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .mapStyle(.standard(elevation: .realistic))
            .onAppear {
                // Delay to ensure map is ready
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    fitRegionToRoute()
                }
            }
        }
    }

    private func fitRegionToRoute() {
        guard !locations.isEmpty else { return }

        let coordinates = locations.map { $0.toCLLocation().coordinate.forAppleBasemap }

        let minLat = coordinates.map { $0.latitude }.min() ?? 0
        let maxLat = coordinates.map { $0.latitude }.max() ?? 0
        let minLon = coordinates.map { $0.longitude }.min() ?? 0
        let maxLon = coordinates.map { $0.longitude }.max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Ensure minimum span to avoid zero-size issues
        let latDelta = max((maxLat - minLat) * 1.2, 0.001)
        let lonDelta = max((maxLon - minLon) * 1.2, 0.001)

        let span = MKCoordinateSpan(
            latitudeDelta: latDelta,
            longitudeDelta: lonDelta
        )

        // Ensure UI update happens on main thread
        DispatchQueue.main.async {
            self.position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }
}
