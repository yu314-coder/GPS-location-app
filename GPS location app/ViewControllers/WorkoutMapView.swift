import SwiftUI
import MapKit
import HealthKit

private enum WorkoutMapPeriod: String, CaseIterable, Identifiable {
    case all = "All"
    case threeMonths = "3 Months"
    case week = "Week"
    case custom = "Custom"

    var id: String { rawValue }
}

private struct WorkoutMapTrack: Identifiable {
    let id: UUID
    let title: String
    let startDate: Date
    let distance: Double
    let duration: TimeInterval
    let coordinates: [CLLocationCoordinate2D]
    let transportType: MKDirectionsTransportType
    let canRoadAlign: Bool
    let costing: MapMatchingService.Costing

    var coordinateCount: Int { coordinates.count }
}

private struct RoadAlignmentSegment {
    let original: [CLLocationCoordinate2D]

    var start: CLLocationCoordinate2D? { original.first }
    var end: CLLocationCoordinate2D? { original.last }
}

/// MKMapView-backed layer. Renders ALL routes as a single MKMultiPolyline overlay
/// (via MKMultiPolylineRenderer) instead of thousands of SwiftUI overlays — this
/// is what lets the map show every route smoothly without lag/heat. SwiftUI's
/// MapPolyline can't take an MKMultiPolyline, hence the UIViewRepresentable.
private struct TracksMapLayer: UIViewRepresentable {
    let tracks: [WorkoutMapTrack]
    let selectedTrackID: UUID?
    let roadAlignedCoordinates: [UUID: [CLLocationCoordinate2D]]
    let multiPolyline: MKMultiPolyline?
    let satellite: Bool
    let dataVersion: Int                    // bumps when the track set changes
    let fitRegion: MKCoordinateRegion?
    let fitGeneration: Int                  // bumps when a fit/focus is requested
    let onTapCoordinate: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTapCoordinate: onTapCoordinate) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        map.addGestureRecognizer(tap)
        context.coordinator.mapView = map
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coord = context.coordinator
        coord.onTapCoordinate = onTapCoordinate
        coord.tracks = tracks

        let desiredType: MKMapType = satellite ? .hybrid : .standard
        if map.mapType != desiredType { map.mapType = desiredType }

        // Rebuild overlays only when the data set / selection actually changed.
        let signature = "\(dataVersion)|sel:\(selectedTrackID?.uuidString ?? "none")|al:\(roadAlignedCoordinates.count)"
        if signature != coord.lastSignature {
            coord.lastSignature = signature
            rebuildOverlays(on: map)
        }

        // Apply a requested camera fit when the generation changes.
        if coord.lastFitGeneration != fitGeneration, let region = fitRegion {
            coord.lastFitGeneration = fitGeneration
            map.setRegion(map.regionThatFits(region), animated: true)
        }
    }

    private func displayCoordinates(for track: WorkoutMapTrack) -> [CLLocationCoordinate2D] {
        roadAlignedCoordinates[track.id] ?? track.coordinates
    }

    private func rebuildOverlays(on map: MKMapView) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })

        // Always one multi-polyline overlay (raw or corrected — the parent rebuilds
        // it when smoothing/matching changes the geometry). Keeps rendering fast
        // no matter how many routes are shown.
        if let multiPolyline { map.addOverlay(multiPolyline, level: .aboveRoads) }

        // Highlight + endpoint pins for the selected route.
        if let id = selectedTrackID, let track = tracks.first(where: { $0.id == id }) {
            let coords = displayCoordinates(for: track)
            if coords.count > 1 {
                let pl = MKPolyline(coordinates: coords, count: coords.count)
                pl.title = "selected"
                map.addOverlay(pl, level: .aboveLabels)
                if let first = coords.first {
                    let a = MKPointAnnotation(); a.coordinate = first; a.title = "Start"; map.addAnnotation(a)
                }
                if let last = coords.last {
                    let a = MKPointAnnotation(); a.coordinate = last; a.title = "End"; map.addAnnotation(a)
                }
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var mapView: MKMapView?
        var onTapCoordinate: (CLLocationCoordinate2D) -> Void
        var tracks: [WorkoutMapTrack] = []
        var lastSignature = ""
        var lastFitGeneration = Int.min

        init(onTapCoordinate: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onTapCoordinate = onTapCoordinate
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let map = mapView else { return }
            let point = gesture.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            onTapCoordinate(coordinate)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let multi = overlay as? MKMultiPolyline {
                let r = MKMultiPolylineRenderer(multiPolyline: multi)
                r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.55)
                r.lineWidth = 2.5
                return r
            }
            if let pl = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: pl)
                if pl.title == "selected" {
                    r.strokeColor = UIColor.systemOrange
                    r.lineWidth = 5
                } else {
                    r.strokeColor = UIColor.systemBlue.withAlphaComponent(0.55)
                    r.lineWidth = 2.5
                }
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            let id = "endpoint"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.annotation = annotation
            view.markerTintColor = (annotation.title ?? "") == "Start" ? .systemGreen : .systemRed
            view.glyphImage = nil
            view.displayPriority = .required
            return view
        }
    }
}

struct WorkoutMapView: View {
    @StateObject private var flightDataStore = FlightDataStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selectedPeriod: WorkoutMapPeriod = .all
    @State private var customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var tracks: [WorkoutMapTrack] = []
    @State private var selectedTrackID: UUID?
    @State private var fitRegion: MKCoordinateRegion?
    @State private var fitGeneration = 0
    @State private var dataVersion = 0
    @State private var isLoading = false
    @State private var roadAlignedCoordinates: [UUID: [CLLocationCoordinate2D]] = [:]
    @State private var isRoadAligning = false
    @State private var roadAlignProgress = 0
    @State private var roadAlignTotal = 0
    @State private var roadAlignMessage: String?
    @State private var isDownloadingWorkouts = false
    @State private var downloadProgress = 0
    @State private var downloadTotal = 0
    @State private var downloadMessage: String?
    @State private var showDownloadAlert = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var detailFlight: Flight?
    @State private var mapStyleSelection: MapStyleOption = .standard
    @State private var allTracksBounds: MapBounds?
    @State private var allRoutesMultiPolyline: MKMultiPolyline?

    private struct MapBounds {
        let minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

        init?(_ coordinates: [CLLocationCoordinate2D]) {
            guard !coordinates.isEmpty else { return nil }
            var nLat = coordinates[0].latitude, xLat = coordinates[0].latitude
            var nLon = coordinates[0].longitude, xLon = coordinates[0].longitude
            for c in coordinates {
                if c.latitude < nLat { nLat = c.latitude }
                if c.latitude > xLat { xLat = c.latitude }
                if c.longitude < nLon { nLon = c.longitude }
                if c.longitude > xLon { xLon = c.longitude }
            }
            minLat = nLat; maxLat = xLat; minLon = nLon; maxLon = xLon
        }

        init(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
            self.minLat = minLat; self.maxLat = maxLat; self.minLon = minLon; self.maxLon = maxLon
        }

        func union(_ other: MapBounds) -> MapBounds {
            MapBounds(minLat: min(minLat, other.minLat), maxLat: max(maxLat, other.maxLat),
                      minLon: min(minLon, other.minLon), maxLon: max(maxLon, other.maxLon))
        }

        var region: MKCoordinateRegion {
            MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.25, 0.01),
                                       longitudeDelta: max((maxLon - minLon) * 1.25, 0.01))
            )
        }
    }

    private enum MapStyleOption: String, CaseIterable, Identifiable {
        case standard = "Standard"
        case hybrid = "Satellite"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .standard: return "map"
            case .hybrid: return "globe.americas.fill"
            }
        }
    }

    private let routePalette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .indigo, .mint]
    private let healthKitManager = HealthKitManager.shared
    private let roadAlignmentRequestBudget = 40
    private let roadAlignmentRequestSpacingNanoseconds: UInt64 = 1_500_000_000
    private let roadAlignmentMaxTracks = 60

    private var isIPad: Bool { sizeClass == .regular }

    private var selectedTrack: WorkoutMapTrack? {
        guard let selectedTrackID else { return nil }
        return tracks.first { $0.id == selectedTrackID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Extracted, Equatable map layer — it only re-renders when the
                // track data / selection / style actually change. Download progress
                // updates re-render the panels below but NOT this heavy map.
                TracksMapLayer(
                    tracks: tracks,
                    selectedTrackID: selectedTrackID,
                    roadAlignedCoordinates: roadAlignedCoordinates,
                    multiPolyline: allRoutesMultiPolyline,
                    satellite: mapStyleSelection == .hybrid,
                    dataVersion: dataVersion,
                    fitRegion: fitRegion,
                    fitGeneration: fitGeneration,
                    onTapCoordinate: { coordinate in selectNearestTrack(to: coordinate) }
                )
                .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 0) {
                    controlPanel
                        .padding(.horizontal, isIPad ? 24 : 12)
                        .padding(.top, 8)

                    Spacer()

                    bottomPanel
                        .padding(.horizontal, isIPad ? 24 : 12)
                        .padding(.bottom, 12)
                }

                if isLoading {
                    ProgressView("Loading tracks...")
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Picker("Style", selection: $mapStyleSelection) {
                        ForEach(MapStyleOption.allCases) { style in
                            Image(systemName: style.icon).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: fitAllTracks) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(tracks.isEmpty)
                }
            }
            .navigationDestination(item: $detailFlight) { flight in
                WorkoutDetailView(flight: flight)
            }
            .onAppear(perform: loadTracks)
            .onChange(of: selectedPeriod) { loadTracks() }
            .onChange(of: customStartDate) {
                if selectedPeriod == .custom {
                    loadTracks()
                }
            }
            .onChange(of: customEndDate) {
                if selectedPeriod == .custom {
                    loadTracks()
                }
            }
            .onChange(of: flightDataStore.savedFlights.count) {
                // CRITICAL: during a bulk download each saved workout bumps this
                // count. Reloading every track from disk on each one is O(n²) disk
                // I/O + a full map re-render — the main cause of lag/heat/crash.
                // Skip reloads while downloading; loadTracks() runs once at the end.
                guard !isDownloadingWorkouts else { return }
                loadTracks()
            }
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            Picker("Time Period", selection: $selectedPeriod) {
                ForEach(WorkoutMapPeriod.allCases) { period in
                    Text(period.rawValue).tag(period)
                }
            }
            .pickerStyle(.segmented)

            if selectedPeriod == .custom {
                HStack(spacing: 10) {
                    DatePicker("From", selection: $customStartDate, displayedComponents: .date)
                        .labelsHidden()
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                    DatePicker("To", selection: $customEndDate, displayedComponents: .date)
                        .labelsHidden()
                }
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: 10) {
                Button(action: loadTracks) {
                    Label("Load", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .disabled(isLoading || isRoadAligning || isDownloadingWorkouts)

                if isDownloadingWorkouts {
                    Button(action: cancelDownload) {
                        Label("Stop \(downloadProgress)/\(downloadTotal)", systemImage: "stop.circle.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(action: downloadAllWorkoutsFromHealthKit) {
                        Label("Download All", systemImage: "square.and.arrow.down")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRoadAligning)
                }
            }

            HStack(spacing: 10) {
                Button(action: alignVisibleTracksToRoads) {
                    Label(
                        isRoadAligning ? "Aligning \(roadAlignProgress)/\(roadAlignTotal)" : "Align Roads",
                        systemImage: isRoadAligning ? "hourglass" : "point.topleft.down.curvedto.point.bottomright.up"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty || isRoadAligning)

                if !roadAlignedCoordinates.isEmpty {
                    Button(action: resetRoadAlignment) {
                        Label("Original", systemImage: "arrow.uturn.backward")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isRoadAligning)
                }
            }

            if let roadAlignMessage {
                Text(roadAlignMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isDownloadingWorkouts && downloadTotal > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(downloadProgress) / \(downloadTotal)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int((Double(downloadProgress) / Double(max(downloadTotal, 1))) * 100))%")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: Double(downloadProgress), total: Double(downloadTotal))
                        .progressViewStyle(.linear)
                        .tint(.blue)
                }
            }

            if let downloadMessage {
                Text(downloadMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .alert("Workout Download", isPresented: $showDownloadAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadMessage ?? "")
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(tracks.count) tracks")
                        .font(.headline)
                    Text(periodSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(String(format: "%.1f km", totalDistance / 1000))
                    .font(.headline)
                    .foregroundColor(.blue)
            }

            if let selectedTrack {
                selectedTrackInfo(selectedTrack)
            }

            if tracks.isEmpty {
                Text("No saved workout tracks for this period")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: {
                            selectedTrackID = nil
                            fitAllTracks()
                        }) {
                            Label("All", systemImage: "map")
                                .font(.caption)
                                .fontWeight(selectedTrackID == nil ? .bold : .medium)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(selectedTrackID == nil ? Color.blue : Color(.secondarySystemGroupedBackground))
                                .foregroundColor(selectedTrackID == nil ? .white : .primary)
                                .clipShape(Capsule())
                        }

                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            Button(action: {
                                selectedTrackID = track.id
                                focus(track)
                            }) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(routeColor(for: index))
                                        .frame(width: 8, height: 8)
                                    Text(track.startDate, format: .dateTime.month(.abbreviated).day())
                                }
                                .font(.caption)
                                .fontWeight(track.id == selectedTrackID ? .bold : .medium)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(track.id == selectedTrackID ? routeColor(for: index) : Color(.secondarySystemGroupedBackground))
                                .foregroundColor(track.id == selectedTrackID ? .white : .primary)
                                .clipShape(Capsule())
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func selectedTrackMapLabel(_ track: WorkoutMapTrack) -> some View {
        VStack(spacing: 3) {
            Text(track.startDate, format: .dateTime.month(.abbreviated).day().year())
                .font(.caption)
                .fontWeight(.semibold)
            Text(track.startDate, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
    }

    private func selectedTrackInfo(_ track: WorkoutMapTrack) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(track.startDate, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().year().hour().minute())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f km", track.distance / 1000))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                    Text(formatTrackDuration(track.duration))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            // Quick stats row
            HStack(spacing: 0) {
                trackStat(icon: "speedometer", value: averageSpeedText(track), tint: .orange)
                Divider().frame(height: 26)
                trackStat(icon: "point.topleft.down.curvedto.point.bottomright.up", value: "\(track.coordinateCount) pts", tint: .green)
                Divider().frame(height: 26)
                trackStat(icon: "clock", value: formatTrackDuration(track.duration), tint: .blue)
            }

            Button(action: { openDetails(for: track) }) {
                HStack {
                    Image(systemName: "chart.xyaxis.line")
                    Text("View Full Details")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .font(.caption)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Color.blue.opacity(0.12))
                .foregroundColor(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func trackStat(icon: String, value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(tint)
            Text(value)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    private func averageSpeedText(_ track: WorkoutMapTrack) -> String {
        guard track.duration > 0 else { return "--" }
        return String(format: "%.1f km/h", (track.distance / track.duration) * 3.6)
    }

    private func formatTrackDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        if hours > 0 { return String(format: "%dh %dm", hours, minutes) }
        return String(format: "%dm", minutes)
    }

    private func openDetails(for track: WorkoutMapTrack) {
        if let flight = FlightDataStore.shared.loadFlightDetails(id: track.id) {
            detailFlight = flight
        } else if let summary = flightDataStore.savedFlights.first(where: { $0.id == track.id }) {
            detailFlight = summary
        }
    }

    private var periodSubtitle: String {
        switch selectedPeriod {
        case .all:
            return "All saved workouts"
        case .threeMonths:
            return "Last 3 months"
        case .week:
            return "Last 7 days"
        case .custom:
            return "Custom date range"
        }
    }

    private var totalDistance: Double {
        tracks.map(\.distance).reduce(0, +)
    }

    private func loadTracks() {
        isLoading = true
        let summaries = filteredSummaries().sorted { $0.startDate > $1.startDate }
        let interval = selectedInterval()
        let savedIDs = Set(flightDataStore.savedFlights.map(\.id))
            .union(Set(flightDataStore.savedFlights.compactMap(\.workoutUUID)))

        DispatchQueue.global(qos: .userInitiated).async {
            // Decode the HealthKit summary cache OFF the main thread (it was a
            // freeze source when opening the Map tab).
            let cachedHKWorkouts = WorkoutCacheStore.shared.loadWorkouts()
            let pendingHKWorkouts = cachedHKWorkouts.filter { workout in
                guard !savedIDs.contains(workout.id) else { return false }
                if let interval, !interval.contains(workout.startDate) { return false }
                return true
            }

            // Adaptive per-track detail: fewer vertices per route when there are
            // many, keeping the total vertex count (and GPU load) bounded even
            // when showing ALL routes.
            let trackCount = summaries.count
            let perTrackMaxPoints: Int
            switch trackCount {
            case 0...10: perTrackMaxPoints = 600
            case 11...50: perTrackMaxPoints = 250
            case 51...200: perTrackMaxPoints = 120
            case 201...800: perTrackMaxPoints = 60
            default: perTrackMaxPoints = 30
            }

            // Accumulate the global bounding box here, off the main thread, so we
            // never have to flat-map + scan ~1M coordinates on the main thread in
            // fitAllTracks() (the ~3s spike after each load).
            var globalBounds: MapBounds?

            let loaded = summaries.compactMap { summary -> WorkoutMapTrack? in
                // CRITICAL: read the compact route cache (tiny lat/lon file) instead
                // of decoding the full flight detail (all GPS points + every metric
                // history). This is the key fix for iPhone map lag / memory crashes.
                let cachedCoords = FlightDataStore.shared.loadRouteCoordinates(id: summary.id)
                guard cachedCoords.count > 1 else { return nil }

                // Down-sample further for rendering based on how many tracks are shown.
                let coordinates = downsampleCoordinates(cachedCoords, maxPoints: perTrackMaxPoints)
                guard coordinates.count > 1 else { return nil }

                if let b = MapBounds(coordinates) {
                    globalBounds = globalBounds?.union(b) ?? b
                }

                let activityType = summary.workoutType.flatMap { HKWorkoutActivityType(rawValue: $0) }
                return WorkoutMapTrack(
                    id: summary.id,
                    title: workoutTitle(for: summary),
                    startDate: summary.startDate,
                    distance: summary.metrics?.totalDistance ?? 0,
                    duration: summary.metrics?.duration ?? summary.duration,
                    coordinates: coordinates,
                    transportType: mapTransportType(for: summary),
                    canRoadAlign: canRoadAlign(flight: summary),
                    costing: MapMatchingService.costing(for: activityType)
                )
            }
            .sorted { $0.startDate > $1.startDate }

            // Collapse ALL routes into ONE MKMultiPolyline overlay. MapKit renders
            // a single multi-polyline far faster than thousands of separate
            // overlays — this is what lets the map show every route smoothly.
            let multi = MKMultiPolyline(loaded.map { track in
                MKPolyline(coordinates: track.coordinates, count: track.coordinates.count)
            })

            DispatchQueue.main.async {
                tracks = loaded
                allRoutesMultiPolyline = loaded.isEmpty ? nil : multi
                allTracksBounds = globalBounds
                dataVersion += 1
                roadAlignedCoordinates = [:]
                roadAlignMessage = nil
                if let selectedTrackID, !loaded.contains(where: { $0.id == selectedTrackID }) {
                    self.selectedTrackID = nil
                }
                isLoading = false
                fitAllTracks()

                // Auto-fetch routes for any HealthKit workouts in this period that
                // haven't been downloaded yet, so the Map tab matches the Workouts
                // tab. Skip auto-starting when the device is already warm — don't
                // surprise the user with heat just for opening the tab. They can
                // still trigger it manually with "Download All".
                let thermalOK = ProcessInfo.processInfo.thermalState == .nominal
                    || ProcessInfo.processInfo.thermalState == .fair
                if !pendingHKWorkouts.isEmpty && !isDownloadingWorkouts && thermalOK {
                    autoDownloadPendingWorkouts(pendingHKWorkouts)
                }
            }
        }
    }

    private func autoDownloadPendingWorkouts(_ summaries: [WorkoutSummary]) {
        guard healthKitManager.isAuthorized else { return }
        guard !isDownloadingWorkouts else { return }

        isDownloadingWorkouts = true
        downloadProgress = 0
        downloadTotal = summaries.count
        downloadMessage = "Syncing \(summaries.count) workouts from HealthKit..."

        if #available(iOS 16.1, *) {
            DownloadLiveActivityManager.shared.beginBackgroundTask(name: "MapAutoSync")
            DownloadLiveActivityManager.shared.start(
                title: "Syncing Map Workouts",
                total: summaries.count,
                message: "Downloading routes..."
            )
        }

        downloadTask = Task {
            var imported = 0
            var skipped = 0

            // Thermal-aware batching: concurrency shrinks and cooldowns grow as
            // the device heats up so the sync can't overheat-crash the app.
            var index = 0
            while index < summaries.count {
                if Task.isCancelled { break }
                await ThermalDownloadPacing.waitWhileCritical()
                if Task.isCancelled { break }

                let batchSize = ThermalDownloadPacing.concurrency
                let batchEnd = min(index + batchSize, summaries.count)
                let batch = Array(summaries[index..<batchEnd])

                let workouts: [HKWorkout?] = await withTaskGroup(of: HKWorkout?.self, returning: [HKWorkout?].self) { group in
                    for summary in batch {
                        group.addTask {
                            await withCheckedContinuation { continuation in
                                self.healthKitManager.fetchWorkout(uuid: summary.id) { workout, _ in
                                    continuation.resume(returning: workout)
                                }
                            }
                        }
                    }
                    var collected: [HKWorkout?] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected
                }

                let flights: [Flight?] = await withTaskGroup(of: Flight?.self, returning: [Flight?].self) { group in
                    for workout in workouts.compactMap({ $0 }) {
                        group.addTask {
                            await self.fetchAndConvertWorkout(workout)
                        }
                    }
                    var collected: [Flight?] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected
                }

                let valid = flights.compactMap { $0 }
                skipped += batch.count - valid.count
                imported += valid.count

                await FlightDataStore.shared.saveDownloadedFlights(valid)

                index = batchEnd
                await MainActor.run {
                    downloadProgress = index
                    if #available(iOS 16.1, *) {
                        DownloadLiveActivityManager.shared.update(
                            progress: index,
                            total: summaries.count,
                            message: "Syncing routes..."
                        )
                    }
                }

                await ThermalDownloadPacing.cooldown()
            }

            let wasCancelled = Task.isCancelled
            await MainActor.run {
                isDownloadingWorkouts = false
                downloadTask = nil
                downloadMessage = wasCancelled
                    ? "Sync stopped: \(imported) added"
                    : "Synced \(imported) workouts (\(skipped) without route)"
                if #available(iOS 16.1, *) {
                    DownloadLiveActivityManager.shared.end(
                        finalMessage: wasCancelled ? "Stopped after \(imported)" : "\(imported) synced"
                    )
                }
                if imported > 0 {
                    loadTracks()
                }
            }
        }
    }

    private func filteredSummaries() -> [Flight] {
        let interval = selectedInterval()
        return flightDataStore.savedFlights.filter { flight in
            guard let interval else { return true }
            return interval.contains(flight.startDate)
        }
    }

    private func selectedInterval() -> DateInterval? {
        let calendar = Calendar.current
        let now = Date()

        switch selectedPeriod {
        case .all:
            return nil
        case .threeMonths:
            let start = calendar.date(byAdding: .month, value: -3, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .week:
            let start = calendar.date(byAdding: .day, value: -7, to: now) ?? now
            return DateInterval(start: start, end: now)
        case .custom:
            let start = min(customStartDate, customEndDate)
            let end = max(customStartDate, customEndDate)
            let startOfDay = calendar.startOfDay(for: start)
            let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: end)) ?? end
            return DateInterval(start: startOfDay, end: endOfDay)
        }
    }

    private func routeColor(for index: Int) -> Color {
        routePalette[index % routePalette.count]
    }

    private func displayCoordinates(for track: WorkoutMapTrack) -> [CLLocationCoordinate2D] {
        roadAlignedCoordinates[track.id] ?? track.coordinates
    }

    private func applyFit(_ region: MKCoordinateRegion?) {
        guard let region else { return }
        fitRegion = region
        fitGeneration += 1
    }

    private func fitAllTracks() {
        // Use the bounding box precomputed off-main during loadTracks — avoids
        // flat-mapping and scanning ~1M coordinates on the main thread.
        if roadAlignedCoordinates.isEmpty, let bounds = allTracksBounds {
            applyFit(bounds.region)
            return
        }
        // Fallback (e.g. after road-alignment changed the geometry): compute now.
        var bounds: MapBounds?
        for track in tracks {
            if let b = MapBounds(displayCoordinates(for: track)) {
                bounds = bounds?.union(b) ?? b
            }
        }
        applyFit(bounds?.region)
    }

    private func focus(_ track: WorkoutMapTrack) {
        applyFit(MapBounds(displayCoordinates(for: track))?.region)
    }

    private func labelCoordinate(for track: WorkoutMapTrack) -> CLLocationCoordinate2D? {
        let coordinates = displayCoordinates(for: track)
        guard !coordinates.isEmpty else { return nil }
        return coordinates[coordinates.count / 2]
    }

    private func selectNearestTrack(to coordinate: CLLocationCoordinate2D) {
        let candidates = tracks.compactMap { track -> (track: WorkoutMapTrack, distance: CLLocationDistance)? in
            let coordinates = displayCoordinates(for: track)
            guard coordinates.count > 1 else { return nil }
            return (track, nearestDistance(from: coordinate, toPolyline: coordinates))
        }

        guard let nearest = candidates.min(by: { $0.distance < $1.distance }),
              nearest.distance <= 120 else {
            return
        }

        selectedTrackID = nearest.track.id
    }


    private func alignVisibleTracksToRoads() {
        guard !tracks.isEmpty, !isRoadAligning else { return }

        // Only align what's reasonable in one pass to respect API rate limits.
        let tracksToAlign = Array(tracks.prefix(roadAlignmentMaxTracks))
        let useValhalla = MapMatchingService.isConfigured

        isRoadAligning = true
        roadAlignProgress = 0
        roadAlignTotal = tracksToAlign.count
        roadAlignMessage = "Preparing road data…"
        roadAlignedCoordinates = [:]

        Task {
            var aligned: [UUID: [CLLocationCoordinate2D]] = [:]
            // For the MKDirections fallback only — distribute a request budget.
            let segmentLimits = alignmentSegmentLimits(for: tracksToAlign, requestBudget: roadAlignmentRequestBudget)

            // PRIMARY: on-device HMM map matching against locally cached OSM roads.
            // Road tiles download once (the only online step); afterwards alignment
            // works fully offline. Pad the bbox slightly so projections stay inside.
            var offlineIndex: RoadNetworkStore.RoadIndex?
            let unionBounds = tracksToAlign
                .compactMap { MapBounds($0.coordinates) }
                .reduce(nil as MapBounds?) { acc, b in acc.map { $0.union(b) } ?? b }
            if let bounds = unionBounds {
                offlineIndex = await RoadNetworkStore.shared.index(
                    minLat: bounds.minLat - 0.002, minLon: bounds.minLon - 0.002,
                    maxLat: bounds.maxLat + 0.002, maxLon: bounds.maxLon + 0.002,
                    allowDownload: true,
                    progress: { message in
                        Task { @MainActor in roadAlignMessage = message }
                    }
                )
            }
            let engineName = offlineIndex != nil
                ? "on-device map matching · road data © OpenStreetMap"
                : (useValhalla ? "Valhalla map matching" : "Apple Maps road data")
            await MainActor.run {
                roadAlignMessage = "Aligning \(tracksToAlign.count) routes (\(engineName))…"
            }

            for track in tracksToAlign {
                guard track.canRoadAlign else {
                    await MainActor.run { roadAlignProgress += 1 }
                    continue
                }

                // Always match on the full-resolution route (up to ~400 pts from the
                // cache), not the down-sampled render coords.
                let fullCoords = FlightDataStore.shared.loadRouteCoordinates(id: track.id)
                let coordsToAlign = fullCoords.count > track.coordinates.count ? fullCoords : track.coordinates

                // Cascade: on-device HMM vs cached OSM roads (OFFLINE, primary)
                // → Valhalla (optional key) → Apple Maps → offline smoother.
                var corrected: [CLLocationCoordinate2D]?
                var usedNetwork = false
                if let offlineIndex {
                    corrected = OfflineMapMatcher.match(coordinates: coordsToAlign, index: offlineIndex)
                }
                if corrected == nil, useValhalla {
                    corrected = await MapMatchingService.matchRoute(coordinates: coordsToAlign, costing: track.costing)
                    usedNetwork = true
                }
                if corrected == nil, offlineIndex == nil {
                    let maxSegments = segmentLimits[track.id] ?? 1
                    corrected = await roadAlignedRoute(
                        coordinates: coordsToAlign,
                        canRoadAlign: track.canRoadAlign,
                        transportType: track.transportType,
                        maxSegments: maxSegments,
                        requestDelayNanoseconds: roadAlignmentRequestSpacingNanoseconds
                    )
                    if corrected != nil { usedNetwork = true }
                }
                if corrected == nil {
                    // Off-road workout (trail/field) or no data → clean the trace offline.
                    corrected = RouteSmoother.smooth(coordsToAlign)
                }

                if let corrected { aligned[track.id] = corrected }

                await MainActor.run {
                    roadAlignProgress += 1
                    roadAlignedCoordinates = aligned
                }

                // Only pace when we actually hit the network.
                if usedNetwork {
                    try? await Task.sleep(nanoseconds: useValhalla ? 250_000_000 : roadAlignmentRequestSpacingNanoseconds)
                }
            }

            await MainActor.run {
                isRoadAligning = false
                let correctedCount = aligned.count
                roadAlignMessage = "Aligned \(correctedCount) of \(tracksToAlign.count) routes (\(engineName)). Shown on this map only."
                rebuildMultiPolylineFromDisplay()   // reflect aligned geometry in the overlay
                if let selectedTrack {
                    focus(selectedTrack)
                } else {
                    fitAllTracks()
                }
            }
        }
    }

    /// Rebuild the single overlay from the current display coordinates (aligned
    /// where available, raw otherwise) so corrected geometry is shown.
    private func rebuildMultiPolylineFromDisplay() {
        let polylines = tracks.compactMap { track -> MKPolyline? in
            let coords = displayCoordinates(for: track)
            guard coords.count > 1 else { return nil }
            return MKPolyline(coordinates: coords, count: coords.count)
        }
        allRoutesMultiPolyline = polylines.isEmpty ? nil : MKMultiPolyline(polylines)
        dataVersion += 1
    }

    private func resetRoadAlignment() {
        roadAlignedCoordinates = [:]
        roadAlignMessage = nil
        rebuildMultiPolylineFromDisplay()
        if let selectedTrack {
            focus(selectedTrack)
        } else {
            fitAllTracks()
        }
    }

    private func alignmentSegmentLimits(for tracks: [WorkoutMapTrack], requestBudget: Int) -> [UUID: Int] {
        guard !tracks.isEmpty, requestBudget > 0 else { return [:] }

        let sortedTracks = tracks.sorted { $0.distance > $1.distance }
        var limits = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, 0) })
        var remainingBudget = requestBudget

        for track in sortedTracks where remainingBudget > 0 {
            limits[track.id] = 1
            remainingBudget -= 1
        }

        let totalDistance = max(tracks.map(\.distance).reduce(0, +), 1)
        let baseSegments = max(1, min(4, requestBudget / max(tracks.count, 1)))

        while remainingBudget > 0 {
            var assignedInPass = false
            for track in sortedTracks where remainingBudget > 0 {
                let distanceShare = track.distance / totalDistance
                let maxForTrack = max(baseSegments, min(12, Int(ceil(Double(requestBudget) * distanceShare)) + 1))
                let current = limits[track.id] ?? baseSegments
                guard current < maxForTrack else { continue }

                limits[track.id] = current + 1
                remainingBudget -= 1
                assignedInPass = true
            }

            if !assignedInPass {
                break
            }
        }

        return limits
    }

    private func downloadAllWorkoutsFromHealthKit() {
        guard !isDownloadingWorkouts else { return }

        guard healthKitManager.isAuthorized else {
            healthKitManager.requestAuthorization { success, error in
                if success {
                    self.downloadAllWorkoutsFromHealthKit()
                } else {
                    DispatchQueue.main.async {
                        self.downloadMessage = "Please authorize HealthKit access to download workouts. \(error?.localizedDescription ?? "")"
                        self.showDownloadAlert = true
                    }
                }
            }
            return
        }

        isDownloadingWorkouts = true
        downloadProgress = 0
        downloadTotal = 0
        downloadMessage = "Finding workouts..."

        if #available(iOS 16.1, *) {
            DownloadLiveActivityManager.shared.beginBackgroundTask(name: "MapDownload")
            DownloadLiveActivityManager.shared.start(title: "Downloading Workouts", total: 0, message: "Finding workouts...")
        }

        downloadTask = Task {
            do {
                let candidates = try await fetchDownloadCandidates()

                await MainActor.run {
                    downloadTotal = candidates.count
                    downloadProgress = 0
                    if #available(iOS 16.1, *) {
                        DownloadLiveActivityManager.shared.update(progress: 0, total: candidates.count, message: candidates.isEmpty ? "No new workouts" : "Downloading routes...")
                    }
                }

                guard !candidates.isEmpty else {
                    await MainActor.run {
                        isDownloadingWorkouts = false
                        downloadMessage = "No new HealthKit route workouts to download."
                        if #available(iOS 16.1, *) {
                            DownloadLiveActivityManager.shared.end(finalMessage: "No new workouts")
                        }
                        loadTracks()
                    }
                    return
                }

                await MainActor.run {
                    downloadMessage = "Downloading 0/\(candidates.count)..."
                }

                var imported = 0
                var skipped = 0

                // Thermal-aware batching: concurrency shrinks and cooldowns grow
                // as the device heats up so the download can't overheat-crash.
                var index = 0
                while index < candidates.count {
                    if Task.isCancelled { break }
                    await ThermalDownloadPacing.waitWhileCritical()
                    if Task.isCancelled { break }

                    let batchSize = ThermalDownloadPacing.concurrency
                    let batchEnd = min(index + batchSize, candidates.count)
                    let batch = Array(candidates[index..<batchEnd])

                    let results = await withTaskGroup(of: Flight?.self, returning: [Flight?].self) { group in
                        for workout in batch {
                            group.addTask {
                                await self.fetchAndConvertWorkout(workout)
                            }
                        }
                        var collected: [Flight?] = []
                        for await result in group {
                            collected.append(result)
                        }
                        return collected
                    }

                    let validFlights: [Flight] = results.compactMap { $0 }
                    skipped += results.count - validFlights.count
                    imported += validFlights.count

                    // Off-main batched save
                    await FlightDataStore.shared.saveDownloadedFlights(validFlights)

                    index = batchEnd
                    await MainActor.run {
                        downloadProgress = index
                        downloadMessage = "Downloaded \(index)/\(candidates.count)..."
                        if #available(iOS 16.1, *) {
                            DownloadLiveActivityManager.shared.update(progress: index, total: candidates.count, message: "Downloading routes...")
                        }
                    }

                    await ThermalDownloadPacing.cooldown()
                }

                let wasCancelled = Task.isCancelled
                await MainActor.run {
                    isDownloadingWorkouts = false
                    downloadTask = nil
                    if wasCancelled {
                        downloadMessage = "Stopped: \(imported) imported, \(skipped) skipped."
                        if #available(iOS 16.1, *) {
                            DownloadLiveActivityManager.shared.end(finalMessage: "Stopped after \(imported) downloads")
                        }
                    } else {
                        downloadMessage = "Done: \(imported) imported, \(skipped) skipped (no route)."
                        if #available(iOS 16.1, *) {
                            DownloadLiveActivityManager.shared.end(finalMessage: "\(imported) imported, \(skipped) skipped")
                        }
                    }
                    showDownloadAlert = true
                    loadTracks()
                }
            } catch {
                await MainActor.run {
                    isDownloadingWorkouts = false
                    downloadTask = nil
                    downloadMessage = "Failed: \(error.localizedDescription)"
                    if #available(iOS 16.1, *) {
                        DownloadLiveActivityManager.shared.end(finalMessage: "Failed")
                    }
                    showDownloadAlert = true
                }
            }
        }
    }

    private func cancelDownload() {
        print("🛑 User requested map download cancel")
        downloadTask?.cancel()
    }

    private func fetchDownloadCandidates() async throws -> [HKWorkout] {
        let pageSize = 200
        var allCandidates: [HKWorkout] = []
        var beforeDate: Date? = nil
        let existingIDs = await MainActor.run {
            Set(flightDataStore.savedFlights.map(\.id))
                .union(Set(flightDataStore.savedFlights.compactMap(\.workoutUUID)))
        }

        while true {
            let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
                healthKitManager.fetchWorkouts(limit: pageSize, beforeDate: beforeDate) { result, error in
                    if let result {
                        continuation.resume(returning: result)
                    } else {
                        continuation.resume(throwing: error ?? NSError(domain: "HealthKit", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown error"]))
                    }
                }
            }

            let newCandidates = workouts
                .filter { shouldDownloadWorkout($0) }
                .filter { !existingIDs.contains($0.uuid) }

            allCandidates.append(contentsOf: newCandidates)

            await MainActor.run {
                downloadMessage = "Finding workouts... (\(allCandidates.count) candidates)"
            }

            if workouts.count < pageSize { break }
            beforeDate = workouts.last?.startDate.addingTimeInterval(-1)
        }

        return allCandidates
    }

    private func fetchAndConvertWorkout(_ workout: HKWorkout) async -> Flight? {
        let locations: [FlightLocation]? = await withCheckedContinuation { continuation in
            healthKitManager.fetchRoute(for: workout) { locs, _ in
                continuation.resume(returning: locs)
            }
        }

        guard let routeLocations = locations, routeLocations.count > 1 else {
            return nil
        }

        return convertWorkoutToMapFlight(workout, locations: routeLocations)
    }

    private func shouldDownloadWorkout(_ workout: HKWorkout) -> Bool {
        switch workout.workoutActivityType {
        case .running, .walking, .hiking, .cycling, .other:
            return true
        default:
            return false
        }
    }
}

private func roadAlignedRoute(
    coordinates: [CLLocationCoordinate2D],
    canRoadAlign: Bool,
    transportType: MKDirectionsTransportType,
    maxSegments: Int,
    requestDelayNanoseconds: UInt64
) async -> [CLLocationCoordinate2D]? {
    guard maxSegments > 0, canRoadAlign else { return nil }

    let segments = roadAlignmentSegments(from: coordinates, maxSegments: maxSegments)
    guard !segments.isEmpty else { return nil }

    var corrected: [CLLocationCoordinate2D] = []
    var acceptedRouteSegments = 0

    for (index, segment) in segments.enumerated() {
        if index > 0 {
            try? await Task.sleep(nanoseconds: requestDelayNanoseconds)
        }

        guard let start = segment.start,
              let end = segment.end else {
            continue
        }

        // Ask Apple for ALL candidate routes (alternates) for this segment and
        // pick the one that best fits the actual GPS sub-track — a lightweight
        // emission-probability style match instead of blindly taking route #1.
        let candidates = await appleRouteCandidates(from: start, to: end, transportType: transportType)
        let best = bestMatchingRoute(candidates, original: segment.original)

        if let best {
            acceptedRouteSegments += 1
            if corrected.isEmpty {
                corrected.append(contentsOf: best)
            } else {
                corrected.append(contentsOf: best.dropFirst())
            }
        } else {
            if corrected.isEmpty {
                corrected.append(contentsOf: segment.original)
            } else {
                corrected.append(contentsOf: segment.original.dropFirst())
            }
        }
    }

    return corrected.count > 1 && acceptedRouteSegments > 0 ? corrected : nil
}

/// Among candidate road routes, pick the one closest to the original GPS segment
/// (lowest average deviation) that still passes the plausibility check.
private func bestMatchingRoute(
    _ candidates: [[CLLocationCoordinate2D]],
    original: [CLLocationCoordinate2D]
) -> [CLLocationCoordinate2D]? {
    var best: [CLLocationCoordinate2D]?
    var bestScore = Double.greatestFiniteMagnitude
    for route in candidates {
        guard isPlausibleRoadRoute(route, forOriginalSegment: original) else { continue }
        let score = averageDistance(from: route, toPolyline: original)
        if score < bestScore {
            bestScore = score
            best = route
        }
    }
    return best
}

private func roadAlignmentSegments(from coordinates: [CLLocationCoordinate2D], maxSegments: Int) -> [RoadAlignmentSegment] {
    guard coordinates.count > 2, maxSegments > 0 else { return [] }

    var segments: [RoadAlignmentSegment] = []
    var currentSegment: [CLLocationCoordinate2D] = [coordinates[0]]
    var distanceSinceAnchor: CLLocationDistance = 0
    var previousBearing: Double?

    for index in 1..<coordinates.count {
        let previous = coordinates[index - 1]
        let current = coordinates[index]
        distanceSinceAnchor += distanceBetween(previous, current)

        let bearing = bearingBetween(previous, current)
        let turnDelta = previousBearing.map { bearingDelta($0, bearing) } ?? 0
        previousBearing = bearing

        currentSegment.append(current)

        let shouldAddDistanceAnchor = distanceSinceAnchor >= 90
        let shouldAddTurnAnchor = turnDelta >= 25 && distanceSinceAnchor >= 30

        if shouldAddDistanceAnchor || shouldAddTurnAnchor {
            segments.append(RoadAlignmentSegment(original: currentSegment))
            currentSegment = [current]
            distanceSinceAnchor = 0
        }
    }

    if currentSegment.count > 1 {
        segments.append(RoadAlignmentSegment(original: currentSegment))
    }

    guard segments.count > maxSegments else { return segments }

    let strideSize = max(1, Int(ceil(Double(segments.count) / Double(maxSegments))))
    var merged: [RoadAlignmentSegment] = []
    var index = 0

    while index < segments.count {
        let group = segments[index..<min(index + strideSize, segments.count)]
        let mergedCoordinates = group.enumerated().flatMap { groupIndex, segment in
            groupIndex == 0 ? segment.original : Array(segment.original.dropFirst())
        }
        merged.append(RoadAlignmentSegment(original: mergedCoordinates))
        index += strideSize
    }

    return merged
}

private func distanceBetween(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> CLLocationDistance {
    CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        .distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
}

private func isPlausibleRoadRoute(
    _ route: [CLLocationCoordinate2D],
    forOriginalSegment original: [CLLocationCoordinate2D]
) -> Bool {
    guard route.count > 1, original.count > 1 else { return false }

    let originalDistance = polylineDistance(original)
    let routeDistance = polylineDistance(route)
    let directDistance = distanceBetween(original[0], original[original.count - 1])
    let maxReasonableDistance = max(originalDistance * 1.45 + 60, directDistance * 1.8 + 60)

    guard routeDistance <= maxReasonableDistance else { return false }
    guard averageDistance(from: route, toPolyline: original) <= 45 else { return false }
    guard maxSampledDistance(from: route, toPolyline: original) <= 120 else { return false }
    guard maxSampledDistance(from: original, toPolyline: route) <= 120 else { return false }

    return true
}

private func polylineDistance(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
    guard coordinates.count > 1 else { return 0 }

    var distance: CLLocationDistance = 0
    for index in 1..<coordinates.count {
        distance += distanceBetween(coordinates[index - 1], coordinates[index])
    }
    return distance
}

private func averageDistance(from coordinates: [CLLocationCoordinate2D], toPolyline polyline: [CLLocationCoordinate2D]) -> CLLocationDistance {
    let samples = sampledCoordinates(coordinates, maximumPoints: 16)
    guard !samples.isEmpty else { return .greatestFiniteMagnitude }

    let total = samples
        .map { nearestDistance(from: $0, toPolyline: polyline) }
        .reduce(0, +)

    return total / Double(samples.count)
}

private func maxSampledDistance(from coordinates: [CLLocationCoordinate2D], toPolyline polyline: [CLLocationCoordinate2D]) -> CLLocationDistance {
    let samples = sampledCoordinates(coordinates, maximumPoints: 20)
    guard !samples.isEmpty else { return .greatestFiniteMagnitude }

    return samples
        .map { nearestDistance(from: $0, toPolyline: polyline) }
        .max() ?? .greatestFiniteMagnitude
}

private func sampledCoordinates(_ coordinates: [CLLocationCoordinate2D], maximumPoints: Int) -> [CLLocationCoordinate2D] {
    guard coordinates.count > maximumPoints else { return coordinates }

    let strideSize = max(1, coordinates.count / maximumPoints)
    var result = coordinates.enumerated().compactMap { index, coordinate in
        index % strideSize == 0 ? coordinate : nil
    }

    if let last = coordinates.last,
       result.last?.latitude != last.latitude || result.last?.longitude != last.longitude {
        result.append(last)
    }

    return result
}

private func nearestDistance(from coordinate: CLLocationCoordinate2D, toPolyline polyline: [CLLocationCoordinate2D]) -> CLLocationDistance {
    guard polyline.count > 1 else { return .greatestFiniteMagnitude }

    var nearest = CLLocationDistance.greatestFiniteMagnitude
    for index in 1..<polyline.count {
        let distance = distanceFrom(coordinate, toSegmentStart: polyline[index - 1], end: polyline[index])
        nearest = min(nearest, distance)
    }

    return nearest
}

private func distanceFrom(
    _ coordinate: CLLocationCoordinate2D,
    toSegmentStart start: CLLocationCoordinate2D,
    end: CLLocationCoordinate2D
) -> CLLocationDistance {
    let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    let metersPerDegreeLatitude = 111_320.0
    let metersPerDegreeLongitude = metersPerDegreeLatitude * cos(coordinate.latitude * .pi / 180)

    let startX = (start.longitude - coordinate.longitude) * metersPerDegreeLongitude
    let startY = (start.latitude - coordinate.latitude) * metersPerDegreeLatitude
    let endX = (end.longitude - coordinate.longitude) * metersPerDegreeLongitude
    let endY = (end.latitude - coordinate.latitude) * metersPerDegreeLatitude

    let segmentX = endX - startX
    let segmentY = endY - startY
    let segmentLengthSquared = segmentX * segmentX + segmentY * segmentY

    guard segmentLengthSquared > 0 else {
        return origin.distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude))
    }

    let projection = max(0, min(1, -(startX * segmentX + startY * segmentY) / segmentLengthSquared))
    let closestX = startX + projection * segmentX
    let closestY = startY + projection * segmentY

    return sqrt(closestX * closestX + closestY * closestY)
}

private func bearingBetween(_ lhs: CLLocationCoordinate2D, _ rhs: CLLocationCoordinate2D) -> Double {
    let lat1 = lhs.latitude * .pi / 180
    let lat2 = rhs.latitude * .pi / 180
    let lonDelta = (rhs.longitude - lhs.longitude) * .pi / 180

    let y = sin(lonDelta) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lonDelta)
    let bearing = atan2(y, x) * 180 / .pi
    return (bearing + 360).truncatingRemainder(dividingBy: 360)
}

private func bearingDelta(_ lhs: Double, _ rhs: Double) -> Double {
    let delta = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
    return delta > 180 ? 360 - delta : delta
}

private func appleRouteCandidates(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    transportType: MKDirectionsTransportType
) async -> [[CLLocationCoordinate2D]] {
    await withCheckedContinuation { continuation in
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = transportType
        request.requestsAlternateRoutes = true   // get all candidates to pick the best match

        MKDirections(request: request).calculate { response, error in
            if let error,
               let resetSeconds = mapKitThrottleResetSeconds(from: error) {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(resetSeconds + 2) * 1_000_000_000)
                    let retryRequest = MKDirections.Request()
                    retryRequest.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
                    retryRequest.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
                    retryRequest.transportType = transportType
                    retryRequest.requestsAlternateRoutes = true

                    MKDirections(request: retryRequest).calculate { retryResponse, _ in
                        let routes = retryResponse?.routes.map { $0.polyline.routeCoordinates } ?? []
                        continuation.resume(returning: routes)
                    }
                }
            } else {
                let routes = response?.routes.map { $0.polyline.routeCoordinates } ?? []
                continuation.resume(returning: routes)
            }
        }
    }
}

private func mapKitThrottleResetSeconds(from error: Error) -> Int? {
    let nsError = error as NSError
    guard nsError.domain == "GEOErrorDomain", nsError.code == -3 else { return nil }

    if let resetSeconds = nsError.userInfo["timeUntilReset"] as? Int {
        return resetSeconds
    }

    if let details = nsError.userInfo["details"] as? [[String: Any]],
       let resetSeconds = details.compactMap({ $0["timeUntilReset"] as? Int }).first {
        return resetSeconds
    }

    return 60
}

private func sampled(_ locations: [FlightLocation], maximumPoints: Int = 600) -> [FlightLocation] {
    guard locations.count > maximumPoints else { return locations }
    let strideSize = max(1, locations.count / maximumPoints)
    var result = locations.enumerated().compactMap { index, location in
        index % strideSize == 0 ? location : nil
    }

    if let last = locations.last, result.last?.id != last.id {
        result.append(last)
    }

    return result
}

private func downsampleCoordinates(_ coordinates: [CLLocationCoordinate2D], maxPoints: Int) -> [CLLocationCoordinate2D] {
    guard coordinates.count > maxPoints else { return coordinates }
    let strideSize = max(1, coordinates.count / maxPoints)
    var result: [CLLocationCoordinate2D] = []
    result.reserveCapacity(maxPoints + 1)
    var i = 0
    while i < coordinates.count {
        result.append(coordinates[i])
        i += strideSize
    }
    if let last = coordinates.last,
       result.last?.latitude != last.latitude || result.last?.longitude != last.longitude {
        result.append(last)
    }
    return result
}

private func convertWorkoutToMapFlight(_ workout: HKWorkout, locations: [FlightLocation]) -> Flight {
    var flight = Flight(id: workout.uuid, startDate: workout.startDate)
    flight.endDate = workout.endDate
    flight.locations = locations
    flight.workoutType = workout.workoutActivityType.rawValue
    flight.workoutUUID = workout.uuid

    var metrics = FlightMetrics()
    metrics.totalDistance = workout.totalDistance?.doubleValue(for: .meter()) ?? calculatedRouteDistance(from: locations)
    metrics.duration = workout.duration
    if metrics.duration > 0 {
        metrics.averageSpeed = metrics.totalDistance / metrics.duration
    }
    if #available(iOS 18.0, *) {
        metrics.caloriesBurned = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
        metrics.stepsCount = workout.statistics(for: HKQuantityType(.stepCount))?.sumQuantity()?.doubleValue(for: .count())
    } else {
        metrics.caloriesBurned = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0
        if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            metrics.stepsCount = workout.statistics(for: stepType)?.sumQuantity()?.doubleValue(for: .count())
        }
    }

    metrics.totalPoints = locations.count
    metrics.validPoints = locations.filter(\.isValid).count
    if metrics.totalPoints > 0 {
        metrics.averageAccuracy = locations.map(\.horizontalAccuracy).reduce(0, +) / Double(metrics.totalPoints)
        metrics.signalCoverage = Double(metrics.validPoints) / Double(metrics.totalPoints) * 100
        metrics.maxAltitude = locations.map(\.altitude).max() ?? 0
        metrics.minAltitude = locations.map(\.altitude).min() ?? 0
        metrics.currentAltitude = locations.last?.altitude ?? 0
    }

    var previous: FlightLocation?
    for location in locations {
        metrics.updateWithLocation(location, previousLocation: previous, elapsedTime: location.timestamp.timeIntervalSince(workout.startDate))
        previous = location
    }
    metrics.totalDistance = workout.totalDistance?.doubleValue(for: .meter()) ?? metrics.totalDistance
    metrics.duration = workout.duration
    if metrics.duration > 0 {
        metrics.averageSpeed = metrics.totalDistance / metrics.duration
    }

    flight.metrics = metrics
    return flight
}

private func calculatedRouteDistance(from locations: [FlightLocation]) -> Double {
    guard locations.count > 1 else { return 0 }
    var distance: Double = 0
    for index in 1..<locations.count {
        let segment = locations[index].distance(to: locations[index - 1])
        if segment < 1000 {
            distance += segment
        }
    }
    return distance
}

private func workoutTitle(for flight: Flight) -> String {
    guard let rawValue = flight.workoutType,
          let type = HKWorkoutActivityType(rawValue: rawValue) else {
        return "Workout"
    }

    switch type {
    case .running:
        return "Running"
    case .walking:
        return "Walking"
    case .cycling:
        return "Cycling"
    case .hiking:
        return "Hiking"
    case .other:
        return "Other"
    default:
        return "Workout"
    }
}

private func mapTransportType(for flight: Flight) -> MKDirectionsTransportType {
    guard let rawValue = flight.workoutType,
          let type = HKWorkoutActivityType(rawValue: rawValue) else {
        return .walking
    }

    switch type {
    case .cycling, .other:
        return .automobile
    default:
        return .walking
    }
}

private func canRoadAlign(flight: Flight) -> Bool {
    guard let rawValue = flight.workoutType,
          let type = HKWorkoutActivityType(rawValue: rawValue) else {
        return true
    }

    switch type {
    case .running, .walking, .hiking, .cycling:
        return true
    default:
        return false
    }
}

private extension MKPolyline {
    var routeCoordinates: [CLLocationCoordinate2D] {
        var coordinates = Array(repeating: CLLocationCoordinate2D(), count: pointCount)
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates
    }
}
