namespace BotNexus.Agent.Core.ExtensionPoints.ToolExecution;

/// <summary>
/// Evaluates whether a validated tool call may execute.
/// </summary>
/// <param name="context">The tool-execution policy context.</param>
/// <param name="cancellationToken">The cancellation token.</param>
/// <returns>An optional tool-execution decision.</returns>
/// <remarks>
/// Use to validate, block, or log tool calls before execution.
/// Return ToolExecutionDecision with Block=true to prevent execution.
/// Must not throw — exceptions are logged and ignored.
/// </remarks>
public delegate Task<ToolExecutionDecision?> ToolExecutionPolicy(
    ToolExecutionContext context,
    CancellationToken cancellationToken);