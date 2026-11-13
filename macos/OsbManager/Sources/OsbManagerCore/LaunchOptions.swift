import Foundation

public struct LaunchOptions: Equatable {
    public static let usage = "OsbManager [--data <folder>] [--start <account>[,<account>...]] [--light] [--osb-url <address>]"

    public var dataRoot: URL?
    public var start: [String] = []
    public var startLight = false
    public var telemetryUrl: URL?
    public var telemetryTimeScale: Double?
    public var telemetryConsent = false
    public var latencyLog: URL?
    public var dialogShots: URL?
    public var interfaceLanguage: String?
    public var testInstallKeyFile: URL?
    public var updatedFrom: Int32?
    public var osbUrl: String?
    public var testUncaughtException = false
    public var inMemoryCredentials = false
    public var testStopSharingAfter: TimeInterval?

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
            case "--osb-url":
                let address = try value(for: argument)
                guard let url = URL(string: address), url.scheme != nil, url.host != nil else {
                    throw LaunchOptionsError("--osb-url needs an address.")
                }
                options.osbUrl = address
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
            case "--test-uncaught-exception":
                options.testUncaughtException = true
            case "--in-memory-credentials":
                options.inMemoryCredentials = true
            case "--test-stop-sharing":
                guard let seconds = TimeInterval(try value(for: argument)), seconds >= 0, seconds <= 86_400 else { throw LaunchOptionsError("--test-stop-sharing needs seconds from 0 to 86400.") }
                options.testStopSharingAfter = seconds
            case "--test-install-key-file":
                options.testInstallKeyFile = URL(fileURLWithPath: (try value(for: argument) as NSString).expandingTildeInPath)
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
