import AppKit
import OsbManagerApp
import OsbManagerCore

struct ShotOptions {
    static let usage = "OsbManagerShots --fixture <fixture.json> --out <folder>"

    let fixture: URL
    let out: URL

    static func parse(_ arguments: [String]) throws -> ShotOptions {
        var fixture: URL?
        var out: URL?
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { throw ShotFixtureError("\(flag) needs a value.") }
            let value = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
            switch flag {
            case "--fixture": fixture = value
            case "--out": out = value
            default: throw ShotFixtureError("Unknown option \(flag).")
            }
            index += 2
        }
        guard let fixture, let out else { throw ShotFixtureError("Both --fixture and --out are needed.") }
        return ShotOptions(fixture: fixture, out: out)
    }
}

@MainActor
enum ShotRun {
    static func run(_ options: ShotOptions) throws -> [URL] {
        let fixture = try ShotFixture.load(options.fixture)
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let dark = NSAppearance(named: .darkAqua)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("osb-shots-\(UUID().uuidString)", isDirectory: true)
        defer { removeTemporaryFolder(root) }
        let paths = AppPaths(root: root)
        try fixture.writeData(paths: paths)
        let services = try AppServices.create(paths: paths, resources: root, credentials: try fixture.credentials())
        services.characters = fixture.reportedCharacters
        let manager = GameManager(services: services, feed: try fixture.feed())
        let main = MainWindowController(services: services, manager: manager)
        main.window.appearance = dark

        try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)
        var written: [URL] = []
        for shot in fixture.macShots {
            main.window.setContentSize(NSSize(width: shot.size.width, height: shot.size.height))
            main.select(accountId: fixture.selectedId)
            main.selectTab(shot.tab)
            ShotCamera.settle()
            let url = options.out.appendingPathComponent("\(shot.file).png")
            try ShotCamera.png(of: main.window, scale: fixture.scale, crop: shot.crop).write(to: url, options: .atomic)
            written.append(url)
        }
        main.window.close()
        return written
    }

    private static func removeTemporaryFolder(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            FileHandle.standardError.write(Data("OsbManagerShots: could not delete \(folder.path): \(error.localizedDescription)\n".utf8))
        }
    }
}

UserDefaults.standard.setVolatileDomain(["AppleLocale": "en_US", "AppleLanguages": ["en"]], forName: UserDefaults.argumentDomain)

MainActor.assumeIsolated {
    do {
        let options = try ShotOptions.parse(Array(CommandLine.arguments.dropFirst()))
        for url in try ShotRun.run(options) {
            print(url.path)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("OsbManagerShots: \(error.localizedDescription)\n\(ShotOptions.usage)\n".utf8))
        exit(1)
    }
}
