namespace OsbManager.Core.Cache;

/// <summary>Sorted, merged half-open byte intervals [Start, End).</summary>
public sealed class IntervalSet
{
    private readonly List<(long Start, long End)> items = [];

    public int Count => items.Count;

    public long CoveredBytes { get; private set; }

    public IReadOnlyList<(long Start, long End)> Items => items;

    public void Add(long start, long end)
    {
        if (end <= start)
        {
            return;
        }
        var first = FirstEndingAtOrAfter(start);
        var last = first;
        while (last < items.Count && items[last].Start <= end)
        {
            start = Math.Min(start, items[last].Start);
            end = Math.Max(end, items[last].End);
            CoveredBytes -= items[last].End - items[last].Start;
            last++;
        }
        items.RemoveRange(first, last - first);
        items.Insert(first, (start, end));
        CoveredBytes += end - start;
    }

    public bool Contains(long start, long end)
    {
        if (end <= start)
        {
            return true;
        }
        var index = FirstEndingAtOrAfter(end);
        return index < items.Count && items[index].Start <= start;
    }

    private int FirstEndingAtOrAfter(long position)
    {
        int low = 0, high = items.Count;
        while (low < high)
        {
            var middle = (low + high) / 2;
            if (items[middle].End < position)
            {
                low = middle + 1;
            }
            else
            {
                high = middle;
            }
        }
        return low;
    }
}
