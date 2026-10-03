namespace BotNexus.Agent.Core.ExtensionPoints.RunCompletion;

/// <summary>
/// Host evaluation performed when the model would otherwise end a run normally.
/// </summary>
public sealed record RunCompletionDecision(
    RunCompletionStatus Status,
    IReadOnlyList<string> OpenItemIds,
    RunStopReason? StopReason = null,
    string? Detail = null,
    string? Evidence = null,
    string? ContinuationOwner = null,
    string? WakeCondition = null)
{
    public static RunCompletionDecision Completed { get; } =
        new(RunCompletionStatus.Completed, []);

    public static RunCompletionDecision Continue(IReadOnlyList<string> openItemIds, string detail)
        => new(RunCompletionStatus.Working, openItemIds, Detail: detail);

    public static RunCompletionDecision Parked(
        RunStopReason reason,
        IReadOnlyList<string> openItemIds,
        string evidence,
        string continuationOwner,
        string wakeCondition,
        string? detail = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(evidence);
        ArgumentException.ThrowIfNullOrWhiteSpace(continuationOwner);
        ArgumentException.ThrowIfNullOrWhiteSpace(wakeCondition);
        if (!Enum.IsDefined(reason))
            throw new ArgumentOutOfRangeException(nameof(reason), reason, "Unknown run stop reason.");

        return new(
            RunCompletionStatus.Parked,
            openItemIds,
            reason,
            detail,
            evidence,
            continuationOwner,
            wakeCondition);
    }
}
