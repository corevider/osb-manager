import Foundation
@testable import OsbManagerCore

enum OsbFixtures {
    static func osbHeader(version: String, name: String = "OSB", namespace: String = BotScripts.osbNamespace) -> String {
        """
        // ==UserScript==
        // @name         \(name)
        // @namespace    \(namespace)
        // @version      \(version)
        // @updateURL    https://raw.githubusercontent.com/corevider/osb/main/osb.meta.js
        // @downloadURL  https://raw.githubusercontent.com/corevider/osb/main/osb.user.js
        // @match        https://opensro.online/play*
        // @run-at       document-start
        // @grant        none
        // ==/UserScript==
        """
    }

    static func osbSource(version: String, name: String = "OSB", namespace: String = BotScripts.osbNamespace) -> String {
        osbHeader(version: version, name: name, namespace: namespace) + "\nwindow.osbVersion = '\(version)';\n"
    }

    static func thirdPartySource(version: String) -> String {
        """
        // ==UserScript==
        // @name         Other tool
        // @namespace    https://example.com/other
        // @version      \(version)
        // @updateURL    https://example.com/other.meta.js
        // @downloadURL  https://example.com/other.user.js
        // @match        https://opensro.online/play*
        // ==/UserScript==
        window.other = true;
        """
    }

    static func closedPort() throws -> String {
        let server = try FakeHttpServer()
        let base = server.base
        server.stop()
        return base
    }
}
