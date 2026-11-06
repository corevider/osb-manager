using System.Diagnostics;
using System.IO.Compression;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.RegularExpressions;
using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

public class UpdateScriptTests
{
    private static (int ExitCode, string Output) Run(string script, params string[] arguments)
    {
        var start = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(UpdateKit.RepositoryRoot(), "scripts", script) }.Concat(arguments))
        {
            start.ArgumentList.Add(argument);
        }
        using var process = Process.Start(start)!;
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        Assert.True(process.WaitForExit(TimeSpan.FromSeconds(60)));
        return (process.ExitCode, output.Result + error.Result);
    }

    [Fact]
    public void TheScriptsMakeAKeyAndManifestsTheAppAccepts()
    {
        using var temp = new TempDirectory();
        var keyPath = Path.Combine(temp.Path, "key", "release.pem");
        var (keyExit, keyOutput) = Run("new-update-key.ps1", "-KeyPath", keyPath);
        Assert.Equal(0, keyExit);
        var publicKey = keyOutput.Split('\n').Select(l => l.Trim()).Last(l => l.Length > 0);
        UpdateSignature.ParseKey(publicKey);
        Assert.False(System.Security.Cryptography.CngKey.Exists(""));
        Assert.DoesNotContain("PRIVATE", keyOutput);
        var keyText = File.ReadAllText(keyPath);
        Assert.StartsWith("-----BEGIN " + "PRIVATE KEY-----", keyText);
        Assert.DoesNotContain(keyText.Split('\n')[1].Trim(), keyOutput);

        var rules = new FileInfo(keyPath).GetAccessControl().GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>().ToList();
        Assert.True(new FileInfo(keyPath).GetAccessControl().AreAccessRulesProtected);
        Assert.All(rules, rule => Assert.Equal(WindowsIdentity.GetCurrent().User, rule.IdentityReference));

        var windowsZip = temp.File("OSB-Manager-windows-x64.zip");
        using (var archive = ZipFile.Open(windowsZip, ZipArchiveMode.Create))
        {
            using var writer = new StreamWriter(archive.CreateEntry("OsbManager.exe").Open());
            writer.Write("exe");
        }
        var macZip = temp.File("OSB-Manager-macos-arm64.zip");
        File.WriteAllBytes(macZip, new byte[3000]);
        var output = Path.Combine(temp.Path, "out");

        var (signExit, signOutput) = Run("sign-update.ps1", "-KeyPath", keyPath, "-Zip", windowsZip + "," + macZip, "-Version", "1.2.3", "-OutputDirectory", output);
        Assert.True(signExit == 0, signOutput);
        Assert.DoesNotContain(keyText.Split('\n')[1].Trim(), signOutput);

        var verifier = new UpdateSignature([publicKey]);
        foreach (var platform in new[] { UpdatePlatform.WindowsX64, UpdatePlatform.MacosArm64 })
        {
            var manifestBytes = File.ReadAllBytes(Path.Combine(output, platform.ManifestName));
            Assert.True(verifier.Verify(manifestBytes, File.ReadAllBytes(Path.Combine(output, platform.SignatureName))));
            var manifest = UpdateManifest.Parse(manifestBytes, platform);
            Assert.Equal("1.2.3", manifest.Version.ToString());
            UpdateChecker.Verify(platform == UpdatePlatform.WindowsX64 ? windowsZip : macZip, manifest);
        }
    }

    [Fact]
    public void TheKeyScriptRefusesAPathInsideTheRepositoryAndNeverOverwrites()
    {
        using var temp = new TempDirectory();
        var inside = Path.Combine(UpdateKit.RepositoryRoot(), "release-key-test.pem");
        var (insideExit, _) = Run("new-update-key.ps1", "-KeyPath", inside);
        Assert.NotEqual(0, insideExit);
        Assert.False(File.Exists(inside));

        var existing = temp.File("existing.pem");
        File.WriteAllText(existing, "keep");
        var (existingExit, _) = Run("new-update-key.ps1", "-KeyPath", existing);
        Assert.NotEqual(0, existingExit);
        Assert.Equal("keep", File.ReadAllText(existing));
    }

    [Fact]
    public void TheSignScriptRefusesAZipThatDoesNotMatchItsChecksum()
    {
        using var temp = new TempDirectory();
        var keyPath = temp.File("k.pem");
        Assert.Equal(0, Run("new-update-key.ps1", "-KeyPath", keyPath).ExitCode);
        var zip = temp.File("OSB-Manager-windows-x64.zip");
        File.WriteAllBytes(zip, [1, 2, 3]);
        File.WriteAllText(zip + ".sha256", new string('0', 64) + "  OSB-Manager-windows-x64.zip\n");

        var (exit, _) = Run("sign-update.ps1", "-KeyPath", keyPath, "-Zip", zip, "-Version", "1.2.3");

        Assert.NotEqual(0, exit);
        Assert.False(File.Exists(temp.File("OSB-Manager-windows-x64.update.json.sig")));
    }

    [Fact]
    public void TheWindowsAndMacosKeyListsMatch()
    {
        var swift = File.ReadAllText(Path.Combine(UpdateKit.RepositoryRoot(), "macos", "OsbManager", "Sources", "OsbManagerCore", "Updates", "UpdateKeys.swift"));
        var swiftKeys = Regex.Matches(swift, "\"([A-Za-z0-9+/=]{40,})\"").Select(m => m.Groups[1].Value).ToList();

        Assert.Equal(UpdateKeys.Release, swiftKeys);
        Assert.True(UpdateKeys.Release.Count <= 2);
        Assert.Equal(UpdateKeys.Release.Count, new UpdateSignature(UpdateKeys.Release).KeyCount);
    }
}
