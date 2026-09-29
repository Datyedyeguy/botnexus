[CmdletBinding()]
param(
  [string]$Repository='Sytone/botnexus',
  [ValidateRange(1,5)][int]$MaximumAttempts=2,
  [ValidateRange(0,30)][int]$RetryDelaySeconds=2,
  [ValidateRange(1,60)][int]$RequestTimeoutSeconds=10,
  [switch]$SelfTest
)
$ErrorActionPreference='Stop'
if($SelfTest){
  $cases=@(
    @{detail='gh: HTTP 504';expected=$true},
    @{detail='gh: HTTP 503 Service Unavailable';expected=$true},
    @{detail='gh: HTTP 429 rate limit';expected=$true},
    @{detail='connection reset by peer';expected=$true},
    @{detail='gh: HTTP 401 Bad credentials';expected=$false},
    @{detail='gh: HTTP 404 Not Found';expected=$false}
  )
  $transientPattern='(?i)HTTP\s+(?:429|502|503|504)\b|timed?\s*out|connection\s+(?:reset|closed)|temporarily\s+unavailable'
  foreach($case in $cases){if(([bool]($case.detail -match $transientPattern)) -ne $case.expected){throw "Transient classification failed: $($case.detail)"}}
  $mixedAuthors=@(
    [pscustomobject]@{user=[pscustomobject]@{login='agent-farnsworth[bot]'};number=4337},
    [pscustomobject]@{user=[pscustomobject]@{login='external-user'};number=4132}
  )
  $normalized=@($mixedAuthors | ForEach-Object { $_ })
  $owned=@($normalized|Where-Object{[string]$_.user.login-in@('agent-farnsworth[bot]','app/agent-farnsworth')})
  if($normalized.Count-ne 2-or$owned.Count-ne 1-or$owned[0].number-ne 4337){throw 'Top-level GitHub array normalization failed.'}
  [pscustomobject]@{total=$cases.Count+1;passed=$cases.Count+1;failed=0;boundedAttempts=$MaximumAttempts;requestTimeoutSeconds=$RequestTimeoutSeconds;topLevelArrayNormalization=$true}|ConvertTo-Json -Compress
  return
}
$agentAuthors=@('agent-farnsworth[bot]','app/agent-farnsworth')
$auth=Join-Path $PSScriptRoot 'Use-FarnsworthBot.ps1'
$authJson=@(& $auth -Command { param($ctx) [pscustomobject]@{status='ok';login=$ctx.Login} })
if($LASTEXITCODE -ne 0){throw 'Farnsworth GitHub authentication failed.'}
$parts=$Repository.Split('/',2); if($parts.Count-ne 2){throw 'Repository must be owner/name.'}
$owner=$parts[0];$repo=$parts[1]
function Test-TransientGitHubFailure([string]$Detail){
  [bool]($Detail -match '(?i)HTTP\s+(?:429|502|503|504)\b|timed?\s*out|connection\s+(?:reset|closed)|temporarily\s+unavailable|operation was canceled')
}
function Invoke-Gh([string]$Path){
  $headers=@{
    Authorization="Bearer $env:GH_TOKEN"
    Accept='application/vnd.github+json'
    'X-GitHub-Api-Version'='2022-11-28'
    'User-Agent'='agent-farnsworth'
  }
  for($attempt=1;$attempt -le $MaximumAttempts;$attempt++){
    try{
      return Invoke-RestMethod -Uri "https://api.github.com/$Path" -Method Get -Headers $headers -ConnectionTimeoutSeconds $RequestTimeoutSeconds -OperationTimeoutSeconds $RequestTimeoutSeconds
    }catch{
      $detail=[string]$_.Exception.Message
      if($attempt -lt $MaximumAttempts -and (Test-TransientGitHubFailure $detail)){
        if($RetryDelaySeconds -gt 0){Start-Sleep -Seconds $RetryDelaySeconds}
        continue
      }
      throw "GitHub API failed for ${Path} after $attempt attempt(s), bounded to ${RequestTimeoutSeconds}s each: $detail"
    }
  }
}
function Get-Pages([string]$Path){
  $result=[Collections.Generic.List[object]]::new();$page=1
  do{$sep=if($Path.Contains('?')){'&'}else{'?'};$rows=@(Invoke-Gh "${Path}${sep}per_page=100&page=$page");foreach($row in $rows){$result.Add($row)};$page++}while($rows.Count-eq 100)
  @($result)
}
function Get-Checks([object[]]$Checks){
  $failedConclusions=@('failure','cancelled','timed_out','action_required','startup_failure','stale')
  $latest=@($Checks|Group-Object name|ForEach-Object{$_.Group|Sort-Object @{Expression={if($_.started_at){[datetimeoffset]$_.started_at}else{[datetimeoffset]::MinValue}};Descending=$true},@{Expression={[long]$_.id};Descending=$true}|Select-Object -First 1})
  [pscustomobject]@{
    total=$latest.Count
    failed=@($latest|Where-Object{$_.status-eq'completed'-and$_.conclusion-in$failedConclusions}|ForEach-Object{[pscustomobject]@{name=$_.name;status=$_.status;conclusion=$_.conclusion;url=$_.html_url}})
    pending=@($latest|Where-Object{$_.status-ne'completed'}|ForEach-Object{[pscustomobject]@{name=$_.name;status=$_.status;conclusion=$_.conclusion;url=$_.html_url}})
  }
}
try{
  # Invoke-RestMethod may preserve a top-level JSON array as one nested object when
  # the caller wraps its result in @(...). Flatten each page explicitly before
  # filtering authors, otherwise one external PR makes the concatenated login value
  # fail the exact agent-author comparison and the owned census becomes zero.
  $summaries=@(Get-Pages "repos/$owner/$repo/pulls?state=open" | ForEach-Object { $_ })
  $ownedSummaries=@($summaries|Where-Object{[string]$_.user.login-in$agentAuthors})
  # The PR's base object is the base commit captured when GitHub last evaluated
  # that PR, not necessarily the current tip of main. Reconciliation must key
  # mergeability against today's base tip or a main advance can remain invisible.
  $currentBase=(Invoke-Gh "repos/$owner/$repo/commits/main").sha
  if([string]::IsNullOrWhiteSpace([string]$currentBase)){throw 'Current main commit is unavailable.'}
  $rows=[Collections.Generic.List[object]]::new()
  foreach($summary in $ownedSummaries){
    $pr=Invoke-Gh "repos/$owner/$repo/pulls/$($summary.number)"
    $checks=Get-Checks @((Invoke-Gh "repos/$owner/$repo/commits/$($pr.head.sha)/check-runs?filter=latest&per_page=100").check_runs)
    $codes=[Collections.Generic.List[string]]::new()
    if($pr.draft){$codes.Add('draft-reconciliation-required')}
    if($checks.failed.Count){$codes.Add('failed-checks')}
    if($pr.mergeable-eq$false-or[string]$pr.mergeable_state-eq'dirty'){$codes.Add('merge-conflict')}
    elseif([string]$pr.mergeable_state-eq'behind'){$codes.Add('base-behind')}
    $issue=0
    $m=[regex]::Match([string]$pr.body,'(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?|references?)\s*:?\s*#(\d+)')
    if($m.Success){$issue=[int]$m.Groups[1].Value}
    $rows.Add([pscustomobject]@{
      number=[int]$pr.number;primaryIssue=$issue;title=[string]$pr.title;url=[string]$pr.html_url;ownership='agent-owned';draft=[bool]$pr.draft
      head=[pscustomobject]@{ref=[string]$pr.head.ref;sha=[string]$pr.head.sha}
      base=[pscustomobject]@{ref=[string]$pr.base.ref;sha=[string]$currentBase}
      mergeable=$pr.mergeable;mergeState=[string]$pr.mergeable_state;checks=$checks;commentsNeedingAttention=@();problemCodes=@($codes|Sort-Object -Unique)
    })
  }
  [pscustomobject]@{generatedAt=[datetimeoffset]::UtcNow;repository=$Repository;scanned=$ownedSummaries.Count;attention=@($rows|Where-Object{$_.problemCodes.Count});healthyPullRequests=@($rows|Where-Object{-not$_.problemCodes.Count})}|ConvertTo-Json -Depth 8 -Compress
}finally{Remove-Item Env:GH_TOKEN,Env:BOTNEXUS_GIT_AUTH_HEADER -ErrorAction SilentlyContinue}
