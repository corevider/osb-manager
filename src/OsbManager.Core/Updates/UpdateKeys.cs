namespace OsbManager.Core.Updates;

/// <summary>
/// The release public keys (Base64 SubjectPublicKeyInfo, ECDSA P-256), the same list as the macOS app's UpdateKeys.swift.
/// Up to two are kept so that a key can be rotated. With no key the app makes no update requests at all.
/// </summary>
public static class UpdateKeys
{
    public static readonly IReadOnlyList<string> Release = ["MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEJxWc9QUsjEhBLoDOnIJWPJ7pLKq/Juzof8gnf45a43IhrlcYk1POvsCMO1I9Z/Liy+J8fOiBXM+XE8HDeJoFRQ=="];
}
