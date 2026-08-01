import Darwin.Mach
import Foundation

struct ProcessResourceSample: Equatable {
    let cpuPercent: Double
    let physicalFootprintMegabytes: Double
}

final class ProcessResourceMonitor {
    private struct Reading {
        let wallTime: TimeInterval
        let cpuTime: TimeInterval
        let physicalFootprintBytes: UInt64
    }

    private let queue = DispatchQueue(label: "app.usefence.tab.resource-monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastReading: Reading?

    var onSample: ((ProcessResourceSample) -> Void)?

    func start() {
        guard timer == nil else { return }
        lastReading = readCurrentUsage()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.sample()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lastReading = nil
    }

    private func sample() {
        guard let current = readCurrentUsage() else { return }
        defer { lastReading = current }
        guard let previous = lastReading else { return }

        let elapsed = max(current.wallTime - previous.wallTime, 0.001)
        let consumedCPU = max(current.cpuTime - previous.cpuTime, 0)
        onSample?(
            ProcessResourceSample(
                cpuPercent: consumedCPU / elapsed * 100,
                physicalFootprintMegabytes: Double(current.physicalFootprintBytes) / 1_048_576
            )
        )
    }

    private func readCurrentUsage() -> Reading? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { return nil }

        let userSeconds = TimeInterval(info.user_time.seconds)
            + TimeInterval(info.user_time.microseconds) / 1_000_000
        let systemSeconds = TimeInterval(info.system_time.seconds)
            + TimeInterval(info.system_time.microseconds) / 1_000_000
        return Reading(
            wallTime: ProcessInfo.processInfo.systemUptime,
            cpuTime: userSeconds + systemSeconds,
            physicalFootprintBytes: readPhysicalFootprintBytes() ?? info.resident_size
        )
    }

    private func readPhysicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    $0,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
