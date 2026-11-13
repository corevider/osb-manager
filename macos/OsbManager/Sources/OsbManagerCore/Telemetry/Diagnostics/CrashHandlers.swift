import Foundation

public enum CrashHandlers {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var capture: DiagnosticsCapture?
        var previous: (@convention(c) (NSException) -> Void)?
        var installed = false
    }

    private static let state = State()

    public static func install(_ capture: DiagnosticsCapture) {
        state.lock.withLock {
            state.capture = capture
            guard !state.installed else { return }
            state.previous = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler { exception in
                CrashHandlers.handle(exception)
            }
            state.installed = true
        }
    }

    public static func handle(_ exception: NSException) {
        let (capture, previous) = state.lock.withLock { (state.capture, state.previous) }
        capture?.crash(exceptionName: exception.name.rawValue, returnAddresses: exception.callStackReturnAddresses)
        previous?(exception)
    }
}
