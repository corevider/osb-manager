import Foundation
import Testing
@testable import OsbManagerCore

private enum PackageFiles {
    static let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
    static let package = root.appendingPathComponent("macos/OsbManager", isDirectory: true)
    static let scripts = root.appendingPathComponent("macos/scripts", isDirectory: true)

    static func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}

struct AppIdentityTests {
    @Test func namesTheAppOsbManager() {
        #expect(AppIdentity.name == "OSB Manager")
        #expect(AppIdentity.bundleName == "OSB Manager.app")
        #expect(AppIdentity.bundleIdentifier == "com.corevider.osb-manager")
        #expect(AppIdentity.dataFolderName == "OSB Manager")
    }

    @Test func usesTheBundleIdentifierAsTheKeychainService() {
        #expect(AppIdentity.keychainService == AppIdentity.bundleIdentifier)
    }

    @Test func putsTheDataAndTheCefFolderWhereTheSpecSays() {
        let paths = AppPaths.standard()

        #expect(paths.root.path.hasSuffix("/Library/Application Support/OSB Manager"))
        #expect(paths.cef.path == paths.root.path + "/cef")
    }

    @Test func theBundleTemplateCarriesTheNewNameAndNoOldOne() throws {
        let app = try PackageFiles.text(PackageFiles.package.appendingPathComponent("Info.plist.in"))
        let helper = try PackageFiles.text(PackageFiles.package.appendingPathComponent("helper-Info.plist.in"))

        #expect(app.contains("<key>CFBundleName</key>\n    <string>OSB Manager</string>"))
        #expect(app.contains("<key>CFBundleDisplayName</key>\n    <string>OSB Manager</string>"))
        #expect(app.contains("<key>NSPrincipalClass</key>\n    <string>SroCefApplication</string>"))
    }

    @Test func theBuildScriptsUseTheNewIdentifiers() throws {
        let build = try PackageFiles.text(PackageFiles.scripts.appendingPathComponent("build-app.sh"))
        let install = try PackageFiles.text(PackageFiles.scripts.appendingPathComponent("install-remote.sh"))

        #expect(build.contains(AppIdentity.bundleIdentifier))
        #expect(build.contains(AppIdentity.name))
        #expect(install.contains(AppIdentity.name))
    }
}
