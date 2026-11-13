import Foundation

public enum DiagnosticJsonReader {
    public static func event(_ data: Data) -> DiagnosticEvent? {
        guard data.count <= DiagnosticFormats.maxEventBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["source"] as? String == DiagnosticSource.manager.rawValue,
              let kind = (root["kind"] as? String).flatMap(DiagnosticKind.init(rawValue:)),
              let fingerprint = root["fp"] as? String,
              let at = (root["at"] as? String).flatMap(minute),
              let count = int(root["count"]),
              let detail = detail(kind, root) else { return nil }
        return DiagnosticEvent(
            detail: detail,
            fingerprint: fingerprint,
            at: at,
            count: count,
            context: (root["context"] as? [String: Any]).map(context),
            trail: (root["trail"] as? [[String: Any]]).map { $0.compactMap(trailItem) }
        )
    }

    private static func detail(_ kind: DiagnosticKind, _ root: [String: Any]) -> DiagnosticDetail? {
        switch kind {
        case .dotnetException:
            guard let o = root["error"] as? [String: Any], let type = o["type"] as? String, let origin = o["origin"] as? String,
                  let handled = o["handled"] as? Bool else { return nil }
            return .error(ErrorDetail(type: type, origin: origin, handled: handled, frames: o["frames"] as? [String] ?? [], inner: o["inner"] as? [String] ?? []))
        case .processFailed:
            guard let o = root["process"] as? [String: Any], let k = o["kind"] as? String, let reason = o["reason"] as? String,
                  let exit = o["exit_code"] as? String else { return nil }
            return .process(ProcessDetail(kind: k, reason: reason, exitCode: exit, description: o["description"] as? String))
        case .unresponsive:
            guard let o = root["hang"] as? [String: Any], let outcome = o["outcome"] as? String, let waited = int(o["waited_s"]) else { return nil }
            return .hang(HangDetail(outcome: outcome, waitedSeconds: waited))
        case .gpuFailed:
            guard let o = root["gpu"] as? [String: Any], let code = o["code"] as? String, let retries = int(o["retries"]) else { return nil }
            return .gpu(GpuDetail(code: code, retries: retries))
        case .warn:
            guard let o = root["warn"] as? [String: Any], let category = o["category"] as? String, let code = o["code"] as? String else { return nil }
            return .warn(WarnDetail(category: category, code: code, errorClass: o["error_class"] as? String))
        case .runEnd:
            guard let o = root["run_end"] as? [String: Any], let outcome = o["outcome"] as? String, let uptime = int(o["uptime_s"]) else { return nil }
            return .runEnd(RunEndDetail(outcome: outcome, uptimeSeconds: uptime, previousVersion: o["previous_version"] as? String, signal: o["signal"] as? String))
        case .jsError, .botStop:
            return nil
        }
    }

    private static func context(_ o: [String: Any]) -> DiagnosticContext {
        DiagnosticContext(
            phase: o["phase"] as? String,
            loginStage: o["login_stage"] as? String,
            window: int(o["window"]),
            windows: int(o["windows"]),
            light: o["light"] as? Bool,
            hidden: o["hidden"] as? Bool,
            uptimeSeconds: int(o["uptime_s"])
        )
    }

    private static func trailItem(_ o: [String: Any]) -> TrailItem? {
        guard let seconds = int(o["s"]), let level = o["l"] as? String, let category = o["c"] as? String, let code = o["k"] as? String else { return nil }
        return TrailItem(secondsBefore: seconds, level: level, category: category, code: code, count: int(o["n"]) ?? 1, window: int(o["w"]))
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 1e12 else { return nil }
        return Int(double)
    }

    private static func minute(_ text: String) -> Date? {
        guard text.count == 20, text.hasSuffix(":00Z") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
