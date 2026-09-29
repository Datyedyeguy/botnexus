[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][int]$PullRequestNumber,
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][string]$Worktree,
  [string]$Repository='Sytone/botnexus',
  [string]$RepoRoot='Q:/repos/botnexus',
  [string]$BaseBranch='main',
  [switch]$SelfTest
)
$ErrorActionPreference='Stop'

function Get-CompletionDisposition([string]$Body,[int]$IssueNumber,[string]$IssueState) {
  $closes=[regex]::IsMatch($Body,"(?i)\b(?:closes|fixes|resolves)\s+#$IssueNumber\b")
  $refs=[regex]::IsMatch($Body,"(?i)\brefs:?\s+#$IssueNumber\b")
  if($closes -and $refs){throw "PR body ambiguously both closes and references #$IssueNumber."}
  if(-not $closes -and -not $refs){throw "PR body does not identify #$IssueNumber as full or partial work."}
  if($closes){
    [pscustomobject]@{scope='full';shouldCloseIssue=$true;shouldArchiveConversation=$true;expectedIssueState='closed'}
  } else {
    if($IssueState -eq 'closed'){throw "Partial PR uses Refs #$IssueNumber but the issue is already closed."}
    [pscustomobject]@{scope='partial';shouldCloseIssue=$false;shouldArchiveConversation=$false;expectedIssueState='open'}
  }
}

if($SelfTest){
  $full=Get-CompletionDisposition 'Closes #12' 12 'open'
  $partial=Get-CompletionDisposition 'Refs #12' 12 'open'
  if(-not $full.shouldCloseIssue -or -not $full.shouldArchiveConversation -or $partial.shouldCloseIssue -or $partial.shouldArchiveConversation){throw 'Completion disposition self-test failed.'}
  $ambiguousRejected=$false;try{Get-CompletionDisposition 'Closes #12; Refs #12' 12 'open'|Out-Null}catch{$ambiguousRejected=$true}
  $partialClosedRejected=$false;try{Get-CompletionDisposition 'Refs #12' 12 'closed'|Out-Null}catch{$partialClosedRejected=$true}
  if(-not $ambiguousRejected -or -not $partialClosedRejected){throw 'Completion refusal self-test failed.'}
  [pscustomobject]@{total=4;passed=4;failed=0;fullClose=$true;partialStaysOpen=$true;ambiguousRejected=$true;partialClosedRejected=$true}|ConvertTo-Json -Compress
  return
}

if(-not (Test-Path -LiteralPath $Worktree -PathType Container)){throw "Worktree not found: $Worktree"}
$auth=Join-Path $PSScriptRoot 'Use-FarnsworthBot.ps1'
& $auth|Out-Null
try {
  $prJson=gh pr view $PullRequestNumber --repo $Repository --json number,state,mergedAt,mergeCommit,headRefName,headRefOid,baseRefName,body,url
  if($LASTEXITCODE -ne 0){throw "PR #$PullRequestNumber read failed."}
  $pr=$prJson|ConvertFrom-Json
  if($pr.state -ne 'MERGED' -or -not $pr.mergedAt){throw "PR #$PullRequestNumber is not merged."}
  if($pr.baseRefName -cne $BaseBranch){throw "PR #$PullRequestNumber targets '$($pr.baseRefName)', expected '$BaseBranch'."}
  $branch=(& git -C $Worktree rev-parse --abbrev-ref HEAD).Trim()
  $head=(& git -C $Worktree rev-parse HEAD).Trim()
  if($LASTEXITCODE -ne 0 -or $branch -cne $pr.headRefName -or $head -cne $pr.headRefOid){throw "Worktree branch/head does not match merged PR #$PullRequestNumber."}
  if(@(& git -C $Worktree status --porcelain).Count -gt 0){throw "Worktree is dirty: $Worktree"}
  & git -C $Worktree fetch origin $BaseBranch|Out-Null
  if($LASTEXITCODE -ne 0){throw "Fetch origin/$BaseBranch failed."}
  $mergeOid=[string]$pr.mergeCommit.oid
  if([string]::IsNullOrWhiteSpace($mergeOid)){throw "PR #$PullRequestNumber has no merge commit OID."}
  & git -C $Worktree merge-base --is-ancestor $mergeOid "origin/$BaseBranch"
  if($LASTEXITCODE -ne 0){throw "PR #$PullRequestNumber merge commit is not on origin/$BaseBranch."}

  $issueJson=gh issue view $Issue --repo $Repository --json number,state,title,url
  if($LASTEXITCODE -ne 0){throw "Issue #$Issue read failed."}
  $issueRecord=$issueJson|ConvertFrom-Json
  $issueState=([string]$issueRecord.state).ToLowerInvariant()
  $disposition=Get-CompletionDisposition ([string]$pr.body) $Issue $issueState

  if($disposition.shouldCloseIssue -and $issueState -ne 'closed'){
    if($PSCmdlet.ShouldProcess("issue #$Issue","Close after merged PR #$PullRequestNumber was verified on origin/$BaseBranch")){
      gh issue close $Issue --repo $Repository --comment "Verified merged PR #$PullRequestNumber on origin/$BaseBranch at $mergeOid. Closing the completed issue."|Out-Null
      if($LASTEXITCODE -ne 0){throw "Issue #$Issue close failed."}
      $observed=(gh issue view $Issue --repo $Repository --json state|ConvertFrom-Json)
      if($observed.state -ne 'CLOSED'){throw "Issue #$Issue close readback failed."}
      $issueState='closed'
    }
  }
  if($disposition.scope -eq 'full' -and $issueState -ne 'closed' -and -not $WhatIfPreference){throw "Issue #$Issue is still open after full-scope merge completion."}

  $cleanup=Join-Path $PSScriptRoot 'Remove-BotNexusIssueWorktree.ps1'
  if($PSCmdlet.ShouldProcess($Worktree,"Remove merged PR #$PullRequestNumber worktree and branch")){
    $cleanupResult=& $cleanup -Issue $Issue -PullRequestNumber $PullRequestNumber -Repository $Repository -RepoRoot $RepoRoot
  } else {$cleanupResult=$null}

  [pscustomobject]@{pullRequest=$PullRequestNumber;issue=$Issue;scope=$disposition.scope;mergedAt=$pr.mergedAt;mergeCommit=$mergeOid;issueState=$issueState;archiveConversation=($disposition.shouldArchiveConversation -and $issueState -eq 'closed');cleanup=$cleanupResult;url=$pr.url}|ConvertTo-Json -Depth 8 -Compress
} finally {
  & $auth -Scrub|Out-Null
}
