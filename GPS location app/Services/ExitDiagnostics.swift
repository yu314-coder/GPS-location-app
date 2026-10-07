//
//  ExitDiagnostics.swift
//  GPS location app
//
//  WHY THE APP ENDED.
//
//  Twice iOS ended the app in the background in the middle of a workout (a walk after a ride, and
//  two minutes into another ride), with no shutdown in the logs and nothing in Analytics Data to
//  say why. MetricKit gives the system's own account: once a day, how many times the app exited in
//  the background and for what reason (memory or CPU limit, watchdog, abnormal exit, ...), and a
//  diagnostic report for each crash, hang or CPU exception, delivered on the next launch.
//
//  Each payload is saved as JSON beside the velocity logs (Files → GPS location app → VelocityLogs),
//  where the logs are already collected from. Named after the period it covers, so a payload that
//  is offered again on a later launch is not written twice.
//

import Foundation
import MetricKit

final class ExitDiagnostics: NSObject, MXMetricManagerSubscriber {
    static let shared = ExitDiagnostics()

    private var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VelocityLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func start() {
        MXMetricManager.shared.add(self)
        // Anything delivered while no subscriber was listening (the first launch of this build).
        didReceive(MXMetricManager.shared.pastPayloads)
        didReceive(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { save(p.jsonRepresentation(), kind: "metrics", end: p.timeStampEnd) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { save(p.jsonRepresentation(), kind: "diagnostics", end: p.timeStampEnd) }
    }

    private func save(_ json: Data, kind: String, end: Date) {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let url = directory.appendingPathComponent("metrickit_\(kind)_\(df.string(from: end)).json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? json.write(to: url, options: .atomic)
    }

    /// Memory the app is using now, in MB: the figure iOS compares with its limit when it ends an app.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
