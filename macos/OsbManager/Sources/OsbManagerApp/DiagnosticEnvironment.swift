import Foundation
import Metal
import OsbManagerCore

enum DiagnosticEnvironment {
    static func forThisMac(cefVersion: String) -> DiagnosticEnv {
        let info = ProcessInfo.processInfo
        return DiagnosticEnv(
            osBuild: DiagnosticFormats.osBuild(info.operatingSystemVersion),
            webview2: DiagnosticFormats.chromiumVersion(cefVersion: cefVersion),
            ramGb: DiagnosticFormats.ramBucket(bytes: info.physicalMemory),
            cores: DiagnosticFormats.coreBucket(info.activeProcessorCount),
            gpuVendor: DiagnosticFormats.gpuVendor(deviceName: MTLCreateSystemDefaultDevice()?.name)
        )
    }
}
