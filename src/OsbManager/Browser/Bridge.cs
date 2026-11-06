namespace OsbManager.Browser;

/// <summary>
/// The page script that reports bot status, limits the frame rate, switches rendering for light mode and
/// drives automatic login, and the small script that records WebAssembly memory for the Memory tab.
/// </summary>
internal static class Bridge
{
    private static readonly string Parts = string.Join("\n", Load("autologin.js"), Load("light.js"), Load("gpu.js"), Load("drops.js"));
    private static readonly string Page = Load("bridge.js");

    public static string WasmProbe { get; } = Load("memory.js");

    public static string Build(int frameLimit) =>
        $"(() => {{\nconst initialFrameLimit = {Math.Max(0, frameLimit)};\n{Parts}\n{Page}\n}})();\n";

    private static string Load(string name)
    {
        using var stream = typeof(Bridge).Assembly.GetManifestResourceStream("OsbManager." + name)
            ?? throw new InvalidOperationException($"The page script {name} is missing from the build.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
