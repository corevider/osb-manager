using System.IO.Compression;
using System.Security.AccessControl;
using System.Security.Principal;
using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

public class ExeSwapTests
{
    private static string Zip(TempDirectory temp, params (string Name, string Text)[] entries)
    {
        var path = temp.File("update.zip");
        using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
        foreach (var (name, text) in entries)
        {
            using var writer = new StreamWriter(archive.CreateEntry(name).Open());
            writer.Write(text);
        }
        return path;
    }

    private static (TempDirectory Temp, ExeSwap Swap) Installed(string folderName = "OSB Manager")
    {
        var temp = new TempDirectory();
        var folder = Path.Combine(temp.Path, "Programs", folderName);
        Directory.CreateDirectory(folder);
        var exe = Path.Combine(folder, "OsbManager.exe");
        File.WriteAllText(exe, "old");
        return (temp, new ExeSwap(exe));
    }

    [Fact]
    public void StagesSwapsAndCleansUpOnTheNextStart()
    {
        var (temp, swap) = Installed();
        using (temp)
        {
            swap.Stage(Zip(temp, ("OsbManager.exe", "new"), ("README.md", "r"), ("LICENSE", "l")));
            Assert.Equal("old", File.ReadAllText(swap.ExePath));

            swap.Swap();

            Assert.Equal("new", File.ReadAllText(swap.ExePath));
            Assert.Equal("old", File.ReadAllText(swap.PreviousPath));
            Assert.False(File.Exists(swap.StagedPath));

            Assert.Equal(1, new ExeSwap(swap.ExePath).CleanUp());
            Assert.False(File.Exists(swap.PreviousPath));
            Assert.Equal("new", File.ReadAllText(swap.ExePath));
        }
    }

    [Fact]
    public void RollsBackToThePreviousExe()
    {
        var (temp, swap) = Installed();
        using (temp)
        {
            swap.Stage(Zip(temp, ("OsbManager.exe", "new")));
            swap.Swap();

            swap.RollBack();

            Assert.Equal("old", File.ReadAllText(swap.ExePath));
            Assert.False(File.Exists(swap.PreviousPath));
            Assert.False(File.Exists(swap.StagedPath));
        }
    }

    [Fact]
    public void PutsTheOldExeBackWhenTheNewOneCannotBeMovedIn()
    {
        var (temp, swap) = Installed();
        using (temp)
        {
            swap.Stage(Zip(temp, ("OsbManager.exe", "new")));
            using (new FileStream(swap.StagedPath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                Assert.Throws<UpdateException>(swap.Swap);
            }

            Assert.Equal("old", File.ReadAllText(swap.ExePath));
            Assert.False(File.Exists(swap.PreviousPath));
        }
    }

    [Fact]
    public void ChangesNothingWhenTheRunningExeCannotBeMoved()
    {
        var (temp, swap) = Installed();
        using (temp)
        {
            swap.Stage(Zip(temp, ("OsbManager.exe", "new")));
            using (new FileStream(swap.ExePath, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                var error = Assert.Throws<UpdateException>(swap.Swap);
                Assert.Contains("Nothing was changed", error.Message);
            }

            Assert.Equal("old", File.ReadAllText(swap.ExePath));
            Assert.False(File.Exists(swap.PreviousPath));
        }
    }

    [Theory]
    [InlineData("other.exe")]
    [InlineData("sub/OsbManager.exe")]
    [InlineData("../OsbManager.exe")]
    public void RefusesAZipWithoutTheExeAtItsTop(string entry)
    {
        var (temp, swap) = Installed();
        using (temp)
        {
            Assert.Throws<UpdateException>(() => swap.Stage(Zip(temp, (entry, "new"))));

            Assert.Equal("old", File.ReadAllText(swap.ExePath));
            Assert.False(File.Exists(swap.StagedPath));
            Assert.False(File.Exists(Path.Combine(Path.GetDirectoryName(swap.Folder)!, "OsbManager.exe")));
        }
    }

    [Fact]
    public void RefusesAZipThatIsNotAZip()
    {
        var (temp, swap) = Installed();
        using (temp)
        {
            File.WriteAllText(temp.File("update.zip"), "not a zip");

            Assert.Throws<UpdateException>(() => swap.Stage(temp.File("update.zip")));
            Assert.Equal("old", File.ReadAllText(swap.ExePath));
        }
    }

    [Fact]
    public void RefusesToSwapWithoutAStagedExe()
    {
        var (temp, swap) = Installed();
        using (temp)
        {
            Assert.Throws<UpdateException>(swap.Swap);
            Assert.Equal("old", File.ReadAllText(swap.ExePath));
        }
    }

    [Fact]
    public void WorksInAFolderWithSpacesAndAnyName()
    {
        var (temp, swap) = Installed("My Tools (x86) ğüş");
        using (temp)
        {
            swap.Stage(Zip(temp, ("OsbManager.exe", "new")));
            swap.Swap();

            Assert.Equal("new", File.ReadAllText(swap.ExePath));
        }
    }

    [Fact]
    public void TellsAWritableFolderFromOneThatIsNot()
    {
        using var temp = new TempDirectory();

        Assert.True(ExeSwap.CanWrite(temp.Path));
        Assert.False(ExeSwap.CanWrite(Path.Combine(temp.Path, "missing")));
        Assert.Empty(Directory.GetFiles(temp.Path));
    }

    [Fact]
    public void TellsAFolderThatDeniesNewFilesToTheCurrentUserFromOneThatAllowsThem()
    {
        using var temp = new TempDirectory();
        var folder = Directory.CreateDirectory(temp.File("locked"));
        var user = WindowsIdentity.GetCurrent().User!;
        var deny = new FileSystemAccessRule(user, FileSystemRights.CreateFiles, AccessControlType.Deny);
        var security = folder.GetAccessControl();
        security.AddAccessRule(deny);
        folder.SetAccessControl(security);
        try
        {
            Assert.False(ExeSwap.CanWrite(folder.FullName));
        }
        finally
        {
            security.RemoveAccessRule(deny);
            folder.SetAccessControl(security);
        }

        Assert.True(ExeSwap.CanWrite(folder.FullName));
        Assert.Empty(folder.GetFiles());
    }

    [Fact]
    public void TellsAPathThatIsAFileFromAWritableFolder()
    {
        using var temp = new TempDirectory();
        var file = temp.File("not-a-folder");
        File.WriteAllText(file, "x");

        Assert.False(ExeSwap.CanWrite(file));
        Assert.Equal("x", File.ReadAllText(file));
    }
}
