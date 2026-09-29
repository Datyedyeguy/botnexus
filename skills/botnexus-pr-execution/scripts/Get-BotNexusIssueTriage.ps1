[CmdletBinding()]
param([string]$Repository='Sytone/botnexus',[ValidateRange(1,20)][int]$Top=10,[string]$GatewayUrl='http://localhost:5005',[string]$AgentId='farnsworth',[string]$ContractPath,[string]$IssuesFixture,[string]$PullRequestsFixture,[string]$ConversationsFixture,[string]$WorktreesFixture)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}
$contractPath=$ContractPath
$contract=Get-Content -LiteralPath $contractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
$leasedIds=@(Get-BotNexusIssueLeases $contract|ForEach-Object{[int]$_.issue})
function Read-Json([string]$Path,[scriptblock]$Live){if($Path){@(Get-Content $Path -Raw|ConvertFrom-Json)}else{@(& $Live)}}
$issues=Read-Json $IssuesFixture {$raw=gh issue list --repo $Repository --state open --limit 1000 --json number,title,body,labels,createdAt,updatedAt,url,author;if($LASTEXITCODE){throw 'Issue census failed.'};$raw|ConvertFrom-Json}
$prs=Read-Json $PullRequestsFixture {$raw=gh pr list --repo $Repository --state open --limit 500 --json number,headRefName,title,body;if($LASTEXITCODE){throw 'PR census failed.'};$raw|ConvertFrom-Json}
$conversations=Read-Json $ConversationsFixture {
  try {
    $uri=$GatewayUrl.TrimEnd('/')+"/api/conversations?agentId=$([uri]::EscapeDataString($AgentId))"
    @(Invoke-RestMethod -Uri $uri -Method Get)
  }
  catch { throw "Conversation census failed: $($_.Exception.Message)" }
}
$worktrees=if($WorktreesFixture){@(Get-Content $WorktreesFixture -Raw|ConvertFrom-Json)}else{@(& git -C 'Q:/repos/botnexus' worktree list --porcelain|Where-Object{$_ -like 'worktree *'}|ForEach-Object{[pscustomobject]@{path=($_ -replace '^worktree ','')}})}
$openIds=[Collections.Generic.HashSet[int]]::new();foreach($i in $issues){$null=$openIds.Add([int]$i.number)}
$prText=($prs|ForEach-Object{"$($_.headRefName)`n$($_.title)`n$($_.body)"}) -join "`n"
$priority=@{'priority:critical'=0;'priority:high'=1;'priority:medium'=2;'priority:low'=3}
$candidates=@()
foreach($i in $issues){
  # GitHub can transiently return a null label entry while issue metadata is
  # changing. Null is not a taxonomy value; ignore it rather than passing it
  # to Hashtable.ContainsKey, which throws and stops the entire delivery pump.
  $labels=@($i.labels|ForEach-Object{if($_ -is [string]){$_}elseif($null -ne $_ -and $_.PSObject.Properties['name']){[string]$_.name}}|Where-Object{-not [string]::IsNullOrWhiteSpace([string]$_)})
  if([string]$i.title -match '(?i)maintenance|autonomous'){continue}
  if([string]$i.body -match '(?im)^\s*(?:-\s*)?(?:Shared skills[/\\]|[A-Z]:[/\\].*[/\\]\.botnexus[/\\]skills[/\\])'){continue}
  if(@($labels|Where-Object{$_ -in @('status:ready-for-agent','status:in-progress','status:blocked','status:needs-jon-decision','type:epic','type:spike')}).Count){continue}
  $types=@($labels|Where-Object{$_ -like 'type:*'});$priorities=@($labels|Where-Object{$priority.ContainsKey($_)})
  if($types.Count -ne 1 -or $priorities.Count -ne 1){continue}
  $n=[int]$i.number
  if($n -in $leasedIds){continue}
  if($prText -match "(?i)(?:#|/)$n(?:\b|-)"){continue}
  $freshConversationCutoff=[datetimeoffset]::UtcNow.AddMinutes(-60)
  if(@($conversations|Where-Object{
    if($_.status -ne 'Active' -or [string]$_.title -notmatch "^$n\s+-\s+"){return $false}
    $updatedProperty=$_.PSObject.Properties['updatedAt']
    if($null -eq $updatedProperty -or [string]::IsNullOrWhiteSpace([string]$updatedProperty.Value)){return $true}
    try{[datetimeoffset]$updatedProperty.Value -gt $freshConversationCutoff}catch{$true}
  }).Count){continue}
  if(@($worktrees|Where-Object{[string]$_.path -match "(?i)(?:[/\\]|-)$n-"}).Count){continue}
  $deps=@(foreach($line in [regex]::Matches([string]$i.body,'(?im)^(?!.*\bno dependenc(?:y|ies)\b).*\b(?:depends on|blocked by)\b([^\r\n]*)$')){foreach($m in [regex]::Matches($line.Groups[1].Value,'#(\d{1,6})')){$d=[int]$m.Groups[1].Value;if($openIds.Contains($d)){$d}}})
  if($deps.Count){continue}
  if([regex]::IsMatch([string]$i.body,'(?im)^\s*-\s*\[\s\]\s*#\d+\b')){continue}
  $files=@([regex]::Matches([string]$i.body,'(?im)^\s*-\s*`?([^`\r\n]+\.(?:cs|ps1|md|razor|json|yml|yaml))`?\s*$')|ForEach-Object{$_.Groups[1].Value.Trim()}|Select-Object -Unique)
  $candidates+=[pscustomobject]@{number=$n;title=$i.title;type=$types[0];priority=$priorities[0];priorityRank=$priority[$priorities[0]];createdAt=$i.createdAt;updatedAt=$i.updatedAt;author=$i.author.login;url=$i.url;referencedFiles=$files;acceptanceClauses=[regex]::Matches([string]$i.body,'(?im)^\s*(?:-\s*\[[ x]\]|\d+\.)\s+').Count}
}
$selected=@($candidates|Sort-Object priorityRank,@{Expression='createdAt';Descending=$true},number|Select-Object -First $Top)
[pscustomobject]@{status=if($selected.Count){'ready'}else{'idle'};code=if($selected.Count){'triage-candidates'}else{'no-triage-candidate'};count=$selected.Count;candidates=$selected}|ConvertTo-Json -Depth 8 -Compress
