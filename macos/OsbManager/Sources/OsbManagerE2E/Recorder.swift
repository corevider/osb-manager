import Foundation

struct Sample {
    let at: Date
    let processes: [ProcessReading]
    let gpu: GpuReading?
}

@MainActor
final class Recorder {
    let sampler = ProcessSampler()
    private(set) var samples: [Sample] = []
    private var timer: Timer?

    func start() {
        capture()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func capture() {
        samples.append(Sample(at: Date(), processes: sampler.read(), gpu: sampler.gpu()))
    }

    func summary(from start: Date, to end: Date) -> [String: Any] {
        let inRange = samples.filter { $0.at >= start && $0.at <= end }
        guard let first = inRange.first, let last = inRange.last, inRange.count > 1 else { return ["samples": inRange.count] }
        let seconds = max(last.at.timeIntervalSince(first.at), 0.001)
        let before = Dictionary(uniqueKeysWithValues: first.processes.map { ($0.pid, $0) })
        var cpu: [String: Double] = [:]
        var footprint: [String: Double] = [:]
        var perProcess: [[String: Any]] = []
        for process in last.processes {
            footprint[process.kind, default: 0] += Double(process.footprint) / 1_048_576
            guard let start = before[process.pid] else { continue }
            let cpuPercent = Double(process.cpuNanoseconds &- start.cpuNanoseconds) / 1_000_000_000 / seconds * 100
            cpu[process.kind, default: 0] += cpuPercent
            perProcess.append([
                "pid": Int(process.pid),
                "kind": process.kind,
                "startedAt": process.startedAt,
                "cpuPercent": cpuPercent,
                "footprintMB": Double(process.footprint) / 1_048_576,
            ])
        }
        cpu["total"] = cpu.values.reduce(0, +)
        var result: [String: Any] = [
            "samples": inRange.count,
            "seconds": seconds,
            "cpuPercent": cpu,
            "footprintMB": footprint,
            "processes": perProcess.sorted { number($0["startedAt"]) < number($1["startedAt"]) },
        ]
        let device = inRange.compactMap { $0.gpu?.device }
        let renderer = inRange.compactMap { $0.gpu?.renderer }
        if !device.isEmpty {
            result["gpuDeviceMean"] = device.reduce(0, +) / Double(device.count)
            result["gpuDeviceMax"] = device.max() ?? 0
            result["gpuRendererMean"] = renderer.reduce(0, +) / Double(max(renderer.count, 1))
        }
        return result
    }

    func peaks(from start: Date, to end: Date) -> [String: Any] {
        var peak: [String: Double] = [:]
        var gpuMemory = 0.0
        for sample in samples where sample.at >= start && sample.at <= end {
            var sums: [String: Double] = [:]
            for process in sample.processes {
                sums[process.kind, default: 0] += Double(process.footprint) / 1_048_576
            }
            sums["total"] = sums.values.reduce(0, +)
            for (kind, value) in sums {
                peak[kind] = max(peak[kind] ?? 0, value)
            }
            gpuMemory = max(gpuMemory, (sample.gpu?.inUseMemory ?? 0) / 1_048_576)
        }
        return ["footprintPeakMB": peak, "gpuInUsePeakMB": gpuMemory]
    }

    func memory() -> [String: Any] {
        guard let last = samples.last else { return [:] }
        var perKind: [String: [String: Double]] = [:]
        for process in last.processes {
            var entry = perKind[process.kind] ?? ["count": 0, "footprintMB": 0]
            entry["count", default: 0] += 1
            entry["footprintMB", default: 0] += Double(process.footprint) / 1_048_576
            perKind[process.kind] = entry
        }
        return ["perKind": perKind, "gpuInUseMB": (last.gpu?.inUseMemory ?? -1) / 1_048_576]
    }
}

func number(_ value: Any?) -> Double {
    (value as? NSNumber)?.doubleValue ?? 0
}
