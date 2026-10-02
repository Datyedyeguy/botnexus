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

There must be one authoritative result at each decision point. If several rules
contribute, a composite policy resolves them deterministically. Do not publish a
mutable event and let subscribers compete to set the decision.

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
