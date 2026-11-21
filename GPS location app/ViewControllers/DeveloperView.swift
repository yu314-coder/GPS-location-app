import SwiftUI
import MapKit

/// The screen behind the version number.
///
/// Everything here already existed but was reachable only by connecting a Mac or by exporting a
/// log from inside a running workout. That mattered: this app is debugged almost entirely from
/// its own recordings, and after a flight — the one recording that cannot be repeated — the logs
/// were awkward to get at. Hidden behind five taps because it is not for everyday use, and
/// visible at all because it is genuinely needed.
struct DeveloperView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var logs: [(url: URL, size: Int, modified: Date)] = []
    @State private var shareItems: [Any] = []
    @State private var showingShare = false
    @State private var showingDeleteConfirm = false
    @State private var showingDeleteOriginals = false
    @State private var showingRestoreOriginals = false
    private struct RestoreNote: Identifiable { let id = UUID(); let restored: Int; let kept: Int }
    @ObservedObject private var compactor = LogCompactor.shared
    @State private var modelSummary = ""
    // DEV ONLY - remove before the final release (the flight-map download below).
    @StateObject private var tiles = OfflineTileCache.shared
    @State private var tileBytes: Int64 = 0

    private let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        List {
            // A header rather than another row of text: what is on this screen is mostly
            // numbers, and the two that matter most — which build, and how much evidence the
            // speed model holds — should be readable without scrolling.
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Bundle.appVersionDisplay)
                        .font(.system(.largeTitle, design: .rounded))
                        .fontWeight(.semibold)
                    HStack(spacing: 4) {
                        StatTile(value: "\(logs.count)", label: "logs")
                        StatTile(value: "\(WorkoutSession.shared.learnedSpeed.observationCount)",
                                 label: "observations")
                        StatTile(value: "\(Int(WorkoutSession.shared.learnedSpeed.maxLearnedSpeed * 3.6)) km/h",
                                 label: "taught to")
                    }
                }
                .padding(.vertical, 6)
                .listRowBackground(Color.clear)
            }

            // Build 127: a workout from another phone's logs, a flight in it drawn again with this build.
            Section {
                NavigationLink {
                    WorkoutImportView()
                } label: {
                    SettingsRow(symbol: "square.and.arrow.down.on.square", tint: .indigo,
                                title: "Import or re-run a workout",
                                subtitle: "This phone's recordings, or another phone's logs")
                }
                // Build 161: the Recalc / Resync controls that left the Workouts tab, on the same list.
                NavigationLink {
                    EnhancedFlightHistoryView(maintenance: true)
                        .environment(\.workoutMaintenance, true)
                        .navigationTitle("Workout maintenance")
                } label: {
                    SettingsRow(symbol: "wrench.and.screwdriver", tint: .orange,
                                title: "Workout maintenance",
                                subtitle: "Recalculate distance, resync to Apple Health")
                }
            } header: {
                Text("Workouts")
            } footer: {
                Text("Rebuilds a recording from its logs, re-runs a flight in it with this build's flight code, and saves it here and to Apple Health with the type you choose. Everything is saved as a new workout; nothing already here is replaced. Workout maintenance is the Workouts list with its Recalc, Resync and Recalculate Distance buttons.")
            }

            // Build 161: everything about stored (compressed) data in one place.
            Section {
                if compactor.running || compactor.pending.count > 0 {
                    Button { compactor.offerNow() } label: {
                        SettingsRow(symbol: "archivebox", tint: .teal,
                                    title: compactor.running ? "Compressing…" : "Compress stored data",
                                    subtitle: compactor.running
                                        ? "\(compactor.progress.done) of \(compactor.progress.total) files · \(compactor.percent)%"
                                        : "\(compactor.pending.count) files, \(LogCompactor.megabytes(compactor.pending.bytes)) uncompressed")
                    }
                    .buttonStyle(.plain)
                    .disabled(compactor.running)
                }
                if compactor.originalsKept > 0 {
                    Button { showingRestoreOriginals = true } label: {
                        SettingsRow(symbol: "arrow.uturn.backward.circle", tint: .blue, title: "Restore originals",
                                    subtitle: "Put the uncompressed files back and remove their compressed copies")
                    }
                    .buttonStyle(.plain)
                    .disabled(compactor.running)
                    Button(role: .destructive) { showingDeleteOriginals = true } label: {
                        SettingsRow(symbol: "trash", tint: .red, title: "Delete originals",
                                    subtitle: "\(LogCompactor.megabytes(compactor.originalsKept)) in Files → Before compression")
                    }
                    .buttonStyle(.plain)
                    .disabled(compactor.running)
                }
                if !compactor.running && compactor.pending.count == 0 && compactor.originalsKept == 0 {
                    Text("All logs and saved routes are compressed.")
                        .foregroundColor(.secondary).font(.callout)
                }
            } header: {
                Text("Stored data")
            } footer: {
                Text("Compressed files are read back byte for byte and opened the way the app opens them before anything else happens. While you test, the uncompressed originals are kept in Files → Before compression: Restore originals undoes the compression, Delete originals frees the space.")
            }


            Section {
                NavigationLink {
                    PermissionTestView()
                } label: {
                    SettingsRow(symbol: "stethoscope", tint: .teal, title: "Diagnostics",
                                subtitle: "Permissions, GPS, performance")
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Permission state, GPS and HealthKit checks, and performance counters. This used to occupy a tab of its own.")
            }

            Section {
                if logs.isEmpty {
                    Text("No session logs yet.")
                        .foregroundColor(.secondary)
                        .font(.callout)
                } else {
                    ForEach(logs, id: \.url) { log in
                        Button {
                            shareItems = [log.url]
                            showingShare = true
                        } label: {
                            HStack(spacing: 12) {
                                SettingsIcon(symbol: log.url.lastPathComponent.contains("raw50hz")
                                             ? "waveform" : "list.bullet.rectangle",
                                             tint: log.url.lastPathComponent.hasPrefix("watch_")
                                             ? .purple : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(log.url.lastPathComponent)
                                        .font(.footnote)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    HStack(spacing: 8) {
                                        Text(byteFormatter.string(fromByteCount: Int64(log.size)))
                                        Text(log.modified, style: .date)
                                        Text(log.modified, style: .time)
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "square.and.arrow.up")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        shareItems = logs.map(\.url)
                        showingShare = true
                    } label: {
                        SettingsRow(symbol: "square.and.arrow.up", tint: .blue,
                                    title: "Share all", subtitle: "\(logs.count) files")
                    }
                    .buttonStyle(.plain)
                    Button(role: .destructive) { showingDeleteConfirm = true } label: {
                        SettingsRow(symbol: "trash.fill", tint: .red, title: "Delete all logs")
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Session logs")
            } footer: {
                Text("Per workout: one row per second of dead reckoning, the 50 Hz sensor trace, and every GPS fix and barometer reading. Written as the workout runs and kept until deleted here. The raw trace of a long flight can reach hundreds of megabytes.")
            }

            Section {
                if modelSummary.isEmpty {
                    Text("Not loaded yet — start a workout once.")
                        .foregroundColor(.secondary)
                        .font(.callout)
                } else {
                    Text(modelSummary)
                        .font(.system(.footnote, design: .monospaced))
                }
            } header: {
                Text("Learned speed model")
            } footer: {
                Text("Signatures paired with GPS-measured speeds, learned automatically on every trip with GPS. Until it holds 3,000 of them, Velocity Mode reads speed with the built-in network instead.")
            }

            // DEV ONLY - remove before the final release: the map along one flight, downloaded on
            // the ground so the drawn route can be checked against it in the air.
            Section {
                Button {
                    tiles.downloadFlightCorridor(
                        from: CLLocationCoordinate2D(latitude: 25.0777, longitude: 121.2328),   // Taoyuan (TPE)
                        to: CLLocationCoordinate2D(latitude: 1.3644, longitude: 103.9915))      // Changi (SIN)
                } label: {
                    SettingsRow(symbol: "airplane", tint: .orange,
                                title: "Download map: Taiwan → Singapore",
                                subtitle: tiles.isDownloading
                                    ? "Downloading \(tiles.downloadedCount) of \(tiles.totalToDownload) tiles"
                                    : "Map tiles on this phone: \(byteFormatter.string(fromByteCount: tileBytes))")
                }
                .buttonStyle(.plain)
                .disabled(tiles.isDownloading)
            } header: {
                Text("Flight map (test only)")
            } footer: {
                Text("About 850 map tiles along the route, about 150 km either side, plus both airports. Download on Wi-Fi before the flight; in the air the live map draws from them. Zoomed in past them at sea, the map enlarges the nearest stored tile.")
            }
            // Summed off the main thread (build 160): a folder of map tiles listed at every appear.
            .onAppear { refreshTileBytes() }
            .onChange(of: tiles.isDownloading) { _, busy in if !busy { refreshTileBytes() } }

            Section {
                infoRow("Version", Bundle.appVersionDisplay)
                infoRow("Bundle", Bundle.main.bundleIdentifier ?? "—")
                infoRow("iOS", UIDevice.current.systemVersion)
                infoRow("Device", Bundle.deviceModelIdentifier)
            } header: {
                Text("Build")
            }

        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload(); compactor.refreshOriginals(); compactor.refreshPending() }
        .sheet(isPresented: $showingShare) { ShareSheet(items: shareItems) }
        .alert("Restore the originals?", isPresented: $showingRestoreOriginals) {
            Button("Restore") { compactor.restoreOriginals() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The uncompressed files go back where they were and their compressed copies are removed. A saved route changed since it was compressed stays as it is.")
        }
        .alert(item: Binding(get: { compactor.restoreResult.map { RestoreNote(restored: $0.restored, kept: $0.kept) } },
                             set: { if $0 == nil { compactor.restoreResult = nil } })) { r in
            Alert(title: Text("Originals restored"),
                  message: Text("\(r.restored) files restored." + (r.kept > 0 ? " \(r.kept) left compressed (changed since, or already back)." : "")),
                  dismissButton: .default(Text("OK")))
        }
        .alert("Delete the originals?", isPresented: $showingDeleteOriginals) {
            Button("Delete", role: .destructive) { compactor.deleteOriginals() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Frees \(LogCompactor.megabytes(compactor.originalsKept)). The compressed copies stay and hold the same data.")
        }
        .alert("Delete all session logs?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                SessionDiagnosticsRecorder.deleteAllSavedLogs()
                reload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone. Export anything you still need first.")
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
        }
    }

    /// The tile folder's size, read in the background (build 160).
    private func refreshTileBytes() {
        let tiles = self.tiles
        Task {
            let bytes = await Task.detached(priority: .userInitiated) { tiles.cacheSizeBytes() }.value
            tileBytes = bytes
        }
    }

    private func reload() {
        // The ~750 logs are listed off the main thread (build 160); the list fills in when the listing is done.
        Task {
            let found = await Task.detached(priority: .userInitiated) { SessionDiagnosticsRecorder.allSavedLogs() }.value
            logs = found
        }
        let model = WorkoutSession.shared.learnedSpeed
        let calibration = model.calibration
        modelSummary = """
        observations   \(model.observationCount)
        fastest taught \(String(format: "%.0f", model.maxLearnedSpeed * 3.6)) km/h
        correction     ×\(String(format: "%.2f", calibration.slope)) \(String(format: "%+.1f", calibration.intercept)) m/s
        usable         \(model.isUsable ? "yes" : "not yet")
        """
    }
}

extension Bundle {
    /// "1.3 (134)" — the number that decides whether a log means anything, and the first thing
    /// worth knowing when a recording looks wrong.
    static var appVersionDisplay: String {
        let short = main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    static var deviceModelIdentifier: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "?" }
        }
        return machine
    }
}
