[CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
param(
  [string]$Repository='Sytone/botnexus',
  [string]$AgentId='farnsworth',
  [string]$GatewayUrl='http://localhost:5005',
  [string]$ConversationsJson='',
  [ValidateRange(1,60)][int]$RequestTimeoutSeconds=10,
  [switch]$SelfTest
)
$ErrorActionPreference='Stop'

function Get-IssueConversationCandidates([object[]]$Conversations) {
  @(
    foreach($conversation in $Conversations) {
      if(([string]$conversation.status) -ne 'Active'){continue}
      $match=[regex]::Match([string]$conversation.title,'^(?<issue>[1-9]\d{0,5})(?=\s*(?:-|/|:|\|))')
      if(-not $match.Success){continue}
      [pscustomobject]@{conversationId=[string]$conversation.conversationId;title=[string]$conversation.title;issue=[int]$match.Groups['issue'].Value}
    }
  )
}
function Select-ClosedIssueConversations([object[]]$Candidates,[hashtable]$IssueStates) {
  @(
    foreach($candidate in $Candidates) {
      $state=$IssueStates[[string]$candidate.issue]
      if($null -eq $state){throw "Issue state unavailable for #$($candidate.issue); refusing partial archive selection."}
      if([bool]$state.isPullRequest){continue}
      if(([string]$state.state).ToLowerInvariant() -eq 'closed'){$candidate}
    }
  )
}

if($SelfTest){
  $candidates=Get-IssueConversationCandidates @(
    [pscustomobject]@{conversationId='a';title='4124 - work';status='Active'},
    [pscustomobject]@{conversationId='b';title='4124 / PR 4145 - work';status='Active'},
    [pscustomobject]@{conversationId='c';title='PR 4124 work';status='Active'},
    [pscustomobject]@{conversationId='d';title='4125 - archived';status='Archived'}
  )
  if($candidates.Count -ne 2 -or @($candidates.issue|Select-Object -Unique).Count -ne 1){throw 'Anchored title matching failed.'}
  $selected=Select-ClosedIssueConversations $candidates @{'4124'=[pscustomobject]@{state='closed';isPullRequest=$false}}
  if($selected.Count -ne 2){throw 'Closed issue selection failed.'}
  $open=Select-ClosedIssueConversations $candidates @{'4124'=[pscustomobject]@{state='open';isPullRequest=$false}}
  if($open.Count -ne 0){throw 'Open issue exclusion failed.'}
  $pr=Select-ClosedIssueConversations $candidates @{'4124'=[pscustomobject]@{state='closed';isPullRequest=$true}}
  if($pr.Count -ne 0){throw 'PR-number exclusion failed.'}
  [pscustomobject]@{total=4;passed=4;failed=0;anchoredTitles=$true;closedSelected=$true;openExcluded=$true;pullRequestsExcluded=$true}|ConvertTo-Json -Compress
  return
}
if($Repository -notmatch '^([^/]+)/([^/]+)$'){throw 'Repository must be owner/name.'}
$owner=$Matches[1];$repo=$Matches[2]
$auth=Join-Path $PSScriptRoot 'Use-FarnsworthBot.ps1'
& $auth|Out-Null
try {
  if([string]::IsNullOrWhiteSpace($ConversationsJson)){
    try {
      $uri=$GatewayUrl.TrimEnd('/')+"/api/conversations?agentId=$([uri]::EscapeDataString($AgentId))"
      $ConversationsJson=(Invoke-RestMethod -Uri $uri -Method Get -ConnectionTimeoutSeconds $RequestTimeoutSeconds -OperationTimeoutSeconds $RequestTimeoutSeconds)|ConvertTo-Json -Depth 8 -Compress
    }
    catch { throw "Structured conversation list failed: $($_.Exception.Message)" }
  }
  $conversations=@($ConversationsJson|ConvertFrom-Json)
  $candidates=@(Get-IssueConversationCandidates $conversations)
  $headers=@{
    Authorization="Bearer $env:GH_TOKEN"
    Accept='application/vnd.github+json'
    'X-GitHub-Api-Version'='2022-11-28'
    'User-Agent'='agent-farnsworth'
  }
  $states=@{}
  foreach($issue in @($candidates.issue|Sort-Object -Unique)){
    try{
      $data=Invoke-RestMethod -Uri "https://api.github.com/repos/$owner/$repo/issues/$issue" -Method Get -Headers $headers -ConnectionTimeoutSeconds $RequestTimeoutSeconds -OperationTimeoutSeconds $RequestTimeoutSeconds
    }catch{throw "GitHub issue read failed for #${issue}, bounded to ${RequestTimeoutSeconds}s: $($_.Exception.Message)"}
    if($null -eq $data){throw "GitHub issue read failed for #$issue."}
    $states[[string]$issue]=[pscustomobject]@{state=[string]$data.state;isPullRequest=($null -ne $data.pull_request)}
  }
  $selected=@(Select-ClosedIssueConversations $candidates $states)
  $results=[Collections.Generic.List[object]]::new()
  foreach($item in $selected){
    if(-not $PSCmdlet.ShouldProcess("$($item.conversationId) ($($item.title))","Archive because issue #$($item.issue) is closed")){
      $results.Add([pscustomobject]@{conversationId=$item.conversationId;issue=$item.issue;title=$item.title;status='preview'})
      continue
    }
    # Mutation is intentionally delegated to BotNexus's native conversation tool by the coordinator.
    # The installed CLI has a fixed 10-second HTTP timeout and live archive has exceeded it without
    # changing state; this script therefore remains the deterministic selector/proof boundary.
    $results.Add([pscustomobject]@{conversationId=$item.conversationId;issue=$item.issue;title=$item.title;status='archive-required'})
  }
  [pscustomobject]@{generatedAt=[DateTimeOffset]::UtcNow.ToString('o');agentId=$AgentId;candidates=$candidates.Count;closedMatches=$selected.Count;results=@($results)}|ConvertTo-Json -Depth 7 -Compress
} finally {
  Remove-Item Env:GH_TOKEN,Env:BOTNEXUS_GIT_AUTH_HEADER -ErrorAction SilentlyContinue
}
