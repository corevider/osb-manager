import Darwin
import Foundation
import IOKit

struct ProcessReading {
    let pid: Int32
    let kind: String
    let cpuNanoseconds: UInt64
    let footprint: UInt64
    let startedAt: Double
}

struct GpuReading {
    let device: Double
    let renderer: Double
    let inUseMemory: Double
}

final class ProcessSampler {
    private let timebase: mach_timebase_info_data_t

    init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = info
    }

    func read() -> [ProcessReading] {
        let own = getpid()
        var readings: [ProcessReading] = []
        if let value = reading(pid: own, kind: "app") {
            readings.append(value)
        }
        for pid in descendants(of: own) {
            if let value = reading(pid: pid, kind: kind(of: pid)) {
                readings.append(value)
            }
        }
        return readings
    }

    func gpu() -> GpuReading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let raw = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)
            IOObjectRelease(entry)
            if let statistics = raw?.takeRetainedValue() as? [String: Any] {
                func value(_ key: String) -> Double { (statistics[key] as? NSNumber)?.doubleValue ?? -1 }
                return GpuReading(device: value("Device Utilization %"), renderer: value("Renderer Utilization %"), inUseMemory: value("In use system memory"))
            }
            entry = IOIteratorNext(iterator)
        }
        return nil
    }

    private func descendants(of root: Int32) -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var children: [Int32: [Int32]] = [:]
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
            children[Int32(info.pbi_ppid), default: []].append(pid)
        }
        var found: [Int32] = []
        var queue = children[root] ?? []
        while let next = queue.first {
            queue.removeFirst()
            found.append(next)
            queue += children[next] ?? []
        }
        return found
    }

    private func kind(of pid: Int32) -> String {
        let arguments = Self.arguments(of: pid)
        if let type = arguments.first(where: { $0.hasPrefix("--type=") }) {
            switch String(type.dropFirst("--type=".count)) {
            case "renderer": return "renderer"
            case "gpu-process": return "gpu"
            case "utility":
                if let sub = arguments.first(where: { $0.hasPrefix("--utility-sub-type=") }) {
                    let name = String(sub.dropFirst("--utility-sub-type=".count))
                    if name.contains("NetworkService") { return "network" }
                    if name.contains("StorageService") { return "storage" }
                }
                return "utility"
            case let other: return other
            }
        }
        return "other"
    }

    private static func arguments(of pid: Int32) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 8 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        var index = 4
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        var result: [String] = []
        var current: [UInt8] = []
        while index < size {
            if buffer[index] == 0 {
                if !current.isEmpty { result.append(String(decoding: current, as: UTF8.self)) }
                current = []
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return result
    }

    private func reading(pid: Int32, kind: String) -> ProcessReading? {
        var usage = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return nil }
        let machTime = usage.ri_user_time + usage.ri_system_time
        let nanoseconds = machTime * UInt64(timebase.numer) / UInt64(timebase.denom)
        return ProcessReading(pid: pid, kind: kind, cpuNanoseconds: nanoseconds, footprint: usage.ri_phys_footprint, startedAt: startTime(pid))
    }

    private func startTime(_ pid: Int32) -> Double {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
        return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
    }
}
