[CmdletBinding()]
param([string]$ContractPath,[string]$GatewayUrl='http://localhost:5005',[string]$AgentId='farnsworth',[string]$IssuesFixture,[string]$PullRequestsFixture,[string]$ConversationsFixture,[string]$WorktreesFixture,[datetimeoffset]$Now=[datetimeoffset]::UtcNow)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
function Read-Json([string]$Path,[scriptblock]$Live){if($Path){@(Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}else{@(& $Live)}}
$leases=@(Get-BotNexusIssueLeases $contract)
# Capacity represents healthy recent execution, not durable lane inventory. A lane older than the
# recovery threshold no longer owns a slot even when an old lease expiry says otherwise. The lease
# identity remains a duplicate-work fence until deterministic reconciliation recovers or releases it.
$staleLaneHours=if($contract.PSObject.Properties.Name -contains 'staleLaneHours'){[double]$contract.staleLaneHours}else{4}
$activeCutoff=$Now.AddHours(-$staleLaneHours)
$activeLeases=@($leases|Where-Object{[datetimeoffset]$_.acquiredAt -gt $activeCutoff})
$maximum=[int]$contract.maximumActiveDeliveries;$capacity=[Math]::Max(0,$maximum-$activeLeases.Count)
if($capacity -eq 0){[pscustomobject]@{status='blocked';code='no-capacity';activeCount=$activeLeases.Count;maximum=$maximum;candidates=@()}|ConvertTo-Json -Depth 8 -Compress;return}
$issues=Read-Json $IssuesFixture {$raw=gh issue list --repo $contract.repository --state open --limit 1000 --json number,title,body,labels,createdAt,updatedAt,url,author;if($LASTEXITCODE){throw 'GitHub issue query failed.'};$raw|ConvertFrom-Json}
$prs=Read-Json $PullRequestsFixture {$raw=gh pr list --repo $contract.repository --state open --limit 500 --json number,headRefName,title,body,author;if($LASTEXITCODE){throw 'GitHub PR query failed.'};$raw|ConvertFrom-Json}
$ownedOpenPrs=@($prs|Where-Object{[string]$_.author.login -in @($contract.agentPullRequestAuthors)})
if($ownedOpenPrs.Count -ge [int]$contract.maximumOpenAgentPullRequests){[pscustomobject]@{status='blocked';code='agent-open-pr-cap';ownedOpenPullRequests=$ownedOpenPrs.Count;maximum=[int]$contract.maximumOpenAgentPullRequests;candidates=@()}|ConvertTo-Json -Depth 8 -Compress;return}
$conversations=Read-Json $ConversationsFixture {
  try {
    $effectiveAgent=if([string]::IsNullOrWhiteSpace($AgentId)){[string]$contract.agentId}else{$AgentId}
    $uri=$GatewayUrl.TrimEnd('/')+"/api/conversations?agentId=$([uri]::EscapeDataString($effectiveAgent))"
    @(Invoke-RestMethod -Uri $uri -Method Get)
  }
  catch { throw "Conversation query failed: $($_.Exception.Message)" }
}
$worktrees=if($WorktreesFixture){@(Get-Content -LiteralPath $WorktreesFixture -Raw|ConvertFrom-Json)}else{@(& git -C $contract.repositoryRoot worktree list --porcelain|Where-Object{$_ -like 'worktree *'}|ForEach-Object{[pscustomobject]@{path=($_ -replace '^worktree ','')}})}
# Every retained lease still owns its issue identity even after its execution slot expires.
$leasedIds=@($leases|ForEach-Object{[int]$_.issue});$openPrText=($prs|ForEach-Object{"$($_.headRefName)`n$($_.title)`n$($_.body)"}) -join "`n"
$openIssueIds=[Collections.Generic.HashSet[int]]::new();foreach($openIssue in $issues){$null=$openIssueIds.Add([int]$openIssue.number)}
$priority=@{'priority:critical'=0;'priority:high'=1;'priority:medium'=2;'priority:low'=3};$candidates=@()
foreach($issue in $issues){
  $labels=@($issue.labels|ForEach-Object{if($_ -is [string]){$_}else{$_.name}});if($contract.admissionLabel -notin $labels){continue};if(@($labels|Where-Object{$_ -in @($contract.blockedLabels)}).Count){continue};if(@($labels|Where-Object{$_ -in @($contract.excludedTypes)}).Count){continue}
  $n=[int]$issue.number;if($n -in $leasedIds){continue}
  $openDependencies=@(foreach($line in [regex]::Matches([string]$issue.body,'(?im)^(?!.*\bno dependenc(?:y|ies)\b).*\b(?:depends on|blocked by)\b([^\r\n]*)$')){foreach($m in [regex]::Matches($line.Groups[1].Value,'#(\d{1,6})')){$id=[int]$m.Groups[1].Value;if($openIssueIds.Contains($id)){$id}}});if($openDependencies.Count){continue}
  $typeLabels=@($labels|Where-Object{$_ -like 'type:*'});$priorityLabels=@($labels|Where-Object{$priority.ContainsKey($_)});if($typeLabels.Count -ne 1 -or $priorityLabels.Count -ne 1){continue}
  if($openPrText -match "(?i)(?:#|/)$n(?:\b|-)"){continue}
  # Conversation inventory is not execution liveness. A stale Active row must not fence an issue
  # forever; leases, worktrees and PRs remain independent duplicate-work fences.
  $freshConversationCutoff=$Now.AddMinutes(-60)
  if(@($conversations|Where-Object{
    if($_.status -ne 'Active' -or [string]$_.title -notmatch "^$n\s+-\s+"){return $false}
    $updatedProperty=$_.PSObject.Properties['updatedAt']
    if($null -eq $updatedProperty -or [string]::IsNullOrWhiteSpace([string]$updatedProperty.Value)){return $true}
    try{[datetimeoffset]$updatedProperty.Value -gt $freshConversationCutoff}catch{$true}
  }).Count){continue}
  if(@($worktrees|Where-Object{[string]$_.path -match "(?i)(?:[/\\]|-)$n-"}).Count){continue}
  # A decomposed parent with unfinished checklist sub-issues is planning inventory, not one
  # executable slice. Its children must flow through their own dependency graph.
  if([regex]::IsMatch([string]$issue.body,'(?im)^\s*-\s*\[\s\]\s*#\d+\b')){continue}
  $actorProperty=$issue.PSObject.Properties['admissionActor'];$actor=if($null -ne $actorProperty){[string]$actorProperty.Value}else{''};if(-not $IssuesFixture){$eventsRaw=gh api "repos/$($contract.repository)/issues/$n/events?per_page=100";if($LASTEXITCODE){throw "Issue #$n event query failed."};$events=@($eventsRaw|ConvertFrom-Json|Where-Object{$_.event -in @('labeled','unlabeled') -and $_.label.name -eq $contract.admissionLabel});$last=@($events|Select-Object -Last 1)[0];if(-not $last -or $last.event -ne 'labeled'){continue};$actor=[string]$last.actor.login};if($actor -notin @($contract.trustedAdmissionActors)){continue}
  $short=([string]$issue.title -replace '^\[[^]]+\]\s*','' -replace '[^a-zA-Z0-9]+','-').Trim('-').ToLowerInvariant();if($short.Length -gt 48){$short=$short.Substring(0,48).Trim('-')}
  $candidates+=[pscustomobject]@{issue=$n;title=$issue.title;shortName=$short;createdAt=$issue.createdAt;updatedAt=$issue.updatedAt;priorityRank=$priority[$priorityLabels[0]];author=$issue.author.login;admissionActor=$actor;url=$issue.url}
}
$take=[Math]::Min($capacity,[int]$contract.maximumAdmissionsPerRun);$selected=@($candidates|Sort-Object priorityRank,createdAt,issue|Select-Object -First $take)
if(-not $selected.Count){[pscustomobject]@{status='idle';code='no-prelabelled-ready-issue';activeCount=$activeLeases.Count;capacity=$capacity;candidates=@();meaning='No issue currently carries an eligible trusted ready label; this is not a backlog or triage census.'}|ConvertTo-Json -Depth 8 -Compress;return}
[pscustomobject]@{status='ready';code='candidates-selected';activeCount=$activeLeases.Count;capacity=$capacity;candidateCount=$candidates.Count;candidates=$selected;candidate=$selected[0]}|ConvertTo-Json -Depth 8 -Compress
