using BotNexus.Domain.Primitives;
using BotNexus.Domain.World;
using BotNexus.Gateway.Abstractions.Security;
using BotNexus.Gateway.Api.Services;
using BotNexus.Gateway.Contracts.Agents;
using Microsoft.AspNetCore.Mvc;

namespace BotNexus.Gateway.Api.Controllers;

/// <summary>
/// Authenticated administrator boundary for listing and reviewing governed agent proposals.
/// Gateway authentication runs before this controller; every action additionally fails closed
/// unless the stamped caller identity is administrative.
/// </summary>
[ApiController]
[Route("api/agent-proposals")]
public sealed class AgentProposalsController(
    IAgentProposalStore proposals,
    AgentProposalReviewService reviewService) : ControllerBase
{
    private const string CallerIdentityItemKey = "BotNexus.Gateway.CallerIdentity";

    /// <summary>Lists proposals, optionally filtered by review status.</summary>
    [HttpGet]
    public async Task<ActionResult<IReadOnlyList<AgentProposal>>> List(
        [FromQuery] AgentProposalStatus? status,
        CancellationToken cancellationToken)
    {
        if (AdminIdentity is null)
            return Forbidden();
        return Ok(await proposals.ListAsync(status, cancellationToken).ConfigureAwait(false));
    }

    /// <summary>Gets one proposal including review and application evidence.</summary>
    [HttpGet("{proposalId:guid}")]
    public async Task<ActionResult<AgentProposal>> Get(Guid proposalId, CancellationToken cancellationToken)
    {
        if (AdminIdentity is null)
            return Forbidden();
        var proposal = await proposals.GetAsync(proposalId, cancellationToken).ConfigureAwait(false);
        return proposal is null ? NotFound() : Ok(proposal);
    }

    /// <summary>
    /// Records a human decision. Reviewer identity is always derived from the authenticated
    /// <see cref="GatewayCallerIdentity"/> and is intentionally absent from the request contract.
    /// </summary>
    [HttpPost("{proposalId:guid}/review")]
    public async Task<IActionResult> Review(
        Guid proposalId,
        [FromBody] AgentProposalReviewRequest request,
        CancellationToken cancellationToken)
    {
        var identity = AdminIdentity;
        if (identity is null)
            return Forbidden();
        if (request.Decision is AgentProposalStatus.Pending)
            return BadRequest(new { error = "Decision must be Approved or Rejected." });

        CitizenId reviewer;
        try
        {
            reviewer = CitizenId.Of(UserId.From(identity.CallerId));
        }
        catch (Vogen.ValueObjectValidationException)
        {
            return StatusCode(
                StatusCodes.Status403Forbidden,
                new { error = "Authenticated administrator identity is not a valid human reviewer." });
        }

        var result = await reviewService.ReviewAsync(
            proposalId,
            request.Decision,
            reviewer,
            request.Reason,
            cancellationToken).ConfigureAwait(false);

        return result.Outcome switch
        {
            AgentProposalLifecycleOutcome.NotFound => NotFound(),
            AgentProposalLifecycleOutcome.AlreadyReviewed => Conflict(result),
            AgentProposalLifecycleOutcome.ApplicationFailed => StatusCode(StatusCodes.Status500InternalServerError, result),
            _ => Ok(result),
        };
    }

    /// <summary>
    /// Records an operator's evidence-based conclusion for a proposal stranded in Applying.
    /// This endpoint never invokes lifecycle application; a NotApplied conclusion only makes a
    /// later explicit approval retry eligible.
    /// </summary>
    [HttpPost("{proposalId:guid}/reconcile")]
    public async Task<IActionResult> Reconcile(
        Guid proposalId,
        [FromBody] AgentProposalReconciliationRequest request,
        CancellationToken cancellationToken)
    {
        var identity = AdminIdentity;
        if (identity is null)
            return Forbidden();
        if (!Enum.IsDefined(request.Decision))
            return BadRequest(new { error = "Decision must be Applied or NotApplied." });
        if (string.IsNullOrWhiteSpace(request.Evidence))
            return BadRequest(new { error = "Reconciliation evidence is required." });

        CitizenId reconciler;
        try { reconciler = CitizenId.Of(UserId.From(identity.CallerId)); }
        catch (Vogen.ValueObjectValidationException)
        {
            return StatusCode(StatusCodes.Status403Forbidden,
                new { error = "Authenticated administrator identity is not a valid human reconciler." });
        }

        var result = await proposals.ReconcileApplicationAsync(
            proposalId, request.Decision, reconciler, request.Evidence,
            DateTimeOffset.UtcNow, cancellationToken).ConfigureAwait(false);
        return result.Outcome switch
        {
            AgentProposalReconciliationOutcome.NotFound => NotFound(),
            AgentProposalReconciliationOutcome.NotApplying => Conflict(result),
            _ => Ok(result),
        };
    }

    private GatewayCallerIdentity? AdminIdentity
        => HttpContext.Items.TryGetValue(CallerIdentityItemKey, out var value)
            && value is GatewayCallerIdentity { IsAdmin: true } identity
                ? identity
                : null;

    private ObjectResult Forbidden()
        => StatusCode(StatusCodes.Status403Forbidden, new { error = "Caller is not authorized to review agent proposals." });
}

/// <summary>Decision payload for a proposal review; reviewer identity comes from authentication.</summary>
/// <param name="Decision">Approved or Rejected.</param>
/// <param name="Reason">Optional human rationale retained in audit history.</param>
public sealed record AgentProposalReviewRequest(AgentProposalStatus Decision, string? Reason);

/// <summary>Evidence-based resolution of an ambiguous application attempt.</summary>
/// <param name="Decision">Whether external verification proves the lifecycle effect applied.</param>
/// <param name="Evidence">Required operator evidence retained in the proposal ledger.</param>
public sealed record AgentProposalReconciliationRequest(
    AgentProposalReconciliationDecision Decision,
    string Evidence);
