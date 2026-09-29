[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][int]$Issue,[Parameter(Mandatory)][int]$PullRequestNumber,[string]$Repository='Sytone/botnexus',[string]$ContractPath)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
$leasePath=Get-BotNexusIssueLeasePath $contract $Issue
if(-not(Test-Path -LiteralPath $leasePath)){[pscustomobject]@{status='absent';code='delivery-lease-already-released';issue=$Issue;pullRequest=$PullRequestNumber}|ConvertTo-Json -Compress;return}
$lease=Get-Content -LiteralPath $leasePath -Raw|ConvertFrom-Json
if([int]$lease.issue -ne $Issue){throw "Delivery lease belongs to issue #$($lease.issue), not #$Issue."}
$pr=gh pr view $PullRequestNumber --repo $Repository --json number,state,author,body,url|ConvertFrom-Json
if($LASTEXITCODE){throw "PR #$PullRequestNumber read failed."}
if([int]$pr.number -ne $PullRequestNumber -or [string]$pr.state -ne 'OPEN' -or [string]$pr.author.login -notin @($contract.agentPullRequestAuthors)){throw 'PR is not an open Farnsworth-authored publication.'}
if([string]$pr.body -notmatch "(?i)(?:closes|fixes|resolves|refs)\s*#$Issue\b"){throw "PR #$PullRequestNumber does not link issue #$Issue."}
if($PSCmdlet.ShouldProcess($leasePath,"Release pre-PR delivery lease after verified PR #$PullRequestNumber publication")){
  & (Join-Path $PSScriptRoot 'Release-BotNexusIssueLease.ps1') -Issue $Issue -OwnerRunId $lease.ownerRunId -Nonce $lease.nonce -ContractPath $ContractPath|Out-Null
}
[pscustomobject]@{status='completed';code='issue-delivery-published';issue=$Issue;pullRequest=$PullRequestNumber;url=$pr.url}|ConvertTo-Json -Compress
