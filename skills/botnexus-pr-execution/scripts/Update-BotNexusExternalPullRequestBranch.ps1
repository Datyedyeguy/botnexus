[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][int]$PullRequestNumber,[string]$ExpectedHeadSha,[string]$Repository='Sytone/botnexus',[switch]$WhatIf)
$ErrorActionPreference='Stop'
$pr=gh api "repos/$Repository/pulls/$PullRequestNumber"|ConvertFrom-Json;if($LASTEXITCODE){throw 'PR read failed.'}
if([string]$pr.user.login -in @('sytone','agent-farnsworth[bot]','app/agent-farnsworth')){throw 'External branch updater accepts only external PRs.'}
if($ExpectedHeadSha -and [string]$pr.head.sha -cne $ExpectedHeadSha){throw 'Head changed; refusing stale update.'}
if(-not [bool]$pr.maintainer_can_modify){throw 'Contributor has not allowed maintainer edits.'}
if([string]$pr.body -match '(?i)\bstacked\b|\bPR\s+\d+\s+of\s+\d+\b|\bseries\b'){throw 'Declared stacks require contributor-coordinated bottom-up restacking.'}
if([string]$pr.mergeable_state -ne 'behind' -or -not [bool]$pr.mergeable){throw "PR is not a clean behind branch: mergeable=$($pr.mergeable), state=$($pr.mergeable_state)."}
if($WhatIf -or -not $PSCmdlet.ShouldProcess("PR #$PullRequestNumber","GitHub update-branch merge of current base into contributor head $($pr.head.sha)")){
  [pscustomobject]@{status='preview';code='update-branch-ready';number=$PullRequestNumber;head=$pr.head.sha;base=$pr.base.sha}|ConvertTo-Json -Compress;return
}
$body=@{expected_head_sha=[string]$pr.head.sha}|ConvertTo-Json -Compress
$result=$body|gh api --method PUT "repos/$Repository/pulls/$PullRequestNumber/update-branch" --input -|ConvertFrom-Json
if($LASTEXITCODE){throw 'GitHub update-branch failed.'}
$observed=gh api "repos/$Repository/pulls/$PullRequestNumber"|ConvertFrom-Json;if($LASTEXITCODE){throw 'Updated PR readback failed.'}
if([string]$observed.head.sha -ceq [string]$pr.head.sha){throw 'Update-branch returned without changing the head.'}
[pscustomobject]@{status='updated';code='branch-updated';number=$PullRequestNumber;oldHead=$pr.head.sha;newHead=$observed.head.sha;base=$observed.base.sha;message=$result.message}|ConvertTo-Json -Compress
