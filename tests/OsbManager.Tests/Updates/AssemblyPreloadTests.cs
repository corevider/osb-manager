using System.ComponentModel;
using System.Diagnostics;
using System.Reflection;
using OsbManager.Core;
using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

public class AssemblyPreloadTests
{
    private static readonly Assembly App = typeof(UpdateRelaunch).Assembly;

    [Fact]
    public void LoadsEveryAssemblyTheAppReferences()
    {
        var result = AssemblyPreload.LoadReferenceClosure([App]);

        foreach (var reference in App.GetReferencedAssemblies())
        {
            Assert.Contains(reference.Name, result.Loaded);
        }
    }

    [Fact]
    public void LoadsWhatTheRestartTheRollBackAndTheErrorDialogUse()
    {
        var result = AssemblyPreload.LoadReferenceClosure([App]);

        foreach (var type in new[] { typeof(Process), typeof(ProcessStartInfo), typeof(EventWaitHandle), typeof(Win32Exception), typeof(ExeSwap), typeof(AppLog) })
        {
            Assert.Contains(type.Assembly.GetName().Name, result.Loaded);
        }
        Assert.Contains("System.Diagnostics.Process", result.Loaded);
        Assert.Contains("System.Threading", result.Loaded);
        Assert.Contains("System.ComponentModel.Primitives", result.Loaded);
        Assert.Contains("System.Windows.Forms", result.Loaded);
    }

    [Fact]
    public void EveryAssemblyItListsIsLoadedAfterwards()
    {
        var result = AssemblyPreload.LoadReferenceClosure([App]);
        var loaded = AppDomain.CurrentDomain.GetAssemblies().Select(a => a.GetName().Name).ToHashSet(StringComparer.OrdinalIgnoreCase);

        Assert.NotEmpty(result.Loaded);
        Assert.All(result.Loaded, name => Assert.Contains(name, loaded));
    }

    [Fact]
    public void LoadsEachReferenceOnceAndNotTheRoot()
    {
        var calls = new List<string>();

        var result = AssemblyPreload.LoadReferenceClosure([App, App], name =>
        {
            calls.Add(name.Name!);
            return Assembly.Load(name);
        });

        Assert.Equal(calls.Count, calls.Distinct(StringComparer.OrdinalIgnoreCase).Count());
        Assert.Equal(calls.Order(), result.Loaded.Concat(result.Missing).Order());
        Assert.DoesNotContain(App.GetName().Name, calls);
    }

    [Fact]
    public void ListsAReferenceThatCannotBeLoadedAndGoesOn()
    {
        var root = typeof(ExeSwap).Assembly;
        var references = root.GetReferencedAssemblies().Select(r => r.Name!).ToList();
        var refused = references[0];

        var result = AssemblyPreload.LoadReferenceClosure([root], name =>
            name.Name == refused ? throw new FileNotFoundException("") : Assembly.Load(name));

        Assert.Equal([refused], result.Missing);
        Assert.DoesNotContain(refused, result.Loaded);
        Assert.Contains(references[1], result.Loaded);
    }

    [Fact]
    public void AnUnexpectedLoadErrorIsNotHidden()
    {
        Assert.Throws<InvalidOperationException>(() =>
            AssemblyPreload.LoadReferenceClosure([App], _ => throw new InvalidOperationException("load")));
    }
}
