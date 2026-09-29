[CmdletBinding()]
param(
  [string]$Repository = 'Sytone/botnexus',
  [string]$ContractPath,
  [ValidateRange(1,168)][int]$WindowHours = 24,
  [ValidateRange(1,24)][int]$NoPullRequestHours = 4,
  [ValidateRange(1,100)][int]$BlockedIssueWarningCount = 3,
  [datetimeoffset]$NowUtc = [datetimeoffset]::UtcNow,
  [string]$IssuesFixture,
  [string]$PullRequestsFixture,
  [string]$LeasesFixture,
  [string]$TriageFixture
)
$ErrorActionPreference = 'Stop'
if (-not $ContractPath) {
  $ContractPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'
}
$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
$windowStart = $NowUtc.AddHours(-$WindowHours)
$staleLaneHours = if ($contract.PSObject.Properties.Name -contains 'staleLaneHours') { [double]$contract.staleLaneHours } else { 4 }
$staleCutoff = $NowUtc.AddHours(-$staleLaneHours)
$agentAuthors = @($contract.agentPullRequestAuthors)

function Read-FixtureArray([string]$Path) {
  if (-not $Path) { return $null }
  $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  return @($value)
}
function Invoke-GhJson([string[]]$Arguments, [string]$FailureMessage) {
  $raw = & gh @Arguments
  if ($LASTEXITCODE) { throw $FailureMessage }
  return @($raw | ConvertFrom-Json)
}
function Get-Labels($Item) {
  return @($Item.labels | ForEach-Object {
    if ($_ -is [string]) { $_ }
    elseif ($null -ne $_ -and $_.PSObject.Properties['name']) { [string]$_.name }
  } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}
function As-Utc($Value) {
  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
  return [datetimeoffset]$Value
}
function Round-Rate([double]$Value) { return [Math]::Round($Value, 2) }

$issues = Read-FixtureArray $IssuesFixture
$openBlockedIssues = $null
if ($null -eq $issues) {
  $updatedSearch = 'updated:>=' + $windowStart.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $issues = Invoke-GhJson @('issue','list','--repo',$Repository,'--state','all','--search',$updatedSearch,'--limit','1000','--json','number,title,state,createdAt,closedAt,updatedAt,url,labels') 'Recent GitHub issue census failed.'
  if ($issues.Count -ge 1000) { throw 'Recent issue census reached its fixed 1000-row boundary; completeness is unknown.' }
  $openBlockedIssues = Invoke-GhJson @('issue','list','--repo',$Repository,'--state','open','--label','status:blocked','--limit','1000','--json','number,title,state,createdAt,closedAt,updatedAt,url,labels') 'Blocked GitHub issue census failed.'
  if ($openBlockedIssues.Count -ge 1000) { throw 'Blocked issue census reached its fixed 1000-row boundary; completeness is unknown.' }
}
$pullRequests = Read-FixtureArray $PullRequestsFixture
$openPullRequests = $null
$latestPullRequests = $null
if ($null -eq $pullRequests) {
  $updatedSearch = 'updated:>=' + $windowStart.ToString('yyyy-MM-ddTHH:mm:ssZ')
  $pullRequests = Invoke-GhJson @('pr','list','--repo',$Repository,'--state','all','--search',$updatedSearch,'--limit','500','--json','number,title,state,author,createdAt,closedAt,mergedAt,url,isDraft') 'Recent GitHub pull-request census failed.'
  if ($pullRequests.Count -ge 500) { throw 'Recent pull-request census reached its fixed 500-row boundary; completeness is unknown.' }
  $openPullRequests = Invoke-GhJson @('pr','list','--repo',$Repository,'--state','open','--limit','500','--json','number,title,state,author,createdAt,closedAt,mergedAt,url,isDraft') 'Open GitHub pull-request census failed.'
  if ($openPullRequests.Count -ge 500) { throw 'Open pull-request census reached its fixed 500-row boundary; completeness is unknown.' }
  $latestPullRequests = Invoke-GhJson @('pr','list','--repo',$Repository,'--state','all','--limit','20','--json','number,title,state,author,createdAt,closedAt,mergedAt,url,isDraft') 'Latest GitHub pull-request census failed.'
}

if ($LeasesFixture) {
  $leases = @(Get-Content -LiteralPath $LeasesFixture -Raw | ConvertFrom-Json)
} else {
  . (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
  $leases = @(Get-BotNexusIssueLeases $contract)
}
if ($TriageFixture) {
  $triage = Get-Content -LiteralPath $TriageFixture -Raw | ConvertFrom-Json
} else {
  $triageRaw = & (Join-Path $PSScriptRoot 'Get-BotNexusIssueTriage.ps1') -Repository $Repository -Top 20 -ContractPath $ContractPath
  if ($LASTEXITCODE) { throw 'Issue triage census failed.' }
  $triage = @($triageRaw | Where-Object { $_ -is [string] -and $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)[0] | ConvertFrom-Json
}

$ownedPullRequests = @($pullRequests | Where-Object {
  $login = if ($_.author -is [string]) { [string]$_.author } elseif ($_.author) { [string]$_.author.login } else { '' }
  $login -in $agentAuthors
})
$createdPullRequests = @($ownedPullRequests | Where-Object { (As-Utc $_.createdAt) -ge $windowStart })
$mergedPullRequests = @($ownedPullRequests | Where-Object { $null -ne (As-Utc $_.mergedAt) -and (As-Utc $_.mergedAt) -ge $windowStart })
$closedUnmergedPullRequests = @($ownedPullRequests | Where-Object {
  $closed = As-Utc $_.closedAt
  $merged = As-Utc $_.mergedAt
  $null -ne $closed -and $closed -ge $windowStart -and $null -eq $merged
})
$openOwnedPullRequests = if ($null -ne $openPullRequests) {
  @($openPullRequests | Where-Object {
    $login = if ($_.author -is [string]) { [string]$_.author } elseif ($_.author) { [string]$_.author.login } else { '' }
    $login -in $agentAuthors
  })
} else {
  @($ownedPullRequests | Where-Object { [string]$_.state -eq 'OPEN' -or [string]$_.state -eq 'open' })
}
$latestOwnedSource = if ($null -ne $latestPullRequests) {
  @($latestPullRequests | Where-Object {
    $login = if ($_.author -is [string]) { [string]$_.author } elseif ($_.author) { [string]$_.author.login } else { '' }
    $login -in $agentAuthors
  })
} else { $ownedPullRequests }
$latestCreatedPullRequest = @($latestOwnedSource | Sort-Object { As-Utc $_.createdAt } -Descending | Select-Object -First 1)
$hoursSinceLatestPullRequest = if ($latestCreatedPullRequest.Count) {
  [Math]::Round(($NowUtc - (As-Utc $latestCreatedPullRequest[0].createdAt)).TotalHours, 2)
} else { $null }

$issuesCreated = @($issues | Where-Object { (As-Utc $_.createdAt) -ge $windowStart })
$issuesClosed = @($issues | Where-Object { $null -ne (As-Utc $_.closedAt) -and (As-Utc $_.closedAt) -ge $windowStart })
$blockedOpen = if ($null -ne $openBlockedIssues) {
  @($openBlockedIssues)
} else {
  @($issues | Where-Object {
    ([string]$_.state -eq 'OPEN' -or [string]$_.state -eq 'open') -and 'status:blocked' -in (Get-Labels $_)
  })
}
$blockedTouched = @($blockedOpen | Where-Object { (As-Utc $_.updatedAt) -ge $windowStart })

$healthyLeases = @($leases | Where-Object { (As-Utc $_.acquiredAt) -gt $staleCutoff })
$staleLeases = @($leases | Where-Object { (As-Utc $_.acquiredAt) -le $staleCutoff })
$capacity = [Math]::Max(0, [int]$contract.maximumActiveDeliveries - $healthyLeases.Count)
$triageCount = if ($triage.PSObject.Properties['count']) { [int]$triage.count } else { @($triage.candidates).Count }

$anomalies = @()
if ($staleLeases.Count) {
  $anomalies += [pscustomobject]@{code='stale-delivery-lanes';severity='error';value=$staleLeases.Count;threshold=$staleLaneHours;detail="$($staleLeases.Count) lease(s) are at least $staleLaneHours hours old and require deterministic recovery."}
}
if ($capacity -gt 0 -and $triageCount -gt 0 -and ($null -eq $hoursSinceLatestPullRequest -or $hoursSinceLatestPullRequest -ge 1)) {
  $anomalies += [pscustomobject]@{code='unused-capacity-with-ready-work';severity='warning';value=$capacity;threshold=1;detail="$capacity delivery slot(s) are free while $triageCount triage candidate(s) are available and no agent pull request was created in the last hour."}
}
if (($healthyLeases.Count -gt 0 -or $triageCount -gt 0) -and ($null -eq $hoursSinceLatestPullRequest -or $hoursSinceLatestPullRequest -ge $NoPullRequestHours)) {
  $anomalies += [pscustomobject]@{code='no-pull-request-progress';severity='error';value=$hoursSinceLatestPullRequest;threshold=$NoPullRequestHours;detail="No agent pull request has been created for at least $NoPullRequestHours hours while executable inventory exists."}
}
if ($blockedTouched.Count -ge $BlockedIssueWarningCount) {
  $anomalies += [pscustomobject]@{code='blocked-issue-spike';severity='warning';value=$blockedTouched.Count;threshold=$BlockedIssueWarningCount;detail="$($blockedTouched.Count) currently blocked issue(s) changed during the reporting window."}
}
if ($issuesCreated.Count -ge 5 -and $issuesClosed.Count * 2 -lt $issuesCreated.Count) {
  $anomalies += [pscustomobject]@{code='issue-backlog-growth';severity='warning';value=($issuesCreated.Count-$issuesClosed.Count);threshold=0;detail="Issue creation exceeded closure by $($issuesCreated.Count-$issuesClosed.Count) during the reporting window."}
}

[pscustomobject]@{
  status = if ($anomalies.Count) { 'attention' } else { 'ok' }
  generatedAt = $NowUtc.ToString('o')
  windowStart = $windowStart.ToString('o')
  windowHours = $WindowHours
  metrics = [pscustomobject]@{
    pullRequestsCreated = $createdPullRequests.Count
    pullRequestsPerHour = Round-Rate ($createdPullRequests.Count / [double]$WindowHours)
    pullRequestsMerged = $mergedPullRequests.Count
    pullRequestsClosedUnmerged = $closedUnmergedPullRequests.Count
    openOwnedPullRequests = $openOwnedPullRequests.Count
    hoursSinceLatestPullRequest = $hoursSinceLatestPullRequest
    issuesCreated = $issuesCreated.Count
    issuesClosed = $issuesClosed.Count
    issueNetChange = $issuesCreated.Count - $issuesClosed.Count
    openBlockedIssues = $blockedOpen.Count
    blockedIssuesTouched = $blockedTouched.Count
    healthyDeliveryLeases = $healthyLeases.Count
    staleDeliveryLeases = $staleLeases.Count
    freeDeliverySlots = $capacity
    triageCandidates = $triageCount
  }
  anomalies = @($anomalies)
  details = [pscustomobject]@{
    createdPullRequests = @($createdPullRequests | Sort-Object { As-Utc $_.createdAt } -Descending | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{number=$_.number;title=$_.title;url=$_.url;createdAt=$_.createdAt} })
    mergedPullRequests = @($mergedPullRequests | Sort-Object { As-Utc $_.mergedAt } -Descending | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{number=$_.number;title=$_.title;url=$_.url;mergedAt=$_.mergedAt} })
    issuesCreated = @($issuesCreated | Sort-Object { As-Utc $_.createdAt } -Descending | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{number=$_.number;title=$_.title;url=$_.url;createdAt=$_.createdAt} })
    issuesClosed = @($issuesClosed | Sort-Object { As-Utc $_.closedAt } -Descending | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{number=$_.number;title=$_.title;url=$_.url;closedAt=$_.closedAt} })
    blockedIssuesTouched = @($blockedTouched | Sort-Object { As-Utc $_.updatedAt } -Descending | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{number=$_.number;title=$_.title;url=$_.url;updatedAt=$_.updatedAt} })
    staleLeases = @($staleLeases | Sort-Object acquiredAt | Select-Object -First 20 | ForEach-Object { [pscustomobject]@{issue=$_.issue;acquiredAt=$_.acquiredAt;conversationId=$_.conversationId} })
  }
} | ConvertTo-Json -Depth 8 -Compress
