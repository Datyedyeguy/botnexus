[CmdletBinding()]
param(
  [string]$Repository = 'Sytone/botnexus',
  [string[]]$TrustedAuthor = @(),
  [switch]$IncludeHealthy,
  [switch]$IncludeFiles,
  [string]$ContractPath = '',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

$defaultTrustedAuthors = @('sytone', 'agent-farnsworth[bot]', 'app/agent-farnsworth')
$agentAuthors = @('agent-farnsworth[bot]', 'app/agent-farnsworth')
. (Join-Path $PSScriptRoot 'Import-BotNexusPullRequestDraftState.ps1')
if ([string]::IsNullOrWhiteSpace($ContractPath)) {
  $contractCandidates = @('Q:/repos/botnexus/.github/pr-contract.json',(Join-Path (Split-Path -Parent $PSScriptRoot) 'reference/pr-contract.json'))
  $ContractPath = [string]@($contractCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)[0]
}
if ([string]::IsNullOrWhiteSpace($ContractPath)) { throw 'PR contract is unavailable from repository main and the skill bootstrap snapshot.' }
$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json

function New-OrdinalSet([string[]]$Values) {
  @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() } | Sort-Object -Unique)
}

function Get-CheckClassification([object[]]$Checks) {
  $failedConclusions = @('failure', 'cancelled', 'timed_out', 'action_required', 'startup_failure', 'stale')
  $acceptedConclusions = @('success', 'neutral', 'skipped')
  $failed = [Collections.Generic.List[object]]::new()
  $pending = [Collections.Generic.List[object]]::new()
  $skipped = [Collections.Generic.List[object]]::new()
  $unknown = [Collections.Generic.List[object]]::new()
  # GitHub may return several runs for the same check name even with filter=latest.
  # Only the newest run of each merge-gate context is authoritative; otherwise a
  # repaired check remains permanently red because an older failed run survives.
  $latestChecks = @(
    $Checks |
      Group-Object { [string]$_.name } |
      ForEach-Object {
        $_.Group |
          Sort-Object @{Expression={
            $stampProperty = $_.PSObject.Properties['started_at']
            $stamp = if ($null -ne $stampProperty) { [string]$stampProperty.Value } else { '' }
            if (-not [string]::IsNullOrWhiteSpace($stamp)) { [datetimeoffset]$stamp } else { [datetimeoffset]::MinValue }
          };Descending=$true}, @{Expression={ [long]$_.id };Descending=$true} |
          Select-Object -First 1
      }
  )
  foreach ($check in $latestChecks) {
    $status = ([string]$check.status).ToLowerInvariant()
    $conclusion = ([string]$check.conclusion).ToLowerInvariant()
    if ($status -ne 'completed') { $pending.Add($check); continue }
    if ($conclusion -in $failedConclusions) { $failed.Add($check); continue }
    if ($conclusion -eq 'skipped') { $skipped.Add($check); continue }
    if ($conclusion -notin $acceptedConclusions) { $unknown.Add($check) }
  }
  [pscustomobject]@{
    total = $latestChecks.Count
    failed = @($failed)
    pending = @($pending)
    skipped = @($skipped)
    unknown = @($unknown)
  }
}

function Get-HandledKeys([object[]]$Bodies) {
  @(
    foreach ($item in $Bodies) {
      foreach ($match in [regex]::Matches([string]$item.body, '<!--\s*botnexus:handled-comment:([a-z0-9-]+)\s*-->', 'IgnoreCase')) {
        $match.Groups[1].Value
      }
    }
  ) | Sort-Object -Unique
}

function Get-CommentAttention(
  [object[]]$IssueComments,
  [object[]]$ReviewComments,
  [object[]]$Reviews,
  [string[]]$Trusted,
  [string[]]$Agents
) {
  $allBodies = @($IssueComments) + @($ReviewComments) + @($Reviews)
  $handled = Get-HandledKeys $allBodies
  $result = [Collections.Generic.List[object]]::new()
  $ignoredAutomation = 0

  $sources = @(
    @($IssueComments | ForEach-Object { [pscustomobject]@{ key="issue-$($_.id)"; kind='issue-comment'; id=$_.id; author=$_.user.login; authorType=$_.user.type; body=$_.body; createdAt=$_.created_at; url=$_.html_url } }),
    @($ReviewComments | ForEach-Object { [pscustomobject]@{ key="review-comment-$($_.id)"; kind='review-comment'; id=$_.id; author=$_.user.login; authorType=$_.user.type; body=$_.body; createdAt=$_.created_at; url=$_.html_url } }),
    @($Reviews | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.body) } | ForEach-Object { [pscustomobject]@{ key="review-$($_.id)"; kind='review'; id=$_.id; author=$_.user.login; authorType=$_.user.type; body=$_.body; createdAt=$_.submitted_at; url=$_.html_url } })
  )

  foreach ($sourceGroup in $sources) {
    foreach ($item in @($sourceGroup)) {
      if ([string]$item.author -in $Agents -or [string]$item.key -in $handled) { continue }
      if ([string]::IsNullOrWhiteSpace([string]$item.body)) { continue }
      $isTrusted = [string]$item.author -in $Trusted
      if (-not $isTrusted -and [string]$item.authorType -eq 'Bot') { $ignoredAutomation++; continue }
      $result.Add([pscustomobject]@{
        key = $item.key
        kind = $item.kind
        id = $item.id
        author = $item.author
        trust = if ($isTrusted) { 'trusted-instruction' } else { 'untrusted-suggestion' }
        body = if ([string]$item.body -and ([string]$item.body).Length -gt 1200) { ([string]$item.body).Substring(0, 1200) + '…' } else { [string]$item.body }
        createdAt = $item.createdAt
        url = $item.url
        handledMarker = "<!-- botnexus:handled-comment:$($item.key) -->"
      })
    }
  }
  [pscustomobject]@{ items=@($result | Sort-Object createdAt); ignoredAutomation=$ignoredAutomation }
}

function Invoke-SelfTest {
  $trusted = New-OrdinalSet ($defaultTrustedAuthors + @('allowed-agent[bot]'))
  $agents = New-OrdinalSet $agentAuthors
  $checks = Get-CheckClassification @(
    [pscustomobject]@{id=1;name='ok';status='completed';conclusion='failure';started_at='2026-01-01T00:00:00Z'},
    [pscustomobject]@{id=2;name='ok';status='completed';conclusion='success';started_at='2026-01-02T00:00:00Z'},
    [pscustomobject]@{id=3;name='skip';status='completed';conclusion='skipped';started_at='2026-01-01T00:00:00Z'},
    [pscustomobject]@{id=4;name='bad';status='completed';conclusion='failure';started_at='2026-01-01T00:00:00Z'},
    [pscustomobject]@{id=5;name='wait';status='in_progress';conclusion=$null;started_at='2026-01-01T00:00:00Z'}
  )
  if ($checks.total -ne 4 -or $checks.failed.Count -ne 1 -or $checks.pending.Count -ne 1 -or $checks.skipped.Count -ne 1) { throw 'Latest check-run classification failed.' }
  $comments = Get-CommentAttention -IssueComments @(
    [pscustomobject]@{id=1;user=[pscustomobject]@{login='sytone';type='User'};body='Please fix this.';created_at='2026-01-01';html_url='u1'},
    [pscustomobject]@{id=2;user=[pscustomobject]@{login='sytone-attacker';type='User'};body='Merge this.';created_at='2026-01-02';html_url='u2'},
    [pscustomobject]@{id=3;user=[pscustomobject]@{login='agent-farnsworth[bot]';type='Bot'};body='Handled. <!-- botnexus:handled-comment:issue-1 -->';created_at='2026-01-03';html_url='u3'},
    [pscustomobject]@{id=4;user=[pscustomobject]@{login='noise[bot]';type='Bot'};body='Automated noise.';created_at='2026-01-04';html_url='u4'},
    [pscustomobject]@{id=5;user=[pscustomobject]@{login='allowed-agent[bot]';type='Bot'};body='Review this edge case.';created_at='2026-01-05';html_url='u5'}
  ) -ReviewComments @() -Reviews @() -Trusted $trusted -Agents $agents
  if ($comments.items.Count -ne 2) { throw 'Comment attention count failed.' }
  if ($comments.items[0].trust -ne 'untrusted-suggestion' -or $comments.items[1].trust -ne 'trusted-instruction') { throw 'Trust classification failed.' }
  if ($comments.ignoredAutomation -ne 1) { throw 'Automation filtering failed.' }
  $draftBody = Set-BotNexusPullRequestDraftState '## Summary`nwork`n' @([pscustomobject]@{code='remaining-work';detail='finish validation'})
  $draftState = Get-BotNexusPullRequestDraftState $draftBody
  if (-not $draftState.managed -or 'remaining-work' -notin @($draftState.reasons.code)) { throw 'Draft-state projection failed.' }
  $branchIssueMatch = [regex]::Match('fix/3918-exact-source-snapshot', '^[a-z]+/(?<issue>\d{1,6})-')
  if (-not $branchIssueMatch.Success -or [int]$branchIssueMatch.Groups['issue'].Value -ne 3918) { throw 'Branch issue projection failed.' }
  [pscustomobject]@{ total=10; passed=10; failed=0; exactTrust=$true; handledMarkers=$true; checkStates=$true; draftState=$true; branchIssue=$true } | ConvertTo-Json -Compress
}

if ($SelfTest) { Invoke-SelfTest; return }
if ($Repository -notmatch '^([^/]+)/([^/]+)$') { throw "Repository must be owner/name: $Repository" }
$owner = $Matches[1]
$repo = $Matches[2]
$trusted = New-OrdinalSet ($defaultTrustedAuthors + $TrustedAuthor)
$agents = New-OrdinalSet $agentAuthors
$auth = Join-Path $PSScriptRoot 'Use-FarnsworthBot.ps1'
& $auth | Out-Null

$stderrPath = Join-Path ([IO.Path]::GetTempPath()) ("botnexus-pr-scan-{0}.err" -f [guid]::NewGuid().ToString('N'))
function Invoke-GhApi([string]$Path) {
  try {
    $raw = @(& gh api --method GET $Path 2>$stderrPath)
    if ($LASTEXITCODE -ne 0) {
      $detail = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -LiteralPath $stderrPath -Raw).Trim() } else { '' }
      throw "GitHub query failed for $Path. $detail"
    }
    if ($raw.Count -eq 0) { return $null }
    ($raw -join "`n") | ConvertFrom-Json
  } finally {
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
  }
}
function Get-GhPages([string]$Path) {
  $items = [Collections.Generic.List[object]]::new()
  $page = 1
  do {
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    $batch = @(Invoke-GhApi "$Path${separator}per_page=100&page=$page")
    foreach ($item in $batch) { if ($null -ne $item) { $items.Add($item) } }
    $page++
  } while ($batch.Count -eq 100)
  @($items)
}

try {
  $openPrs = @(Get-GhPages "repos/$owner/$repo/pulls?state=open")
  $attention = [Collections.Generic.List[object]]::new()
  $healthy = [Collections.Generic.List[object]]::new()
  $waitingCount = 0

  foreach ($summary in $openPrs) {
    $number = [int]$summary.number
    $pr = Invoke-GhApi "repos/$owner/$repo/pulls/$number"
    $files = @(Get-GhPages "repos/$owner/$repo/pulls/$number/files")
    $issueComments = @(Get-GhPages "repos/$owner/$repo/issues/$number/comments")
    $reviewComments = @(Get-GhPages "repos/$owner/$repo/pulls/$number/comments")
    $reviews = @(Get-GhPages "repos/$owner/$repo/pulls/$number/reviews")
    $checkPayload = Invoke-GhApi "repos/$owner/$repo/commits/$($pr.head.sha)/check-runs?filter=latest"
    $checks = @($checkPayload.check_runs)
    $checkState = Get-CheckClassification $checks
    $commentState = Get-CommentAttention -IssueComments $issueComments -ReviewComments $reviewComments -Reviews $reviews -Trusted $trusted -Agents $agents

    $latestReviews = @($reviews | Group-Object { $_.user.login } | ForEach-Object { $_.Group | Sort-Object submitted_at -Descending | Select-Object -First 1 })
    $changesRequested = @($latestReviews | Where-Object { ([string]$_.state).ToUpperInvariant() -eq 'CHANGES_REQUESTED' })
    $problems = [Collections.Generic.List[string]]::new()
    $waiting = [Collections.Generic.List[string]]::new()
    if ($files.Count -ne [int]$pr.changed_files) { $problems.Add('incomplete-file-inventory') }
    if ($checks.Count -eq 0) { $problems.Add('missing-checks') }
    if ($checkState.failed.Count -gt 0) { $problems.Add('failed-checks') }
    if ($checkState.unknown.Count -gt 0) { $problems.Add('unknown-check-results') }
    if ($checkState.pending.Count -gt 0) { $waiting.Add('pending-checks') }
    if ($null -eq $pr.mergeable -or [string]$pr.mergeable_state -eq 'unknown') { $waiting.Add('mergeability-pending') }
    elseif (-not [bool]$pr.mergeable -or [string]$pr.mergeable_state -eq 'dirty') { $problems.Add('merge-conflict') }
    elseif ([string]$pr.mergeable_state -eq 'behind') { $problems.Add('base-behind') }
    if ($changesRequested.Count -gt 0) { $problems.Add('changes-requested') }
    if ($commentState.items.Count -gt 0) { $problems.Add('unhandled-comments') }
    $allowedTypePattern = (@($contract.allowedTypes) | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
    if ([string]$pr.title -notmatch "^(?:$allowedTypePattern)(\([a-z0-9#._-]+\))?!?: [a-z0-9]") { $problems.Add('invalid-title') }
    $prLabels = @($pr.labels | ForEach-Object { $_.name })
    $expectedTypeLabel = switch -Regex ([string]$pr.title) {
      '^fix' { 'type:bug'; break }
      '^feat' { 'type:feature'; break }
      '^docs' { 'type:docs'; break }
      '^refactor' { 'type:refactor'; break }
      '^perf' { 'type:improvement'; break }
      '^test' { 'type:test'; break }
      '^(chore|style|ci|build)' { 'type:chore'; break }
      default { $null }
    }
    $isOwnedPr = [string]$pr.user.login -in $agents
    $isExternalPr = -not $isOwnedPr -and [string]$pr.user.login -ne 'sytone'
    $externalReviewMarker = "<!-- botnexus:external-review:v1:head=$($pr.head.sha) -->"
    $currentHeadReviewed = @($issueComments | Where-Object {
      [string]$_.body -like "*$externalReviewMarker*" -and [string]$_.user.login -in $agents
    }).Count -gt 0
    if ($isExternalPr -and -not $currentHeadReviewed) { $problems.Add('external-review-required') }
    if ($isOwnedPr -and $expectedTypeLabel -and $expectedTypeLabel -notin $prLabels) { $problems.Add('pr-label-drift') }
    $draftState = Get-BotNexusPullRequestDraftState ([string]$pr.body)
    if ([bool]$pr.draft) {
      $problems.Add('draft-reconciliation-required')
      if (-not $draftState.managed) { $problems.Add('draft-state-unmanaged') }
    }

    $projectCheck = {
      param($check)
      [pscustomobject]@{
        name = $check.name
        status = $check.status
        conclusion = $check.conclusion
        startedAt = $check.started_at
        completedAt = $check.completed_at
        url = $check.html_url
      }
    }
    $prIdentityText = "$($pr.head.ref)`n$($pr.title)`n$($pr.body)"
    $closingIssues = @($(
      foreach ($match in [regex]::Matches($prIdentityText, '(?i)(?:closes|fixes|resolves)\s*#(\d{1,6})')) { [int]$match.Groups[1].Value }
    ) | Sort-Object -Unique)
    $linkedIssues = @($(
      foreach ($match in [regex]::Matches($prIdentityText, '(?i)(?:closes|fixes|resolves|refs)\s*#(\d{1,6})|(?:^|[/#-])(\d{3,6})(?:\b|-)')) {
        $value = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        if ($value) { [int]$value }
      }
    ) | Sort-Object -Unique)
    $branchIssueMatch = [regex]::Match([string]$pr.head.ref, '^[a-z]+/(?<issue>\d{1,6})-')
    $branchIssue = if ($branchIssueMatch.Success) { [int]$branchIssueMatch.Groups['issue'].Value } else { $null }
    $primaryIssue = if ($closingIssues.Count -eq 1) { $closingIssues[0] } elseif ($null -ne $branchIssue) { $branchIssue } elseif ($linkedIssues.Count -eq 1) { $linkedIssues[0] } else { $null }
    $contractIssue = $primaryIssue
    $linkedIssueState = $null
    $linkedIssueLabels = @()
    if ($null -ne $primaryIssue) {
      $linkedIssue = Invoke-GhApi "repos/$owner/$repo/issues/$primaryIssue"
      if ($null -ne $linkedIssue.PSObject.Properties['pull_request']) { $problems.Add('primary-link-is-pr') }
      else {
        $linkedIssueState = ([string]$linkedIssue.state).ToLowerInvariant()
        $linkedIssueLabels = @($linkedIssue.labels | ForEach-Object { $_.name })
        if ($linkedIssueState -ne 'open') { $problems.Add('linked-issue-closed') }
        if ($isOwnedPr -and 'status:in-progress' -in $linkedIssueLabels) { $problems.Add('stale-issue-claim') }
      }
    }
    $contractValidation = $null
    if ($null -ne $contractIssue) {
      $validator = Join-Path $PSScriptRoot 'Test-BotNexusPullRequest.ps1'
      $contractValidation = & $validator -Title $pr.title -Body ([string]$pr.body) -Issue $contractIssue -ContractPath $ContractPath -PartialWork:($closingIssues.Count -eq 0)
      if (-not $contractValidation.valid) { $problems.Add('pr-contract-invalid') }
    }
    $row = [pscustomobject]@{
      number = $number
      primaryIssue = $primaryIssue
      closingIssues = @($closingIssues)
      linkedIssues = @($linkedIssues)
      linkedIssueState = $linkedIssueState
      linkedIssueLabels = @($linkedIssueLabels)
      title = $pr.title
      url = $pr.html_url
      author = $pr.user.login
      ownership = if($isOwnedPr){'agent-owned'}elseif($isExternalPr){'external'}else{'maintainer-owned'}
      externalReview = if($isExternalPr){[pscustomobject]@{required=(-not $currentHeadReviewed);marker=$externalReviewMarker;maintainerCanModify=[bool]$pr.maintainer_can_modify;headRepository=$pr.head.repo.full_name}}else{$null}
      labels = @($prLabels)
      expectedTypeLabel = $expectedTypeLabel
      draft = [bool]$pr.draft
      draftState = [pscustomobject]@{ managed=[bool]$draftState.managed; version=$draftState.version; reasons=@($draftState.reasons) }
      head = [pscustomobject]@{ ref=$pr.head.ref; sha=$pr.head.sha; repository=$pr.head.repo.full_name }
      base = [pscustomobject]@{ ref=$pr.base.ref; sha=$pr.base.sha; repository=$pr.base.repo.full_name }
      mergeable = $pr.mergeable
      mergeState = $pr.mergeable_state
      changedFiles = [pscustomobject]@{
        expected = [int]$pr.changed_files
        collected = $files.Count
        paths = if ($IncludeFiles) { @($files | ForEach-Object { $_.filename }) } else { @() }
      }
      checks = [pscustomobject]@{
        total = $checkState.total
        failed = @($checkState.failed | ForEach-Object { & $projectCheck $_ })
        pending = @($checkState.pending | ForEach-Object { & $projectCheck $_ })
        skipped = @($checkState.skipped | ForEach-Object { & $projectCheck $_ })
        unknown = @($checkState.unknown | ForEach-Object { & $projectCheck $_ })
      }
      changesRequested = @($changesRequested | ForEach-Object { [pscustomobject]@{ id=$_.id; author=$_.user.login; body=$_.body; submittedAt=$_.submitted_at; url=$_.html_url } })
      commentsNeedingAttention = @($commentState.items)
      ignoredAutomationComments = $commentState.ignoredAutomation
      prContract = $contractValidation
      problemCodes = @($problems)
      waitingCodes = @($waiting)
    }
    if ($problems.Count -gt 0 -or $waiting.Count -gt 0) {
      if ($waiting.Count -gt 0) { $waitingCount++ }
      $attention.Add($row)
    } elseif ($IncludeHealthy) { $healthy.Add($row) }
  }

  $actionable = @($attention | Where-Object { $_.problemCodes.Count -gt 0 })
  $result = [ordered]@{
    generatedAt = [DateTimeOffset]::UtcNow.ToString('o')
    repository = $Repository
    scanned = $openPrs.Count
    healthy = $openPrs.Count - $attention.Count
    waiting = $waitingCount
    actionable = $actionable.Count
    hasActionableProblems = ($actionable.Count -gt 0)
    trustedAuthors = @($trusted | Sort-Object)
  }
  if ($attention.Count -gt 0) { $result.attention = @($attention | Sort-Object @{Expression={ if($_.problemCodes.Count -gt 0){0}else{1} }}, number) }
  if ($IncludeHealthy) { $result.healthyPullRequests = @($healthy | Sort-Object number) }
  [pscustomobject]$result | ConvertTo-Json -Depth 12 -Compress
} finally {
  Remove-Item Env:GH_TOKEN,Env:BOTNEXUS_GIT_AUTH_HEADER -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
}
