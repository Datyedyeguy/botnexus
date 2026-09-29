[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$ContractPath,
  [string]$GatewayUrl = 'http://localhost:5005',
  [string]$AgentId = 'farnsworth',
  [int]$SelectedIssue = 0,
  [ValidateRange(1,20)][int]$Top = 5,
  [string]$IssuesFixture,
  [string]$PullRequestsFixture,
  [string]$ConversationsFixture,
  [string]$WorktreesFixture,
  [string]$OwnerRunId = ([guid]::NewGuid().ToString('N'))
)
$ErrorActionPreference = 'Stop'
if (-not $ContractPath) { $ContractPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json' }

function Read-OneJson([scriptblock]$Action) {
  $lines = @(& $Action)
  # Child PowerShell scripts communicate failure by throwing. Do not inspect the process-global
  # LASTEXITCODE here: a successful script that runs no native command inherits an unrelated prior
  # native exit code and would be misclassified as failed.
  $json = @($lines | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)[0]
  if (-not $json) { throw 'Deterministic dispatch child command returned no JSON result.' }
  $json | ConvertFrom-Json
}

$common = @{ ContractPath = $ContractPath; GatewayUrl = $GatewayUrl; AgentId = $AgentId }
foreach ($name in 'IssuesFixture','PullRequestsFixture','ConversationsFixture','WorktreesFixture') {
  if ($PSBoundParameters.ContainsKey($name)) { $common[$name] = $PSBoundParameters[$name] }
}
$reconcileArgs = @{ ContractPath = $ContractPath; GatewayUrl = $GatewayUrl; AgentId = $AgentId }
foreach ($name in 'PullRequestsFixture','ConversationsFixture','WorktreesFixture') {
  if ($PSBoundParameters.ContainsKey($name)) { $reconcileArgs[$name] = $PSBoundParameters[$name] }
}
$reconcile = Read-OneJson { & (Join-Path $PSScriptRoot 'Reconcile-BotNexusIssueLease.ps1') @reconcileArgs }

$previewArgs = @{} + $common
$previewArgs.OwnerRunId = $OwnerRunId
$preview = Read-OneJson { & (Join-Path $PSScriptRoot 'Start-BotNexusIssueDelivery.ps1') @previewArgs -WhatIf }
if ($preview.status -eq 'preview' -and @($preview.handoffs).Count -gt 0) {
  if ($WhatIfPreference) {
    [pscustomobject]@{ status='preview'; code='ready-issue-would-start'; reconcile=$reconcile; handoff=@($preview.handoffs)[0] } | ConvertTo-Json -Depth 10 -Compress
    return
  }
  $live = Read-OneJson { & (Join-Path $PSScriptRoot 'Start-BotNexusIssueDelivery.ps1') @previewArgs }
  [pscustomobject]@{ status='handoff'; code='ready-issue-reserved'; reconcile=$reconcile; handoff=@($live.handoffs)[0] } | ConvertTo-Json -Depth 10 -Compress
  return
}
if ($preview.code -in @('no-capacity','agent-open-pr-cap')) {
  [pscustomobject]@{ status='blocked'; code=$preview.code; reconcile=$reconcile; detail=$preview } | ConvertTo-Json -Depth 10 -Compress
  return
}

$triageArgs = @{ Top = $Top; GatewayUrl = $GatewayUrl; AgentId = $AgentId; ContractPath = $ContractPath }
foreach ($name in 'IssuesFixture','PullRequestsFixture','ConversationsFixture','WorktreesFixture') {
  if ($PSBoundParameters.ContainsKey($name)) { $triageArgs[$name] = $PSBoundParameters[$name] }
}
$triage = Read-OneJson { & (Join-Path $PSScriptRoot 'Get-BotNexusIssueTriage.ps1') @triageArgs }
if ($triage.status -ne 'ready' -or @($triage.candidates).Count -eq 0) {
  [pscustomobject]@{ status='idle'; code='no-ready-issue'; reconcile=$reconcile; candidates=@() } | ConvertTo-Json -Depth 10 -Compress
  return
}
if ($SelectedIssue -le 0) {
  # The bounded triage packet already excludes owned, blocked, decision-tagged, dependency-blocked,
  # malformed, and overlapping work. Select its first deterministic candidate; the issue lane still
  # verifies the report against current source before any implementation mutation.
  $SelectedIssue=[int]@($triage.candidates)[0].number
}
$candidate = @($triage.candidates | Where-Object { [int]$_.number -eq $SelectedIssue })[0]
if (-not $candidate) { throw "Selected issue #$SelectedIssue is not in the current bounded candidate packet." }
if ($WhatIfPreference) {
  $previewHandoff=[pscustomobject]@{status='preview';code='candidate-would-be-marked-ready';issue=[int]$candidate.number;title="$($candidate.number) - deterministic-selection";candidate=$candidate}
  [pscustomobject]@{status='preview';code='selected-issue-would-start';candidate=$candidate;handoff=$previewHandoff}|ConvertTo-Json -Depth 10 -Compress
  return
}
if ($IssuesFixture) {throw 'SelectedIssue live transition is unavailable with issue fixtures.'}

$leaseOwner = "dispatch-$OwnerRunId"
$selectionLease = Read-OneJson { & (Join-Path $PSScriptRoot 'Update-BotNexusIssueTriageLease.ps1') -Action Acquire -OwnerRunId $leaseOwner }
if ($selectionLease.status -ne 'acquired') {
  [pscustomobject]@{ status='blocked'; code='selection-active'; lease=$selectionLease } | ConvertTo-Json -Depth 8 -Compress
  return
}
try {
  $null = Read-OneJson { & (Join-Path $PSScriptRoot 'Update-BotNexusIssue.ps1') -Action Admit -Issue $SelectedIssue }
  $postPreview = Read-OneJson { & (Join-Path $PSScriptRoot 'Start-BotNexusIssueDelivery.ps1') @previewArgs -WhatIf }
  if ($postPreview.status -ne 'preview' -or @($postPreview.handoffs).Count -eq 0) {
    # Selection and reservation intentionally use separate bounded helpers. State can change between
    # them (another coordinator may acquire the issue, or a durable fence may appear). That is a
    # healthy collision, not a command failure. Remove only the ready label this invocation added
    # and let the next run select another candidate.
    $null = Read-OneJson { & (Join-Path $PSScriptRoot 'Update-BotNexusIssue.ps1') -Action Unadmit -Issue $SelectedIssue }
    [pscustomobject]@{status='idle';code='selected-issue-became-ineligible';candidate=$candidate;detail=$postPreview}|ConvertTo-Json -Depth 10 -Compress
    return
  }
  $live = Read-OneJson { & (Join-Path $PSScriptRoot 'Start-BotNexusIssueDelivery.ps1') @previewArgs }
  [pscustomobject]@{ status='handoff'; code='selected-issue-reserved'; candidate=$candidate; handoff=@($live.handoffs)[0] } | ConvertTo-Json -Depth 10 -Compress
}
finally {
  & (Join-Path $PSScriptRoot 'Update-BotNexusIssueTriageLease.ps1') -Action Release -OwnerRunId $leaseOwner -Nonce $selectionLease.lease.nonce | Out-Null
}
