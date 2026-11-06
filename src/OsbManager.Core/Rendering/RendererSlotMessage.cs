using System.Text.Json;

namespace OsbManager.Core.Rendering;

/// <summary>
/// A page asking for the renderer slot ("gpu-slot") or handing it back ("gpu-slot-done"). The page is untrusted:
/// only short alphanumeric request ids are accepted.
/// </summary>
public sealed record RendererSlotMessage(bool Done, string Id)
{
    public const string RequestType = "gpu-slot";
    public const string DoneType = "gpu-slot-done";
    private const int MaxId = 32;

    public static RendererSlotMessage? TryParse(string? json)
    {
        if (json is null || json.Length > 256)
        {
            return null;
        }
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 2 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("type", out var type) || type.ValueKind != JsonValueKind.String
                || !root.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.String)
            {
                return null;
            }
            var done = type.GetString() switch
            {
                RequestType => false,
                DoneType => true,
                _ => (bool?)null,
            };
            var text = id.GetString() ?? "";
            if (done is null || text.Length is 0 or > MaxId || !text.All(char.IsAsciiLetterOrDigit))
            {
                return null;
            }
            return new RendererSlotMessage(done.Value, text);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The grant the app sends back to the page.</summary>
    public static string Grant(string id) => JsonSerializer.Serialize(new { type = RequestType, id });
}
