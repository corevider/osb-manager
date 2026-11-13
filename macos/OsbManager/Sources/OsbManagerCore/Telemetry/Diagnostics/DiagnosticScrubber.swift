import Foundation

public enum ErrorTypeNames {
    public static let fallback = "Exception"
    public static let serverAcceptsMacNamespaces = true
    public static let serverNamespaces = ["System.", "Microsoft.", "OsbManager.", "Windows."]
    public static let macNamespaces = ["Foundation.", "OsbManagerCore.", "OsbManagerApp.", "OsbManagerCef."]
    public static let foundationExceptions: Set<String> = [
        "NSInvalidArgumentException", "NSRangeException", "NSInternalInconsistencyException", "NSGenericException",
        "NSMallocException", "NSObjectInaccessibleException", "NSObjectNotAvailableException", "NSDestinationInvalidException",
        "NSInvalidArchiveOperationException", "NSInvalidUnarchiveOperationException", "NSUnknownKeyException",
        "NSFileHandleOperationException", "NSCharacterConversionException", "NSParseErrorException",
        "NSInconsistentArchiveException", "NSWindowServerCommunicationException", "NSImageCacheException",
    ]

    public static func exception(named name: String) -> String {
        foundationExceptions.contains(name) ? "Foundation." + name : "Foundation.NSException"
    }

    public static func swiftError(_ error: Error) -> String {
        if type(of: error) == NSError.self { return "Foundation.NSError" }
        var name = String(reflecting: type(of: error))
        if let generic = name.firstIndex(of: "<") { name = String(name[..<generic]) }
        return macNamespaces.contains(where: { name.hasPrefix($0) }) && DiagnosticFormats.isTypeName(name) ? name : fallback
    }

    public static func wire(_ type: String, acceptsMacNamespaces: Bool = serverAcceptsMacNamespaces) -> String {
        let allowed = acceptsMacNamespaces ? serverNamespaces + macNamespaces : serverNamespaces
        guard type != fallback else { return fallback }
        return allowed.contains(where: { type.hasPrefix($0) }) && DiagnosticFormats.isTypeName(type) ? type : fallback
    }
}

public enum RendererTermination {
    public static func reason(status: Int32) -> String {
        switch status {
        case 1: "terminated"
        case 2: "crashed"
        case 3: "out_of_memory"
        case 4: "launch_failed"
        default: "unexpected"
        }
    }

    public static func detail(status: Int32, errorCode: Int32) -> ProcessDetail {
        ProcessDetail(kind: "render_process_exited", reason: reason(status: status), exitCode: DiagnosticFormats.exitCode(errorCode))
    }
}

public enum DiagnosticScrubber {
    public static let privateMark = "<x>"
    public static let pathMark = "<path>"
    public static let other = "other"
    private static let pathPattern = TextPattern(
        "[A-Za-z]:\\\\|\\\\\\\\|/Users/|/home/|/private/|/var/folders/|/Volumes/|/Applications/|~/|file:|%[A-Z]+%|Users[\\\\/]",
        caseInsensitive: true
    )

    public static func looksLikePath(_ text: String?) -> Bool {
        guard let text else { return false }
        return pathPattern.occurs(in: text)
    }

    public static func isClean(_ text: String?, _ terms: PrivateTerms) -> Bool {
        text == nil || (!looksLikePath(text) && !terms.hits(text))
    }

    public static func code(_ value: String?, _ terms: PrivateTerms) -> String? {
        DiagnosticFormats.isCode(value) && isClean(value, terms) ? value : nil
    }

    public static func version(_ value: String?, _ terms: PrivateTerms) -> String? {
        DiagnosticFormats.isVersion(value) && isClean(value, terms) ? value : nil
    }

    public static func frame(_ value: String, _ terms: PrivateTerms) -> String {
        guard DiagnosticFormats.isFrame(value) else { return FrameReducer.external }
        if looksLikePath(value) { return pathMark }
        return terms.hits(value) ? privateMark : value
    }

    public static func phase(_ value: String?) -> String? {
        value.map { DiagnosticFormats.phases.contains($0) ? $0 : other }
    }

    public static func loginStage(_ value: String?) -> String? {
        value.map { DiagnosticFormats.loginStages.contains($0) ? $0 : other }
    }

    public static func gpuFailure(_ text: String?) -> String? {
        guard let text = text?.lowercased(), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if text.contains("adapter") || text.contains("null") { return "adapter-null" }
        if text.contains("lost") || text.contains("destroyed") { return "device-lost" }
        if text.contains("memory") { return "out-of-memory" }
        if text.contains("support") || text.contains("webgpu is not") || text.contains("navigator.gpu") { return "unsupported" }
        return other
    }

    public static func scrub(_ event: DiagnosticEvent, _ terms: PrivateTerms) -> DiagnosticEvent? {
        guard DiagnosticFormats.isHex16(event.fingerprint), event.fingerprint != DiagnosticFormats.reservedFingerprint else { return nil }
        var result = event
        result.count = DiagnosticFormats.clamp(event.count, 1, DiagnosticFormats.maxCount)
        result.context = context(event.context, terms)
        result.trail = trail(event.trail, event.source, terms)
        switch event.detail {
        case .error(let error):
            guard let clean = self.error(error, event.source, terms) else { return nil }
            result.detail = .error(clean)
        case .process(let process):
            guard DiagnosticFormats.processKinds.contains(process.kind), DiagnosticFormats.processReasons.contains(process.reason),
                  DiagnosticFormats.isExitCode(process.exitCode) else { return nil }
            result.detail = .process(ProcessDetail(kind: process.kind, reason: process.reason, exitCode: process.exitCode, description: code(process.description, terms)))
        case .hang(let hang):
            guard DiagnosticFormats.hangOutcomes.contains(hang.outcome) else { return nil }
            result.detail = .hang(HangDetail(outcome: hang.outcome, waitedSeconds: DiagnosticFormats.clamp(hang.waitedSeconds, 0, DiagnosticFormats.maxHangSeconds)))
        case .gpu(let gpu):
            guard let clean = code(gpu.code, terms) else { return nil }
            result.detail = .gpu(GpuDetail(code: clean, retries: DiagnosticFormats.clamp(gpu.retries, 0, DiagnosticFormats.maxGpuRetries)))
        case .stop(let stop):
            guard let clean = code(stop.code, terms), DiagnosticFormats.stopSources.contains(stop.source) else { return nil }
            result.detail = .stop(StopDetail(code: clean, source: stop.source))
        case .warn(let warn):
            guard let category = code(warn.category, terms), let clean = code(warn.code, terms) else { return nil }
            result.detail = .warn(WarnDetail(category: category, code: clean, errorClass: code(warn.errorClass, terms), refusal: refusal(warn.refusal, terms)))
        case .runEnd(let end):
            guard DiagnosticFormats.runOutcomes.contains(end.outcome) else { return nil }
            let previous = end.previousVersion.flatMap { version($0, terms) }
            if end.previousVersion != nil, previous == nil { return nil }
            let signal = end.outcome == "crash" ? end.signal.flatMap { DiagnosticFormats.runSignals.contains($0) ? $0 : nil } : nil
            result.detail = .runEnd(RunEndDetail(outcome: end.outcome, uptimeSeconds: DiagnosticFormats.roundUptime(Double(end.uptimeSeconds)), previousVersion: previous, signal: signal))
            result.context = nil
            result.trail = nil
        }
        return result
    }

    public static func mode(_ value: String?) -> String? {
        value.map { DiagnosticFormats.modes.contains($0) ? $0 : other }
    }

    public static func template(_ text: String?, _ terms: PrivateTerms) -> String? {
        guard let text else { return nil }
        if looksLikePath(text) { return pathMark }
        if terms.hits(text) { return privateMark }
        return DiagnosticFormats.isTemplate(text) ? text : nil
    }

    private static func error(_ error: ErrorDetail, _ source: DiagnosticSource, _ terms: PrivateTerms) -> ErrorDetail? {
        source == .osb ? pageError(error, terms) : managerError(error, terms)
    }

    private static func managerError(_ error: ErrorDetail, _ terms: PrivateTerms) -> ErrorDetail? {
        guard DiagnosticFormats.origins.contains(error.origin) else { return nil }
        let type = ErrorTypeNames.wire(error.type)
        guard isClean(type, terms) else { return nil }
        let frames = error.frames.prefix(DiagnosticFormats.maxFrames).map { frame($0, terms) }
        let inner = error.inner.prefix(DiagnosticFormats.maxInner).map { name -> String in
            let wire = ErrorTypeNames.wire(name)
            return isClean(wire, terms) ? wire : ErrorTypeNames.fallback
        }
        return ErrorDetail(type: type, origin: error.origin, handled: error.handled, frames: Array(frames), inner: Array(inner))
    }

    private static func pageError(_ error: ErrorDetail, _ terms: PrivateTerms) -> ErrorDetail? {
        guard DiagnosticFormats.pageOrigins.contains(error.origin), DiagnosticFormats.isTypeName(error.type), isClean(error.type, terms) else { return nil }
        let frames = error.frames.prefix(DiagnosticFormats.maxFrames).map { frame($0, terms) }
        let inner = error.inner.prefix(DiagnosticFormats.maxInner).map { name in
            DiagnosticFormats.isTypeName(name) && isClean(name, terms) ? name : ErrorTypeNames.fallback
        }
        return ErrorDetail(
            type: error.type,
            origin: error.origin,
            handled: error.handled,
            frames: Array(frames),
            inner: Array(inner),
            template: template(error.template, terms),
            module: code(error.module, terms)
        )
    }

    private static func refusal(_ refusal: RefusalDetail?, _ terms: PrivateTerms) -> RefusalDetail? {
        guard let refusal, let source = code(refusal.source, terms), let reason = code(refusal.reason, terms) else { return nil }
        return RefusalDetail(source: source, reason: reason, native: DiagnosticFormats.clamp(refusal.native, 0, 65_535))
    }

    private static func context(_ context: DiagnosticContext?, _ terms: PrivateTerms) -> DiagnosticContext? {
        guard let context else { return nil }
        return DiagnosticContext(
            phase: phase(context.phase),
            mode: mode(context.mode),
            townPhase: code(context.townPhase, terms),
            dead: context.dead,
            loginStage: loginStage(context.loginStage),
            window: context.window.flatMap { (1...64).contains($0) ? $0 : nil },
            windows: context.windows.flatMap { (0...64).contains($0) ? $0 : nil },
            light: context.light,
            hidden: context.hidden,
            uptimeSeconds: context.uptimeSeconds.map { DiagnosticFormats.roundUptime(Double($0)) }
        )
    }

    private static func trail(_ trail: [TrailItem]?, _ source: DiagnosticSource, _ terms: PrivateTerms) -> [TrailItem]? {
        guard let trail else { return nil }
        let limit = source == .osb ? DiagnosticFormats.maxOsbTrail : DiagnosticFormats.maxTrail
        return trail.suffix(limit).compactMap { item in
            guard DiagnosticFormats.trailLevels.contains(item.level),
                  let category = code(item.category, terms),
                  let clean = code(item.code, terms) else { return nil }
            return TrailItem(
                secondsBefore: DiagnosticFormats.clamp(item.secondsBefore, -86_400, 0),
                level: item.level,
                category: category,
                code: clean,
                count: DiagnosticFormats.clamp(item.count, 1, DiagnosticFormats.maxCount),
                window: item.window.flatMap { (1...64).contains($0) ? $0 : nil },
                outcome: code(item.outcome, terms),
                errorClass: code(item.errorClass, terms),
                numbers: numbers(item.numbers),
                flags: flags(item.flags)
            )
        }
    }

    private static func numbers(_ numbers: [String: Double]?) -> [String: Double]? {
        let kept = numbers?.filter { DiagnosticFormats.detailNumbers.contains($0.key) && $0.value.isFinite && abs($0.value) <= DiagnosticFormats.maxDetailMagnitude }
        return kept?.isEmpty == false ? kept : nil
    }

    private static func flags(_ flags: [String: Bool]?) -> [String: Bool]? {
        let kept = flags?.filter { DiagnosticFormats.detailFlags.contains($0.key) }
        return kept?.isEmpty == false ? kept : nil
    }
}
