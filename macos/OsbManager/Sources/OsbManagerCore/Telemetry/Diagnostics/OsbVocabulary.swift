import Foundation

public struct OsbVocabularyError: Error, Equatable {
    public let field: String
}

public final class OsbVocabulary: @unchecked Sendable {
    public static let fileName = "diagnostics-vocabulary.json"
    public static let other = "other"
    public static let unknownFrame = "?"
    public static let unknownWord = "<x>"
    public static let fallbackType = "Error"
    public static let anonymousFrame = "<anonymous>"

    private static let frameLocation = TextPattern("(@[0-9]{1,7}:[0-9]{1,5}|\\+IL_[0-9A-F]{4,6})$")
    private static let templateWord = TextPattern("<(?:q|n|url|x|path|redacted)>|(?:[A-Za-z0-9_$]|[^\\x00-\\x7f])+")
    private static let digitsOnly = TextPattern("^[0-9]+$")
    private static let codeWord = TextPattern("^[A-Za-z0-9_]+$")

    public let version: String
    public let modules: Set<String>
    public let stopCodes: Set<String>
    public let activityCategories: Set<String>
    public let activityCodes: Set<String>
    public let errorCodes: Set<String>
    public let errorTypes: Set<String>
    public let phases: Set<String>
    public let modes: Set<String>
    public let townPhases: Set<String>
    public let outcomes: Set<String>
    public let refusalSources: Set<String>
    public let refusalReasons: Set<String>
    public let engineWords: Set<String>
    public let identifiers: Set<String>

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = root["version"] as? String else {
            throw OsbVocabularyError(field: "version")
        }
        func list(_ name: String) throws -> Set<String> {
            guard let items = root[name] as? [String] else { throw OsbVocabularyError(field: name) }
            return Set(items)
        }
        self.version = version
        modules = try list("modules")
        stopCodes = try list("stop_codes")
        activityCategories = try list("activity_categories")
        activityCodes = try list("activity_codes")
        errorCodes = try list("error_codes")
        errorTypes = try list("error_types")
        phases = try list("phases")
        modes = try list("modes")
        townPhases = try list("town_phases")
        outcomes = try list("outcomes")
        refusalSources = try list("refusal_sources")
        refusalReasons = try list("refusal_reasons")
        engineWords = Set(try list("engine_words").map { $0.lowercased() })
        identifiers = try list("identifiers")
    }

    public static func load(from url: URL) throws -> OsbVocabulary {
        try OsbVocabulary(data: Data(contentsOf: url))
    }

    public func frame(_ frame: String) -> String {
        if frame == FrameReducer.external { return frame }
        let location = Self.frameLocation.firstMatch(in: frame) ?? ""
        let name = String(frame.dropLast(location.count))
        let known = name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            part == Self.anonymousFrame || part == Self.unknownFrame || identifiers.contains(String(part))
        }
        return known ? frame : Self.unknownFrame + location
    }

    public func words(_ text: String) -> String {
        Self.templateWord.replacingEach(in: text) { word in
            word.hasPrefix("<") || knownWord(word) ? word : Self.unknownWord
        }
    }

    public func knownWord(_ word: String) -> Bool {
        Self.digitsOnly.matchesWhole(word) || (Self.codeWord.matchesWhole(word) && (engineWords.contains(word.lowercased()) || identifiers.contains(word)))
    }

    public func map(_ event: DiagnosticEvent, changed: inout Int) -> DiagnosticEvent {
        var count = 0
        var result = event
        result.trail = event.trail?.map { mapTrail($0, &count) }
        switch event.detail {
        case .error(let error):
            result.detail = .error(mapError(error, &count))
        case .stop(let stop):
            result.detail = .stop(StopDetail(code: required(stop.code, stopCodes, &count), source: stop.source))
        case .warn(let warn):
            result.detail = .warn(mapWarn(warn, &count))
        default:
            break
        }
        result.context = event.context.map { mapContext($0, &count) }
        changed += count
        return result
    }

    private func mapError(_ error: ErrorDetail, _ count: inout Int) -> ErrorDetail {
        var result = error
        result.type = errorTypes.contains(error.type) ? error.type : changed(Self.fallbackType, &count)
        if let original = error.template {
            let template = words(original)
            if template != original { count += 1 }
            result.template = template
        }
        result.frames = error.frames.map { original in
            let kept = frame(original)
            if kept != original { count += 1 }
            return kept
        }
        let inner = error.inner.map { errorTypes.contains($0) ? $0 : Self.fallbackType }
        if inner != error.inner { count += 1 }
        result.inner = inner
        result.module = optional(error.module, modules, &count)
        return result
    }

    private func mapWarn(_ warn: WarnDetail, _ count: inout Int) -> WarnDetail {
        let refusal = warn.refusal.map { r in
            RefusalDetail(source: required(r.source, refusalSources, &count), reason: required(r.reason, refusalReasons, &count), native: r.native)
        }
        return WarnDetail(
            category: required(warn.category, activityCategories, &count),
            code: required(warn.code, activityCodes, &count),
            errorClass: optional(warn.errorClass, errorCodes, &count),
            refusal: refusal
        )
    }

    private func mapContext(_ context: DiagnosticContext, _ count: inout Int) -> DiagnosticContext {
        var result = context
        result.phase = context.phase.map { required($0, phases, &count) }
        result.mode = context.mode.map { required($0, modes, &count) }
        result.townPhase = optional(context.townPhase, townPhases, &count)
        if context.loginStage != nil {
            result.loginStage = nil
            count += 1
        }
        return result
    }

    private func mapTrail(_ item: TrailItem, _ count: inout Int) -> TrailItem {
        var result = item
        result.category = required(item.category, activityCategories, &count)
        result.code = required(item.code, activityCodes, &count)
        result.outcome = optional(item.outcome, outcomes, &count)
        result.errorClass = optional(item.errorClass, errorCodes, &count)
        return result
    }

    private func required(_ value: String, _ allowed: Set<String>, _ count: inout Int) -> String {
        allowed.contains(value) ? value : changed(Self.other, &count)
    }

    private func optional(_ value: String?, _ allowed: Set<String>, _ count: inout Int) -> String? {
        guard let value, !allowed.contains(value) else { return value }
        count += 1
        return nil
    }

    private func changed<T>(_ value: T, _ count: inout Int) -> T {
        count += 1
        return value
    }
}
