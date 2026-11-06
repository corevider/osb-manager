using System.Text.Json.Serialization;

namespace OsbManager.Core.Accounts;

public sealed class Account
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public bool StartLight { get; set; }
    public WindowPlacement? Window { get; set; }

    /// <summary>The game login ID. The password is kept only in <see cref="ProtectedPassword"/>.</summary>
    public string LoginId { get; set; } = "";

    /// <summary>The password, encrypted for the current Windows user.</summary>
    public string? ProtectedPassword { get; set; }

    /// <summary>Server name or id to pick on the login screen; empty keeps the game's default.</summary>
    public string Server { get; set; } = "";

    /// <summary>Character to enter after logging in; empty leaves the choice to the player.</summary>
    public string Character { get; set; } = "";

    public bool AutoLogin { get; set; }

    /// <summary>WebView2 profile that holds this account's cookies, storage and cache.</summary>
    [JsonIgnore]
    public string ProfileName => "acc-" + Id;

    [JsonIgnore]
    public bool HasCredentials => LoginId.Length > 0 && !string.IsNullOrEmpty(ProtectedPassword);
}

public sealed record WindowPlacement(int X, int Y, int Width, int Height, bool Maximized);

/// <summary>New login settings for an account. A null password keeps the saved one.</summary>
public sealed record LoginDetails(string LoginId, string? Password, string Server, string Character, bool AutoLogin);

public interface ICredentialProtector
{
    string Protect(string secret);

    /// <summary>Returns null when the value cannot be decrypted, for example under another Windows user.</summary>
    string? Unprotect(string protectedSecret);
}
