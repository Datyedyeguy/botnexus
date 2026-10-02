# Agent core extension-point naming

This reference is for contributors who add or review an extension point in
`BotNexus.Agent.Core`. It defines how to name a dependency according to the
authority it has over agent execution. The convention applies to new APIs and to
existing APIs when they are deliberately refactored; the current API does not yet
use every name in this reference.

## Choose the category

Classify an extension point by its contract, not by where in the loop it runs.
`Before` and `After` describe timing but do not identify responsibility.

| Category | Contract | Cardinality | Result affects execution? | Type suffix |
| --- | --- | --- | --- | --- |
| Policy | Answers what the loop may or should do next | One authoritative policy per decision point | Yes | `Policy` |
| Transformer | Converts or replaces data without choosing control flow | One pipeline, optionally composed | Only through transformed data | `Transformer` |
| Provider | Supplies data or a capability requested by the loop | One provider per requested capability | No direct control decision | `Provider` |
| Service | Performs host-owned work or manages state | One service per responsibility | Only through its documented operation | `Service` or a domain-specific noun |
| Observer | Receives a fact after the owning code has decided or acted | Zero or many | No | `Observer` |
| Event | Immutable fact published to subscribers | Zero or many subscribers | No | `Event` |
| Configuration | Sets a fixed limit, mode, timeout, or default | One value | Read by the owning algorithm | `Options`, `Mode`, or a value-specific name |

Use this test in order:

1. Does the return value choose whether or how execution proceeds? Use a policy.
2. Does the return value replace or convert data? Use a transformer.
3. Does the loop request data or a capability? Use a provider.
4. Does the dependency perform work or own mutable state? Use a service.
5. Does it only receive an immutable fact? Use an observer or event.
6. Is it a fixed value read by the loop? Use configuration.

Do not use `Hook` as the primary category. A hook identifies an invocation point,
not the authority of the invoked dependency. Do not use a general `Delegate`
suffix when a category above expresses the contract.

## Policies

A policy receives an immutable, purpose-specific context and returns a typed
decision. The loop remains the sole owner of execution and mutable agent state.
Policies must not mutate `Agent`, `AgentState`, or `AgentLoopRunner` directly.

```csharp
public interface IRunCompletionPolicy
{
    Task<RunCompletionDecision> EvaluateAsync(
        RunCompletionContext context,
        CancellationToken cancellationToken);
}
```

Use these names:

- Interface: `I<Decision>Policy`, such as `IRunCompletionPolicy`.
- Context: `<Decision>Context`, such as `RunCompletionContext`.
- Result: `<Decision>Decision`, such as `RunCompletionDecision`.
- Method: `EvaluateAsync` for asynchronous evaluation or `Evaluate` when the
  operation is necessarily synchronous.
- Default implementation: `Default<Decision>Policy`.
- Composition: `Composite<Decision>Policy` with a documented ordering and
  conflict rule.
- Contributing rule interface: `I<Decision>Rule`, such as `IToolExecutionRule`.
- Rule implementation: `<Concern><Decision>Rule`, such as
  `AccessToolExecutionRule`.
- Rule result: `<Decision>RuleResult` when individual contributions differ from
  the final decision, such as when a rule can abstain.

There must be one authoritative result at each decision point. If several rules
contribute, a composite policy resolves them deterministically. Do not publish a
mutable event and let subscribers compete to set the decision.

### Reuse policy points, extend their rules

A **policy point** is a named question at a specific boundary in the flow, such
as whether a proposed tool call may execute. It has one context contract, one
final decision contract, and one policy invoked by the loop.

When several checks answer that same question, the host assembles an ordered
collection of rules behind a composite policy. Each rule evaluates the same
read-only context; the composite produces the final decision. Registration order
must be explicit and stable, not an incidental result of service discovery.

For example, the proposed tool-execution composition is:

```text
Tool execution policy point
  -> CompositeToolExecutionPolicy
       -> SafetyToolExecutionRule
       -> AccessToolExecutionRule
       -> ApprovalToolExecutionRule
       -> BudgetToolExecutionRule
  -> One ToolExecutionDecision applied by the loop
```

These names describe the target design, not currently available registration
APIs. Adding another tool-execution check should require one rule and its host
registration, not another `AgentOptions` property, loop branch, policy interface,
or copy of the existing composite. A rule implements only its policy point's
contract; it must not implement unrelated policy methods with placeholder
responses. Do not create pass-through policies or adapters merely to insert a
check into the chain.

Reuse an existing point when its question, context, and decision vocabulary fit.
Introduce a new point only when the loop must delegate a genuinely different
decision or evaluate at a different boundary. Do not pre-create unused points.

### Define composition per policy family

Composition is not a universal "first result wins" algorithm. Each family must
document these rules before accepting additional contributors:

| Contract | Required definition |
| --- | --- |
| Ordering | Stable rule order and whether evaluation is sequential or parallel |
| Aggregation | Outcome precedence, conflict resolution, and whether a rule may abstain |
| Defaults | Empty-chain behavior, all-abstain behavior, and which checks are mandatory |
| Short-circuiting | Which outcomes may stop evaluation and which checks must still run |
| Failure | Cancellation propagation, total/per-rule budgets, and exception or timeout outcomes |
| Evidence | Stable rule identifiers, contributing reasons, and skipped/failed checks |

For tool authorization, an early allow must never bypass later restrictions.
Denial prevents execution; required approval cannot be satisfied by another rule
returning allow; an indeterminate mandatory check blocks execution. Abstention
does not establish permission. The family must explicitly define whether a chain
with no applicable checks permits execution, and how mandatory checks are
validated at composition time. Reasons for denial, pending approval, and failed
evaluation must remain distinguishable even when all prevent execution.

For completion, every required check must establish completion before the
composite returns completed. The family defines how continuation requests and
supported parked dispositions combine, including incompatible dispositions.
For recovery, a first-applicable strategy is appropriate only after mandatory
safety checks and retry limits have been satisfied. Limits enforced by the loop
remain authoritative regardless of policy results.

Short-circuit only when remaining checks cannot change the final decision and
are not required for evidence collection. Required durable audit work stays in
a service with explicit sequencing; it must not depend on a rule being reached.
Rules must not execute a tool or initiate a recovery action themselves. The loop
applies the final decision, then publishes the resulting lifecycle facts.

Test ordering, conflicting results, allow followed by deny, abstention, empty
chains, missing mandatory checks, safe short-circuiting, cancellation, timeouts,
exceptions, and preservation of contributing reasons. Transformer composition is
different: each output becomes the next input rather than an aggregated vote.

## Transformers

A transformer maps input data to output data while leaving the loop responsible
for control flow.

```csharp
public interface IToolResultTransformer
{
    Task<ToolResult> TransformAsync(
        ToolResultTransformContext context,
        CancellationToken cancellationToken);
}
```

Use `I<Subject>Transformer`, `<Subject>TransformContext`, and `TransformAsync`.
For a sequence, use `Composite<Subject>Transformer` and document ordering. A
transformer must not hide an allow/deny decision; that belongs in a policy.

## Providers and services

A provider answers a request for data or a capability. Name it
`I<Subject>Provider` and name its method after the value it supplies, such as
`GetMessagesAsync` or `GetExecutionOptionsAsync`.

A service performs an operation or owns state outside the loop. Name it after
the domain responsibility, such as `ICredentialInvalidationService`. Use a
domain-specific noun instead of `Service` when one is clearer, such as
`IProviderSuspensionRegistry` or `IProviderRecoveryCoordinator`.

Do not combine service work and policy authority in one contract. For example,
recording a tool-call audit is service work; deciding whether the tool may run is
policy evaluation. A policy may depend on a service, but the loop should receive
only the policy decision.

## Observers and events

An event is an immutable statement that something happened. An observer consumes
events or diagnostics and cannot change the action being reported.

Use `<Subject>Event` for event records and `I<Subject>Observer` when a dedicated
observer contract is needed. Prefer the existing `AgentEvent` subscription stream
for agent lifecycle facts instead of adding one callback property per event.
Observer failures must not silently become policy decisions.

## Current API classification

The following table classifies the behavior-bearing callback and interface seams,
plus adjacent configuration whose role is otherwise easy to mistake. It is a
migration guide, not a claim that current names already follow this convention.
Ordinary scalar limits, modes, and timeouts remain configuration and are omitted
unless they qualify the behavior of a listed seam.

| Current extension point | Category | Target concept |
| --- | --- | --- |
| `BeforeToolCallDelegate` | Policy | Tool execution policy |
| `BeforeToolAuditDelegate` | Mixed service and policy | Its current contract combines durable audit work with authority to block; separate those responsibilities |
| `AfterToolCallDelegate` | Transformer | Tool result transformer |
| `EvaluateRunCompletionDelegate` | Policy | Run completion policy |
| `ConvertToLlmDelegate` | Transformer | Provider-message transformer |
| `TransformContextDelegate` | Transformer | Agent-context transformer |
| `SanitizeToolResultText` | Transformer | Tool-result text transformer |
| `GetMessagesDelegate` | Provider | Steering or follow-up message provider |
| `GetProviderExecutionOptionsDelegate` | Provider | Provider execution-options provider |
| `InvalidateProviderCredentialsDelegate` | Service | Credential invalidation service |
| `ToolCallDispositionDelegate` | Observer | Tool execution decision observer or event |
| `OnDiagnostic` | Observer | Diagnostic observer |
| `MaybeCompactAsync` | Mixed policy and transformer | Separate compaction decision from context transformation if both remain necessary |
| `IProviderSuspensionRegistry` | Service | Provider suspension registry |
| `IProviderRecoveryCoordinator` | Service | Provider recovery coordinator |
| `IHostSuspendDetector` | Service | Host active-time service used to enforce elapsed-time policy correctly |
| `RetryRandomSource` | Provider | Retry randomness provider |
| `ClaimAuditOptions` | Configuration | Claim-audit settings; the settings object is not itself an observer |
| `SatelliteToolExecutionOptions` | Configuration | Satellite tool-execution settings |
| `RecoveryAdmissionTimeout` | Configuration | Deadline qualifying provider recovery admission |

## Adding an extension point

Before adding a property to `AgentOptions` or `AgentLoopConfig`:

1. Write the question or fact represented by the extension point.
2. Select one category from this reference.
  For policies, reuse an existing policy point and add a rule when its contract
  fits; do not add a new extension point solely for another check.
3. Define a narrow immutable context instead of exposing the mutable agent.
4. Define a typed decision or output when a value is returned.
5. Specify cardinality, ordering, cancellation, timeout, exception, and default
   behavior in the public contract.
6. Reuse the lifecycle event stream for notification-only behavior.
7. Add tests for the default path, a non-default result, cancellation, and the
   documented failure behavior.

Do not add a raw `Func<>` or `Action<>` to public agent configuration when the
dependency represents a named domain responsibility. A named interface normally
communicates and tests that responsibility more clearly. A named delegate remains
appropriate for a small stateless adapter when it still follows the category's
naming and contract rules.
