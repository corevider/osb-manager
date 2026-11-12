using System.Drawing;
using System.Windows.Forms;
using OsbManager.UI;

namespace OsbManager.Tests;

public class GridViewTests
{
    [Fact]
    public void BoldRowsFollowANewFont()
    {
        using var grid = new GridView(("Account", 100, HorizontalAlignment.Left));
        grid.SetRows([new GridRow(["Main"]), new GridRow(["All characters"], Bold: true)]);

        grid.Font = new Font(grid.Font.FontFamily, grid.Font.Size * 2);

        Assert.False(grid.Items[0].Font.Bold);
        Assert.True(grid.Items[1].Font.Bold);
        Assert.Equal(grid.Font.Size, grid.Items[1].Font.Size);
    }
}
