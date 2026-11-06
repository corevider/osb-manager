using System.Security.Cryptography;
using System.Text;
using OsbManager.Core.Accounts;

namespace OsbManager.Browser;

/// <summary>Protects the telemetry install key for the current Windows user, with an entropy of its own.</summary>
internal sealed class InstallKeyProtector : ICredentialProtector
{
    private static readonly byte[] Entropy = "OsbManager.installkey.v1"u8.ToArray();

    public string Protect(string secret)
    {
        var plain = Encoding.UTF8.GetBytes(secret);
        try
        {
            return Convert.ToBase64String(ProtectedData.Protect(plain, Entropy, DataProtectionScope.CurrentUser));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
    }

    public string? Unprotect(string protectedSecret)
    {
        byte[] plain;
        try
        {
            plain = ProtectedData.Unprotect(Convert.FromBase64String(protectedSecret), Entropy, DataProtectionScope.CurrentUser);
        }
        catch (Exception e) when (e is FormatException or CryptographicException)
        {
            return null;
        }
        try
        {
            return Encoding.UTF8.GetString(plain);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
    }
}
