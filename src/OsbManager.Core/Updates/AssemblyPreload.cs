using System.Reflection;

namespace OsbManager.Core.Updates;

public sealed record AssemblyPreloadResult(IReadOnlyList<string> Loaded, IReadOnlyList<string> Missing);

public static class AssemblyPreload
{
    public static AssemblyPreloadResult LoadReferenceClosure(IEnumerable<Assembly> roots) =>
        LoadReferenceClosure(roots, Assembly.Load);

    public static AssemblyPreloadResult LoadReferenceClosure(IEnumerable<Assembly> roots, Func<AssemblyName, Assembly> load)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var loaded = new List<string>();
        var missing = new List<string>();
        var pending = new Queue<Assembly>();
        foreach (var root in roots)
        {
            if (root.GetName().Name is { } name && seen.Add(name))
            {
                pending.Enqueue(root);
            }
        }
        while (pending.TryDequeue(out var assembly))
        {
            foreach (var reference in assembly.GetReferencedAssemblies())
            {
                if (reference.Name is not { } name || !seen.Add(name))
                {
                    continue;
                }
                try
                {
                    pending.Enqueue(load(reference));
                    loaded.Add(name);
                }
                catch (Exception e) when (e is FileNotFoundException or FileLoadException or BadImageFormatException)
                {
                    missing.Add(name);
                }
            }
        }
        return new AssemblyPreloadResult(loaded, missing);
    }
}
