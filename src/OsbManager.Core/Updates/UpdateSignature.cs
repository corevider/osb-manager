using System.Security.Cryptography;
using System.Text;

namespace OsbManager.Core.Updates;

/// <summary>
/// Verifies a manifest's detached signature: ECDSA P-256 over SHA-256, the 64-byte r||s form, written as Base64.
/// Any one of the trusted keys may have signed it, so a key can be rotated.
/// </summary>
public sealed class UpdateSignature
{
    public const int SignatureBytes = 64;
    public const int MaxFileBytes = 256;
    private const string P256Oid = "1.2.840.10045.3.1.7";

    private readonly IReadOnlyList<byte[]> keys;

    public UpdateSignature(IEnumerable<string> publicKeys)
    {
        keys = publicKeys.Select(ParseKey).ToList();
    }

    public int KeyCount => keys.Count;

    public static byte[] ParseKey(string base64SubjectPublicKeyInfo)
    {
        byte[] der;
        try
        {
            der = Convert.FromBase64String(base64SubjectPublicKeyInfo.Trim());
        }
        catch (FormatException e)
        {
            throw new ArgumentException("An update key is not Base64.", nameof(base64SubjectPublicKeyInfo), e);
        }
        using var ecdsa = ECDsa.Create();
        ecdsa.ImportSubjectPublicKeyInfo(der, out var read);
        if (read != der.Length || ecdsa.ExportParameters(false).Curve.Oid.Value != P256Oid)
        {
            throw new ArgumentException("An update key is not a P-256 public key.", nameof(base64SubjectPublicKeyInfo));
        }
        return der;
    }

    public bool Verify(byte[] manifest, byte[] signatureFile)
    {
        if (keys.Count == 0 || signatureFile.Length > MaxFileBytes)
        {
            return false;
        }
        byte[] signature;
        try
        {
            signature = Convert.FromBase64String(Encoding.ASCII.GetString(signatureFile).Trim());
        }
        catch (FormatException)
        {
            return false;
        }
        if (signature.Length != SignatureBytes)
        {
            return false;
        }
        foreach (var key in keys)
        {
            using var ecdsa = ECDsa.Create();
            ecdsa.ImportSubjectPublicKeyInfo(key, out _);
            if (ecdsa.VerifyData(manifest, signature, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation))
            {
                return true;
            }
        }
        return false;
    }
}
