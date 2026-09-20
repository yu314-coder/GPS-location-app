import Foundation
import Darwin

/// What one estimator cost to run, measured rather than assumed.
///
/// The two speed models are being compared on accuracy, and the moment one of them is a
/// neural network the obvious next question is what it costs to carry. Guessing from
/// parameter counts is worthless — the GRU is 125k parameters, which sounds like nothing,
/// but it runs 80 recurrent steps every half second for the length of a ride, and where
/// those steps execute (CPU, GPU, or the Neural Engine) changes the answer by an order of
/// magnitude. So measure it on the device that will carry it.
struct InferenceCost {
    /// Elapsed time inside the call.
    var wallMicros: Double = 0
    /// CPU time on the calling thread. Lower than wall time means the work went somewhere
    /// else — the GPU or the Neural Engine — and that gap is the whole point of measuring both.
    var cpuMicros: Double = 0
    /// Whole-process energy over the call, nanojoules. Not attributable to one model on its
    /// own, but the two models run microseconds apart on an otherwise idle tick, so the delta
    /// around each call is dominated by that call. Zero means the counter is coarser than the
    /// call, which is itself worth knowing.
    var energyNanojoules: UInt64 = 0
    /// Whole-process GPU time over the call, nanoseconds.
    var gpuNanos: UInt64 = 0
    /// Number of calls folded into this record.
    var calls: Int = 0

    mutating func accumulate(_ other: InferenceCost) {
        wallMicros += other.wallMicros
        cpuMicros += other.cpuMicros
        energyNanojoules += other.energyNanojoules
        gpuNanos += other.gpuNanos
        calls += other.calls
    }
}

/// Reads the counters iOS actually exposes to a sandboxed app.
///
/// `proc_pid_rusage`, which is how you would do this on a Mac, is not in the iOS SDK at all —
/// there is no libproc.h. What is available is the Mach task port, and `TASK_POWER_INFO_V2`
/// carries a real energy figure in nanojoules on arm64 plus accumulated GPU time. Both are
/// whole-process and monotonic, so everything here is a delta between two samples.
enum PowerMeter {

    /// CPU nanoseconds burned by the calling thread. Cheap enough to call twice per model per
    /// window without the measurement distorting what it measures.
    @inline(__always)
    static func threadCPUNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    }

    @inline(__always)
    static func monotonicNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    }

    struct TaskPower {
        var energyNanojoules: UInt64
        var gpuNanos: UInt64
        var cpuUserNanos: UInt64
        var cpuSystemNanos: UInt64
    }

    /// nil if the kernel refuses the flavour, which is the honest thing to log rather than a
    /// zero that reads like "used no power".
    static func taskPower() -> TaskPower? {
        var info = task_power_info_v2()
        var count = mach_msg_type_number_t(MemoryLayout<task_power_info_v2>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_POWER_INFO_V2), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return TaskPower(energyNanojoules: info.task_energy,
                         gpuNanos: info.gpu_energy.task_gpu_utilisation,
                         cpuUserNanos: info.cpu_energy.total_user,
                         cpuSystemNanos: info.cpu_energy.total_system)
    }

    /// Runs `body`, returning its value alongside what it cost.
    static func measure<T>(_ body: () throws -> T) rethrows -> (value: T, cost: InferenceCost) {
        let before = taskPower()
        let wall0 = monotonicNanos()
        let cpu0 = threadCPUNanos()
        let value = try body()
        let cpu1 = threadCPUNanos()
        let wall1 = monotonicNanos()
        let after = taskPower()
        var cost = InferenceCost()
        cost.wallMicros = Double(wall1 &- wall0) / 1000.0
        cost.cpuMicros = Double(cpu1 &- cpu0) / 1000.0
        if let b = before, let a = after {
            cost.energyNanojoules = a.energyNanojoules &- b.energyNanojoules
            cost.gpuNanos = a.gpuNanos &- b.gpuNanos
        }
        cost.calls = 1
        return (value, cost)
    }
}
