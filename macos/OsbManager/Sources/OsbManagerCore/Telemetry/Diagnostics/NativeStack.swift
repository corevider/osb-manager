import Darwin
import Foundation

public enum NativeStack {
    public static let machineryPrefixes = [
        "OsbManagerCore.NativeStack.",
        "OsbManagerCore.AppLog.",
        "OsbManagerCore.DiagnosticsCapture.",
        "OsbManagerCore.CrashHandlers.",
        "OsbManagerApp.TelemetryController.",
    ]

    private typealias SwiftDemangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
    private typealias CxxDemangle = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?

    private static let ownImage = UnsafeRawPointer(#dsohandle)
    private static let swiftDemangle: SwiftDemangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle").map { unsafeBitCast($0, to: SwiftDemangle.self) }
    private static let cxxDemangle: CxxDemangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__cxa_demangle").map { unsafeBitCast($0, to: CxxDemangle.self) }

    public static func frames(_ returnAddresses: [NSNumber]) -> [String] {
        let resolved = returnAddresses.prefix(64).map { number -> NativeFrame in
            resolve(UnsafeRawPointer(bitPattern: number.uintValue))
        }
        return FrameReducer.reduce(resolved)
    }

    public static func callerFrames() -> [String] {
        withoutMachinery(frames(Thread.callStackReturnAddresses))
    }

    public static func withoutMachinery(_ frames: [String]) -> [String] {
        var rest = ArraySlice(frames)
        while let first = rest.first, first == FrameReducer.external || machineryPrefixes.contains(where: { first.hasPrefix($0) }) {
            rest = rest.dropFirst()
        }
        if rest.isEmpty {
            return frames.contains(FrameReducer.external) ? [FrameReducer.external] : []
        }
        return Array(rest)
    }

    public static func demangle(_ symbol: String) -> String {
        if symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") || symbol.hasPrefix("$S") || symbol.hasPrefix("_T0") {
            return demangledSwift(symbol) ?? symbol
        }
        if symbol.hasPrefix("_Z") || symbol.hasPrefix("__Z") {
            return demangledCxx(symbol.hasPrefix("__Z") ? String(symbol.dropFirst()) : symbol) ?? symbol
        }
        return symbol
    }

    @inline(never)
    public static func selfCheck() -> [String] {
        frames(Thread.callStackReturnAddresses)
    }

    private static func resolve(_ address: UnsafeRawPointer?) -> NativeFrame {
        guard let address else { return NativeFrame(ownImage: false, symbol: nil) }
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let base = info.dli_fbase else { return NativeFrame(ownImage: false, symbol: nil) }
        guard UnsafeRawPointer(base) == ownImage else { return NativeFrame(ownImage: false, symbol: nil) }
        let symbol = info.dli_sname.map { demangle(String(cString: $0)) }
        return NativeFrame(ownImage: true, symbol: symbol)
    }

    private static func demangledSwift(_ symbol: String) -> String? {
        guard let swiftDemangle else { return nil }
        return symbol.withCString { pointer -> String? in
            guard let output = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return nil }
            defer { free(output) }
            return String(cString: output)
        }
    }

    private static func demangledCxx(_ symbol: String) -> String? {
        guard let cxxDemangle else { return nil }
        return symbol.withCString { pointer -> String? in
            var status: Int32 = 0
            guard let output = cxxDemangle(pointer, nil, nil, &status), status == 0 else { return nil }
            defer { free(output) }
            return String(cString: output)
        }
    }
}
