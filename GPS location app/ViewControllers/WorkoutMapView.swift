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

    var coordinateCount: Int { coordinates.count }
}

private struct RoadAlignmentSegment {
    let original: [CLLocationCoordinate2D]

    var start: CLLocationCoordinate2D? { original.first }
    var end: CLLocationCoordinate2D? { original.last }
}

struct WorkoutMapView: View {
    @StateObject private var flightDataStore = FlightDataStore.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var selectedPeriod: WorkoutMapPeriod = .all
    @State private var customStartDate = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEndDate = Date()
    @State private var tracks: [WorkoutMapTrack] = []
    @State private var selectedTrackID: UUID?
    @State private var position: MapCameraPosition = .automatic
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

    private let routePalette: [Color] = [.blue, .green, .orange, .purple, .pink, .cyan, .indigo, .mint]
    private let healthKitManager = HealthKitManager.shared
    private let roadAlignmentRequestBudget = 40
    private let roadAlignmentRequestSpacingNanoseconds: UInt64 = 1_500_000_000

    private var isIPad: Bool { sizeClass == .regular }

    private var selectedTrack: WorkoutMapTrack? {
        guard let selectedTrackID else { return nil }
        return tracks.first { $0.id == selectedTrackID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MapReader { proxy in
                    Map(position: $position) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            MapPolyline(coordinates: displayCoordinates(for: track))
                                .stroke(
                                    routeColor(for: index).opacity(track.id == selectedTrackID ? 1.0 : 0.55),
                                    lineWidth: track.id == selectedTrackID ? 5 : 3
                                )
                        }

                        if let selectedTrack {
                            let coordinates = displayCoordinates(for: selectedTrack)
                            if let labelCoordinate = labelCoordinate(for: selectedTrack) {
                                Annotation("", coordinate: labelCoordinate, anchor: .bottom) {
                                    selectedTrackMapLabel(selectedTrack)
                                }
                            }

                            if let first = coordinates.first {
                                Marker("Start", coordinate: first)
                                    .tint(.green)
                            }

                            if let last = coordinates.last {
                                Marker("End", coordinate: last)
                                    .tint(.red)
                            }
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .simultaneousGesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                if let coordinate = proxy.convert(value.location, from: .local) {
                                    selectNearestTrack(to: coordinate)
                                }
                            }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }

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
                    Button(action: fitAllTracks) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(tracks.isEmpty)
                }
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
            .onChange(of: flightDataStore.savedFlights.count) { loadTracks() }
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

                Button(action: downloadAllWorkoutsFromHealthKit) {
                    Label(
                        isDownloadingWorkouts ? "Downloading \(downloadProgress)/\(downloadTotal)" : "Download All",
                        systemImage: isDownloadingWorkouts ? "hourglass" : "square.and.arrow.down"
                    )
                    .font(.caption)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDownloadingWorkouts || isRoadAligning)
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

            Text(String(format: "%.1f km", track.distance / 1000))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.blue)
        }
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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
        let summaries = filteredSummaries()

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = summaries.compactMap { summary -> WorkoutMapTrack? in
                let fullFlight = FlightDataStore.shared.loadFlightDetails(id: summary.id) ?? summary
                guard fullFlight.locations.count > 1 else { return nil }

                let sampledLocations = sampled(fullFlight.locations)
                let coordinates = sampledLocations.map { $0.toCLLocation().coordinate }
                guard coordinates.count > 1 else { return nil }

                return WorkoutMapTrack(
                    id: fullFlight.id,
                    title: workoutTitle(for: fullFlight),
                    startDate: fullFlight.startDate,
                    distance: fullFlight.metrics?.totalDistance ?? 0,
                    duration: fullFlight.metrics?.duration ?? fullFlight.duration,
                    coordinates: coordinates,
                    transportType: mapTransportType(for: fullFlight),
                    canRoadAlign: canRoadAlign(flight: fullFlight)
                )
            }
            .sorted { $0.startDate > $1.startDate }

            DispatchQueue.main.async {
                tracks = loaded
                roadAlignedCoordinates = [:]
                roadAlignMessage = nil
                if let selectedTrackID, !loaded.contains(where: { $0.id == selectedTrackID }) {
                    self.selectedTrackID = nil
                }
                isLoading = false
                fitAllTracks()
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

    private func fitAllTracks() {
        let coordinates = tracks.flatMap { displayCoordinates(for: $0) }
        setMapRegion(for: coordinates)
    }

    private func focus(_ track: WorkoutMapTrack) {
        setMapRegion(for: displayCoordinates(for: track))
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

    private func setMapRegion(for coordinates: [CLLocationCoordinate2D]) {
        guard !coordinates.isEmpty else {
            position = .automatic
            return
        }

        let minLat = coordinates.map(\.latitude).min() ?? 0
        let maxLat = coordinates.map(\.latitude).max() ?? 0
        let minLon = coordinates.map(\.longitude).min() ?? 0
        let maxLon = coordinates.map(\.longitude).max() ?? 0

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.25, 0.01),
            longitudeDelta: max((maxLon - minLon) * 1.25, 0.01)
        )

        withAnimation {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    private func alignVisibleTracksToRoads() {
        guard !tracks.isEmpty, !isRoadAligning else { return }

        isRoadAligning = true
        roadAlignProgress = 0
        roadAlignTotal = tracks.count
        roadAlignMessage = "Building rate-limited Apple Maps routes for visible tracks. Saved workout data will not be changed."
        roadAlignedCoordinates = [:]

        let tracksToAlign = tracks
        Task {
            var aligned: [UUID: [CLLocationCoordinate2D]] = [:]
            let segmentLimits = alignmentSegmentLimits(for: tracksToAlign, requestBudget: roadAlignmentRequestBudget)

            for track in tracksToAlign {
                let maxSegments = segmentLimits[track.id] ?? 1
                if let corrected = await roadAlignedRoute(
                    for: track,
                    maxSegments: maxSegments,
                    requestDelayNanoseconds: roadAlignmentRequestSpacingNanoseconds
                ) {
                    aligned[track.id] = corrected
                }

                await MainActor.run {
                    roadAlignProgress += 1
                    roadAlignedCoordinates = aligned
                }
            }

            await MainActor.run {
                isRoadAligning = false
                let correctedCount = aligned.count
                roadAlignMessage = correctedCount == tracksToAlign.count
                    ? "Road alignment is shown on this map only. Requests are spaced to avoid Apple Maps throttling."
                    : "Aligned \(correctedCount) of \(tracksToAlign.count) tracks. Some tracks still use original GPS to avoid Apple Maps throttling."
                if let selectedTrack {
                    focus(selectedTrack)
                } else {
                    fitAllTracks()
                }
            }
        }
    }

    private func resetRoadAlignment() {
        roadAlignedCoordinates = [:]
        roadAlignMessage = nil
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

        let startDownload = {
            isDownloadingWorkouts = true
            downloadProgress = 0
            downloadTotal = 0
            downloadMessage = "Loading HealthKit workouts and routes..."

            healthKitManager.fetchWorkouts { workouts, error in
                guard let workouts else {
                    DispatchQueue.main.async {
                        isDownloadingWorkouts = false
                        downloadMessage = "Failed to load HealthKit workouts: \(error?.localizedDescription ?? "Unknown error")"
                        showDownloadAlert = true
                    }
                    return
                }

                let existingIDs = Set(flightDataStore.savedFlights.map(\.id))
                let existingWorkoutIDs = Set(flightDataStore.savedFlights.compactMap(\.workoutUUID))
                let candidates = workouts
                    .filter { shouldDownloadWorkout($0) }
                    .filter { !existingIDs.contains($0.uuid) && !existingWorkoutIDs.contains($0.uuid) }

                DispatchQueue.main.async {
                    downloadTotal = candidates.count
                    downloadProgress = 0
                    downloadMessage = candidates.isEmpty
                        ? "No new HealthKit route workouts to download."
                        : "Downloading route data from HealthKit..."
                }

                guard !candidates.isEmpty else {
                    DispatchQueue.main.async {
                        isDownloadingWorkouts = false
                        loadTracks()
                    }
                    return
                }

                downloadNextWorkout(candidates, index: 0, imported: 0, skipped: 0, failed: 0)
            }
        }

        if healthKitManager.isAuthorized {
            startDownload()
        } else {
            healthKitManager.requestAuthorization { success, error in
                if success {
                    startDownload()
                } else {
                    downloadMessage = "Please authorize HealthKit access to download workouts. \(error?.localizedDescription ?? "")"
                    showDownloadAlert = true
                }
            }
        }
    }

    private func downloadNextWorkout(
        _ workouts: [HKWorkout],
        index: Int,
        imported: Int,
        skipped: Int,
        failed: Int
    ) {
        guard index < workouts.count else {
            DispatchQueue.main.async {
                isDownloadingWorkouts = false
                downloadMessage = "Downloaded \(imported) workouts. Skipped \(skipped). Failed \(failed)."
                showDownloadAlert = true
                loadTracks()
            }
            return
        }

        let workout = workouts[index]
        healthKitManager.fetchRoute(for: workout) { locations, _ in
            let routeLocations = locations ?? []

            if routeLocations.count > 1 {
                let flight = convertWorkoutToMapFlight(workout, locations: routeLocations)
                DispatchQueue.main.async {
                    FlightDataStore.shared.saveFlight(flight)
                    downloadProgress = index + 1
                    downloadMessage = "Downloaded \(downloadProgress)/\(downloadTotal)"
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                    downloadNextWorkout(workouts, index: index + 1, imported: imported + 1, skipped: skipped, failed: failed)
                }
            } else {
                DispatchQueue.main.async {
                    downloadProgress = index + 1
                    downloadMessage = "Downloaded \(downloadProgress)/\(downloadTotal)"
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
                    downloadNextWorkout(workouts, index: index + 1, imported: imported, skipped: skipped + 1, failed: failed)
                }
            }
        }
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
    for track: WorkoutMapTrack,
    maxSegments: Int,
    requestDelayNanoseconds: UInt64
) async -> [CLLocationCoordinate2D]? {
    guard maxSegments > 0, track.canRoadAlign else { return nil }

    let segments = roadAlignmentSegments(from: track.coordinates, maxSegments: maxSegments)
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

        let route = await appleRouteCoordinates(from: start, to: end, transportType: track.transportType)

        if let route,
           isPlausibleRoadRoute(route, forOriginalSegment: segment.original) {
            acceptedRouteSegments += 1
            if corrected.isEmpty {
                corrected.append(contentsOf: route)
            } else {
                corrected.append(contentsOf: route.dropFirst())
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

private func appleRouteCoordinates(
    from start: CLLocationCoordinate2D,
    to end: CLLocationCoordinate2D,
    transportType: MKDirectionsTransportType
) async -> [CLLocationCoordinate2D]? {
    await withCheckedContinuation { continuation in
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = transportType
        request.requestsAlternateRoutes = false

        MKDirections(request: request).calculate { response, error in
            if let error,
               let resetSeconds = mapKitThrottleResetSeconds(from: error) {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(resetSeconds + 2) * 1_000_000_000)
                    let retryRequest = MKDirections.Request()
                    retryRequest.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
                    retryRequest.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
                    retryRequest.transportType = transportType
                    retryRequest.requestsAlternateRoutes = false

                    MKDirections(request: retryRequest).calculate { retryResponse, _ in
                        continuation.resume(returning: retryResponse?.routes.first?.polyline.routeCoordinates)
                    }
                }
            } else {
                continuation.resume(returning: response?.routes.first?.polyline.routeCoordinates)
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
        return "Flight"
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
