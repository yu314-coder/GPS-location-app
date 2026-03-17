import SwiftUI
import MapKit
import CoreLocation

struct LiveMapView: View {
    @Binding var locations: [FlightLocation]
    @Binding var currentLocation: CLLocation?

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            // Start marker
            if let first = locations.first {
                Marker("Start", coordinate: first.toCLLocation().coordinate)
                    .tint(.green)
            }

            // Current position marker
            if let current = currentLocation {
                Annotation("Current", coordinate: current.coordinate) {
                    CurrentPositionMarker()
                }
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onChange(of: currentLocation) { _, newLocation in
            if let location = newLocation {
                updateRegion(for: location)
            }
        }
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Button(action: centerOnCurrentLocation) {
                    Image(systemName: "location.fill")
                        .padding(8)
                        .background(Color.white.opacity(0.8))
                        .clipShape(Circle())
                }
            }
            .padding()
        }
    }

    private func updateRegion(for location: CLLocation) {
        withAnimation {
            position = .region(MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
    }

    private func centerOnCurrentLocation() {
        if let location = currentLocation {
            withAnimation {
                position = .region(MKCoordinateRegion(
                    center: location.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                ))
            }
        }
    }
}

struct CurrentPositionMarker: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.3))
                .frame(width: 32, height: 32)

            Circle()
                .fill(Color.blue)
                .frame(width: 16, height: 16)

            Circle()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 16, height: 16)
        }
    }
}
