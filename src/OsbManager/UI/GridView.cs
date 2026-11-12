namespace OsbManager.UI;

internal sealed record GridRow(string[] Cells, object? Tag = null, bool Bold = false, bool? Checked = null);

/// <summary>A details ListView that updates rows in place, so a refresh every second does not flicker.</summary>
internal sealed class GridView : ListView
{
    private Font? boldFont;

    public GridView(params (string Title, int Width, HorizontalAlignment Align)[] columns)
    {
        View = View.Details;
        FullRowSelect = true;
        GridLines = true;
        HideSelection = false;
        DoubleBuffered = true;
        Dock = DockStyle.Fill;
        foreach (var (title, width, align) in columns)
        {
            Columns.Add(title, width, align);
        }
    }

    public bool Syncing { get; private set; }

    public void SetRows(IReadOnlyList<GridRow> rows)
    {
        Syncing = true;
        BeginUpdate();
        try
        {
            while (Items.Count > rows.Count)
            {
                Items.RemoveAt(Items.Count - 1);
            }
            for (var i = 0; i < rows.Count; i++)
            {
                var row = rows[i];
                var item = i < Items.Count ? Items[i] : Items.Add(new ListViewItem());
                for (var c = 0; c < row.Cells.Length; c++)
                {
                    if (c >= item.SubItems.Count)
                    {
                        item.SubItems.Add(row.Cells[c]);
                    }
                    else if (item.SubItems[c].Text != row.Cells[c])
                    {
                        item.SubItems[c].Text = row.Cells[c];
                    }
                }
                item.Tag = row.Tag;
                var font = row.Bold ? boldFont ??= new Font(Font, FontStyle.Bold) : Font;
                if (!Equals(item.Font, font))
                {
                    item.Font = font;
                }
                if (row.Checked is { } isChecked && item.Checked != isChecked)
                {
                    item.Checked = isChecked;
                }
            }
        }
        finally
        {
            EndUpdate();
            Syncing = false;
        }
    }

    protected override void OnFontChanged(EventArgs e)
    {
        base.OnFontChanged(e);
        if (boldFont is not { } previous)
        {
            return;
        }
        boldFont = new Font(Font, FontStyle.Bold);
        foreach (ListViewItem item in Items)
        {
            if (ReferenceEquals(item.Font, previous))
            {
                item.Font = boldFont;
            }
        }
        previous.Dispose();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            boldFont?.Dispose();
        }
        base.Dispose(disposing);
    }
}
