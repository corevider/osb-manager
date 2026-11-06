using System.Security.Cryptography;
using System.Text;
using OsbManager.Browser;

namespace OsbManager.Tests;

public class DpapiProtectorTests
{
    private static readonly byte[] CurrentEntropy = "OsbManager.login.v1"u8.ToArray();

    private static string RandomPassword() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(18));

    private static string Seal(string secret, byte[] entropy) =>
        Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(secret), entropy, DataProtectionScope.CurrentUser));

    private static bool Opens(string sealedSecret, byte[] entropy)
    {
        try
        {
            ProtectedData.Unprotect(Convert.FromBase64String(sealedSecret), entropy, DataProtectionScope.CurrentUser);
            return true;
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    [Fact]
    public void ProtectsWithTheAppEntropy()
    {
        var password = RandomPassword();

        var sealedSecret = new DpapiProtector().Protect(password);

        Assert.True(Opens(sealedSecret, CurrentEntropy));
        Assert.False(Opens(sealedSecret, "something else"u8.ToArray()));
        Assert.Equal(password, new DpapiProtector().Unprotect(sealedSecret));
    }

    [Theory]
    [InlineData("not base64 !!")]
    [InlineData("AAAA")]
    [InlineData("")]
    public void RejectsValuesItCannotDecrypt(string value)
    {
        Assert.Null(new DpapiProtector().Unprotect(value));
    }

    [Fact]
    public void RejectsAValueSealedWithAnotherEntropy()
    {
        Assert.Null(new DpapiProtector().Unprotect(Seal(RandomPassword(), "something else"u8.ToArray())));
    }
}
