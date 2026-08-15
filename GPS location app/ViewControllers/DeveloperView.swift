import SwiftUI

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
    @State private var showingForgetConfirm = false
    @State private var modelSummary = ""

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

            Section {
                infoRow("Version", Bundle.appVersionDisplay)
                infoRow("Bundle", Bundle.main.bundleIdentifier ?? "—")
                infoRow("iOS", UIDevice.current.systemVersion)
                infoRow("Device", Bundle.deviceModelIdentifier)
            } header: {
                Text("Build")
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
                Button(role: .destructive) { showingForgetConfirm = true } label: {
                    SettingsRow(symbol: "trash.fill", tint: .red, title: "Forget learned speeds")
                }
                .buttonStyle(.plain)
            } header: {
                Text("Learned speed model")
            } footer: {
                Text("Signatures paired with GPS-measured speeds, used when GPS is unavailable. Forgetting means it must be taught again from scratch.")
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
                            VStack(alignment: .leading, spacing: 3) {
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
                        }
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
                Text("One row per second of dead reckoning, plus the 50 Hz sensor trace. The raw trace of a long flight can reach tens of megabytes.")
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .sheet(isPresented: $showingShare) { ShareSheet(items: shareItems) }
        .alert("Delete all session logs?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) {
                SessionDiagnosticsRecorder.deleteAllSavedLogs()
                reload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone. Export anything you still need first.")
        }
        .alert("Forget learned speeds?", isPresented: $showingForgetConfirm) {
            Button("Forget", role: .destructive) {
                WorkoutSession.shared.learnedSpeed.forget()
                reload()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The model will have to relearn from GPS across future trips.")
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

    private func reload() {
        logs = SessionDiagnosticsRecorder.allSavedLogs()
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
