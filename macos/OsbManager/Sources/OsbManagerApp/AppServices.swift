import AppKit
import OsbManagerCef
import OsbManagerCore

@MainActor
public final class AppServices {
    public let paths: AppPaths
    public let log: AppLog
    public let accounts: AccountStore
    public let scripts: ScriptStore
    public let settings: AppSettings
    public let library: PageScriptLibrary
    public let sox: SoxLog
    public var characters: [String: String] = [:]
    public let credentials: CredentialStore
    public let profiles: CefProfiles
    public let renderers = RendererQueue()
    public var browserFactory: GameBrowserFactory = CefGameBrowserFactory()
    public var preBridgeScripts: [String] = []
    public var allowEvaluate = false
    public var diagnostics: DiagnosticsCapture?
    public private(set) var rangeFetcher: RangeFetcher = URLSessionRangeFetcher()
    private var cache: SharedAssetCache?
    public let downloader: ScriptDownloading = HttpScriptDownloader()
    public let scriptJobs = ScriptJobs()
    private let instanceLock: InstanceLock

    private init(paths: AppPaths, log: AppLog, accounts: AccountStore, scripts: ScriptStore, settings: AppSettings, library: PageScriptLibrary, sox: SoxLog, credentials: CredentialStore, instanceLock: InstanceLock) {
        self.paths = paths
        self.log = log
        self.accounts = accounts
        self.scripts = scripts
        self.settings = settings
        self.library = library
        self.sox = sox
        self.credentials = credentials
        self.profiles = CefProfiles(dataRoot: paths.root)
        self.instanceLock = instanceLock
    }

    public static func create(paths: AppPaths, resources: URL?, credentials: CredentialStore? = nil) throws -> AppServices {
        try paths.ensureCreated()
        guard let lock = InstanceLock(directory: paths.root) else {
            throw AppStartupError("\(AppIdentity.name) is already running with this data folder.", holderPid: InstanceLock.holderProcessId(directory: paths.root))
        }
        let log = AppLog(directory: paths.logs)
        log.info("\(AppIdentity.name) \(AppVersion.current()) started.")
        log.info("Started with data folder \(paths.root.path).")
        let accounts = try loadAccounts(paths: paths, log: log)
        guard let resources else {
            throw AppStartupError("The page scripts are missing. Start the app from the \(AppIdentity.bundleName) bundle.")
        }
        return AppServices(
            paths: paths,
            log: log,
            accounts: accounts,
            scripts: ScriptStore(directory: paths.scripts, log: { log.warn($0) }),
            settings: AppSettings.load(from: paths.settingsFile),
            library: PageScriptLibrary(directory: resources),
            sox: SoxLog(url: paths.soxFile),
            credentials: credentials ?? KeychainCredentialStore(service: Bundle.main.bundleIdentifier ?? AppIdentity.keychainService),
            instanceLock: lock
        )
    }

    public var cacheIfCreated: SharedAssetCache? { cache }

    public func sharedCache() -> SharedAssetCache {
        if let cache {
            return cache
        }
        let log = self.log
        let created = SharedAssetCache(directory: paths.packCache, fetcher: rangeFetcher, log: { log.warn($0) })
        cache = created
        return created
    }

    public func applyShareSetting() {
        CefPackInterception.shared.use(settings.shareGameFiles ? sharedCache() : nil)
    }

    public func use(rangeFetcher fetcher: RangeFetcher) {
        rangeFetcher = fetcher
        CefPackInterception.shared.use(nil)
        cache?.dispose()
        cache = nil
        applyShareSetting()
    }

    public func shutdownCache() {
        CefPackInterception.shared.use(nil)
        cache?.dispose()
    }

    public func note(_ level: String, _ code: String) {
        diagnostics?.trail(level, code)
    }

    public func ourCharacters() -> [String] {
        OurCharacters.names(reported: characters, accounts: accounts.accounts)
    }

    private static func loadAccounts(paths: AppPaths, log: AppLog) throws -> AccountStore {
        do {
            return try AccountStore.load(from: paths.accountsFile)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = paths.root.appendingPathComponent("accounts.invalid-\(stamp).json")
            try FileManager.default.moveItem(at: paths.accountsFile, to: aside)
            log.error("accounts.json could not be read and was moved to \(aside.lastPathComponent)", error)
            return try AccountStore.load(from: paths.accountsFile)
        }
    }
}

public struct AppStartupError: Error, LocalizedError {
    public let message: String
    public let holderPid: Int32?

    init(_ message: String, holderPid: Int32? = nil) {
        self.message = message
        self.holderPid = holderPid
    }

    public var errorDescription: String? { message }
}
