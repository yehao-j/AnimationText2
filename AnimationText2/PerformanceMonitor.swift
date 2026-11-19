import Darwin
import Foundation
import QuartzCore

public struct PerformanceSnapshot {
    public let processCPU: Double
    public let framesPerSecond: Double
    public let glyphCount: Int
}

final class PerformanceMonitor {
    private var sampleStart = 0.0
    private var frameCount = 0

    func frameRendered(at time: Double, glyphCount: Int) -> PerformanceSnapshot? {
        if sampleStart == 0 { sampleStart = time }
        frameCount += 1

        let elapsed = time - sampleStart
        guard elapsed >= 0.8 else { return nil }
        let snapshot = PerformanceSnapshot(
            processCPU: ProcessCPUUsage.current(),
            framesPerSecond: Double(frameCount) / elapsed,
            glyphCount: glyphCount
        )
        sampleStart = time
        frameCount = 0
        return snapshot
    }
}

enum ProcessCPUUsage {
    /// Sums all non-idle threads. 100% means one fully occupied CPU core,
    /// so a multi-threaded process can report more than 100%.
    static func current() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t()
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else {
            return 0
        }
        defer {
            for index in 0..<Int(threadCount) {
                mach_port_deallocate(mach_task_self_, threads[index])
            }
            let byteCount = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_act_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), byteCount)
        }

        var totalUsage = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { integerPointer in
                    thread_info(
                        threads[index],
                        thread_flavor_t(THREAD_BASIC_INFO),
                        integerPointer,
                        &infoCount
                    )
                }
            }
            if result == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return totalUsage
    }
}
