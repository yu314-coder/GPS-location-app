import SwiftUI
import HealthKit
import UniformTypeIdentifiers

/// DEVELOPER MODE: Import a workout (build 127). See WorkoutImporter and WorkoutLogReplay.
struct WorkoutImportView: View {
    @StateObject private var importer = WorkoutImporter()
    @State private var picking = false
    @State private var chosen: WorkoutImporter.Source?
    @State private var rerunFlight = true
    @State private var useLoggedGPS = false
    @State private var type: HKWorkoutActivityType = .other
    @State private var toHealth = true
    @State private var replaceSameMoment = false
    @State private var done: String?

    // The same list the workout screen offers (LiveSessionView.workoutTypes).
    private let types: [(HKWorkoutActivityType, String, String)] = [
        (.cycling, "Cycling", "bicycle"),
        (.running, "Running", "figure.run"),
        (.walking, "Walking", "figure.walk"),
        (.hiking, "Hiking", "mountain.2.fill"),
        (.other, "Other", "figure.mixed.cardio"),
        (.traditionalStrengthTraining, "General", "figure.mixed.cardio")
    ]

    private let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.allowedUnits = [.useKB, .useMB, .useGB]; f.countStyle = .file; return f
    }()

    var body: some View {
        List {
            Section {
                Button { picking = true } label: {
                    SettingsRow(symbol: "square.and.arrow.down", tint: .blue, title: "Choose files or a folder",
                                subtitle: "The other phone's logs, or a flight_details file")
                }
                .buttonStyle(.plain)
                .disabled(importer.busy)
            } footer: {
                Text("On the other phone: Developer → Session logs → Share all, then AirDrop or save to Files. A recording is its velocity_events, velocity_debug and velocity_raw50hz files; the raw file is what lets a flight be drawn again.")
            }

            if !importer.sources.isEmpty {
                Section {
                    ForEach(importer.sources) { source in
                        Button { chosen = source } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(source)).font(.body)
                                    Text(detail(source)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if chosen == source { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: { Text("Found") }

                if let chosen {
                    Section {
                        if case .logs(let set) = chosen {
                            Toggle("Re-run a flight with this build", isOn: $rerunFlight)
                                .disabled(!set.canRerunFlight)
                            Toggle("Use the GPS logged in Force Velocity", isOn: $useLoggedGPS)
                        }
                        Button(importer.preview == nil ? "Read" : "Read again") {
                            importer.read(chosen, rerunFlight: rerunFlight, useLoggedGPS: useLoggedGPS)
                        }
                        .disabled(importer.busy)
                    } footer: {
                        Text("A flight is found in the logs and drawn again with this build's takeoff, direction, cabin clock and speed. The ground is as the phone drew it: its GPS fixes and its dead-reckoned steps between them. In Force Velocity the app ignored GPS and logged it only as an answer key, so it is left out unless you switch this on.")
                    }
                }
            }

            if importer.busy || importer.status != nil {
                Section {
                    if importer.busy, importer.progress > 0 { ProgressView(value: importer.progress) }
                    if let s = importer.status { Text(s).font(.callout).foregroundStyle(.secondary) }
                    if importer.busy { Button("Stop", role: .cancel) { importer.cancel() } }
                }
            }

            if let p = importer.preview {
                Section {
                    StaticMapView(locations: p.flight.locations)
                        .frame(height: 260)
                        .listRowInsets(EdgeInsets())
                    ForEach(Array(p.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.0).foregroundStyle(.secondary)
                            Spacer()
                            Text(line.1).multilineTextAlignment(.trailing).monospacedDigit()
                        }
                        .font(.callout)
                    }
                    ForEach(p.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                } header: { Text("Preview") }

                Section {
                    Picker("Workout type", selection: $type) {
                        ForEach(types, id: \.0.rawValue) { t in Label(t.1, systemImage: t.2).tag(t.0) }
                    }
                    Toggle("Save to Apple Health", isOn: $toHealth)
                    if let same = p.sameMoment {
                        Toggle(isOn: $replaceSameMoment) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Replace this phone's workout")
                                Text(String(format: "Started at the same time, %.1f km. It is deleted here%@.",
                                            (same.metrics?.totalDistance ?? 0) / 1000,
                                            same.workoutUUID != nil ? " and in Apple Health" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        importer.save(type: type, toHealth: toHealth, replaceSameMoment: replaceSameMoment) { done = $0 }
                    } label: {
                        Label("Save workout", systemImage: "tray.and.arrow.down.fill")
                    }
                    .disabled(importer.busy)
                } header: { Text("Save") } footer: {
                    Text("The type only names the workout in Apple Health, but Health adds walking distance and estimated steps for Walking, Running and Hiking, so a flight is best saved as Other. The type is saved exactly as chosen, whatever Settings → Save as says.")
                }
            }

            if let done {
                Section { Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .navigationTitle("Import a workout")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .json, .folder, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                chosen = nil; done = nil
                importer.receive(urls)
            }
        }
        .onChange(of: importer.sources) { _, s in if chosen == nil, s.count == 1 { chosen = s.first } }
        .onChange(of: chosen) { _, c in
            if case .logs(let set)? = c { rerunFlight = set.canRerunFlight }
        }
        .onChange(of: importer.preview?.flight.id) { _, _ in
            if let raw = importer.preview?.flight.workoutType, let t = HKWorkoutActivityType(rawValue: raw),
               types.contains(where: { $0.0 == t }) { type = t } else { type = .other }
            // A flight goes to Health as Other unless chosen otherwise: no estimated steps for 3,000 km.
            if importer.preview?.flight.notes?.contains("flight re-run") == true { type = .other }
            replaceSameMoment = false
        }
    }

    private func title(_ s: WorkoutImporter.Source) -> String {
        switch s {
        case .logs(let set): return "Recording " + set.stamp.replacingOccurrences(of: "_", with: " ")
        case .saved(let url): return url.lastPathComponent
        }
    }

    private func detail(_ s: WorkoutImporter.Source) -> String {
        switch s {
        case .logs(let set):
            let parts = [set.events != nil ? "events" : nil, set.debug != nil ? "debug" : nil,
                         set.raw.isEmpty ? nil : (set.raw.count == 1 ? "raw motion" : "raw motion ×\(set.raw.count)")].compactMap { $0 }
            return parts.joined(separator: " · ") + " · " + sizeFormatter.string(fromByteCount: set.bytes)
        case .saved: return "A saved workout, as that phone saved it"
        }
    }
}
