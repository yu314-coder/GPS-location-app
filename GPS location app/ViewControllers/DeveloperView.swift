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
                NavigationLink {
                    TeachFromLogView()
                } label: {
                    SettingsRow(symbol: "graduationcap.fill", tint: .indigo,
                                title: "Teach from a saved log",
                                subtitle: "Replay a recorded 50 Hz trace into the model")
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

// MARK: - Teach from a saved log

/// Replays a recorded raw trace into the learned model.
///
/// The model can only answer for conditions it has observed, and a flight is the one condition
/// that cannot be practised. But a flight WAS recorded, with GPS valid throughout, and its cabin
/// vibration predicts its own airspeed to a leave-one-out MAE of 43.3 km/h against a 253.7 km/h
/// baseline - skill +0.83, the same as the best mounted car drives. Those observations were
/// simply never kept, because the airborne partition did not exist when the flight happened.
///
/// So the evidence does not have to be gathered again by flying: the log already holds it.
struct TeachFromLogView: View {
    @State private var logs: [(url: URL, size: Int, modified: Date)] = []
    @State private var airborne = false
    @State private var busy: URL?
    @State private var result: String?

    private var rawLogs: [(url: URL, size: Int, modified: Date)] {
        logs.filter { $0.url.lastPathComponent.contains("raw50hz") }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $airborne) {
                    SettingsRow(symbol: "airplane", tint: .cyan, title: "This log is a flight",
                                subtitle: "Kept apart from the ground model")
                }
            } footer: {
                Text("Air and ground are separate memories. A cruise is quiet and so is a smooth road, so one store answering for both is wrong in either direction.")
            }

            Section {
                if rawLogs.isEmpty {
                    Text("No 50 Hz traces saved yet.")
                        .foregroundColor(.secondary).font(.callout)
                }
                ForEach(rawLogs, id: \.url) { log in
                    Button {
                        teach(log.url)
                    } label: {
                        HStack {
                            SettingsRow(symbol: "waveform.path", tint: .indigo,
                                        title: log.url.lastPathComponent
                                            .replacingOccurrences(of: "velocity_raw50hz_", with: "")
                                            .replacingOccurrences(of: ".csv", with: ""),
                                        subtitle: ByteCountFormatter.string(fromByteCount: Int64(log.size),
                                                                            countStyle: .file))
                            if busy == log.url { ProgressView().controlSize(.small) }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(busy != nil)
                }
            } header: {
                Text("Saved traces")
            } footer: {
                if let result {
                    Text(result).foregroundColor(.secondary)
                } else {
                    Text("Replays the trace through the same 4-second window a live workout uses, recording the signature it saw at each speed GPS measured. Nothing is inferred - only what the file already contains is used.")
                }
            }
        }
        .navigationTitle("Teach from a log")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { logs = SessionDiagnosticsRecorder.allSavedLogs() }
    }

    private func teach(_ url: URL) {
        busy = url
        result = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let n = WorkoutSession.shared.learnedSpeed.importRawLog(at: url, airborne: airborne)
            DispatchQueue.main.async {
                busy = nil
                result = n > 0
                    ? "Learned \(n) observations from this trace. The model now holds \(WorkoutSession.shared.learnedSpeed.observationCount)."
                    : "No usable observations - the trace has no GPS speeds to learn from."
            }
        }
    }
}
