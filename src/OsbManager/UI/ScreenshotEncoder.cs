using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using OsbManager.Core.Telemetry;

namespace OsbManager.UI;

internal static class ScreenshotEncoder
{
    public const int MaxWidth = 1920;
    private const int MinWidth = 320;

    public static byte[]? Fit(byte[] png)
    {
        using var source = new Bitmap(new MemoryStream(png));
        var width = Math.Min(source.Width, MaxWidth);
        while (width >= MinWidth)
        {
            var height = Math.Max(1, (int)Math.Round(source.Height * (width / (double)source.Width)));
            using var scaled = width == source.Width ? new Bitmap(source) : Scale(source, width, height);
            using var output = new MemoryStream();
            scaled.Save(output, ImageFormat.Png);
            if (output.Length <= ReportPayload.MaxScreenshotBytes)
            {
                return output.ToArray();
            }
            width = (int)(width * 0.8);
        }
        return null;
    }

    private static Bitmap Scale(Bitmap source, int width, int height)
    {
        var target = new Bitmap(width, height, PixelFormat.Format24bppRgb);
        using var graphics = Graphics.FromImage(target);
        graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
        graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
        graphics.DrawImage(source, new Rectangle(0, 0, width, height));
        return target;
    }
}
