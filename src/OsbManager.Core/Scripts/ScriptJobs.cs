namespace OsbManager.Core.Scripts;

public sealed class ScriptJobs
{
    private int active;

    public bool Busy => Volatile.Read(ref active) > 0;

    public IDisposable Begin()
    {
        Interlocked.Increment(ref active);
        return new Scope(this);
    }

    private sealed class Scope(ScriptJobs jobs) : IDisposable
    {
        private int disposed;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref disposed, 1) == 0)
            {
                Interlocked.Decrement(ref jobs.active);
            }
        }
    }
}
