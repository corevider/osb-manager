import CryptoKit
import Foundation

public enum DiagnosticFingerprint {
    public static let frameCount = 5

    public static func of(_ detail: DiagnosticDetail) -> String {
        switch detail {
        case .error(let error):
            return forException(type: error.type, origin: error.origin, frames: error.frames)
        case .process(let process):
            return of(DiagnosticKind.processFailed.rawValue, process.kind, process.reason, process.description ?? "")
        case .hang(let hang):
            return of(DiagnosticKind.unresponsive.rawValue, hang.outcome)
        case .gpu(let gpu):
            return of(DiagnosticKind.gpuFailed.rawValue, gpu.code)
        case .stop(let stop):
            return of(DiagnosticKind.botStop.rawValue, stop.code, stop.source)
        case .warn(let warn):
            return of(DiagnosticKind.warn.rawValue, warn.category, warn.code)
        case .runEnd(let end):
            return of(DiagnosticKind.runEnd.rawValue, end.outcome)
        }
    }

    public static func forException(type: String, origin: String, frames: [String]) -> String {
        let own = frames
            .filter { $0 != FrameReducer.external && $0 != DiagnosticScrubber.privateMark && $0 != DiagnosticScrubber.pathMark }
            .prefix(frameCount)
        return of(DiagnosticKind.dotnetException.rawValue, type, origin, own.joined(separator: ","))
    }

    public static func of(_ parts: String...) -> String {
        let text = "manager|" + parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
