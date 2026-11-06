import AppKit
import CefBridge
import Darwin
import OsbManagerCef
import OsbManagerCore

@MainActor
public enum OsbManagerApplication {
    private static var retainedDelegate: AppDelegate?
    private static var terminationSignal: DispatchSourceSignal?

    public static func run(arguments: [String], driver: ((AppDelegate) async -> Void)? = nil) -> Never {
        guard CefRuntime.loadFramework() else {
            stop("The CEF framework could not be loaded from the app bundle.", code: 1)
        }
        guard let application = SroCefApplication.shared as? SroCefApplication else {
            stop("The application class is not SroCefApplication.", code: 1)
        }
        application.setActivationPolicy(.regular)

        let options: LaunchOptions
        do {
            options = try LaunchOptions.parse(arguments)
        } catch {
            stop("\(error.localizedDescription)\n\(LaunchOptions.usage)", code: 2)
        }

        let paths = options.dataRoot.map(AppPaths.init(root:)) ?? AppPaths.standard()
        if let previous = options.updatedFrom {
            UpdateRelaunch.announceAndWait(paths: paths, previousProcess: previous)
        }
        let services: AppServices
        do {
            services = try AppServices.create(paths: paths, resources: Bundle.main.resourceURL)
        } catch let error as AppStartupError where error.holderPid != nil {
            bringRunningInstanceToFront(pid: error.holderPid ?? 0)
        } catch {
            Dialogs.info("\(AppIdentity.name) cannot start", detail: error.localizedDescription, style: .critical)
            exit(1)
        }
        services.allowEvaluate = driver != nil

        let delegate = AppDelegate(options: options, services: services, driver: driver)
        retainedDelegate = delegate
        application.delegate = delegate
        application.terminationHandler = {
            MainActor.assumeIsolated { delegate.requestTermination(confirm: true) }
        }

        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { delegate.requestTermination(confirm: false) }
        }
        source.resume()
        terminationSignal = source

        do {
            try CefRuntime.start(rootCache: paths.cef, logFile: paths.logs.appendingPathComponent("cef.log")) {
                signal(SIGTERM, SIG_IGN)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { delegate.begin() }
                }
            }
        } catch {
            services.log.error("CEF could not start", error)
            Dialogs.info("\(AppIdentity.name) cannot start", detail: error.localizedDescription, style: .critical)
            exit(1)
        }

        CefRuntime.run()
        CefRuntime.shutdown()
        exit(0)
    }

    private static func stop(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(code)
    }

    private static func bringRunningInstanceToFront(pid: Int32) -> Never {
        guard let running = NSRunningApplication(processIdentifier: pid), let url = running.bundleURL else {
            exit(0)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        var finished = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in finished = true }
        let deadline = Date().addingTimeInterval(5)
        while !finished && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        exit(0)
    }
}
