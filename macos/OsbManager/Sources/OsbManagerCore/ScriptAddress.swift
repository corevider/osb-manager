import Foundation

public enum ScriptAddress {
    public static func url(_ address: String, allowLoopbackHttp: Bool = false) throws -> URL {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(), url.host != nil else {
            throw ScriptFormatError("Use an https:// address.")
        }
        if scheme == "https" || (allowLoopbackHttp && scheme == "http" && isLoopback(url)) {
            return url
        }
        throw ScriptFormatError("Use an https:// address.")
    }

    public static func download(_ address: String, downloader: ScriptDownloading, maxBytes: Int, allowLoopbackHttp: Bool = false) async throws -> String {
        let url = try url(address, allowLoopbackHttp: allowLoopbackHttp)
        let text = try await downloader.download(url, maxBytes: maxBytes)
        if text.utf8.count > maxBytes {
            throw ScriptFormatError("The script is too large.")
        }
        return text
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}
