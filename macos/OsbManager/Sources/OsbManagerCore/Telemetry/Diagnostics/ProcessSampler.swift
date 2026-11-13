import Darwin
import Foundation

public struct PerfWindowInfo: Equatable, Sendable {
    public var rendererPid: Int32?
    public var light: Bool
    public var hidden: Bool
    public var inWorld: Bool

    public init(rendererPid: Int32?, light: Bool, hidden: Bool, inWorld: Bool) {
        self.rendererPid = rendererPid
        self.light = light
        self.hidden = hidden
        self.inWorld = inWorld
    }
}

public final class PerfWindowCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PerfWindowInfo] = []

    public init() {}

    public var windows: [PerfWindowInfo] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

public enum ProcessSampler {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? (1, 1) : (Double(info.numer), Double(info.denom))
    }()

    public static func role(helperName name: String) -> ProcessRole {
        if name.hasSuffix("(GPU)") { return .gpu }
        if name.hasSuffix("(Renderer)") { return .renderer }
        return .utility
    }

    public static func windows(_ infos: [PerfWindowInfo]) -> PerfWindows {
        PerfWindows(
            open: infos.count,
            light: infos.filter(\.light).count,
            hidden: infos.filter(\.hidden).count,
            inWorld: infos.filter(\.inWorld).count
        )
    }

    public static func sample(windows infos: [PerfWindowInfo], at moment: Date) -> PerfSample {
        let own = getpid()
        let windowRenderers = Set(infos.compactMap(\.rendererPid).filter { $0 > 0 && $0 != own })
        var helpers: [ProcessReading] = []
        var seen: Set<Int32> = []
        for pid in childProcesses(of: own) where seen.insert(pid).inserted {
            guard let usage = usage(pid) else { continue }
            let named = role(helperName: name(of: pid))
            let role: ProcessRole = windowRenderers.contains(pid) ? .renderer : named == .renderer ? .other : named
            helpers.append(ProcessReading(pid: pid, role: role, footprintBytes: usage.footprint, cpuSeconds: usage.cpuSeconds))
        }
        for pid in windowRenderers where seen.insert(pid).inserted {
            if let usage = usage(pid) {
                helpers.append(ProcessReading(pid: pid, role: .renderer, footprintBytes: usage.footprint, cpuSeconds: usage.cpuSeconds))
            }
        }
        return PerfSample(at: moment, app: appReading(), helpers: helpers, windows: windows(infos))
    }

    public static func appReading() -> ProcessReading? {
        guard let footprint = appFootprint() else { return nil }
        return ProcessReading(pid: getpid(), role: .app, footprintBytes: footprint, cpuSeconds: appCpuSeconds() ?? 0)
    }

    static func childProcesses(of parent: Int32) -> [Int32] {
        var buffer = [Int32](repeating: 0, count: 512)
        let count = buffer.withUnsafeMutableBytes { pointer in
            proc_listchildpids(parent, pointer.baseAddress, Int32(pointer.count))
        }
        guard count > 0 else { return [] }
        return Array(buffer.prefix(min(Int(count), buffer.count))).filter { $0 > 0 }
    }

    static func name(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(cString: buffer)
    }

    static func usage(_ pid: Int32) -> (footprint: Double, cpuSeconds: Double)? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        let ticks = Double(info.ri_user_time) + Double(info.ri_system_time)
        return (Double(info.ri_phys_footprint), ticks * timebase.numer / timebase.denom / 1_000_000_000)
    }

    static func appFootprint() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        if result == KERN_SUCCESS, info.phys_footprint > 0 {
            return Double(info.phys_footprint)
        }
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let fallback = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount) }
        }
        return fallback == KERN_SUCCESS ? Double(basic.resident_size) : nil
    }

    static func appCpuSeconds() -> Double? {
        var basic = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount) }
        }
        var live = task_thread_times_info_data_t()
        var liveCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let liveResult = withUnsafeMutablePointer(to: &live) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(liveCount)) { task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &liveCount) }
        }
        guard basicResult == KERN_SUCCESS, liveResult == KERN_SUCCESS else { return nil }
        return seconds(basic.user_time) + seconds(basic.system_time) + seconds(live.user_time) + seconds(live.system_time)
    }

    private static func seconds(_ value: time_value_t) -> Double {
        Double(value.seconds) + Double(value.microseconds) / 1_000_000
    }
}
