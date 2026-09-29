[CmdletBinding()]
param([Parameter(Mandatory)][int]$PullRequestNumber,[string]$Repository='Sytone/botnexus',[switch]$SelfTest)
$ErrorActionPreference='Stop'
function Get-Packet($Pr,$Files,$Comments,$OpenPrs){
  $owner=$Repository.Split('/')[0];$external=[string]$Pr.user.login -notin @('sytone','agent-farnsworth[bot]','app/agent-farnsworth')
  if(-not $external){throw "PR #$($Pr.number) is not external."}
  $head=[string]$Pr.head.sha;$marker="<!-- botnexus:external-review:v1:head=$head -->"
  $reviewed=@($Comments|Where-Object{[string]$_.body -like "*$marker*" -and [string]$_.user.login -in @('agent-farnsworth[bot]','app/agent-farnsworth')}).Count -gt 0
  $stacked=[string]$Pr.body -match '(?i)\bstacked\b|\bPR\s+\d+\s+of\s+\d+\b|\bseries\b'
  $linked=@([regex]::Matches("$($Pr.title)`n$($Pr.body)",'(?i)(?:closes|fixes|resolves|refs)\s*#(\d{1,6})')|ForEach-Object{[int]$_.Groups[1].Value}|Sort-Object -Unique)
  $paths=@($Files|ForEach-Object{$_.filename ?? $_.path})
  $overlap=@($OpenPrs|Where-Object{[int]$_.number -ne [int]$Pr.number -and @($_.files|Where-Object{$_ -in $paths}).Count -gt 0}|ForEach-Object{[pscustomobject]@{number=$_.number;author=$_.author;files=@($_.files|Where-Object{$_ -in $paths})}})
  $refresh=if($stacked){'contributor-restack'}elseif(-not [bool]$Pr.maintainer_can_modify){'contributor-required'}elseif([string]$Pr.mergeable_state -eq 'behind' -and [bool]$Pr.mergeable){'github-update-branch'}elseif([string]$Pr.mergeable_state -eq 'dirty' -or $Pr.mergeable -eq $false){'conflict-contributor-required'}else{'none'}
  [pscustomobject]@{version=1;number=[int]$Pr.number;url=$Pr.html_url;external=$true;author=$Pr.user.login;head=[pscustomobject]@{repository=$Pr.head.repo.full_name;ref=$Pr.head.ref;sha=$head};base=[pscustomobject]@{repository=$Pr.base.repo.full_name;ref=$Pr.base.ref;sha=$Pr.base.sha};maintainerCanModify=[bool]$Pr.maintainer_can_modify;mergeable=$Pr.mergeable;mergeState=$Pr.mergeable_state;stacked=$stacked;refreshAction=$refresh;linkedIssues=$linked;files=$paths;overlap=$overlap;reviewMarker=$marker;currentHeadReviewed=$reviewed;reviewDimensions=@('issue-plan-alignment','active-work-overlap','architecture','security-trust','correctness-tests','maintainability')}
}
if($SelfTest){
  $pr=[pscustomobject]@{number=7;title='fix: x';body='Refs #12';html_url='u';user=[pscustomobject]@{login='ext'};head=[pscustomobject]@{sha='abc';ref='b';repo=[pscustomobject]@{full_name='ext/r'}};base=[pscustomobject]@{sha='def';ref='main';repo=[pscustomobject]@{full_name='Sytone/botnexus'}};maintainer_can_modify=$true;mergeable=$true;mergeable_state='behind'}
  $p=Get-Packet $pr @([pscustomobject]@{filename='a.cs'}) @() @();if($p.refreshAction -ne 'github-update-branch' -or $p.currentHeadReviewed -or 12 -notin $p.linkedIssues){throw 'Ordinary external fixture failed.'}
  $pr.body='Stacked. PR 2 of 3';$p=Get-Packet $pr @() @() @();if($p.refreshAction -ne 'contributor-restack' -or -not $p.stacked){throw 'Stack fixture failed.'}
  $pr.body='Refs #12';$pr.maintainer_can_modify=$false;$p=Get-Packet $pr @() @([pscustomobject]@{body='<!-- botnexus:external-review:v1:head=abc -->';user=[pscustomobject]@{login='agent-farnsworth[bot]'}}) @();if($p.refreshAction -ne 'contributor-required' -or -not $p.currentHeadReviewed){throw 'Permission/review fixture failed.'}
  [pscustomobject]@{total=3;passed=3;failed=0}|ConvertTo-Json -Compress;return
}
$pr=gh api "repos/$Repository/pulls/$PullRequestNumber"|ConvertFrom-Json;if($LASTEXITCODE){throw 'PR read failed.'}
$files=gh api "repos/$Repository/pulls/$PullRequestNumber/files?per_page=100"|ConvertFrom-Json;if($LASTEXITCODE){throw 'PR files read failed.'};if($files.Count -ne [int]$pr.changed_files){throw 'PR file pagination incomplete.'}
$comments=gh api "repos/$Repository/issues/$PullRequestNumber/comments?per_page=100"|ConvertFrom-Json;if($LASTEXITCODE){throw 'PR comments read failed.'}
$openRaw=gh pr list --repo $Repository --state open --limit 500 --json number,author|ConvertFrom-Json;if($LASTEXITCODE){throw 'Open PR read failed.'}
$open=@();foreach($other in $openRaw){$f=gh api "repos/$Repository/pulls/$($other.number)/files?per_page=100"|ConvertFrom-Json;if($LASTEXITCODE){throw "PR #$($other.number) files read failed."};$open+=[pscustomobject]@{number=$other.number;author=$other.author.login;files=@($f.filename)}}
Get-Packet $pr $files $comments $open|ConvertTo-Json -Depth 10 -Compress
