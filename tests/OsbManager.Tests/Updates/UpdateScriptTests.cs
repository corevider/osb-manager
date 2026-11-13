using System.Diagnostics;
using System.IO.Compression;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.RegularExpressions;
using OsbManager.Core.Updates;

namespace OsbManager.Tests.Updates;

public class UpdateScriptTests
{
    private sealed record ScriptRun(int ExitCode, string Output, string Error)
    {
        public string Report => $"exit code {ExitCode}{Environment.NewLine}stdout:{Environment.NewLine}{Output}{Environment.NewLine}stderr:{Environment.NewLine}{Error}";

        public bool ErrorSays(string text) => Regex.Replace(Error, @"\s+", " ").Contains(text, StringComparison.Ordinal);
    }

    private static ScriptRun Run(string script, params string[] arguments)
    {
        var start = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true,
        };
        start.Environment.Remove("PSModulePath");
        foreach (var argument in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(UpdateKit.RepositoryRoot(), "scripts", script) }.Concat(arguments))
        {
            start.ArgumentList.Add(argument);
        }
        using var process = Process.Start(start)!;
        process.StandardInput.Close();
        var output = process.StandardOutput.ReadToEndAsync();
        var error = process.StandardError.ReadToEndAsync();
        Assert.True(process.WaitForExit(TimeSpan.FromSeconds(60)));
        return new ScriptRun(process.ExitCode, output.Result, error.Result);
    }

    private static int PersistedKeyCount()
    {
        var folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Microsoft", "Crypto", "Keys");
        return Directory.Exists(folder) ? Directory.GetFiles(folder).Length : 0;
    }

    [Fact]
    public void TheScriptsMakeAKeyAndManifestsTheAppAccepts()
    {
        using var temp = new TempDirectory();
        var keyPath = Path.Combine(temp.Path, "key", "release.pem");
        var persistedKeys = PersistedKeyCount();
        var key = Run("new-update-key.ps1", "-KeyPath", keyPath);
        Assert.True(key.ExitCode == 0, key.Report);
        var keyOutput = key.Output;
        var publicKey = keyOutput.Split('\n').Select(l => l.Trim()).Last(l => l.Length > 0);
        UpdateSignature.ParseKey(publicKey);
        Assert.Equal(persistedKeys, PersistedKeyCount());
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

        var sign = Run("sign-update.ps1", "-KeyPath", keyPath, "-Zip", windowsZip + "," + macZip, "-Version", "1.2.3", "-OutputDirectory", output);
        Assert.True(sign.ExitCode == 0, sign.Report);
        Assert.DoesNotContain(keyText.Split('\n')[1].Trim(), sign.Report);
        Assert.Equal(persistedKeys, PersistedKeyCount());

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
        var insideRun = Run("new-update-key.ps1", "-KeyPath", inside);
        Assert.True(insideRun.ExitCode != 0, insideRun.Report);
        Assert.True(insideRun.ErrorSays("outside the repository"), insideRun.Report);
        Assert.False(File.Exists(inside));

        var existing = temp.File("existing.pem");
        File.WriteAllText(existing, "keep");
        var existingRun = Run("new-update-key.ps1", "-KeyPath", existing);
        Assert.True(existingRun.ExitCode != 0, existingRun.Report);
        Assert.True(existingRun.ErrorSays("never overwrites"), existingRun.Report);
        Assert.Equal("keep", File.ReadAllText(existing));
    }

    [Fact]
    public void TheSignScriptRefusesAZipThatDoesNotMatchItsChecksum()
    {
        using var temp = new TempDirectory();
        var keyPath = temp.File("k.pem");
        var key = Run("new-update-key.ps1", "-KeyPath", keyPath);
        Assert.True(key.ExitCode == 0, key.Report);
        var zip = temp.File("OSB-Manager-windows-x64.zip");
        File.WriteAllBytes(zip, [1, 2, 3]);
        File.WriteAllText(zip + ".sha256", new string('0', 64) + "  OSB-Manager-windows-x64.zip\n");

        var sign = Run("sign-update.ps1", "-KeyPath", keyPath, "-Zip", zip, "-Version", "1.2.3");

        Assert.True(sign.ExitCode != 0, sign.Report);
        Assert.True(sign.ErrorSays("does not match"), sign.Report);
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
