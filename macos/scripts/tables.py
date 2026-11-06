import json
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
summary = json.load(open(os.path.join(root, "measure-summary.json")))


def fmt(value, digits=1):
    return "-" if value is None else "%.*f" % (digits, value)


def phase_table(phases):
    lines = [
        "| Phase | Window | Window state | Page visibility | Renderer CPU % | GPU proc CPU % | App CPU % | Network+storage CPU % | Total CPU % | GPU util % | Timers /s (10 = full) | rAF /s | Status msgs | Visible fraction |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for phase in phases:
        cpu = phase["cpuPercentByKind"]
        services = cpu.get("network", 0) + cpu.get("storage", 0) + cpu.get("utility", 0)
        for index, (name, page) in enumerate(phase["pages"].items()):
            first = index == 0
            lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                phase["label"] if first else "",
                name,
                page.get("windowVisibility"),
                page.get("pageVisibility"),
                fmt(page.get("rendererCpuPercent")),
                fmt(cpu.get("gpu")) if first else "",
                fmt(cpu.get("app")) if first else "",
                fmt(services) if first else "",
                fmt(cpu.get("total")) if first else "",
                fmt(phase.get("gpuDeviceMean")) if first else "",
                fmt(page.get("timerTicksPerSecond")),
                fmt(page.get("framesPerSecond")),
                page.get("statusMessages"),
                fmt(page.get("visibleFraction"), 2),
            ))
    return "\n".join(lines)


def memory_table(phases):
    lines = [
        "| Phase | Renderers MB | GPU MB | App MB | Network+storage MB | Total MB | GPU in-use MB |",
        "|---|---|---|---|---|---|---|",
    ]
    for phase in phases:
        peak = phase["footprintPeakMBByKind"]
        services = peak.get("network", 0) + peak.get("storage", 0) + peak.get("utility", 0)
        lines.append("| %s | %s | %s | %s | %s | %s | %s |" % (
            phase["label"], fmt(peak.get("renderer"), 0), fmt(peak.get("gpu"), 0), fmt(peak.get("app"), 0),
            fmt(services, 0), fmt(peak.get("total"), 0), fmt(phase.get("gpuInUsePeakMB"), 0)))
    return "\n".join(lines)


if __name__ == "__main__":
    phases = summary.get("phases", [])
    print(phase_table(phases))
    print()
    print(memory_table(phases))
