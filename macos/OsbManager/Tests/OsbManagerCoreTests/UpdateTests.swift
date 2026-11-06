import CryptoKit
import Foundation
import Testing
@testable import OsbManagerCore

struct TestKey {
    let key = P256.Signing.PrivateKey()

    var publicKey: String { key.publicKey.derRepresentation.base64EncodedString() }

    func sign(_ data: Data) -> Data {
        Data(((try? key.signature(for: data))?.rawRepresentation.base64EncodedString() ?? "").utf8 + [10])
    }
}

struct SeenUpdate: Sendable {
    let url: URL
    let headers: [String: String]
}

final class FakeGitHub: UpdateTransport, @unchecked Sendable {
    static let tag = "v1.0.3"
    static let api = "https://api.github.com/repos/corevider/osb-manager/releases/latest"

    enum Answer {
        case body(Data)
        case status(Int, location: String?)
        case failure(Error)
        case chunks([Data])
    }

    private let lock = NSLock()
    private var routes: [String: Answer] = [:]
    private var log: [SeenUpdate] = []

    var seen: [SeenUpdate] { lock.withLock { log } }

    static func assetUrl(_ name: String, tag: String = tag) -> String {
        "https://github.com/corevider/osb-manager/releases/download/\(tag)/\(name)"
    }

    static func storageUrl(_ name: String) -> String {
        "https://release-assets.githubusercontent.com/github-production-release-asset/1/\(name)?sig=x"
    }

    func route(_ url: String, _ answer: Answer) {
        lock.withLock { routes[url] = answer }
    }

    func asset(_ name: String, _ data: Data, tag: String = tag) {
        route(Self.assetUrl(name, tag: tag), .status(302, location: Self.storageUrl(name)))
        route(Self.storageUrl(name), .body(data))
    }

    func release(tag: String = tag, title: String, assets: [String]) {
        let list = assets.map { ["name": $0, "browser_download_url": "https://evil.example/\($0)"] }
        let object: [String: Any] = ["tag_name": tag, "name": title, "draft": false, "assets": list]
        route(Self.api, .body((try? JSONSerialization.data(withJSONObject: object)) ?? Data()))
    }

    func send(_ request: URLRequest, limit: Int64, timeout: TimeInterval, sink: @escaping @Sendable (Data) throws -> Void) async throws -> UpdateHop {
        let url = request.url!
        let answer: Answer? = lock.withLock {
            log.append(SeenUpdate(url: url, headers: request.allHTTPHeaderFields ?? [:]))
            return routes[url.absoluteString]
        }
        switch answer {
        case .body(let data):
            guard Int64(data.count) <= limit else { throw UpdateError("\(url.host ?? "") offered \(data.count) bytes, more than the \(limit) allowed.") }
            try sink(data)
            return UpdateHop(status: 200)
        case .chunks(let chunks):
            var total: Int64 = 0
            for chunk in chunks {
                total += Int64(chunk.count)
                guard total <= limit else { throw UpdateError("\(url.host ?? "") sent more than the \(limit) bytes allowed.") }
                try sink(chunk)
            }
            return UpdateHop(status: 200)
        case .status(let status, let location):
            return UpdateHop(status: status, location: location)
        case .failure(let error):
            throw error
        case nil:
            return UpdateHop(status: 404)
        }
    }
}

struct FakeRelease {
    var platform = UpdatePlatform.macosArm64
    var version = "1.0.3"
    var zip = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    func manifest(version: String? = nil, size: Int? = nil, sha256: String? = nil, platform: String? = nil) -> Data {
        let hash = sha256 ?? SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        let text = "{\"format\":1,\"product\":\"osb-manager\",\"platform\":\"\(platform ?? self.platform.name)\",\"version\":\"\(version ?? self.version)\",\"asset\":\"\(self.platform.zipName)\",\"size\":\(size ?? zip.count),\"sha256\":\"\(hash)\"}\n"
        return Data(text.utf8)
    }

    func publish(_ github: FakeGitHub, key: TestKey, manifest: Data? = nil, signature: Data? = nil, title: String = "OSB Manager 1.0.3") {
        let body = manifest ?? self.manifest()
        github.release(title: title, assets: [platform.zipName, platform.manifestName, platform.signatureName])
        github.asset(platform.manifestName, body)
        github.asset(platform.signatureName, signature ?? key.sign(body))
        github.asset(platform.zipName, zip)
    }
}

func makeChecker(_ github: FakeGitHub, current: String = "1.0.2", keys: [String]) throws -> UpdateChecker {
    UpdateChecker(
        http: UpdateHttp(transport: github, userAgent: "OSBManager/1.0.2 (macOS)"),
        platform: .macosArm64,
        current: UpdateVersion(current)!,
        signature: try UpdateSignature(publicKeys: keys)
    )
}

struct UpdateSignatureTests {
    @Test func offersANewerSignedReleaseAndDownloadsTheVerifiedZip() async throws {
        let key = TestKey()
        let github = FakeGitHub()
        let release = FakeRelease()
        release.publish(github, key: key, title: "OSB Manager 1.0.3\n\u{202E}fixes")
        let checker = try makeChecker(github, keys: [key.publicKey])

        let result = await checker.check()

        #expect(result.status == .available)
        let offer = try #require(result.offer)
        #expect(offer.version.description == "1.0.3")
        #expect(offer.title == "OSB Manager 1.0.3 fixes")
        #expect(offer.zipUrl.absoluteString == FakeGitHub.assetUrl("OSB-Manager-macos-arm64.zip"))
        let temp = TemporaryDirectory()
        let zip = try await checker.download(offer, into: temp.url)
        #expect(try Data(contentsOf: zip) == release.zip)
        #expect(!github.seen.contains { $0.url.host == "evil.example" })
    }

    @Test func refusesATamperedManifest() async throws {
        let key = TestKey()
        let github = FakeGitHub()
        let release = FakeRelease()
        let signed = release.manifest()
        release.publish(github, key: key, manifest: release.manifest(version: "9.0.0"), signature: key.sign(signed))

        let result = try await makeChecker(github, keys: [key.publicKey]).check()

        #expect(result.status == .failed)
        #expect(result.offer == nil)
    }

    @Test func refusesAnotherKeyAndAcceptsTheRotatedOne() async throws {
        let old = TestKey()
        let rotated = TestKey()
        let github = FakeGitHub()
        FakeRelease().publish(github, key: rotated)

        #expect(try await makeChecker(github, keys: [old.publicKey]).check().status == .failed)
        #expect(try await makeChecker(github, keys: [old.publicKey, rotated.publicKey]).check().status == .available)
    }

    @Test func treatsAMissingSignatureAsNotSigned() async throws {
        let key = TestKey()
        let github = FakeGitHub()
        let release = FakeRelease()
        github.release(title: "x", assets: [release.platform.zipName, release.platform.manifestName])
        github.asset(release.platform.manifestName, release.manifest())

        let result = try await makeChecker(github, keys: [key.publicKey]).check()

        #expect(result.status == .notSigned)
        #expect(github.seen.count == 1)
    }

    @Test(arguments: ["", "not base64!", "AAAA"])
    func refusesAMalformedSignature(_ text: String) async throws {
        let key = TestKey()
        let github = FakeGitHub()
        FakeRelease().publish(github, key: key, signature: Data(text.utf8))

        #expect(try await makeChecker(github, keys: [key.publicKey]).check().status == .failed)
    }

    @Test func refusesATamperedZip() async throws {
        let key = TestKey()
        let github = FakeGitHub()
        var release = FakeRelease()
        release.publish(github, key: key)
        let checker = try makeChecker(github, keys: [key.publicKey])
        let offer = try #require(await checker.check().offer)
        release.zip[100] ^= 0xFF
        github.route(FakeGitHub.storageUrl(release.platform.zipName), .body(release.zip))
        let temp = TemporaryDirectory()

        await #expect(throws: UpdateError.self) { _ = try await checker.download(offer, into: temp.url) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    }

    @Test func stopsAZipLargerThanTheSignedSize() async throws {
        let key = TestKey()
        let github = FakeGitHub()
        let release = FakeRelease()
        release.publish(github, key: key)
        let checker = try makeChecker(github, keys: [key.publicKey])
        let offer = try #require(await checker.check().offer)
        github.route(FakeGitHub.storageUrl(release.platform.zipName), .chunks([release.zip, Data(count: 10)]))
        let temp = TemporaryDirectory()

        await #expect(throws: UpdateError.self) { _ = try await checker.download(offer, into: temp.url) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).isEmpty)
    }

    @Test(arguments: ["1.0.1", "1.0.2", "0.9.99"])
    func doesNotOfferAnOlderOrTheSameVersion(_ version: String) async throws {
        let key = TestKey()
        let github = FakeGitHub()
        FakeRelease(version: version).publish(github, key: key)

        let result = try await makeChecker(github, keys: [key.publicKey]).check()

        #expect(result.status == .upToDate)
        #expect(result.offer == nil)
    }

    @Test(arguments: ["1.0", "1.0.3-beta", "01.0.3", "1.0.3.4", "v1.0.3", "", "１.0.3"])
    func refusesAMalformedSignedVersion(_ version: String) async throws {
        let key = TestKey()
        let github = FakeGitHub()
        FakeRelease(version: version).publish(github, key: key)

        let result = try await makeChecker(github, keys: [key.publicKey]).check()

        #expect(result.status == .failed)
        #expect(result.message.contains("version"))
    }

    @Test func refusesAManifestForAnotherPlatform() async throws {
        let key = TestKey()
        let github = FakeGitHub()
        let release = FakeRelease()
        release.publish(github, key: key, manifest: release.manifest(platform: "windows-x64"))

        let result = try await makeChecker(github, keys: [key.publicKey]).check()

        #expect(result.status == .failed)
        #expect(result.message.contains("platform"))
    }

    @Test(arguments: [
        "{\"format\":1,\"product\":\"osb-manager\",\"platform\":\"macos-arm64\",\"version\":\"1.0.3\",\"asset\":\"OSB-Manager-macos-arm64.zip\",\"size\":10,\"sha256\":\"ab\"}",
        "{\"format\":true,\"product\":\"osb-manager\",\"platform\":\"macos-arm64\",\"version\":\"1.0.3\",\"asset\":\"OSB-Manager-macos-arm64.zip\",\"size\":10,\"sha256\":\"\(String(repeating: "a", count: 64))\"}",
        "{\"format\":1,\"product\":\"osb-manager\",\"platform\":\"macos-arm64\",\"version\":\"1.0.3\",\"asset\":\"OSB-Manager-macos-arm64.zip\",\"size\":10.5,\"sha256\":\"\(String(repeating: "a", count: 64))\"}",
        "{\"format\":1,\"product\":\"osb-manager\",\"platform\":\"macos-arm64\",\"version\":\"1.0.3\",\"asset\":\"other.zip\",\"size\":10,\"sha256\":\"\(String(repeating: "a", count: 64))\"}",
        "{\"format\":1,\"product\":\"osb-manager\",\"platform\":\"macos-arm64\",\"version\":\"1.0.3\",\"asset\":\"OSB-Manager-macos-arm64.zip\",\"size\":0,\"sha256\":\"\(String(repeating: "a", count: 64))\"}",
        "{\"format\":1,\"product\":\"osb-manager\",\"platform\":\"macos-arm64\",\"version\":\"1.0.3\",\"asset\":\"OSB-Manager-macos-arm64.zip\",\"size\":10,\"sha256\":\"\(String(repeating: "A", count: 64))\"}",
        "{\"format\":1,\"product\":\"osb-manager\",\"platform\":\"macos-arm64\",\"version\":\"1.0.3\",\"asset\":\"OSB-Manager-macos-arm64.zip\",\"size\":10,\"sha256\":\"\(String(repeating: "a", count: 64))\",\"url\":\"https://evil.example\"}",
        "[1]",
        "not json",
    ])
    func rejectsMalformedManifests(_ json: String) {
        #expect(throws: UpdateError.self) { try UpdateManifest.parse(Data(json.utf8), platform: .macosArm64) }
    }

    @Test func acceptsAManifestAndSignatureMadeBySignUpdatePs1() throws {
        let signature = try UpdateSignature(publicKeys: [PowerShellVector.publicKey])
        let manifest = Data(PowerShellVector.manifest.utf8)

        #expect(signature.verify(manifest: manifest, signatureFile: Data(PowerShellVector.signature.utf8)))
        #expect(try UpdateManifest.parse(manifest, platform: .macosArm64).version.description == "1.2.3")
        var tampered = manifest
        tampered[tampered.count - 3] ^= 1
        #expect(!signature.verify(manifest: tampered, signatureFile: Data(PowerShellVector.signature.utf8)))
    }

    @Test func comparesVersionsNumerically() {
        #expect(UpdateVersion("1.0.10")! > UpdateVersion("1.0.9")!)
        #expect(UpdateVersion("1.10.0")! > UpdateVersion("1.9.99")!)
        #expect(UpdateVersion("2.0.0")! < UpdateVersion("10.0.0")!)
        #expect(UpdateVersion("1.0.2")! == UpdateVersion("1.0.2")!)
    }

    @Test func theBuiltInKeysParse() throws {
        #expect(UpdateKeys.release.count <= 2)
        #expect(try UpdateSignature(publicKeys: UpdateKeys.release).keyCount == UpdateKeys.release.count)
    }
}

struct UpdateTransportTests {
    private static let asset = "https://github.com/corevider/osb-manager/releases/download/v1.0.3/a.bin"

    private func http(_ github: FakeGitHub) -> UpdateHttp {
        UpdateHttp(transport: github, userAgent: "OSBManager/1.0.2 (macOS)")
    }

    @Test(arguments: [
        ("https://api.github.com/x", true),
        ("https://github.com/x", true),
        ("https://release-assets.githubusercontent.com/x", true),
        ("https://objects.githubusercontent.com/x", true),
        ("https://GitHub.com/x", true),
        ("http://github.com/x", false),
        ("https://github.com:8443/x", false),
        ("https://user:pass@github.com/x", false),
        ("https://raw.githubusercontent.com/x", false),
        ("https://github.com.evil.example/x", false),
        ("https://github.com./x", false),
        ("file:///tmp/x", false),
    ])
    func allowsOnlyGitHubOverHttps(_ url: String, _ allowed: Bool) {
        #expect(UpdateHosts.gitHub.allows(URL(string: url)!) == allowed)
    }

    @Test func refusesAnotherHostWithoutContactingIt() async {
        let github = FakeGitHub()

        await #expect(throws: UpdateError.self) { _ = try await http(github).data(URL(string: "https://evil.example/a")!, limit: 100, timeout: 5, accept: "*/*") }
        #expect(github.seen.isEmpty)
    }

    @Test(arguments: ["https://evil.example/a.bin", "http://release-assets.githubusercontent.com/a.bin", "https://release-assets.githubusercontent.com:444/a.bin", "//evil.example/a.bin"])
    func refusesARedirectOffTheAllowlist(_ target: String) async {
        let github = FakeGitHub()
        github.route(Self.asset, .status(302, location: target))

        do {
            _ = try await http(github).data(URL(string: Self.asset)!, limit: 100, timeout: 5, accept: "*/*")
            Issue.record("The redirect was followed.")
        } catch let error as UpdateError {
            #expect(error.message.contains("Refused a redirect"))
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(github.seen.count == 1)
    }

    @Test func followsAllowedRedirectsAndRelativeOnes() async throws {
        let github = FakeGitHub()
        github.route(Self.asset, .status(307, location: "/corevider/b"))
        github.route("https://github.com/corevider/b", .status(302, location: FakeGitHub.storageUrl("b")))
        github.route(FakeGitHub.storageUrl("b"), .body(Data([1, 2, 3])))

        #expect(try await http(github).data(URL(string: Self.asset)!, limit: 100, timeout: 5, accept: "*/*") == Data([1, 2, 3]))
    }

    @Test func stopsAfterTooManyRedirects() async {
        let github = FakeGitHub()
        github.route("https://github.com/a", .status(302, location: "https://github.com/b"))
        github.route("https://github.com/b", .status(302, location: "https://github.com/a"))

        await #expect(throws: UpdateError("Too many redirects from github.com.")) { _ = try await http(github).data(URL(string: "https://github.com/a")!, limit: 100, timeout: 5, accept: "*/*") }
        #expect(github.seen.count == UpdateHttp.maxRedirects + 1)
    }

    @Test func reportsTimeoutsNetworkErrorsAndServerErrors() async {
        let github = FakeGitHub()
        github.route("https://github.com/t", .failure(URLError(.timedOut)))
        github.route("https://github.com/n", .failure(URLError(.cannotConnectToHost)))
        github.route("https://github.com/s", .status(503, location: nil))

        await #expect(throws: UpdateError("The request to github.com timed out.")) { _ = try await http(github).data(URL(string: "https://github.com/t")!, limit: 100, timeout: 5, accept: "*/*") }
        await #expect(throws: UpdateError.self) { _ = try await http(github).data(URL(string: "https://github.com/n")!, limit: 100, timeout: 5, accept: "*/*") }
        await #expect(throws: UpdateError("github.com answered HTTP 503.")) { _ = try await http(github).data(URL(string: "https://github.com/s")!, limit: 100, timeout: 5, accept: "*/*") }
    }

    @Test func refusesABodyLargerThanTheLimit() async {
        let github = FakeGitHub()
        github.route(Self.asset, .body(Data(count: 2000)))

        await #expect(throws: UpdateError.self) { _ = try await http(github).data(URL(string: Self.asset)!, limit: 1000, timeout: 5, accept: "*/*") }
    }

    @Test func sendsAFixedUserAgentAndNoCookies() async throws {
        let github = FakeGitHub()
        github.route(Self.asset, .body(Data([1])))

        _ = try await http(github).data(URL(string: Self.asset)!, limit: 100, timeout: 5, accept: "*/*")

        let headers = try #require(github.seen.first?.headers)
        #expect(headers["User-Agent"] == "OSBManager/1.0.2 (macOS)")
        #expect(headers["Cookie"] == nil)
        #expect(headers["Authorization"] == nil)
    }

    @Test func theRealSessionKeepsNoCookiesCacheOrCredentialsAndHasTimeouts() {
        let configuration = UrlSessionUpdateTransport.configuration(timeout: 20)

        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.timeoutIntervalForRequest == 20)
        #expect(configuration.timeoutIntervalForResource == 20)
        #expect(UrlSessionUpdateTransport.configuration(timeout: 1800).timeoutIntervalForRequest == 30)
    }

    @Test func cleansTheReleaseTitle() {
        #expect(UpdateChecker.cleanTitle("  a\r\n\tb  ") == "a b")
        #expect(UpdateChecker.cleanTitle("x\u{200E}y\u{202E}z") == "xyz")
        #expect(UpdateChecker.cleanTitle(String(repeating: "a", count: 500)).count == UpdateChecker.maxTitleLength)
    }
}

struct UpdateScheduleTests {
    private func service(_ github: FakeGitHub, clock: ManualClock, enabled: @escaping @Sendable () -> Bool, keys: [String]) -> UpdateService {
        var options = UpdateServiceOptions(currentVersion: "1.0.2", platform: .macosArm64, publicKeys: keys, userAgent: "OSBManager/1.0.2 (macOS)", transport: github)
        options.clock = SchedulerClock(clock)
        return UpdateService(options: options, enabled: enabled, log: { _ in })
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    @Test func makesNoRequestWhenTheSettingIsOff() async {
        let key = TestKey()
        let github = FakeGitHub()
        FakeRelease().publish(github, key: key)
        let clock = ManualClock()
        let updates = service(github, clock: clock, enabled: { false }, keys: [key.publicKey])

        updates.start()
        for _ in 0..<40 {
            await clock.advance(by: .seconds(6 * 3600)) { await settle() }
        }
        updates.stop()

        #expect(github.seen.isEmpty)
    }

    @Test func makesNoRequestWithoutAReleaseKey() async {
        let github = FakeGitHub()
        let clock = ManualClock()
        let updates = service(github, clock: clock, enabled: { true }, keys: [])

        updates.start()
        await clock.advance(by: .seconds(3 * 86400)) { await settle() }
        let manual = await updates.checkNow()

        #expect(github.seen.isEmpty)
        #expect(updates.problem != nil)
        #expect(manual.status == .failed)
    }

    @Test func checksAfterTheFirstDelayWaitsWhileBusyAndRepeats() async {
        let key = TestKey()
        let github = FakeGitHub()
        FakeRelease(version: "1.0.2").publish(github, key: key)
        let clock = ManualClock()
        let updates = service(github, clock: clock, enabled: { true }, keys: [key.publicKey])
        updates.busy = true

        updates.start()
        await settle()
        await clock.advance(by: .seconds(600)) { await settle() }
        #expect(github.seen.isEmpty)

        updates.busy = false
        await clock.advance(by: .seconds(60)) { await settle() }
        #expect(github.seen.filter { $0.url.host == "api.github.com" }.count == 1)

        await clock.advance(by: .seconds(6 * 3600)) { await settle() }
        #expect(github.seen.filter { $0.url.host == "api.github.com" }.count == 2)
        updates.stop()
    }
}

struct UpdateNoticeFlowTests {
    private func offer(_ version: String) -> UpdateOffer {
        UpdateOffer(
            manifest: UpdateManifest(version: UpdateVersion(version)!, platform: "macos-arm64", asset: "OSB-Manager-macos-arm64.zip", size: 1, sha256: String(repeating: "a", count: 64)),
            tag: "v" + version, title: "OSB Manager " + version, zipUrl: URL(string: "https://github.com/x")!, releasePage: URL(string: "https://github.com/y")!)
    }

    @Test func laterHidesAVersionUntilTheUserAsksOrANewerOneComes() {
        let notice = UpdateNotice()

        #expect(notice.offer(offer("1.0.3"), requestedByUser: false))
        notice.later()
        #expect(notice.current == nil)
        #expect(!notice.offer(offer("1.0.3"), requestedByUser: false))
        #expect(notice.offer(offer("1.0.3"), requestedByUser: true))
        notice.later()
        #expect(notice.offer(offer("1.0.4"), requestedByUser: false))
        #expect(!notice.offer(offer("1.0.3"), requestedByUser: true))
    }

    @Test func installsOnlyAfterTheUserChoseIt() {
        let notice = UpdateNotice()
        #expect(notice.beginInstall() == nil)

        _ = notice.offer(offer("1.0.3"), requestedByUser: false)
        #expect(notice.beginInstall() != nil)
        #expect(notice.beginInstall() == nil)
        #expect(!notice.offer(offer("1.0.4"), requestedByUser: true))
        notice.installFailed()
        #expect(notice.beginInstall() != nil)
    }
}
