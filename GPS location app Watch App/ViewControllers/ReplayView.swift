import SwiftUI
import MapKit

struct ReplayView: View {
    let flight: Flight

    @State private var currentIndex = 0
    @State private var isPlaying = false
    @State private var playbackSpeed: Double = 1.0
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            headerView

            mapView

            controlsView
        }
        .onDisappear {
            stopPlayback()
        }
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Text("Route Replay")
                .font(.headline)

            if let origin = flight.origin, let destination = flight.destination {
                Text("\(origin) → \(destination)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.systemGray6)
    }

    private var mapView: some View {
        Group {
            if !flight.locations.isEmpty {
                ReplayMapView(
                    allLocations: flight.locations,
                    currentIndex: currentIndex
                )
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var controlsView: some View {
        VStack(spacing: 16) {
            progressBar
            controlButtons
            speedControl
        }
        .padding()
        .background(Color.systemGray6)
    }

    private var progressBar: some View {
        VStack(spacing: 8) {
            timeLabels
            progressSlider
        }
    }

    private var timeLabels: some View {
        HStack {
            Text(formatTime(timeAtIndex(currentIndex)))
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text(formatProgress())
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Text(formatTime(flight.duration))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var progressSlider: some View {
        let maxIndex = max(flight.locations.count - 1, 0)
        return Slider(
            value: Binding(
                get: { Double(currentIndex) },
                set: { currentIndex = Int($0) }
            ),
            in: 0...Double(maxIndex)
        )
    }

    private var controlButtons: some View {
        HStack(spacing: 30) {
            Button(action: skipBackward) {
                Image(systemName: "backward.fill")
                    .font(.title2)
            }

            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }

            Button(action: skipForward) {
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
        }
    }

    private var speedControl: some View {
        HStack {
            Text("Speed:")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { speed in
                speedButton(for: speed)
            }
        }
    }

    private func speedButton(for speed: Double) -> some View {
        Button(action: {
            playbackSpeed = speed
        }) {
            Text("\(Int(speed))x")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(playbackSpeed == speed ? Color.blue : Color(white: 0.9))
                .foregroundColor(playbackSpeed == speed ? .white : .primary)
                .cornerRadius(8)
        }
    }

    private func togglePlayback() {
        if isPlaying {
            stopPlayback()
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        isPlaying = true
        let interval = 0.1 / playbackSpeed

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            if currentIndex < flight.locations.count - 1 {
                currentIndex += 1
            } else {
                stopPlayback()
                currentIndex = 0
            }
        }
    }

    private func stopPlayback() {
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func skipBackward() {
        currentIndex = max(0, currentIndex - 50)
    }

    private func skipForward() {
        currentIndex = min(flight.locations.count - 1, currentIndex + 50)
    }

    private func timeAtIndex(_ index: Int) -> TimeInterval {
        guard index < flight.locations.count else { return 0 }
        let location = flight.locations[index]
        return location.timestamp.timeIntervalSince(flight.startDate)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private func formatProgress() -> String {
        let progress = Double(currentIndex) / Double(max(flight.locations.count - 1, 1)) * 100
        return String(format: "%.0f%%", progress)
    }
}

struct ReplayMapView: View {
    let allLocations: [FlightLocation]
    let currentIndex: Int

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            // Start marker
            if let first = allLocations.first {
                Marker("Start", coordinate: first.toCLLocation().coordinate)
                    .tint(.green)
            }

            // Current position
            if currentIndex < allLocations.count {
                let current = allLocations[currentIndex]
                Annotation("Current", coordinate: current.toCLLocation().coordinate) {
                    CurrentPositionMarker()
                }
            }
        }
        .onChange(of: currentIndex) { _, _ in
            updateRegion()
        }
        .onAppear {
            updateRegion()
        }
    }

    private func updateRegion() {
        guard currentIndex < allLocations.count else { return }
        let location = allLocations[currentIndex].toCLLocation()

        withAnimation {
            position = .region(MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            ))
        }
    }
}

struct ReplayView_Previews: PreviewProvider {
    static var previews: some View {
        ReplayView(flight: Flight())
    }
}
