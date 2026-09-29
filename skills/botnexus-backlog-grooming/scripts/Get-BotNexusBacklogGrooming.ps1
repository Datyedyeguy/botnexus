[CmdletBinding()]
param([string]$Repository='Sytone/botnexus',[ValidateRange(1,20)][int]$Top=10,[string]$IssuesFixture,[string]$PullRequestsFixture,[datetimeoffset]$Now=[datetimeoffset]::UtcNow)
$ErrorActionPreference='Stop'
function Read-Json([string]$Path,[scriptblock]$Live){if($Path){@(Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json)}else{@(& $Live)}}
$issues=Read-Json $IssuesFixture {$raw=gh issue list --repo $Repository --state open --limit 1000 --json number,title,body,labels,createdAt,updatedAt,url,author;if($LASTEXITCODE){throw 'Issue census failed.'};$raw|ConvertFrom-Json}
$prs=Read-Json $PullRequestsFixture {$raw=gh pr list --repo $Repository --state open --limit 500 --json number,title,body,headRefName,author,url;if($LASTEXITCODE){throw 'PR census failed.'};$raw|ConvertFrom-Json}
$issueByNumber=@{};foreach($issue in $issues){$issueByNumber[[int]$issue.number]=$issue}
$records=@()
foreach($issue in $issues){
  $labels=@($issue.labels|ForEach-Object{if($_ -is [string]){$_}else{$_.name}})
  if('status:in-progress' -in $labels -or 'status:ready-for-agent' -in $labels){continue}
  $n=[int]$issue.number;$body=[string]$issue.body;$title=[string]$issue.title
  $age=[Math]::Floor(($Now-[datetimeoffset]$issue.updatedAt).TotalDays)
  $refs=@([regex]::Matches($body,'#(\d{1,6})')|ForEach-Object{[int]$_.Groups[1].Value}|Where-Object{$_ -ne $n}|Select-Object -Unique)
  $openRefs=@($refs|Where-Object{$issueByNumber.ContainsKey($_)})
  $prMatches=@($prs|Where-Object{"$($_.title)`n$($_.body)`n$($_.headRefName)" -match "(?i)(?:#|/)$n(?:\b|-)"}|ForEach-Object{[int]$_.number})
  $words=@([regex]::Matches($title.ToLowerInvariant(),'[a-z0-9]{4}')|ForEach-Object{$_.Value}|Where-Object{$_ -notin @('with','from','that','this','when','into','through','using','should','agent','gateway','portal','tools','tooling')}|Select-Object -Unique)
  $overlapHints=@()
  if($words.Count -ge 2){
    foreach($other in $issues){if([int]$other.number -eq $n){continue};$otherTitle=[string]$other.title;$shared=@($words|Where-Object{$otherTitle -match "(?i)\b$([regex]::Escape($_))\b"});if($shared.Count -ge [Math]::Min(3,$words.Count)){$overlapHints+=[int]$other.number}}
  }
  $required=@('## Summary','## Why it matters','## Example');$missing=@($required|Where-Object{$body -notmatch "(?im)^$([regex]::Escape($_))\s*$"})
  $decisionSignals=@([regex]::Matches($body,'(?i)decision requested|requires? (?:jon|human|maintainer) decision|purchase|licen[sc]e|which option|choose between')).Count
  $decompositionSignals=@([regex]::Matches($body,'(?i)part of #|depends on #|blocked by #|parent|child issue|slice \d+')).Count
  $score=0;if($age -ge 30){$score+=40}elseif($age -ge 14){$score+=20}elseif($age -ge 7){$score+=10};$score+=($missing.Count*4);$score+=([Math]::Min(15,$overlapHints.Count*3));if($openRefs.Count){$score+=4};if($prMatches.Count){$score+=8};if($decisionSignals){$score+=12};if($decompositionSignals -ge 2){$score+=6}
  $records+=[pscustomobject]@{number=$n;title=$title;author=$issue.author.login;updatedAt=$issue.updatedAt;ageDays=[int]$age;labels=$labels;score=$score;missingReadableSections=$missing;openIssueReferences=$openRefs;openPullRequestReferences=$prMatches;overlapHints=@($overlapHints|Select-Object -Unique|Select-Object -First 8);decisionSignals=$decisionSignals;decompositionSignals=$decompositionSignals;url=$issue.url}
}
$selected=@($records|Sort-Object @{Expression='score';Descending=$true},@{Expression='ageDays';Descending=$true},number|Select-Object -First $Top)
[pscustomobject]@{status=if($selected.Count){'ready'}else{'idle'};code=if($selected.Count){'grooming-candidates'}else{'no-grooming-candidate'};count=$selected.Count;candidates=$selected}|ConvertTo-Json -Depth 8 -Compress
