namespace BotNexus.Agent.Core.ExtensionPoints.RunCompletion;

public enum RunCompletionStatus
{
    Working,
    Parked,
    IncompleteWithoutStopReason,
    Completed,
    Failed,
    Cancelled,
}