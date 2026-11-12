// swift-tools-version: 6.2
import Foundation
import PackageDescription

let environment = ProcessInfo.processInfo.environment
let cefRoot = environment["CEF_ROOT"] ?? "/cef-root-is-not-set"
let wrapperDirectory = environment["CEF_WRAPPER_DIR"] ?? "\(cefRoot)/wrapper-build"
let coreOnly = environment["OSB_CORE_ONLY"] == "1"
let coreTargetNames: Set<String> = ["OsbManagerCore", "OsbManagerCoreTests"]

let cefCompileFlags = [
    "-I", cefRoot,
    "-D__STDC_CONSTANT_MACROS", "-D__STDC_FORMAT_MACROS",
    "-fno-rtti", "-fno-exceptions", "-fno-strict-aliasing",
    "-fobjc-call-cxx-cdtors", "-fvisibility=hidden", "-fvisibility-inlines-hidden",
    "-Wno-deprecated-declarations", "-Wno-narrowing",
]

let allTargets: [Target] = [
    .target(
        name: "CefBridge",
        publicHeadersPath: "include",
        cxxSettings: [.unsafeFlags(cefCompileFlags)],
        linkerSettings: [
            .unsafeFlags(["-L\(wrapperDirectory)", "-lcef_dll_wrapper"]),
            .linkedFramework("AppKit"),
            .linkedFramework("IOSurface"),
        ]
    ),
    .target(
        name: "OsbManagerCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "OsbManagerCef",
        dependencies: ["CefBridge", "OsbManagerCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .target(
        name: "OsbManagerApp",
        dependencies: ["OsbManagerCore", "OsbManagerCef", "CefBridge"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "OsbManager",
        dependencies: ["OsbManagerApp"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "OsbManagerE2E",
        dependencies: ["OsbManagerApp", "OsbManagerCore", "OsbManagerCef", "CefBridge"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "OsbManagerShots",
        dependencies: ["OsbManagerApp", "OsbManagerCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "OsbManagerCoreTests",
        dependencies: ["OsbManagerCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "OsbManagerCefTests",
        dependencies: ["OsbManagerCef"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

let package = Package(
    name: "OsbManager",
    platforms: [.macOS(.v26)],
    targets: coreOnly ? allTargets.filter { coreTargetNames.contains($0.name) } : allTargets,
    cxxLanguageStandard: .cxx20
)
