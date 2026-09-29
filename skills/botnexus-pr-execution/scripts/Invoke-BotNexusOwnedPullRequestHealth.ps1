[CmdletBinding()]
param(
  [string]$GatewayUrl='http://localhost:5005',
  [string]$AgentId='farnsworth',
  [string]$StatePath=(Join-Path $HOME '.botnexus/agents/farnsworth/workspace/state/botnexus-owned-pr-health.json'),
  [int]$RetryAfterMinutes=60,
  [ValidateRange(1,60)][int]$RequestTimeoutSeconds=10
)
$ErrorActionPreference='Stop'
$collector=Join-Path $PSScriptRoot 'Get-BotNexusOwnedPullRequestHealth.ps1'
$lines=@(& $collector)
$json=@($lines|Where-Object{$_ -is [string] -and $_.TrimStart().StartsWith('{')}|Select-Object -Last 1)[0]
if(-not $json){throw 'Owned PR health collector returned no JSON result.'}
$packet=$json|ConvertFrom-Json
$owned=@($packet.attention|Where-Object{$_.ownership -eq 'agent-owned' -and @($_.problemCodes).Count -gt 0})

$state=@{}
if(Test-Path -LiteralPath $StatePath){
  $saved=Get-Content -LiteralPath $StatePath -Raw|ConvertFrom-Json
  foreach($p in $saved.PSObject.Properties){
    if($p.Value -is [string]){$state[$p.Name]=[pscustomobject]@{marker=[string]$p.Value;routedAt=[datetimeoffset]::MinValue}}
    else{$state[$p.Name]=[pscustomobject]@{marker=[string]$p.Value.marker;routedAt=[datetimeoffset]$p.Value.routedAt}}
  }
}
function Invoke-Api([string]$Method,[string]$Path,$Body=$null){
  $args=@{
    Uri=$GatewayUrl.TrimEnd('/')+$Path
    Method=$Method
    ContentType='application/json'
    ConnectionTimeoutSeconds=$RequestTimeoutSeconds
    OperationTimeoutSeconds=$RequestTimeoutSeconds
  }
  if($null -ne $Body){$args.Body=$Body|ConvertTo-Json -Depth 8 -Compress}
  Invoke-RestMethod @args
}
$conversationResponse=Invoke-Api Get "/api/conversations?agentId=$AgentId"
$conversations=@($(foreach($item in $conversationResponse){$item}))
$routed=[Collections.Generic.List[object]]::new()
foreach($pr in $owned){
  $codes=@($pr.problemCodes|Sort-Object -Unique)
  # Mergeability can change when main advances without changing the PR head or
  # emitting a PR-head webhook. Include the observed base SHA so a newly
  # conflicting merge against a newer base is routed once rather than hidden
  # forever behind an old head/problem fingerprint.
  $marker="$($pr.head.sha)|$($pr.base.sha)|$($codes -join ',')"
  $prior=$state[[string]$pr.number]
  if($prior -and $prior.marker -eq $marker -and [datetimeoffset]::UtcNow -lt $prior.routedAt.AddMinutes($RetryAfterMinutes)){continue}
  $issue=[int]$pr.primaryIssue
  $conversation=$null
  if($issue -gt 0){$conversation=(@($conversations|Where-Object{$_.status -eq 'Active' -and [string]$_.title -match "^$issue\s+-\s+"}|Sort-Object updatedAt -Descending|Select-Object -First 1))[0]}
  if(-not $conversation){
    $title=if($issue -gt 0){"$issue - PR $($pr.number) health"}else{"PR $($pr.number) health"}
    $conversation=Invoke-Api Post '/api/conversations' @{agentId=$AgentId;title=$title;purpose="Repair owned PR #$($pr.number) through terminal CI and independent readback. Never merge without Jon's authorization."}
    $conversations+=@($conversation)
  }
  $failed=@($pr.checks.failed|ForEach-Object{$_.name})
  $comments=@($pr.commentsNeedingAttention|ForEach-Object{"$($_.author): $($_.url)"})
  $message=@"
Owned PR #$($pr.number) has actionable state on head $($pr.head.sha): $($codes -join ', '). Failed checks: $(if($failed.Count){$failed -join ', '}else{'none'}). Actionable comments: $(if($comments.Count){$comments -join '; '}else{'none'}). Resume only this existing PR in its current branch/worktree. Inspect each exact problem once, repair attributable failures or comments, synchronize without rewriting published history, run exact-source CORE if the head changes, update only the existing PR through canonical helpers, and verify terminal CI plus readback. Do not merge and do not create a PR-specific cron.
"@
  $response=Invoke-Api Post "/api/agents/$AgentId/conversations/$($conversation.conversationId)/messages" @{message=$message;wake=$true;sender='owned-pr-health'}
  $state[[string]$pr.number]=[pscustomobject]@{marker=$marker;routedAt=[datetimeoffset]::UtcNow}
  $routed.Add([pscustomobject]@{pr=[int]$pr.number;conversationId=[string]$conversation.conversationId;sessionId=[string]$response.sessionId;problemCodes=$codes})
}
# Drop state for PRs no longer open so the file remains bounded.
$openNumbers=@($packet.attention.number)+@($packet.healthyPullRequests.number)
foreach($key in @($state.Keys)){if([int]$key -notin $openNumbers){$state.Remove($key)}}
[IO.Directory]::CreateDirectory((Split-Path -Parent $StatePath))|Out-Null
[IO.File]::WriteAllText($StatePath,($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
# Close the lifecycle loop on every run, even when no PR needs repair. The deterministic
# selector returns every active issue/PR-health conversation whose leading issue is closed;
# archive each through the canonical REST endpoint and verify it disappeared from active state.
$archiveLines=@(& (Join-Path $PSScriptRoot 'Remove-BotNexusClosedIssueConversations.ps1') -Repository 'Sytone/botnexus' -AgentId $AgentId -GatewayUrl $GatewayUrl -RequestTimeoutSeconds $RequestTimeoutSeconds)
$archiveJson=@($archiveLines|Where-Object{$_ -is [string] -and $_.TrimStart().StartsWith('{')}|Select-Object -Last 1)[0]
if(-not $archiveJson){throw 'Closed-issue conversation selector returned no JSON result.'}
$archivePacket=$archiveJson|ConvertFrom-Json
$archived=[Collections.Generic.List[object]]::new()
foreach($item in @($archivePacket.results|Where-Object{$_.status -eq 'archive-required'})){
  Invoke-Api Delete "/api/conversations/$($item.conversationId)"|Out-Null
  $remainingResponse=Invoke-Api Get "/api/conversations?agentId=$AgentId"
  $remaining=@($(foreach($row in $remainingResponse){$row}))
  if(@($remaining|Where-Object{$_.conversationId -eq $item.conversationId}).Count){throw "Conversation archive readback failed: $($item.conversationId)"}
  $archived.Add([pscustomobject]@{conversationId=[string]$item.conversationId;issue=[int]$item.issue;title=[string]$item.title})
}
[pscustomobject]@{status='ok';code=if($routed.Count){'owned-pr-problems-routed'}elseif($archived.Count){'closed-issue-conversations-archived'}else{'no-new-owned-pr-problems'};scanned=[int]$packet.scanned;ownedActionable=$owned.Count;routed=@($routed);archived=@($archived)}|ConvertTo-Json -Depth 8 -Compress
