namespace OsbManager.Core.Updates;

/// <summary>An update step failed; the message is safe to show and log.</summary>
public sealed class UpdateException : Exception
{
    public UpdateException(string message)
        : base(message)
    {
    }

    public UpdateException(string message, Exception inner)
        : base(message, inner)
    {
    }
}
