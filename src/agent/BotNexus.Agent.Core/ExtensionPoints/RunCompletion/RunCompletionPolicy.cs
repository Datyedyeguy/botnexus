namespace BotNexus.Agent.Core.ExtensionPoints.RunCompletion;

public delegate Task<RunCompletionDecision> RunCompletionPolicy(CancellationToken cancellationToken);