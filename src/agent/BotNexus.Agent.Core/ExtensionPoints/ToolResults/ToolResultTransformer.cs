namespace BotNexus.Agent.Core.ExtensionPoints.ToolResults;

/// <summary>
/// Transforms a completed tool result before it reaches the provider.
/// </summary>
/// <param name="context">The tool-result transformation context.</param>
/// <param name="cancellationToken">The cancellation token.</param>
/// <returns>An optional post-processing result.</returns>
/// <remarks>
/// Use to transform, filter, or override tool results before they reach the LLM.
/// Return ToolResultTransformResult to replace Content, Details, or IsError.
/// Must not throw — exceptions are logged and ignored.
/// </remarks>
public delegate Task<ToolResultTransformResult?> ToolResultTransformer(
    ToolResultTransformContext context,
    CancellationToken cancellationToken);