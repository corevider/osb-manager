using System.Text;

namespace OsbManager.Core.Scripts;

/// <summary>Turns @match patterns and @include/@exclude globs into regular expressions valid in both .NET and JavaScript.</summary>
public static class UrlPattern
{
    public static string FromMatch(string pattern)
    {
        if (pattern == "<all_urls>")
        {
            return "^(https?|file|ftp)://.*$";
        }
        var schemeEnd = pattern.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd <= 0)
        {
            throw new FormatException($"Invalid @match pattern: {pattern}");
        }
        var scheme = pattern[..schemeEnd];
        var rest = pattern[(schemeEnd + 3)..];
        var slash = rest.IndexOf('/');
        var host = slash < 0 ? rest : rest[..slash];
        var path = slash < 0 ? "/" : rest[slash..];

        var regex = new StringBuilder("^");
        regex.Append(scheme == "*" ? "https?" : Escape(scheme)).Append("://");
        if (host == "*")
        {
            regex.Append("[^/]*");
        }
        else if (host.StartsWith("*.", StringComparison.Ordinal))
        {
            regex.Append("([^/]*\\.)?").Append(Escape(host[2..]));
        }
        else
        {
            regex.Append(Escape(host));
        }
        regex.Append(Wildcards(path)).Append('$');
        return regex.ToString();
    }

    public static string FromGlob(string glob)
    {
        if (glob.Length > 2 && glob.StartsWith('/') && glob.EndsWith('/'))
        {
            return glob[1..^1];
        }
        return "^" + Wildcards(glob) + "$";
    }

    private static string Wildcards(string text) => string.Join(".*", text.Split('*').Select(Escape));

    private static string Escape(string text)
    {
        var builder = new StringBuilder(text.Length);
        foreach (var c in text)
        {
            if ("\\^$.|?*+()[]{}/".Contains(c))
            {
                builder.Append('\\');
            }
            builder.Append(c);
        }
        return builder.ToString();
    }
}
