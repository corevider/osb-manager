using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace OsbManager.Core.Accounts;

public sealed partial class AccountStore
{
    public const int MaxNameLength = 40;

    private readonly string path;
    private readonly List<Account> accounts = [];

    private AccountStore(string path)
    {
        this.path = path;
    }

    public IReadOnlyList<Account> Accounts => accounts;

    public static AccountStore Load(string path)
    {
        var store = new AccountStore(path);
        foreach (var account in JsonFile.Read<List<Account>>(path) ?? [])
        {
            var valid = account is not null
                && IdPattern().IsMatch(account.Id)
                && NameProblem(account.Name, store.accounts, null) is null;
            if (valid)
            {
                account!.Name = account.Name.Trim();
                store.accounts.Add(account);
            }
        }
        return store;
    }

    public Account Add(string name)
    {
        ThrowIfInvalid(name, null);
        var account = new Account { Id = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(6)), Name = name.Trim() };
        accounts.Add(account);
        Save();
        return account;
    }

    public void Rename(Account account, string name)
    {
        ThrowIfInvalid(name, account);
        account.Name = name.Trim();
        Save();
    }

    public void Remove(Account account)
    {
        if (accounts.Remove(account))
        {
            Save();
        }
    }

    /// <summary>
    /// Moves an account up (negative offset) or down the list and saves the order. Start all opens the accounts in
    /// this order. Returns false when the account is not in the list or is already at that end.
    /// </summary>
    public bool Move(Account account, int offset)
    {
        var from = accounts.IndexOf(account);
        if (from < 0)
        {
            return false;
        }
        var to = Math.Clamp(from + offset, 0, accounts.Count - 1);
        if (to == from)
        {
            return false;
        }
        accounts.RemoveAt(from);
        accounts.Insert(to, account);
        Save();
        return true;
    }

    public void UpdateLogin(Account account, LoginDetails details, ICredentialProtector protector)
    {
        var problem = LoginProblem(details, account.HasCredentials);
        if (problem is not null)
        {
            throw new ArgumentException(problem, nameof(details));
        }
        account.LoginId = details.LoginId.Trim();
        if (!string.IsNullOrEmpty(details.Password))
        {
            account.ProtectedPassword = protector.Protect(details.Password);
        }
        if (account.LoginId.Length == 0)
        {
            account.ProtectedPassword = null;
        }
        account.Server = details.Server.Trim();
        account.Character = details.Character.Trim();
        account.AutoLogin = details.AutoLogin;
        Save();
    }

    public void ClearPassword(Account account)
    {
        account.ProtectedPassword = null;
        account.AutoLogin = false;
        Save();
    }

    public static string? RevealPassword(Account account, ICredentialProtector protector) =>
        account.ProtectedPassword is { Length: > 0 } stored ? protector.Unprotect(stored) : null;

    /// <summary>Why the login settings cannot be saved, or null when they can. Limits follow the game's own fields.</summary>
    public static string? LoginProblem(LoginDetails details, bool hasSavedPassword)
    {
        var loginId = details.LoginId.Trim();
        if (loginId.Length > 256 || loginId.Any(char.IsControl))
        {
            return "Use a login ID of at most 256 characters, without control characters.";
        }
        if (details.Password is { Length: > 1024 })
        {
            return "Use a password of at most 1024 characters.";
        }
        if (details.Character.Trim().Length > 64 || details.Character.Any(char.IsControl))
        {
            return "Use a character name of at most 64 characters.";
        }
        if (details.Server.Trim().Length > 64 || details.Server.Any(char.IsControl))
        {
            return "Use a server name of at most 64 characters.";
        }
        if (details.AutoLogin && (loginId.Length == 0 || string.IsNullOrEmpty(details.Password) && !hasSavedPassword))
        {
            return "Automatic login needs a login ID and a password.";
        }
        return null;
    }

    public void Save() => JsonFile.Write(path, accounts);

    /// <summary>Why a name cannot be used, or null when it can.</summary>
    public static string? NameProblem(string? name, IEnumerable<Account> existing, Account? self)
    {
        var trimmed = name?.Trim() ?? "";
        if (trimmed.Length == 0)
        {
            return "Enter a name.";
        }
        if (trimmed.Length > MaxNameLength)
        {
            return $"Use at most {MaxNameLength} characters.";
        }
        if (trimmed.Any(char.IsControl))
        {
            return "Remove control characters from the name.";
        }
        if (existing.Any(a => a != self && string.Equals(a.Name, trimmed, StringComparison.OrdinalIgnoreCase)))
        {
            return "Another account already uses this name.";
        }
        return null;
    }

    private void ThrowIfInvalid(string name, Account? self)
    {
        var problem = NameProblem(name, accounts, self);
        if (problem is not null)
        {
            throw new ArgumentException(problem, nameof(name));
        }
    }

    [GeneratedRegex("^[0-9a-f]{12}$")]
    private static partial Regex IdPattern();
}
