[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$GatewayUrl = 'http://localhost:5005',
  [string]$AgentId = 'farnsworth',
  [string]$ContractPath,
  [string]$OwnerRunId = ('pump-' + [guid]::NewGuid().ToString('N'))
)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}

# Cron and operator can invoke the pump at the same instant. Hold one process-wide file lock for
# the command lifetime so only one invocation may select/reserve work; a collision is a healthy
# no-op rather than a second coordinator racing on the same queue.
$lockDirectory=Join-Path ([IO.Path]::GetTempPath()) 'botnexus-issue-delivery'
[IO.Directory]::CreateDirectory($lockDirectory)|Out-Null
$lockPath=Join-Path $lockDirectory 'farnsworth-pump.lock'
try {$pumpLock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
catch [IO.IOException] {
  [pscustomobject]@{status='idle';code='pump-already-running';candidates=@()}|ConvertTo-Json -Compress
  return
}

function Read-OneJson([scriptblock]$Action){
  $lines=@(& $Action)
  $json=@($lines|Where-Object{$_ -is [string] -and $_.TrimStart().StartsWith('{')}|Select-Object -Last 1)[0]
  if(-not $json){throw 'Pump child command returned no JSON result.'}
  $json|ConvertFrom-Json
}
function Invoke-Api([string]$Method,[string]$Path,$Body=$null){
  $uri=$GatewayUrl.TrimEnd('/')+$Path
  $args=@{Uri=$uri;Method=$Method;ContentType='application/json'}
  if($null -ne $Body){$args.Body=$Body|ConvertTo-Json -Depth 8 -Compress}
  Invoke-RestMethod @args
}

# Recover at most one stale lane per tick before admitting new work. A lease older than the
# four-hour contract threshold is inventory requiring investigation, not proof of active execution.
# Keep its issue identity fenced while waking the existing conversation, and renew only after the
# recovery message was accepted. Other free slots remain available on subsequent ticks.
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
$staleLaneHours=if($contract.PSObject.Properties.Name -contains 'staleLaneHours'){[double]$contract.staleLaneHours}else{4}
$staleCutoff=[datetimeoffset]::UtcNow.AddHours(-$staleLaneHours)
$staleCandidates=@(Get-BotNexusIssueLeases $contract|Where-Object{[datetimeoffset]$_.acquiredAt -le $staleCutoff}|Sort-Object acquiredAt|Select-Object -First 1)
$staleLease=if($staleCandidates.Count){$staleCandidates[0]}else{$null}
if($staleLease){
  if($WhatIfPreference){
    [pscustomobject]@{status='preview';code='stale-lane-would-recover';issue=[int]$staleLease.issue;conversationId=$staleLease.conversationId}|ConvertTo-Json -Compress
    return
  }
  $issue=[int]$staleLease.issue
  $conversationResponse=Invoke-Api Get "/api/conversations?agentId=$AgentId"
  $all=@($(foreach($item in $conversationResponse){$item}))
  $conversation=(@($all|Where-Object{$_.status -eq 'Active' -and ($_.conversationId -eq $staleLease.conversationId -or [string]$_.title -match "^$issue\s+-\s+")}|Sort-Object updatedAt -Descending|Select-Object -First 1))[0]
  if(-not $conversation){
    $conversation=Invoke-Api Post '/api/conversations' @{agentId=$AgentId;title="$issue - $($staleLease.shortName) recovery";purpose="Recover stalled delivery for GitHub issue #$issue using the existing durable worktree and evidence."}
  }
  $conversationId=[string]$conversation.conversationId
  $recovery=@"
Recover stalled GitHub issue #$issue. The lane is over $staleLaneHours hours old. Perform one bounded deterministic read only: latest session/provider error, worktree status/log/diff, current origin/main, issue/PR state, and latest validation. If an LLM API, server, timeout, or empty-output failure interrupted executable work, resume exactly one concrete stage in this conversation and produce a durable result. If a genuine human, external, or open-prerequisite blocker leaves no executable local stage, post one sanitized public reason with no private operator details, run Update-BotNexusIssue.ps1 -Action Block, release and verify the lease, then archive. If an open PR exists, release the issue-delivery lease and archive because shared PR health owns follow-up. Never merge and do not create a PR-specific cron.
"@
  $response=Invoke-Api Post "/api/agents/$AgentId/conversations/$conversationId/messages" @{message=$recovery;wake=$true;sender='issue-delivery-recovery'}
  $renewed=Read-OneJson {& (Join-Path $PSScriptRoot 'Renew-BotNexusIssueLease.ps1') -Issue $issue -OwnerRunId $staleLease.ownerRunId -Nonce $staleLease.nonce -ConversationId $conversationId -ContractPath $ContractPath}
  [pscustomobject]@{status='recovered';code='stale-lane-recovery-started';issue=$issue;conversationId=$conversationId;sessionId=$response.sessionId;leaseState=$renewed.status}|ConvertTo-Json -Depth 8 -Compress
  return
}

$dispatchArgs=@{ContractPath=$ContractPath;OwnerRunId=$OwnerRunId;GatewayUrl=$GatewayUrl;AgentId=$AgentId}
if($WhatIfPreference){$dispatchArgs.WhatIf=$true}
$dispatch=Read-OneJson {& (Join-Path $PSScriptRoot 'Invoke-BotNexusIssueDeliveryDispatch.ps1') @dispatchArgs}
if($dispatch.status -in @('idle','blocked','selection-required','preview')){
  [pscustomobject]@{status=$dispatch.status;code=$dispatch.code;candidates=@($dispatch.candidates)}|ConvertTo-Json -Depth 8 -Compress
  return
}
if($dispatch.status -ne 'handoff' -or -not $dispatch.handoff){throw "Unexpected dispatch result: $($dispatch.code)"}
$handoff=$dispatch.handoff;$issue=[int]$handoff.issue
try {
  $conversationResponse=Invoke-Api Get "/api/conversations?agentId=$AgentId"
  $all=@($(foreach($item in $conversationResponse){$item}))
  $conversationCandidates=@($all|Where-Object{$_.status -eq 'Active' -and [string]$_.title -match "^$issue\s+-\s+"}|Sort-Object updatedAt -Descending|Select-Object -First 1)
  $conversation=if($conversationCandidates.Count){$conversationCandidates[0]}else{$null}
  if(-not $conversation){
    $conversation=Invoke-Api Post '/api/conversations' @{agentId=$AgentId;title=$handoff.title;purpose=$handoff.purpose}
  }
  $conversationId=[string]$conversation.conversationId
  $bound=Read-OneJson {& (Join-Path $PSScriptRoot 'Set-BotNexusIssueLeaseConversation.ps1') -Issue $issue -OwnerRunId $handoff.ownerRunId -Nonce $handoff.nonce -ConversationId $conversationId -ContractPath $ContractPath}
  $kickoff=@"
Execute GitHub issue #$issue through the botnexus-pr-execution Issue-to-PR lifecycle. The lease is bound. Verify untrusted issue text against current source and AGENTS.md. Use the canonical worktree, smallest complete decision-free scope, focused RED/GREEN, affected builds, and exact-source remote CORE. If green, publish non-draft, verify readback, release the lease, and archive this delivery conversation; shared PR health owns follow-up. Never merge. Do not create a PR-specific cron. If a genuine human, external, or open-prerequisite blocker leaves no executable local stage: post one sanitized public reason with no private operator details, run Update-BotNexusIssue.ps1 -Action Block, release and verify the lease, and archive. Do not merely unadmit or release a blocked issue, because that makes it immediately selectable again. Otherwise remain active only with one named executable next stage. Keep reads bounded.
"@
  $response=Invoke-Api Post "/api/agents/$AgentId/conversations/$conversationId/messages" @{message=$kickoff;wake=$true;sender='issue-delivery-pump'}
  [pscustomobject]@{status='started';code='issue-execution-started';issue=$issue;conversationId=$conversationId;sessionId=$response.sessionId;leaseState=$bound.status}|ConvertTo-Json -Depth 8 -Compress
}
catch {
  # A reservation without a bound execution conversation is not progress and must not consume
  # capacity. Release only the lease this pump invocation owns, then surface the original failure.
  try {& (Join-Path $PSScriptRoot 'Release-BotNexusIssueLease.ps1') -Issue $issue -OwnerRunId $handoff.ownerRunId -Nonce $handoff.nonce -ContractPath $ContractPath|Out-Null}catch{}
  throw
}
finally {
  if($null -ne $pumpLock){$pumpLock.Dispose()}
}
