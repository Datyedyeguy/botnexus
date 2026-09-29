[CmdletBinding()]
param(
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][int]$PullRequestNumber,
  [string]$Repository = 'Sytone/botnexus',
  [string]$RepoRoot = 'Q:/repos/botnexus'
)
$ErrorActionPreference = 'Stop'
$worktreeLines = @(& git -C $RepoRoot worktree list --porcelain)
$prJson = gh pr view $PullRequestNumber --repo $Repository --json number,state,mergedAt,mergeCommit,headRefName,headRefOid,baseRefName
if ($LASTEXITCODE -ne 0) { throw "PR #$PullRequestNumber read failed." }
$pr = $prJson | ConvertFrom-Json
if ($pr.state -ne 'MERGED' -or -not $pr.mergedAt) { throw "PR #$PullRequestNumber is not merged." }
$entries = @($worktreeLines | Where-Object { $_ -like 'worktree Q:/repos/botnexus-wt/*' } | ForEach-Object { $_ -replace '^worktree ','' })
$matches = @($entries | Where-Object {
  $branch = (& git -C $_ rev-parse --abbrev-ref HEAD 2>$null).Trim()
  $head = (& git -C $_ rev-parse HEAD 2>$null).Trim()
  $branch -ceq $pr.headRefName -and $head -ceq $pr.headRefOid
})
if ($matches.Count -ne 1) { throw "Expected one worktree matching merged PR #$PullRequestNumber exact branch/head; found $($matches.Count)." }
$path = $matches[0]
$status = @(& git -C $path status --porcelain)
if ($status.Count -gt 0) { throw "Worktree is dirty: $path" }
$head = (& git -C $path rev-parse HEAD).Trim()
& git -C $RepoRoot fetch origin $pr.baseRefName
if ($LASTEXITCODE -ne 0) { throw 'Fetch failed.' }
$mergeOid = [string]$pr.mergeCommit.oid
if ([string]::IsNullOrWhiteSpace($mergeOid)) {
  $mergeJson = gh pr view $PullRequestNumber --repo $Repository --json mergeCommit
  $mergeOid = [string](($mergeJson | ConvertFrom-Json).mergeCommit.oid)
}
& git -C $RepoRoot merge-base --is-ancestor $mergeOid "origin/$($pr.baseRefName)"
if ($LASTEXITCODE -ne 0) { throw "PR merge commit is not on origin/$($pr.baseRefName): $mergeOid" }
. (Join-Path $RepoRoot 'scripts/repo/Remove-Worktree.ps1')
$result = Remove-WorktreeSafely -RepoRoot $RepoRoot -WorktreePath $path -DeleteBranch
if ($result.outcome -notin @('removed','reclaimed','absent')) { throw "Cleanup failed: $($result.outcome)" }
$result | ConvertTo-Json -Depth 6
