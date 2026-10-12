import SwiftUI
import HealthKit
import UniformTypeIdentifiers

/// DEVELOPER MODE: Import a workout (build 127). See WorkoutImporter and WorkoutLogReplay.
/// Build 128: this phone's own recordings are listed directly, and a workout's detail screen opens this with its
/// own recording chosen (`preselectStamp`) and read at once, showing only that recording; saving it in place of the
/// original closes this and calls `onReplaced`, and the detail screen of the deleted original then closes too.
struct WorkoutImportView: View {
    var preselectStamp: String? = nil
    var onReplaced: (() -> Void)? = nil
    @StateObject private var importer = WorkoutImporter()
    @Environment(\.dismiss) private var dismiss
    @State private var showAllOwn = false
    @State private var didPreselect = false
    @State private var picking = false
    @State private var chosen: WorkoutImporter.Source?
    @State private var rerunFlight = true
    @State private var useLoggedGPS = false
    @State private var type: HKWorkoutActivityType = .other
    @State private var toHealth = true
    /// Another phone's workout only: replace this phone's workouts it overlaps. Its own recording always does.
    @State private var replace = false
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

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"; return f
    }()
    private static let shownFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    /// Opened from a workout's detail screen: that workout only.
    private var focused: Bool { preselectStamp != nil }

    var body: some View {
        List {
            if focused {
                Section {
                    if let chosen {
                        sourceRow(chosen)
                    } else if importer.ownLoaded {
                        Text("This workout's recording is no longer on this phone.").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                } header: {
                    Text("This workout's recording")
                } footer: {
                    Text("Drawn again from this phone's own logs with this build. Saved, it takes the original's place here and in Apple Health unless you switch that off below.")
                }
            } else {
                Section {
                    if importer.ownLoaded, importer.ownSources.isEmpty {
                        Text("No recordings on this phone.").foregroundStyle(.secondary)
                    }
                    ForEach(showAllOwn ? importer.ownSources : Array(importer.ownSources.prefix(8))) { source in
                        sourceRow(source)
                    }
                    if !showAllOwn, importer.ownSources.count > 8 {
                        Button("Show all \(importer.ownSources.count) recordings") { showAllOwn = true }
                    }
                } header: {
                    Text("On this phone")
                } footer: {
                    Text("Re-run a workout recorded here with this build, and replace the original with it. Marked recordings still have their workout saved.")
                }

                Section {
                    Button { picking = true } label: {
                        SettingsRow(symbol: "square.and.arrow.down", tint: .blue, title: "Choose files or a folder",
                                    subtitle: "The other phone's logs, or a flight_details file")
                    }
                    .buttonStyle(.plain)
                    .disabled(importer.busy)
                } header: {
                    Text("From another phone")
                } footer: {
                    Text("On the other phone: Developer → Session logs → Share all, then AirDrop or save to Files. A recording is its velocity_events, velocity_debug and velocity_raw50hz files; the raw file is what lets a flight be drawn again.")
                }

                if !importer.sources.isEmpty {
                    Section {
                        ForEach(importer.sources) { source in sourceRow(source) }
                    } header: { Text("Found in the files you chose") }
                }
            }

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
                    if !p.overlapping.isEmpty {
                        if p.ownRecording {
                            // Never optional for the same phone: a re-run beside its original counts that time twice.
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.overlapping.count == 1 ? "Replaces the original" : "Replaces \(p.overlapping.count) workouts it overlaps")
                                Text(p.overlapping.count == 1
                                     ? "Deleted here and in Apple Health, with its distance and steps, before the re-run is saved, so the two never overlap."
                                     : "Deleted here and in Apple Health, with their distance and steps, before the re-run is saved, so nothing overlaps it.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Toggle(isOn: $replace) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.overlapping.count == 1 ? "Replace this phone's workout" : "Replace this phone's \(p.overlapping.count) workouts")
                                    Text(replace ? "Deleted here and in Apple Health, with their distance and steps."
                                                 : "Off: both are kept, overlapping in time.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(p.overlapping) { old in replacedRow(old) }
                    }
                    Button {
                        let replacing = !p.overlapping.isEmpty && (p.ownRecording || replace)
                        importer.save(type: type, toHealth: toHealth, replace: replace) { message in
                            done = message
                            // The detail screen underneath shows the original, which is gone now: back to the list.
                            if replacing, let onReplaced { onReplaced(); dismiss() }
                        }
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
        .navigationTitle(focused ? "Re-run this workout" : "Import or re-run")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .json, .folder, .plainText, .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                chosen = nil; done = nil
                importer.receive(urls)
            }
        }
        .onAppear { importer.loadOwnRecordings() }
        .onChange(of: importer.sources) { _, s in if chosen == nil, s.count == 1 { chosen = s.first } }
        .onChange(of: importer.ownSources) { _, own in
            // Opened from a workout's detail screen: its recording, read at once.
            guard !didPreselect, let stamp = preselectStamp,
                  let source = own.first(where: { if case .logs(let set) = $0 { return set.stamp == stamp }; return false }) else { return }
            didPreselect = true
            chosen = source
            if case .logs(let set) = source { rerunFlight = set.canRerunFlight }
            importer.read(source, rerunFlight: rerunFlight, useLoggedGPS: useLoggedGPS)
        }
        .onChange(of: chosen) { _, c in
            if case .logs(let set)? = c { rerunFlight = set.canRerunFlight }
        }
        .onChange(of: importer.preview?.flight.id) { _, _ in
            if let raw = importer.preview?.flight.workoutType, let t = HKWorkoutActivityType(rawValue: raw),
               types.contains(where: { $0.0 == t }) { type = t } else { type = .other }
            // A flight goes to Health as Other unless chosen otherwise: no estimated steps for 3,000 km.
            if importer.preview?.flight.notes?.contains("flight re-run") == true { type = .other }
            // Another phone's workout replaces nothing here unless asked (this phone's own always does).
            replace = false
        }
    }

    private func sourceRow(_ source: WorkoutImporter.Source) -> some View {
        Button { chosen = source } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(source)).font(.body)
                    if case .logs = source {
                        Text(summaryLine(source)).font(.subheadline).monospacedDigit()
                    }
                    Text(detail(source)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if chosen == source { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { importer.summarize(source) }
    }

    /// Route distance, average speed and time of a recording: the saved workout's, or as recorded.
    private func summaryLine(_ source: WorkoutImporter.Source) -> String {
        guard let s = importer.summaries[source.id] else { return "Adding up the route…" }
        guard let km = s.km else { return "No route in these logs" }
        return [Self.km(km), s.kmh.map { Self.kmh($0) + " avg" }, Self.duration(s.seconds)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A workout the save will replace (or, switched off, overlap).
    private func replacedRow(_ old: Flight) -> some View {
        let km = old.totalDistance / 1000
        let seconds = (old.endDate ?? old.startDate.addingTimeInterval(old.metrics?.duration ?? 0)).timeIntervalSince(old.startDate)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.shownFormat.string(from: old.startDate)).font(.callout)
                Text([Self.duration(seconds), old.workoutUUID != nil ? "in Apple Health" : nil,
                      old.notes?.components(separatedBy: "\n").first].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Self.km(km)).font(.callout)
                Text(seconds > 0 ? Self.kmh(km / (seconds / 3600)) + " avg" : "–").font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
    }

    private static func km(_ km: Double) -> String { km.formatted(.number.precision(.fractionLength(km < 100 ? 2 : 1))) + " km" }
    private static func kmh(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(1))) + " km/h" }
    private static func duration(_ s: TimeInterval) -> String {
        let m = Int((s / 60).rounded()); return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }

    private func title(_ s: WorkoutImporter.Source) -> String {
        switch s {
        case .logs(let set):
            if let d = Self.stampFormat.date(from: set.stamp) { return Self.shownFormat.string(from: d) }
            return "Recording " + set.stamp.replacingOccurrences(of: "_", with: " ")
        case .saved(let url): return url.lastPathComponent
        }
    }

    private func detail(_ s: WorkoutImporter.Source) -> String {
        switch s {
        case .logs(let set):
            let parts = [set.events != nil ? "events" : nil, set.debug != nil ? "debug" : nil,
                         set.raw.isEmpty ? nil : (set.raw.count == 1 ? "raw motion" : "raw motion ×\(set.raw.count)")].compactMap { $0 }
            var saved = ""
            if importer.isOwn(s) {
                let overlaps = importer.overlapCount(s)
                saved = importer.savedStamps.contains(set.stamp) ? " · workout saved"
                    : overlaps > 0 ? " · overlaps \(overlaps == 1 ? "a saved workout" : "\(overlaps) saved workouts")"
                    : " · no saved workout"
            }
            // Not from a saved workout: the distance is the route as the phone drew it then.
            let recorded = importer.summaries[s.id].map { $0.km != nil && !$0.saved } == true ? "as recorded · " : ""
            return recorded + parts.joined(separator: " · ") + " · " + sizeFormatter.string(fromByteCount: set.bytes) + saved
        case .saved: return "A saved workout, as that phone saved it"
        }
    }
}
