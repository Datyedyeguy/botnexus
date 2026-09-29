$ErrorActionPreference='Stop'
$validator=Join-Path $PSScriptRoot 'Test-BotNexusPullRequest.ps1'
$contractCandidates=@(
 'Q:/repos/botnexus/.github/pr-contract.json',
 'Q:/repos/botnexus-wt/4153-pr-contract-enforcement/.github/pr-contract.json',
 (Join-Path (Split-Path -Parent $PSScriptRoot) 'reference/pr-contract.json')
)
$contract=@($contractCandidates|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1)[0]
if(-not $contract){throw 'No PR contract candidate is available for the contract suite.'}
$valid=@'
## Summary
Outcome. Closes #4153
## Root cause
Verified mechanism.
## Changes
- behavior
## Anti-reinvention
- reused seam
## Tests
- regression
## Validation
- Guard 51/0
## Risk & rollback
- low; revert
## Merge notes
- no migration
'@
function Test-Case([string]$Name,[string]$Body,[bool]$Expected,[switch]$Partial){
 $r=& $validator -Title 'fix(ci): enforce the PR contract' -Body $Body -Issue 4153 -ContractPath $contract -PartialWork:$Partial
 if($r.valid -ne $Expected){throw "$Name expected valid=$Expected; got $($r|ConvertTo-Json -Depth 8 -Compress)"}
 [pscustomobject]@{name=$Name;passed=$true;violations=@($r.violations|ForEach-Object code)}
}
$cases=@()
$cases+=Test-Case valid $valid $true
$cases+=Test-Case missingRoot ($valid-replace '(?ms)^## Root cause.*?(?=^## Changes)','') $false
$cases+=Test-Case wrongRisk ($valid-replace '## Risk & rollback','## Risk') $false
$cases+=Test-Case missingAnti ($valid-replace '(?ms)^## Anti-reinvention.*?(?=^## Tests)','') $false
$cases+=Test-Case missingMerge ($valid-replace '(?ms)^## Merge notes.*','') $false
$cases+=Test-Case placeholder ($valid-replace 'reused seam','<Name the existing seams>') $false
$cases+=Test-Case wrongIssue ($valid-replace '#4153','#99') $false
$partial=$valid-replace 'Closes #4153','Refs #4153'
$cases+=Test-Case partial $partial $true -Partial
$cases+=Test-Case partialCloses $valid $false -Partial
$publisher=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Publish-BotNexusPullRequest.ps1') -Raw
$newWrapper=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'New-BotNexusPullRequest.ps1') -Raw
$updateWrapper=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Update-BotNexusPullRequest.ps1') -Raw
$issueUpdater=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Update-BotNexusIssue.ps1') -Raw
$collector=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Get-BotNexusPullRequests.ps1') -Raw
$completion=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Complete-BotNexusPullRequest.ps1') -Raw
$healthRouter=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-BotNexusOwnedPullRequestHealth.ps1') -Raw
$healthCollector=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Get-BotNexusOwnedPullRequestHealth.ps1') -Raw
$closedSweep=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Remove-BotNexusClosedIssueConversations.ps1') -Raw
$candidate=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Get-BotNexusCandidateIssue.ps1') -Raw
$skill=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'SKILL.md') -Raw
$promotionGateIndex=$publisher.IndexOf('promotion refused: PR #$existing')
$metadataWriteIndex=$publisher.IndexOf('& gh pr edit $existing')
$finalReadbackIndex=$publisher.LastIndexOf('$stored = (& gh pr view $prNumber')
$claimReleaseIndex=$publisher.LastIndexOf('& $issueUpdater -Action Release')
$taxonomy=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'reference/label-taxonomy.json') -Raw
$sourceChecks=@(
  @{name='create-operation-boundary';ok=($newWrapper -match '-Operation Create' -and $newWrapper -notmatch 'gh pr')},
  @{name='update-operation-boundary';ok=($updateWrapper -match '-Operation Update' -and $updateWrapper -notmatch 'gh pr')},
  @{name='operation-mismatch-refusal';ok=($publisher -match 'create operation refused' -and $publisher -match 'update operation refused')},
  @{name='utf8-body-file-transport';ok=($publisher.Contains('WriteAllText($PublicationBodyFile') -and $publisher.Contains("'--body-file',`$PublicationBodyFile"))},
  @{name='post-write-readback';ok=($publisher -match 'published-but-nonconformant' -and $publisher -match 'storedContract')},
  @{name='trusted-base-ci-guard-parity';ok=($publisher -match 'pr-conventions-guard\.mjs' -and $publisher -match 'Invoke-BotNexusPrConventionsGuard\.mjs' -and $publisher -match 'blockingGuardViolations' -and $publisher -notmatch '\$deferred =')},
  @{name='trusted-base-ci-guard-runner-present';ok=(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Invoke-BotNexusPrConventionsGuard.mjs'))},
  @{name='draft-reason-persistence';ok=($publisher -match 'Test-BotNexusPullRequestReadiness.ps1' -and $publisher -match 'EXCEPTIONAL DRAFT --')},
  @{name='normal-create-rejects-incomplete';ok=($publisher -match 'publication-not-ready: resolve these blockers before creating a PR')},
  @{name='exceptional-draft-allowlist';ok=($publisher -match 'human-requested-early-review' -and $publisher -match 'external-coordination-blocker' -and $publisher -match 'recovery-handoff' -and $publisher -match 'maintainer-safety-hold' -and $publisher -match 'exceptional-draft-reason-required')},
  @{name='create-wrapper-carries-draft-reason';ok=($newWrapper -match 'DraftReasonCode' -and $newWrapper -match 'DraftReasonDetail')},
  @{name='partial-scope-can-be-ready';ok=($skill -match "Partial coverage of a larger issue is not a draft reason" -and $skill -match 'use `Refs` and leave the parent issue open')},
  @{name='unfinished-work-not-published';ok=($skill -match 'Do not create a PR merely to preserve unfinished work')},
  @{name='draft-metadata-only-boundary';ok=($updateWrapper -match 'DraftMetadataOnly' -and $publisher -match 'draft-metadata-persisted' -and $publisher -match "Operation -ne 'Update'" -and $publisher -match 'existing.isDraft')},
  @{name='draft-metadata-readback';ok=($publisher -match 'managed draft metadata readback failed' -and $publisher -match 'stored.headRefOid' -and $publisher -match 'stored.author.login')},
  @{name='draft-promotion-gate';ok=($publisher -match 'promotion refused' -and $publisher -match 'statusCheckRollup' -and $publisher -match 'gh pr ready')},
  @{name='draft-promotion-before-metadata-write';ok=($promotionGateIndex -ge 0 -and $metadataWriteIndex -gt $promotionGateIndex)},
  @{name='explicit-draft-reason-resolution';ok=($updateWrapper -match 'ResolveDraftReasonCode' -and $publisher -match 'ResolveDraftReasonCode' -and (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-BotNexusPullRequestReadiness.ps1') -Raw) -match 'Cannot resolve draft reason code')},
  @{name='label-and-claim-fail-closed';ok=($publisher -notmatch 'label pass failed' -and $publisher -notmatch 'claim release failed')},
  @{name='draft-state-readback-before-claim-release';ok=($publisher -match '\[bool\]\$stored\.isDraft -ne \$OpenAsDraft' -and $finalReadbackIndex -ge 0 -and $claimReleaseIndex -gt $finalReadbackIndex)},
  @{name='claim-taxonomy-matches-lifecycle';ok=($taxonomy -notmatch 'Auto-expires after 24h' -and $taxonomy -match 'until publication releases the claim')},
  @{name='issue-claim-readback';ok=($issueUpdater -match 'claim readback drift' -and $issueUpdater -match 'expectedLabels')},
  @{name='collector-lifecycle-drift';ok=($collector -match 'pr-label-drift' -and $collector -match 'stale-issue-claim' -and $collector -match 'linked-issue-closed')},
  @{name='post-merge-completion-gate';ok=($completion -match "state -ne 'MERGED'" -and $completion -match 'merge-base --is-ancestor' -and $completion -match "scope='partial'" -and $completion -match 'archiveConversation')},
  @{name='closed-conversation-sweep-runs-in-health-loop';ok=($healthRouter -match 'Remove-BotNexusClosedIssueConversations\.ps1' -and $healthRouter -match 'Invoke-Api Delete' -and $healthRouter -match 'archive readback failed')},
  @{name='owned-health-retries-only-transient-github-failures';ok=($healthCollector -match 'MaximumAttempts' -and $healthCollector -match 'HTTP\\s\+\(\?:429\|502\|503\|504\)' -and $healthCollector -match 'Test-TransientGitHubFailure' -and $healthCollector -match 'after \$attempt attempt')},
  @{name='owned-health-requests-have-hard-deadlines';ok=($healthCollector -match 'RequestTimeoutSeconds' -and $healthCollector -match 'ConnectionTimeoutSeconds' -and $healthCollector -match 'OperationTimeoutSeconds' -and $healthRouter -match 'RequestTimeoutSeconds' -and $closedSweep -match 'RequestTimeoutSeconds')},
  @{name='closed-conversation-sweep-uses-bounded-api';ok=($closedSweep -notmatch 'botnexus conversation' -and $closedSweep -match '/api/conversations\?agentId=' -and $closedSweep -match 'OperationTimeoutSeconds')},
  @{name='candidate-cache-disabled-by-default';ok=($candidate -match '\[int\]\$CacheMinutes = 0')},
  @{name='single-policy-owner';ok=($skill -match 'SKILL.md owns lifecycle policy' -and $skill -match 'must not restate or fork policy')},
  @{name='auth-fails-closed';ok=($publisher -match 'GitHub identity precondition failed' -and $publisher -match "Do NOT run 'gh auth switch'")}
)
foreach($check in $sourceChecks){if(-not $check.ok){throw "Source contract failed: $($check.name)"};$cases+=[pscustomobject]@{name=$check.name;passed=$true;violations=@()}}
[pscustomobject]@{total=$cases.Count;passed=@($cases|Where-Object passed).Count;failed=0;cases=$cases}|ConvertTo-Json -Depth 8 -Compress
