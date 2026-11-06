import CryptoKit
import Foundation

public struct UpdateSignature: Sendable {
    public static let signatureBytes = 64
    public static let maxFileBytes = 256

    private let keys: [P256.Signing.PublicKey]

    public init(publicKeys: [String]) throws {
        keys = try publicKeys.map(Self.parseKey)
    }

    public var keyCount: Int { keys.count }

    public static func parseKey(_ base64: String) throws -> P256.Signing.PublicKey {
        guard let der = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateError("An update key is not Base64.")
        }
        do {
            return try P256.Signing.PublicKey(derRepresentation: der)
        } catch {
            throw UpdateError("An update key is not a P-256 public key.")
        }
    }

    public func verify(manifest: Data, signatureFile: Data) -> Bool {
        guard !keys.isEmpty, signatureFile.count <= Self.maxFileBytes,
              let text = String(data: signatureFile, encoding: .ascii),
              let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count == Self.signatureBytes,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else { return false }
        return keys.contains { $0.isValidSignature(signature, for: manifest) }
    }
}
