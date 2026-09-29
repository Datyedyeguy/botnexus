[CmdletBinding()]
param(
  [string]$Repository = 'Sytone/botnexus',
  [int]$CacheMinutes = 0,
  [ValidateRange(1,100)][int]$Top = 20,
  [string]$ExcludedTitlePattern = '(?i)maintenance|autonomous',
  [string]$CachePath = "$env:TEMP/botnexus-candidate-issues.json"
)
$ErrorActionPreference = 'Stop'
$now = [DateTimeOffset]::UtcNow
if ((Test-Path -LiteralPath $CachePath) -and $CacheMinutes -gt 0) {
  $age = $now - [DateTimeOffset](Get-Item -LiteralPath $CachePath).LastWriteTimeUtc
  if ($age.TotalMinutes -lt $CacheMinutes) { Get-Content -LiteralPath $CachePath -Raw; return }
}
$raw = gh issue list --repo $Repository --state open --limit 1000 --json number,title,body,labels,createdAt,updatedAt,url,author
if ($LASTEXITCODE -ne 0) { throw 'GitHub issue query failed.' }
$prRaw = gh pr list --repo $Repository --state open --limit 100 --json number,headRefName,body,title
if ($LASTEXITCODE -ne 0) { throw 'GitHub pull request query failed.' }
$issues = @($raw | ConvertFrom-Json)
$openIssueIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($openIssue in $issues) { $null = $openIssueIds.Add([int]$openIssue.number) }
$openPrIssueIds = @($prRaw | ConvertFrom-Json | ForEach-Object {
  $text = "$($_.headRefName)`n$($_.title)`n$($_.body)"
  foreach ($match in [regex]::Matches($text, '(?i)(?:closes|fixes|resolves|refs|#|^|/)(?:\s*#?)?(\d{1,6})(?:\b|-)')) { [int]$match.Groups[1].Value }
} | Select-Object -Unique)
$repoRoot = (& git rev-parse --show-toplevel 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($repoRoot)) { $repoRoot = 'Q:/repos/botnexus' }
$worktreeLines = @(& git -C $repoRoot worktree list --porcelain 2>$null)
$worktreeIssueIds = @($worktreeLines | Where-Object { $_ -like 'worktree *' } | ForEach-Object {
  if ($_ -match '(?i)(?:botnexus-wt[/\\](?:[^/\\]*?-)?|[/\\])(?:fix|feat|test|docs|chore|refactor|perf|ci|build)[-/](\d+)-') { [int]$Matches[1] }
  elseif ($_ -match 'botnexus-wt[/\\](\d+)-') { [int]$Matches[1] }
} | Select-Object -Unique)
$priority = @{ 'priority:critical'=0; 'priority:high'=1; 'priority:p1'=1; 'priority:medium'=2; 'priority:low'=3 }
$candidates = foreach ($issue in $issues) {
  $labels = @($issue.labels.name)
  if ($ExcludedTitlePattern -and $issue.title -match $ExcludedTitlePattern) { continue }
  if ([string]$issue.body -match '(?im)^\s*(?:-\s*)?(?:Shared skills[/\\]|[A-Z]:[/\\].*[/\\]\.botnexus[/\\]skills[/\\])') { continue }
  if ($issue.number -in $openPrIssueIds -or $issue.number -in $worktreeIssueIds) { continue }
  $openDependencies = @(
    foreach ($dependencyLine in [regex]::Matches([string]$issue.body, '(?im)^(?!.*\bno dependenc(?:y|ies)\b).*\b(?:depends on|blocked by)\b([^\r\n]*)$')) {
      foreach ($dependencyId in [regex]::Matches($dependencyLine.Groups[1].Value, '#(\d{1,6})')) {
        $id = [int]$dependencyId.Groups[1].Value
        if ($openIssueIds.Contains($id)) { $id }
      }
    }
  )
  if ($openDependencies.Count -gt 0) { continue }
  if ($labels -contains 'type:epic' -or $labels -contains 'type:spike') { continue }
  if ($labels -contains 'status:in-progress' -or $labels -contains 'status:blocked' -or $labels -contains 'status:needs-jon-decision') { continue }
  $priorityLabels = @($labels | Where-Object { $priority.ContainsKey($_) })
  $typeLabels = @($labels | Where-Object { $_ -like 'type:*' })
  if ($priorityLabels.Count -ne 1 -or $typeLabels.Count -ne 1) { continue }
  $rank = 4
  foreach ($label in $labels) { if ($priority.ContainsKey($label)) { $rank = [Math]::Min($rank, $priority[$label]) } }
  [pscustomobject]@{
    number = $issue.number
    title = $issue.title
    priorityRank = $rank
    createdAt = $issue.createdAt
    updatedAt = $issue.updatedAt
    labels = $labels
    url = $issue.url
    author = $issue.author.login
  }
}
$result = [pscustomobject]@{
  generatedAt = $now.ToString('o')
  repository = $Repository
  eligibleCount = @($candidates).Count
  count = [Math]::Min(@($candidates).Count, $Top)
  candidates = @($candidates | Sort-Object priorityRank, @{Expression='createdAt'; Descending=$true}, number | Select-Object -First $Top)
}
$json = $result | ConvertTo-Json -Depth 7
Set-Content -LiteralPath $CachePath -Value $json -Encoding utf8
$json
