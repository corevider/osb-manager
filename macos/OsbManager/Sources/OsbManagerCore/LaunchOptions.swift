import Foundation

public struct LaunchOptions: Equatable {
    public static let usage = "OsbManager [--data <folder>] [--start <account>[,<account>...]] [--light]"

    public var dataRoot: URL?
    public var start: [String] = []
    public var startLight = false
    public var telemetryUrl: URL?
    public var telemetryTimeScale: Double?
    public var telemetryConsent = false
    public var latencyLog: URL?
    public var dialogShots: URL?
    public var interfaceLanguage: String?
    public var updatedFrom: Int32?

    public init() {}

    public static func parse(_ arguments: [String]) throws -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw LaunchOptionsError("\(flag) needs a value.") }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--data":
                let path = try value(for: argument)
                guard !path.isEmpty else { throw LaunchOptionsError("--data needs a folder.") }
                options.dataRoot = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            case "--start":
                options.start += try value(for: argument)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            case "--light":
                options.startLight = true
            case UpdateRelaunch.option:
                let text = try value(for: argument)
                guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = Int32(text), pid > 0 else {
                    throw LaunchOptionsError("\(UpdateRelaunch.option) needs a process id.")
                }
                options.updatedFrom = pid
            #if DEBUG
            case "--telemetry-url":
                guard let url = URL(string: try value(for: argument)), url.scheme != nil else { throw LaunchOptionsError("--telemetry-url needs an address.") }
                options.telemetryUrl = url
            case "--telemetry-time-scale":
                guard let scale = Double(try value(for: argument)), scale >= 1, scale <= 100_000 else { throw LaunchOptionsError("--telemetry-time-scale needs a number from 1 to 100000.") }
                options.telemetryTimeScale = scale
            case "--telemetry-consent":
                options.telemetryConsent = true
            case "--latency-log":
                options.latencyLog = URL(fileURLWithPath: (try value(for: argument) as NSString).expandingTildeInPath)
            case "--dialog-shots":
                options.dialogShots = URL(fileURLWithPath: (try value(for: argument) as NSString).expandingTildeInPath, isDirectory: true)
            case "--language":
                options.interfaceLanguage = try value(for: argument)
            #endif
            default:
                throw LaunchOptionsError("Unknown option \(argument).")
            }
            index += 1
        }
        return options
    }
}

public struct LaunchOptionsError: Error, LocalizedError, Equatable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
