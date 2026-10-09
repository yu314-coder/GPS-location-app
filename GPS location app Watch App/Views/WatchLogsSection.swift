//
//  WatchLogsSection.swift
//  GPS location app Watch App
//
//  SENDING THE WORKOUT LOGS BY HAND.
//
//  A log is sent to the iPhone when a workout ends and again whenever the app starts, and it stays
//  on the watch until the iPhone confirms it has a copy. After a long flight the watch ended at 2%
//  with Bluetooth off, so nothing could be sent and there was no way to see whether the log was
//  still here or to send it once the watch was charged. This lists what is on the watch and sends
//  it on request.
//

import SwiftUI

final class WatchLogsModel: ObservableObject {
    @Published private(set) var onWatch = 0
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var inFlight: [(name: String, fraction: Double)] = []
    @Published var note: String?

    func refresh() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: WatchDiagnosticsRecorder.logDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let logs = files.filter { $0.pathExtension == "csv" }
        onWatch = logs.count
        bytes = logs.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        inFlight = WatchConnectivityManager.shared.outstandingDiagnosticsTransfers()
    }

    /// Every log not already on its way. One written to in the last minute belongs to a workout
    /// still running and goes when that workout ends.
    func send() {
        guard WatchConnectivityManager.shared.sessionIsActivated else {
            note = "Not connected to the iPhone app yet. Open it on the iPhone and try again."
            return
        }
        let before = WatchConnectivityManager.shared.outstandingDiagnosticsLogNames().count
        WatchDiagnosticsRecorder.sendUnsentLogs(untouchedFor: 60)
        refresh()
        let queued = inFlight.count - before
        note = queued > 0 ? "Sending \(queued) log\(queued == 1 ? "" : "s"). Keep the iPhone nearby."
                          : (inFlight.isEmpty ? "Nothing to send." : "Already on the way.")
    }

    /// Cancel the queued transfers and queue the logs again, for one that seems stuck.
    func sendAgain() {
        WatchConnectivityManager.shared.cancelOutstandingDiagnosticsTransfers()
        WatchDiagnosticsRecorder.sendUnsentLogs(untouchedFor: 60)
        refresh()
        note = "Sending again."
    }
}

struct WatchLogsSection: View {
    @StateObject private var logs = WatchLogsModel()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section(header: Text("Workout logs"),
                footer: Text("A log stays on the watch until the iPhone has a copy, which then appears in the iPhone app's VelocityLogs folder.")) {
            HStack {
                Text("On this watch")
                Spacer()
                Text(logs.onWatch == 0 ? "none"
                     : "\(logs.onWatch) · \(ByteCountFormatter.string(fromByteCount: logs.bytes, countStyle: .file))")
                    .foregroundColor(.secondary)
            }
            ForEach(logs.inFlight, id: \.name) { t in
                HStack {
                    Text("Sending").font(.footnote)
                    Spacer()
                    Text("\(Int(t.fraction * 100))%").font(.footnote).foregroundColor(.secondary)
                }
            }
            Button("Send to iPhone") { logs.send() }
                .disabled(logs.onWatch == 0)
            if !logs.inFlight.isEmpty {
                Button("Send again") { logs.sendAgain() }
            }
            if let note = logs.note {
                Text(note).font(.footnote).foregroundColor(.secondary)
            }
        }
        .onAppear { logs.refresh() }
        .onReceive(tick) { _ in logs.refresh() }
    }
}
