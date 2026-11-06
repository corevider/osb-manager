using System.Security.Cryptography;
using System.Text;
using OsbManager.Core.Accounts;

namespace OsbManager.Browser;

/// <summary>
/// Encrypts saved passwords with Windows DPAPI, so only the same Windows user on this PC can read them.
/// </summary>
internal sealed class DpapiProtector : ICredentialProtector
{
    private static readonly byte[] Entropy = "OsbManager.login.v1"u8.ToArray();

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
        byte[] encrypted;
        try
        {
            encrypted = Convert.FromBase64String(protectedSecret);
        }
        catch (FormatException)
        {
            return null;
        }
        byte[] plain;
        try
        {
            plain = ProtectedData.Unprotect(encrypted, Entropy, DataProtectionScope.CurrentUser);
        }
        catch (CryptographicException)
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
