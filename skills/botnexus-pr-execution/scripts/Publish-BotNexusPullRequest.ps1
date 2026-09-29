<#
.SYNOPSIS
  One-shot conventions-compliant PR shipper for Sytone/botnexus.

.DESCRIPTION
  Replaces the hand-rolled tmp/ship-<n>.ps1 + tmp/pr-<n>.ps1 pair that was being
  written per PR (56 such files accumulated in tmp before this existed). Takes a
  structured body file, and emits:

    1. a Conventional-Commits commit subject + why-body + trailers
       (Refs / Validated-by / Co-authored-by), and
    2. a PR whose title matches that subject exactly and whose body is the
       template-conformant markdown.

  Enforces docs/development/pr-and-commit-conventions.md BEFORE spending a push:
  validates the title, the required sections for the change type, the issue link,
  and UI evidence when the diff touches rendered UI. A malformed PR is caught
  locally in milliseconds instead of by CI minutes later.

  Also runs the mandatory scope check (git diff --stat origin/main) and refuses
  to push a contaminated worktree. Use -WhatIf for the canonical non-mutating
  preflight; -DryRun remains as a compatibility alias.

  Emits compact JSONL lifecycle events with stable event, status, mode, code,
  message, and data fields. Validation rejection events name the defective PR
  property and are followed by a non-zero exit.

.PARAMETER Worktree   Path to the worktree holding the work.
.PARAMETER Type       Conventional Commits type (feat/fix/docs/...).
.PARAMETER Scope      Optional scope, e.g. '#2317' or 'portal'.
.PARAMETER Subject    Lowercase imperative description, no trailing period.
.PARAMETER Issue      Issue number this closes.
.PARAMETER BodyFile   Markdown file containing the PR body (template sections).
.PARAMETER Why        1-3 line commit-body rationale. Defaults to the Summary section.
.PARAMETER Validated  Validation evidence string, e.g. 'Gateway.Tests 4026/0/1'.
.PARAMETER Breaking   Marks a breaking change (appends '!' to the type).
.PARAMETER Draft      Open the PR as a draft.
.PARAMETER SkipScope  Bypass the scope check (requires an explicit reason).
.PARAMETER BaseBranch Immediate PR base. Defaults to main; upper native stack layers name their parent branch.
.PARAMETER StackLayer Required with a non-main BaseBranch. Enables gh/gh-stack preflight and stack safety checks.
.PARAMETER NoScrubPaths Opt OUT of the default machine-local path scrub (#2699). Only for the
                      rare reviewed case where a literal path is genuinely required; the
                      run then falls back to reject-with-a-report on any leak.
.PARAMETER WhatIf     Canonical preview. Validate and print everything, push nothing.
.PARAMETER DryRun     Compatibility alias for -WhatIf.

.EXAMPLE
  pwsh -NoProfile -File New-BotNexusPullRequest.ps1 -Worktree Q:/repos/botnexus-wt/fix-2317-x -Type fix -Scope '#2317' -Subject 'latch the route guard' -Issue 2317 -BodyFile body.md -Validated 'BlazorClient.Tests 914/0' -WhatIf
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Worktree,
  [Parameter(Mandatory)][string]$Type,
  [string]$Scope,
  [Parameter(Mandatory)][string]$Subject,
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][string]$BodyFile,
  [string]$Why,
  [string]$Validated,
  [switch]$Breaking,
  [switch]$Draft,
  [switch]$MetadataOnly,
  [switch]$DraftMetadataOnly,
  [string]$DraftReasonCode = 'explicit-draft',
  [string]$DraftReasonDetail = 'The publisher was invoked with -Draft; the owning conversation must explicitly clear this reason after confirming completion.',
  [string[]]$ResolveDraftReasonCode = @(),
  [switch]$SkipScope,
  [string]$BaseBranch = 'main',
  [switch]$StackLayer,
  [string]$PartialWork,
  [switch]$NoScrubPaths,
  [switch]$WhatIf,
  [switch]$DryRun,
  [Parameter(Mandatory)][ValidateSet('Create','Update')][string]$Operation,
  [int]$PullRequestNumber = 0,
  [string]$ContractPath = ''
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ContractPath)) {
  $candidateContract = Join-Path $Worktree '.github/pr-contract.json'
  $mainContract = 'Q:/repos/botnexus/.github/pr-contract.json'
  $skillContract = Join-Path (Split-Path -Parent $PSScriptRoot) 'reference/pr-contract.json'
  $ContractPath = if (Test-Path -LiteralPath $candidateContract) { $candidateContract } elseif (Test-Path -LiteralPath $mainContract) { $mainContract } elseif (Test-Path -LiteralPath $skillContract) { $skillContract } else { '' }
}
if ([string]::IsNullOrWhiteSpace($ContractPath)) { throw 'Canonical PR contract is unavailable in the candidate worktree, current main checkout, and skill bootstrap snapshot.' }
$PreviewOnly = [bool]($DryRun -or $WhatIf)
$RunId = [guid]::NewGuid().ToString('N')
$PublicationBodyFile = $null

function Write-PrEvent {
  param(
    [Parameter(Mandatory)][string]$Event,
    [Parameter(Mandatory)][ValidateSet('started','passed','rejected','completed')][string]$Status,
    [string]$Code = '',
    [string]$Message = '',
    [hashtable]$Data = @{}
  )
  $record = [ordered]@{
    timestampUtc = [DateTimeOffset]::UtcNow.ToString('O')
    runId = $RunId
    event = $Event
    status = $Status
    mode = $(if ($PreviewOnly) { 'whatif' } else { 'live' })
    code = $Code
    message = $Message
    data = $Data
  }
  Write-Host ($record | ConvertTo-Json -Compress -Depth 8)
}

function Get-RejectionCode([string]$Message) {
  switch -Regex ($Message) {
    '^type ' { 'invalid-type'; break }
    '^subject ' { 'invalid-subject'; break }
    '^title ' { 'invalid-title'; break }
    '^body ' { 'invalid-body'; break }
    'issue|closing keyword|auto-closing|PartialWork' { 'invalid-issue-link'; break }
    'validation counts' { 'invalid-validation'; break }
    'worktree|nothing staged|nothing to ship|contaminated' { 'invalid-change-set'; break }
    'base branch|base .* ancestor|stack' { 'invalid-base'; break }
    'scratch' { 'invalid-scratch-content'; break }
    'local path|internal-only|internal material' { 'unsafe-content'; break }
    default { 'validation-failed' }
  }
}

Write-PrEvent -Event 'pr.validation' -Status 'started' -Message 'Validating pull request properties and candidate tree.' -Data @{
  issue = $Issue; type = $Type; scope = $Scope; subject = $Subject; baseBranch = $BaseBranch
}

# Shared with the gh issue/pr comment paths -- see Import-LocalPathScrubber.ps1 for why the rules
# live outside this script rather than inline.
. (Join-Path $PSScriptRoot 'Import-LocalPathScrubber.ps1')
$RepoSlug = 'Sytone/botnexus'
$BotEmail = '293187211+agent-farnsworth[bot]@users.noreply.github.com'
$Contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
$AllowedTypes = @($Contract.allowedTypes)

function Fail($msg) {
  Write-PrEvent -Event 'pr.validation' -Status 'rejected' -Code (Get-RejectionCode $msg) -Message $msg
  Write-Error "PR REJECTED: $msg"
  exit 1
}

# An ENVIRONMENTAL precondition is unavailable (no network, unreachable remote, unauthenticated
# gh) as opposed to a genuine policy rejection OF THE CHANGE. Distinct sentinel so a caller -- and
# the test suite -- can tell "this PR is bad" apart from "this machine could not check" (#3247).
#
# It still exits NON-ZERO. An unverifiable gate must never be reported as a passing one; the point
# of the separate sentinel is legibility of the cause, not leniency about the outcome.
#
# The machine-readable marker is emitted as its OWN short line, separately from the human text.
# PowerShell's Write-Error renders through the error formatter, which HARD-WRAPS at the host's
# console width -- so a caller matching 'ENVIRONMENT UNAVAILABLE' in captured output gets a hit or
# a miss depending on how wide the terminal happened to be. That is the same class of defect as
# the one this issue is about (a result that depends on the environment rather than the input),
# and it is why the token is short, single-word and printed on a line of its own.
function FailEnv($msg) {
  Write-PrEvent -Event 'pr.validation' -Status 'rejected' -Code 'environment-unavailable' -Message $msg
  Write-Host 'PR-REJECTED-ENV'
  Write-Error "PR REJECTED: ENVIRONMENT UNAVAILABLE - $msg"
  exit 1
}

# --- scratch classification (#3249, #3250) -------------------------------------------------
# ONE predicate, consumed by both the -DryRun preview and the real ship path. Two copies would
# drift, and a preview that disagreed with the ship would be worse than no preview: it would
# report "all checks passed" for a tree that is about to be refused (#3250).
function Get-ScratchOffenders {
  param([string[]]$Paths)
  $p = @($Paths | Where-Object { $_ })
  [pscustomobject]@{
    # Scratch artefacts written into the worktree's tmp/ folder. A bare `git add -A` once
    # committed tmp/body-<n>.md into PR #2337.
    Tmp  = @($p | Where-Object { $_ -like 'tmp/*' })
    # Scratch does not only live under tmp/. PR #3249 put `tmp-gate.err` -- 71 lines of
    # `az storage blob download-batch` progress output -- at the REPOSITORY ROOT, where a
    # tmp/-prefixed check cannot see it. A redirect typo (`> tmp-gate.err` instead of
    # `> tmp/gate.err`) is enough, and the name is plausible enough to survive a skim.
    #
    # Match on scratch SHAPE, and only at the root: a real `tests/fixtures/sample.log` is
    # legitimate and must pass. A guard that over-rejects becomes one callers route around,
    # which is worse than the leak it was added to stop.
    Root = @($p |
      Where-Object { $_ -notmatch '/' } |
      Where-Object { $_ -match '^(tmp|temp|scratch)[-_.]' -or $_ -match '\.(err|out|log|tmp|bak)$' })
  }
}

# Identical refusal text on both paths, so a caller never learns two vocabularies for one
# condition and cannot conclude the preview and the ship disagree about the rule.
function Format-ScratchRefusal {
  param([ValidateSet('tmp','root')][string]$Kind, [string[]]$Paths)
  if ($Kind -eq 'tmp') {
    return "refusing to ship: scratch files staged under tmp/: $($Paths -join ', ')"
  }
  return ("refusing to ship: scratch-shaped file(s) at the repository root: $($Paths -join ', ')`n" +
          "  These are capture artifacts, not source. Delete them, or move them under tmp/ which is excluded.`n" +
          "  (PR #3249 near-miss: a redirect typo put 71 lines of gate progress output at the root.)")
}

# Reconstructs, WITHOUT MUTATING ANYTHING, the path set the ship path's index will hold after
# its `git add -A -- . :(exclude)tmp :(exclude)tmp/*` (#3250).
#
# Two rules, and both must match the staging pathspec exactly or the preview lies:
#   * already-staged paths count even if excluded later -- `git add` never UNstages, so a path
#     someone staged by hand survives into the commit regardless of the exclusion.
#   * unstaged/untracked paths count only if the exclusion would NOT drop them.
#
# Read-only by construction: `diff --cached` and `status --porcelain` neither write the index
# nor touch the worktree, so a dry run leaves `git status --porcelain -uall` byte-identical.
function Get-ShipIndexPreview {
  # Paths already in the index. These ship no matter what the staging pathspec excludes.
  $staged = @(Invoke-Git @('diff','--cached','--name-only') | Where-Object { $_ })

  # Everything else git can see, including untracked files inside untracked directories (-uall).
  # Porcelain v1 is `XY <path>`; a rename reads `R  old -> new`, and it is the NEW path that
  # would be committed.
  $visible = @(Invoke-Git @('status','--porcelain','-uall') |
    Where-Object { $_ } |
    ForEach-Object { ($_ -replace '^..\s+','') -replace '^.* -> ','' } |
    ForEach-Object { $_.Trim('"') })

  # The ship path's own exclusion, stated ONCE here so the two cannot drift apart.
  $wouldStage = @($visible | Where-Object { $_ -ne 'tmp' -and $_ -notlike 'tmp/*' })

  @($staged + $wouldStage) | Sort-Object -Unique
}

# #4058: model the exact add -A result in a disposable index, never the caller's index.
# Starting from the real index preserves already-staged excluded tmp paths. Native Git
# owns rename/delete/ignore semantics; no porcelain path parsing defines this candidate.
function Get-ShipCandidateTree {
  $savedIndex = [Environment]::GetEnvironmentVariable('GIT_INDEX_FILE', 'Process')
  $indexPresent = Test-Path Env:GIT_INDEX_FILE
  $indexPath = (Invoke-Git @('rev-parse','--path-format=absolute','--git-path','index')) -join ''
  # Until independently proven, reject nonordinary indexes rather than guessing.
  if (-not (Test-Path -LiteralPath $indexPath)) { Fail 'unsupported candidate index: missing index.' }
  if ((Invoke-Git @('rev-parse','--shared-index-path')) -join '') { Fail 'unsupported candidate index: split index.' }
  $indexEntries = @(Invoke-Git @('ls-files','--stage','--sparse'))
  if (@($indexEntries | Where-Object { $_ -match '^040000 ' -or $_ -match '^[0-9]+ [0-9a-f]+ [123]\t' }).Count) {
    Fail 'unsupported candidate index: sparse directory or unresolved entries.'
  }
  $temporaryIndex = Join-Path (Split-Path $indexPath) ('4058-candidate-' + [guid]::NewGuid().ToString('N') + '.index')
  try {
    if (Test-Path -LiteralPath $indexPath) { Copy-Item -LiteralPath $indexPath -Destination $temporaryIndex }
    $env:GIT_INDEX_FILE = $temporaryIndex
    if (-not (Test-Path -LiteralPath $temporaryIndex)) { Invoke-Git @('read-tree','HEAD') | Out-Null }
    Invoke-Git @('add','-A','--','.',':(exclude)tmp',':(exclude)tmp/*') | Out-Null
    (Invoke-Git @('write-tree')) -join ''
  }
  finally {
    if ($indexPresent) { $env:GIT_INDEX_FILE = $savedIndex }
    else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    foreach ($file in @($temporaryIndex, "$temporaryIndex.lock")) {
      if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
  }
}

function Assert-ShipCandidate {
  param([string]$ExpectedHead = $CheckedHead)
  $head = (Invoke-Git @('rev-parse','HEAD')) -join ''
  $base = (Invoke-Git @('rev-parse',$BaseRef)) -join ''
  $main = (Invoke-Git @('rev-parse','origin/main')) -join ''
  $branchNow = (Invoke-Git @('rev-parse','--abbrev-ref','HEAD')) -join ''
  if ($head -ne $ExpectedHead -or $base -ne $CheckedBase -or $main -ne $CheckedMain -or $branchNow -ne $Branch) {
    Fail 'checked candidate changed: HEAD, branch or base moved after the evidence gates. Revalidate before shipping.'
  }
  if ((Get-ShipCandidateTree) -ne $CheckedTree) {
    Fail 'checked candidate changed: pending content differs from the evidence-gated tree. Revalidate before shipping.'
  }
}

# Commit from the pinned tree in a second private index. A writer racing the real
# index/worktree after the final check cannot smuggle unchecked bytes into this commit.
# The real index is already staged and checked; this preserves normal Git commit/message behavior.
function Invoke-CheckedCommit {
  param([switch]$Amend)
  Assert-ShipCandidate
  $expectedParents = if ($Amend) { (Invoke-Git @('log','-1','--format=%P',$CheckedHead)) -join '' } else { $CheckedHead }
  $savedIndex = [Environment]::GetEnvironmentVariable('GIT_INDEX_FILE', 'Process')
  $indexPresent = Test-Path Env:GIT_INDEX_FILE
  $indexPath = (Invoke-Git @('rev-parse','--path-format=absolute','--git-path','index')) -join ''
  $commitIndex = Join-Path (Split-Path $indexPath) ('4058-commit-' + [guid]::NewGuid().ToString('N') + '.index')
  try {
    $env:GIT_INDEX_FILE = $commitIndex
    Invoke-Git @('read-tree',$CheckedTree) | Out-Null
    $commitArgs = @('commit','--no-verify','-m',$CommitMsg)
    if ($Amend) { $commitArgs += '--amend' }
    Invoke-Git $commitArgs | Out-Null
  }
  finally {
    if ($indexPresent) { $env:GIT_INDEX_FILE = $savedIndex }
    else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    foreach ($file in @($commitIndex, "$commitIndex.lock")) {
      if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
    }
  }
  $newHead = (Invoke-Git @('rev-parse','HEAD')) -join ''
  $newParents = (Invoke-Git @('log','-1','--format=%P',$newHead)) -join ''
  if ($newParents -cne $expectedParents -or
      ((Invoke-Git @('rev-parse',"$newHead^{tree}")) -join '') -ne $CheckedTree -or
      ((Invoke-Git @('rev-parse','--abbrev-ref','HEAD')) -join '') -cne $Branch) {
    Fail 'checked candidate changed: committed history, branch or tree differs from the evidence-gated candidate.'
  }
  $script:CommittedHead = $newHead
}

# ------------------------------------------------------------ 0. worktree
# The worktree was previously trusted blind (#2928). When a concurrent lane removed it
# mid-flight, every `git -C <worktree>` call failed, nothing was pushed, and the script
# still fell through to `gh pr create` and returned ok=$true with an empty PR field --
# so the caller recorded a PR that never left the machine. A fail-open in the one script
# whose whole purpose is to prevent drift is worse than a loud error. Check it FIRST,
# before any other work, so the failure names the real cause instead of a downstream symptom.
if (-not (Test-Path -LiteralPath $Worktree)) { Fail "worktree path does not exist: $Worktree" }
$null = & git -C $Worktree rev-parse --is-inside-work-tree 2>&1
if ($LASTEXITCODE -ne 0) { Fail "path is not a git worktree: $Worktree" }

# Every git step below is load-bearing: a failed add/commit/push must abort rather than
# fall through to PR creation. Wrap them so no call site can forget the exit-code check.
function Invoke-Git {
  param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure, [switch]$Authenticated)
  # #3070: credentials are supplied PER INVOCATION and never persisted. `git -c` puts the
  # header in this one process's argv; nothing reaches .git/config, so there is no window
  # in which a failed ship can strand a live token on disk. Redacted from any error text
  # below, because Fail prints the full argv.
  $pre = @()
  if ($Authenticated -and $env:BOTNEXUS_GIT_AUTH_HEADER) {
    # Destination preservation must not leak the bot token to an arbitrary pushurl.
    # Check Git's effective URLs (including insteadOf/pushInsteadOf expansion), then
    # scope the header to GitHub and prohibit redirects on this authenticated call.
    $targets = @(& git -C $Worktree remote get-url --push --all origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or $targets.Count -eq 0 -or
        @($targets | Where-Object { $_ -notmatch '^https://github\.com/Sytone/botnexus(?:\.git)?/?$' }).Count) {
      Fail 'authenticated push target must be the credential-free Sytone/botnexus HTTPS URL; destination was not changed.'
    }
    $pre = @('-c', "http.https://github.com/.extraHeader=$env:BOTNEXUS_GIT_AUTH_HEADER", '-c', 'http.followRedirects=false')
  }
  # Native stderr is diagnostic, never OID/path data. Do not merge warnings into stdout.
  $out = & git -C $Worktree @pre @Arguments 2>$null
  if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
    Fail "git $($Arguments -join ' ') failed (exit $LASTEXITCODE) in ${Worktree}:`n  $($out -join "`n  ")"
  }
  $out
}

# Protect title/body refusals too, not only the later Git gates (#3923).
$botAuth = Join-Path $PSScriptRoot 'Use-FarnsworthBot.ps1'
Push-Location $Worktree
try {
# ---------------------------------------------------------------- 1. title
if ($Type -notin $AllowedTypes) { Fail "type '$Type' not one of: $($AllowedTypes -join ', ')" }
if ($Subject -match '\.$')      { Fail "subject must not end with a period." }
$firstWord = ($Subject -split '\s+')[0] -replace '[^A-Za-z]',''
# Sentence-cased prose is rejected; acronyms/CamelCase identifiers (CLI, SignalR) are fine.
if ($firstWord -cmatch '^[A-Z][a-z]+$') { Fail "subject should be lowercase imperative - got '$firstWord'." }

$scopePart = if ($Scope) { "($Scope)" } else { '' }
$bang      = if ($Breaking) { '!' } else { '' }
$Title     = "$Type$scopePart$bang" + ": " + $Subject
if ($Title.Length -gt 72) { Fail "title is $($Title.Length) chars, limit 72. It becomes the squash subject.`n  $Title" }
if ($Operation -eq 'Update' -and $PullRequestNumber -le 0) { Fail 'update operation requires PullRequestNumber.' }
if ($Operation -eq 'Create' -and $PullRequestNumber -gt 0) { Fail 'create operation must not specify PullRequestNumber.' }

# ---------------------------------------------------------------- 2. body
if (-not (Test-Path $BodyFile)) { Fail "body file not found: $BodyFile" }
$Body = Get-Content $BodyFile -Raw
if ([string]::IsNullOrWhiteSpace($Body)) { Fail "body file is empty: $BodyFile" }

# Strip HTML comments so unfilled template guidance never counts as a real section.
$visible  = [regex]::Replace($Body, '(?s)<!--.*?-->', '')
$headings = [regex]::Matches($visible, '(?m)^#{1,4}\s+(.+?)\s*$') |
            ForEach-Object { $_.Groups[1].Value.Trim().ToLower() }

$required = switch ($Type) {
  'fix'                          { @('summary','root cause','changes','tests','validation','risk & rollback') }
  { $_ -in 'docs','chore','style','ci','build' } { @('summary','changes','validation','risk & rollback') }
  default                        { @('summary','changes','tests','validation','risk & rollback') }
}
$missing = $required | Where-Object { $_ -notin $headings }
if ($missing) { Fail "body is missing required section(s) for a '$Type' PR: $($missing -join ', ')" }
$contractValidator = Join-Path $PSScriptRoot 'Test-BotNexusPullRequest.ps1'
$contractResult = & $contractValidator -Title $Title -Body $Body -Issue $Issue -ContractPath $ContractPath -PartialWork:([bool]$PartialWork)
if (-not $contractResult.valid) { Fail ('body failed canonical PR contract: ' + (($contractResult.violations | ForEach-Object message) -join '; ')) }

# The PR BODY must carry an auto-closing keyword bound to THIS issue. `Refs` is deliberately NOT
# accepted here: GitHub does not auto-close on `Refs`, so a `Refs`-linked PR merges and silently
# leaves its issue open forever. That is not hypothetical -- 132 of 370 merged PRs (36%) used
# `Refs` in the body, and on 2026-08-12 an audit found 27 issues sitting OPEN on top of merged,
# verified-on-main work, the oldest stranded for three weeks.
#
# The convention doc means two DIFFERENT artifacts and this gate had conflated them:
#   PR body        -> `Closes #N`  (auto-closes on merge)
#   commit trailer -> `Refs: #N`   (provenance only; emitted below, never auto-closes)
# The number must match -Issue: `Closes #<other>` links a PR to an issue it does not resolve.
# `-PartialWork <reason>` is the ONE sanctioned exception, and it is deliberately not a bare switch:
# it demands a written reason naming the unmet acceptance clause, and it REQUIRES the body to carry
# `Refs #<issue>` so the link still exists. This exists because the alternative observed in practice
# is worse -- an agent blocked by this gate either writes `Closes` on work that does not close the
# issue (auto-closing it on merge with clauses unmet, which is exactly the mis-close #2104 suffered)
# or abandons the tooling and hand-rolls `gh pr create`, losing every other check here.
if ($PartialWork) {
  if ($visible -match '(?i)\b(closes|fixes|resolves)\s+#\d+') {
    Fail "-PartialWork was supplied but the body still uses an auto-closing keyword. Partial work must use 'Refs #$Issue' so the issue stays open."
  }
  if ($visible -notmatch "(?i)\brefs:?\s+#$Issue\b") {
    Fail "-PartialWork requires the body to link the issue with 'Refs #$Issue' so the work is still traceable."
  }
  Write-Host "NOTE: opening as PARTIAL work on #$Issue (will NOT auto-close). Reason: $PartialWork" -ForegroundColor Yellow
}
else {
$closeMatch = [regex]::Match($visible, '(?i)\b(closes|fixes|resolves)\s+#(\d+)')
if (-not $closeMatch.Success) {
  if ($visible -match '(?i)\brefs\s+#\d+') {
    Fail "body links the issue with 'Refs', which does NOT auto-close it on merge. Use 'Closes #$Issue' in the PR body; the 'Refs: #$Issue' commit trailer is emitted automatically. If the work genuinely does not resolve #$Issue, open it against the issue it does resolve."
  }
  Fail "body must link the issue with an auto-closing keyword (e.g. 'Closes #$Issue')."
}
if ([int]$closeMatch.Groups[2].Value -ne $Issue) {
  Fail "body closes #$($closeMatch.Groups[2].Value) but -Issue is $Issue. The closing keyword must name the issue this PR resolves."
}
}

# ------------------------------------------------- 2b. machine-local path leak
# The body is posted verbatim, so any local path an agent pasted in ships to a public
# repo (7 already-merged PRs leaked one before this gate existed). Scrubbing is now the
# DEFAULT (#2699): a redaction that must be requested is skipped precisely when the author
# is in a hurry, which is when it is most needed. -NoScrubPaths opts OUT, and then the old
# reject-with-a-report posture applies so opting out can never publish a leak silently.
function Assert-NoLocalPath([hashtable]$Parts) {
  $report = @()
  foreach ($k in $Parts.Keys) {
    $hits = Get-LocalPathMatch -Text $Parts[$k]
    if ($hits.Count) { $report += (Format-LocalPathReport -Match $hits -Label $k) }
  }
  if ($report.Count) {
    Fail ("content contains machine-local paths (username / disk topology would ship to a public repo).`n" +
          ($report -join "`n") +
          "`n  Rewrite them as prose, or drop -NoScrubPaths to substitute the generic tokens.")
  }
}

if (-not $NoScrubPaths) {
  $Title = Remove-LocalPath -Text $Title
  $Body  = Remove-LocalPath -Text $Body
  # Substitution changes length, so the squash-subject limit must be re-checked.
  if ($Title.Length -gt 72) { Fail "title is $($Title.Length) chars after path scrubbing, limit 72.`n  $Title" }
  $visible = [regex]::Replace($Body, '(?s)<!--.*?-->', '')
}
Assert-NoLocalPath @{ title = $Title; body = $Body }

# ------------------------------------------------- 2c. internal-only URL leak
# Same rationale as the path gate above: the body is posted verbatim to a PUBLIC repo, and an
# internal engineering-portal link is meaningless to most readers while leaking internal topology.
# Jon directed this 2026-08-13 after internal TSG links landed in main.bicep, issue #3106 and two
# PR comments and had to be scrubbed after publication.
#
# This REJECTS rather than silently rewriting: unlike a machine-local path, the correct replacement
# is editorial (name the article slug or TSG title so a reader with access can still find it), and
# only the author knows the right wording. A silent substitution would produce a dangling reference.
#
# Deliberately NOT matched: `learn.microsoft.com`, and public `aka.ms` shortlinks such as the
# azcopy download used in the runner Dockerfile. Those resolve for everyone.
function Assert-NoInternalReference([hashtable]$Parts) {
$internalUrlPatterns = @(
  @{ Pattern = '(?i)\beng\.ms\b';                      Hint = 'internal engineering docs portal' }
  @{ Pattern = '(?i)\b[\w-]+\.visualstudio\.com\b';     Hint = 'internal Azure DevOps' }
  @{ Pattern = '(?i)\bmicrosoft\.sharepoint\.com\b';    Hint = 'internal SharePoint' }
  @{ Pattern = '(?i)\bmsit\.[\w-]+\.com\b';             Hint = 'internal MSIT host' }
  @{ Pattern = '(?i)\bportal\.microsoftgeneva\.com\b';  Hint = 'internal Geneva portal' }
  @{ Pattern = '(?i)\bicm\.ad\.msft\.net\b';            Hint = 'internal IcM' }
  # A hostname is not the only way to disclose internal material. Jon, 2026-08-13: "a vague
  # reference is just as bad, this still counts as exposing internal information". Stripping the
  # URL but keeping `.../azure-container-apps-tsg/firstparty/1pappaccessaad` identifies the
  # document just as precisely while being useless to a reader who cannot open it. So the
  # SHAPE of an internal doc reference is rejected too, not merely the host.
  @{ Pattern = '(?i)\bTSG\b';                          Hint = 'internal troubleshooting-guide reference' }
  @{ Pattern = '(?i)\bfirst-?party\s+(guidance|doc|TSG|article)'; Hint = 'internal doc classification' }
  @{ Pattern = '(?i)\binternal\s+(engineering\s+docs?\s+portal|docs?\s+portal|wiki)'; Hint = 'internal doc portal reference' }
  @{ Pattern = '(?i)\bsearch the internal\b';           Hint = 'pointer to an internal source' }
  @{ Pattern = '(?i)@service\.microsoft\.com\b';        Hint = 'internal service contact alias' }
)
$internalHits = @()
foreach ($key in $Parts.Keys) {
  $src = @{ Label = $key; Text = $Parts[$key] }
  if (-not $src.Text) { continue }
  foreach ($p in $internalUrlPatterns) {
    foreach ($m in [regex]::Matches($src.Text, $p.Pattern)) {
      $internalHits += "  $($src.Label): '$($m.Value)' ($($p.Hint))"
    }
  }
}
if ($internalHits.Count) {
  Fail ("content contains internal-only references, which are meaningless to a reader of this public repo `n" +
        "and disclose internal material to one who should not see it.`n" +
        (($internalHits | Select-Object -Unique) -join "`n") +
        "`n  A stripped URL is NOT enough: an article slug, doc-tree path or 'see the internal guidance'" +
        "`n  pointer identifies the source just as precisely. State the technical reason instead, so the" +
        "`n  change is justified by something a reader can actually verify from the code.")
}

}
Assert-NoInternalReference @{ title = $Title; body = $Body; validated = $Validated }

# ---------------------------------------------------------- readiness gate
# Persist every draft reason in the PR body before evaluating any disposition gate. GitHub stores
# only a Boolean draft flag, which is insufficient for deterministic reconciliation after a restart
# or when an external blocker clears.
$readinessValidator = Join-Path $PSScriptRoot 'Test-BotNexusPullRequestReadiness.ps1'
$readiness = & $readinessValidator -Body $Body -ExplicitDraft:$Draft -DraftReasonCode $DraftReasonCode -DraftReasonDetail $DraftReasonDetail -ResolveDraftReasonCode $ResolveDraftReasonCode
$Body = [string]$readiness.body
$OpenAsDraft = -not [bool]$readiness.ready
if ($Operation -eq 'Create' -and $OpenAsDraft -and -not $Draft) {
  Fail ("publication-not-ready: resolve these blockers before creating a PR: " + ((@($readiness.reasons) | ForEach-Object { "$($_.code): $($_.detail)" }) -join '; '))
}
if ($Operation -eq 'Create' -and $Draft) {
  $exceptionalDraftCodes=@('human-requested-early-review','external-coordination-blocker','recovery-handoff','maintainer-safety-hold')
  if([string]::IsNullOrWhiteSpace($DraftReasonCode) -or [string]::IsNullOrWhiteSpace($DraftReasonDetail) -or $DraftReasonCode -notin $exceptionalDraftCodes){
    Fail ("exceptional-draft-reason-required: new draft PRs require one of [" + ($exceptionalDraftCodes -join ', ') + '] and concrete detail.')
  }
}
if ($OpenAsDraft) {
  Write-Host ("readiness gate: EXCEPTIONAL DRAFT -- " + ((@($readiness.reasons) | ForEach-Object { "$($_.code): $($_.detail)" }) -join '; ')) -ForegroundColor Yellow
}

# Metadata-only updates repair an existing PR body/readiness record without rewriting a validated
# branch. They are fail-closed: exact author/title/head/base must match, the body must pass the
# canonical contract above, and a ready PR must already have acceptable terminal checks. This mode
# never fetches/rebases, stages, commits, pushes, labels, releases a claim, or merges.
if ($MetadataOnly) {
  if ($Operation -ne 'Update' -or $PullRequestNumber -le 0 -or $DraftMetadataOnly) {
    Fail '-MetadataOnly requires Update-BotNexusPullRequest.ps1 with a pull request number and cannot be combined with -DraftMetadataOnly.'
  }

  $Branch = (Invoke-Git @('rev-parse','--abbrev-ref','HEAD')) -join ''
  $LocalHead = (Invoke-Git @('rev-parse','HEAD')) -join ''
  & $botAuth -RepoPath $Worktree | Out-Null
  $who = (& gh api user --jq '.login' 2>$null)
  if (-not $who -or $who -like '*Resource not accessible*') {
    $repos = (& gh api installation/repositories --jq '.repositories[].full_name' 2>$null)
    if (-not ($repos -and (@($repos) -contains $RepoSlug -or @($repos) -contains $RepoSlug.ToLowerInvariant()))) {
      Fail 'GitHub identity precondition failed for metadata-only persistence.'
    }
  }
  elseif ($who -notin @('agent-farnsworth[bot]','app/agent-farnsworth')) {
    Fail "GitHub identity precondition failed: gh is authenticated as '$who', expected agent-farnsworth[bot]."
  }

  $existing = (& gh pr view $PullRequestNumber --repo $RepoSlug --json number,title,body,headRefName,headRefOid,baseRefName,author,isDraft,mergeable,statusCheckRollup,url | ConvertFrom-Json)
  if (-not $existing -or [int]$existing.number -ne $PullRequestNumber) { Fail "metadata-only update refused: PR #$PullRequestNumber is missing." }
  if ($existing.headRefName -cne $Branch -or $existing.headRefOid -cne $LocalHead -or $existing.baseRefName -cne $BaseBranch) {
    Fail "metadata-only update refused: branch, base, or exact head SHA does not match PR #$PullRequestNumber."
  }
  if ($existing.author.login -notin @('agent-farnsworth[bot]','app/agent-farnsworth') -or $existing.title -cne $Title) {
    Fail "metadata-only update refused: author or title does not match PR #$PullRequestNumber."
  }
  if (-not $OpenAsDraft -and -not [bool]$existing.isDraft) {
    $unacceptableChecks = @($existing.statusCheckRollup | Where-Object {
      ([string]$_.status).ToUpperInvariant() -ne 'COMPLETED' -or
      ([string]$_.conclusion).ToUpperInvariant() -notin @('SUCCESS','NEUTRAL','SKIPPED')
    })
    if ([string]$existing.mergeable -ne 'MERGEABLE') { Fail "metadata-only update refused: PR #$PullRequestNumber is not currently mergeable." }
    if (@($existing.statusCheckRollup).Count -eq 0) { Fail "metadata-only update refused: PR #$PullRequestNumber has no check results." }
    if ($unacceptableChecks.Count -gt 0) { Fail ("metadata-only update refused: PR #$PullRequestNumber has pending or unacceptable checks: " + (($unacceptableChecks | ForEach-Object { $_.name }) -join ', ')) }
  }

  if ($PreviewOnly) {
    Write-PrEvent -Event 'pr.validation' -Status 'passed' -Code 'metadata-ready' -Message 'Validated PR metadata can be updated without branch mutation.' -Data @{
      number = $PullRequestNumber; title = $Title; branch = $Branch; baseBranch = $BaseBranch; head = $LocalHead; draft = $OpenAsDraft
    }
    return
  }

  $PublicationBodyFile = Join-Path ([IO.Path]::GetTempPath()) ("botnexus-pr-body-$RunId.md")
  [IO.File]::WriteAllText($PublicationBodyFile, $Body, [Text.UTF8Encoding]::new($false))
  & gh pr edit $PullRequestNumber --repo $RepoSlug --base $BaseBranch --title $Title --body-file $PublicationBodyFile | Out-Null
  if ($LASTEXITCODE -ne 0) { Fail "metadata-only update failed for PR #$PullRequestNumber." }
  $stored = (& gh pr view $PullRequestNumber --repo $RepoSlug --json title,body,headRefName,headRefOid,baseRefName,author,isDraft,url | ConvertFrom-Json)
  $storedContract = & $contractValidator -Title ([string]$stored.title) -Body ([string]$stored.body) -Issue $Issue -ContractPath $ContractPath -PartialWork:([bool]$PartialWork)
  $expectedBody = $Body -replace "`r`n", "`n"
  $storedBody = ([string]$stored.body) -replace "`r`n", "`n"
  if (-not $storedContract.valid -or $storedBody -cne $expectedBody -or $stored.title -cne $Title -or
      $stored.headRefName -cne $Branch -or $stored.headRefOid -cne $LocalHead -or
      $stored.baseRefName -cne $BaseBranch -or $stored.author.login -notin @('agent-farnsworth[bot]','app/agent-farnsworth') -or
      [bool]$stored.isDraft -ne $OpenAsDraft) {
    Fail 'published-but-nonconformant: metadata-only readback failed contract, identity, state, body, branch, base, or SHA comparison.'
  }
  Write-PrEvent -Event 'pr.publication' -Status 'completed' -Code 'metadata-updated' -Message 'Pull request metadata was updated without branch mutation.' -Data @{
    number = $PullRequestNumber; url = $stored.url; title = $Title; branch = $Branch; baseBranch = $BaseBranch; head = $LocalHead; draft = $OpenAsDraft
  }
  [pscustomobject]@{ ok=$true; metadataOnly=$true; url=$stored.url; number=$PullRequestNumber; title=$Title; branch=$Branch; baseBranch=$BaseBranch; head=$LocalHead; draft=$OpenAsDraft }
  return
}

# Legacy drafts need a persisted reason before any rebase, repair, or promotion decision. This
# deliberately narrow mode updates only managed draft metadata. It does not fetch/rebase, stage,
# commit, push, label, release a claim, inspect checks, evaluate mergeability, or mark a PR ready.
# The ordinary update path below retains every publication and promotion gate.
if ($DraftMetadataOnly) {
  if ($Operation -ne 'Update' -or -not $Draft -or $PullRequestNumber -le 0) {
    Fail '-DraftMetadataOnly requires Update-BotNexusPullRequest.ps1 with -Draft and a pull request number.'
  }
  if (-not $OpenAsDraft -or $DraftReasonCode -notin @($readiness.reasons.code)) {
    Fail "-DraftMetadataOnly did not produce the required '$DraftReasonCode' reason."
  }

  $Branch = (Invoke-Git @('rev-parse','--abbrev-ref','HEAD')) -join ''
  $LocalHead = (Invoke-Git @('rev-parse','HEAD')) -join ''
  & $botAuth -RepoPath $Worktree | Out-Null
  $who = (& gh api user --jq '.login' 2>$null)
  if (-not $who -or $who -like '*Resource not accessible*') {
    $repos = (& gh api installation/repositories --jq '.repositories[].full_name' 2>$null)
    if (-not ($repos -and (@($repos) -contains $RepoSlug -or @($repos) -contains $RepoSlug.ToLowerInvariant()))) {
      Fail 'GitHub identity precondition failed for draft metadata persistence.'
    }
  }
  elseif ($who -notin @('agent-farnsworth[bot]','app/agent-farnsworth')) {
    Fail "GitHub identity precondition failed: gh is authenticated as '$who', expected agent-farnsworth[bot]."
  }

  $existing = (& gh pr view $PullRequestNumber --repo $RepoSlug --json number,title,body,headRefName,headRefOid,baseRefName,author,isDraft,url | ConvertFrom-Json)
  if (-not $existing -or [int]$existing.number -ne $PullRequestNumber -or -not [bool]$existing.isDraft) {
    Fail "draft metadata update refused: PR #$PullRequestNumber is missing or is not currently draft."
  }
  if ($existing.headRefName -cne $Branch -or $existing.headRefOid -cne $LocalHead -or $existing.baseRefName -cne $BaseBranch) {
    Fail "draft metadata update refused: branch, base, or exact head SHA does not match PR #$PullRequestNumber."
  }
  if ($existing.author.login -notin @('agent-farnsworth[bot]','app/agent-farnsworth') -or $existing.title -cne $Title) {
    Fail "draft metadata update refused: author or title does not match PR #$PullRequestNumber."
  }

  if ($PreviewOnly) {
    Write-PrEvent -Event 'pr.validation' -Status 'passed' -Code 'draft-metadata-ready' -Message 'Managed draft metadata can be persisted; no mutation performed.' -Data @{
      number = $PullRequestNumber; title = $Title; branch = $Branch; baseBranch = $BaseBranch; head = $LocalHead; draft = $true
    }
    return
  }

  $PublicationBodyFile = Join-Path ([IO.Path]::GetTempPath()) ("botnexus-pr-body-$RunId.md")
  [IO.File]::WriteAllText($PublicationBodyFile, $Body, [Text.UTF8Encoding]::new($false))
  $PatchBodyFile = Join-Path ([IO.Path]::GetTempPath()) ("botnexus-pr-patch-$RunId.json")
  try {
    [IO.File]::WriteAllText($PatchBodyFile, (@{ body = $Body } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $mutation = (& gh api --method PATCH "repos/$RepoSlug/issues/$PullRequestNumber" --input $PatchBodyFile | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) { Fail "draft metadata update failed for PR #$PullRequestNumber." }
    $mutationBody = ([string]$mutation.body) -replace "`r`n", "`n"
    $expectedMutationBody = $Body -replace "`r`n", "`n"
    if ($mutationBody -cne $expectedMutationBody) {
      Fail "draft metadata update response did not contain the requested body for PR #$PullRequestNumber."
    }
  }
  finally {
    Remove-Item -LiteralPath $PatchBodyFile -Force -ErrorAction SilentlyContinue
  }
  $stored = (& gh pr view $PullRequestNumber --repo $RepoSlug --json title,body,headRefName,headRefOid,baseRefName,author,isDraft,url | ConvertFrom-Json)
  $expectedBody = $Body -replace "`r`n", "`n"
  $storedBody = ([string]$stored.body) -replace "`r`n", "`n"
  if (-not [bool]$stored.isDraft -or $storedBody -cne $expectedBody -or $stored.title -cne $Title -or
      $stored.headRefName -cne $Branch -or $stored.headRefOid -cne $LocalHead -or
      $stored.baseRefName -cne $BaseBranch -or $stored.author.login -notin @('agent-farnsworth[bot]','app/agent-farnsworth')) {
    Fail 'published-but-nonconformant: managed draft metadata readback failed identity, state, body, branch, base, or SHA comparison.'
  }
  Write-PrEvent -Event 'pr.publication' -Status 'completed' -Code 'draft-metadata-persisted' -Message 'Managed draft metadata was persisted without changing readiness disposition.' -Data @{
    number = $PullRequestNumber; url = $stored.url; title = $Title; branch = $Branch; baseBranch = $BaseBranch; head = $LocalHead; draft = $true
  }
  [pscustomobject]@{ ok=$true; metadataOnly=$true; url=$stored.url; number=$PullRequestNumber; title=$Title; branch=$Branch; baseBranch=$BaseBranch; head=$LocalHead; draft=$true }
  return
}

# ------------------------------------------------- 3. UI evidence (conditional)
  # The enclosing try begins before title/body validation so all valid-repository
  # refusal paths reach the same credential cleanup, including early DryRun exits.
  $Branch = (Invoke-Git @('rev-parse','--abbrev-ref','HEAD')) -join ''

  if ([string]::IsNullOrWhiteSpace($BaseBranch)) { Fail 'base branch cannot be blank.' }
  $null = & git -C $Worktree check-ref-format --branch $BaseBranch 2>&1
  if ($LASTEXITCODE -ne 0) { Fail "invalid base branch '$BaseBranch'." }
  if ($BaseBranch -eq $Branch) { Fail "base branch '$BaseBranch' cannot be the current branch." }
  if ($BaseBranch -ne 'main' -and -not $StackLayer) {
    Fail "a non-main base requires -StackLayer. Ordinary PRs must target main."
  }
  if ($StackLayer -and $BaseBranch -eq 'main') {
    Fail '-StackLayer requires an immediate non-main parent branch; the bottom layer is an ordinary main-based PR.'
  }
  if ($StackLayer) {
    $ghVersion = (& gh --version 2>$null | Select-Object -First 1) -join ''
    $versionMatch = [regex]::Match($ghVersion, '(\d+)\.(\d+)\.(\d+)')
    if (-not $versionMatch.Success -or [version]$versionMatch.Value -lt [version]'2.90.0') {
      Fail "stacked PRs require GitHub CLI 2.90.0 or later; observed '$ghVersion'."
    }
    $extensions = (& gh extension list 2>$null) -join "`n"
    if ($extensions -notmatch '(?m)^gh stack\s+github/gh-stack\s+') {
      Fail "stacked PRs require the official github/gh-stack extension. Install it with: gh extension install github/gh-stack"
    }
  }

  $fetchBranches = @('main')
  if ($BaseBranch -ne 'main') { $fetchBranches += $BaseBranch }
  git -C $Worktree fetch origin @fetchBranches --quiet 2>&1 | Out-Null
  # #3925: capture failure before any ref probe overwrites LASTEXITCODE. Cached refs
  # remain resolvable after a failed fetch; they cannot establish a fresh gate input.
  $fetchExitCode = $LASTEXITCODE
  if ($fetchExitCode -ne 0) {
    $fetchFailure = "git fetch origin $($fetchBranches -join ' ') failed (exit $fetchExitCode)."
    & git -C $Worktree rev-parse --verify --quiet 'origin/main' *>$null
    if ($LASTEXITCODE -ne 0) { $fetchFailure = "cannot resolve 'origin/main'. " + $fetchFailure }
    FailEnv ($fetchFailure + ' Refusing to evaluate PR gates using cached refs. Restore the remote and retry.')
  }
  # #3247: the fetch's exit code was discarded, and EVERY gate below derives from the
  # `origin/main...HEAD` diff. When origin/main cannot be resolved -- no network, an unreachable
  # remote, a fixture whose main was never pushed -- that diff fails, `$changed` comes back EMPTY,
  # and the UI-evidence and contamination gates both pass VACUOUSLY. Reproduced directly: a
  # branch whose diff is a bare .razor file with no evidence anywhere in the body printed
  # "DRY RUN - all checks passed" once origin/main was unresolvable, where the same input is
  # correctly rejected when it resolves.
  #
  # A gate that silently disappears when its input is unavailable is worse than no gate, because
  # its presence is what persuades a reader the check happened. Fail CLOSED, and name the
  # environmental cause distinctly so an unavailable precondition is never mistaken for a clean run.
  & git -C $Worktree rev-parse --verify --quiet 'origin/main' *>$null
  if ($LASTEXITCODE -ne 0) {
    FailEnv ("cannot resolve 'origin/main' in $Worktree, so the whole-stack safety gates" +
             "`n  cannot be evaluated. Refusing to report a pass for gates that did not run." +
             "`n  Fix the remote or the network, then re-run: git -C $Worktree fetch origin main")
  }
  $BaseRef = "origin/$BaseBranch"
  & git -C $Worktree rev-parse --verify --quiet $BaseRef *>$null
  if ($LASTEXITCODE -ne 0) {
    FailEnv ("cannot resolve '$BaseRef' in $Worktree, so the layer UI-evidence and scope gates" +
             "`n  cannot be evaluated. Push/fetch the parent branch, then re-run.")
  }
  & git -C $Worktree merge-base --is-ancestor $BaseRef HEAD *>$null
  if ($LASTEXITCODE -ne 0) {
    Fail "base '$BaseRef' is not an ancestor of HEAD. Rebase the stack with 'gh stack rebase' before shipping this layer."
  }
  if ($StackLayer) {
    & git -C $Worktree merge-base --is-ancestor 'origin/main' $BaseRef *>$null
    if ($LASTEXITCODE -ne 0) {
      Fail "stack parent '$BaseRef' is not based on current origin/main. Run 'gh stack rebase' and revalidate every affected layer."
    }
  }
  # Three-dot: changes introduced BY THIS BRANCH since the merge-base, which is what
  # GitHub shows as the PR file list. Two-dot would also report files that landed on
  # main after this branch was cut, producing phantom 'deletions' and false UI hits.
  $CheckedHead = (Invoke-Git @('rev-parse','HEAD')) -join ''
  $CheckedBase = (Invoke-Git @('rev-parse',$BaseRef)) -join ''
  $CheckedMain = (Invoke-Git @('rev-parse','origin/main')) -join ''
  $CheckedTree = Get-ShipCandidateTree
  Assert-ShipCandidate
  # The parent is an ancestor (checked above). Tree-to-tree preserves that layer
  # boundary while including pending bytes. Disable rename folding so both endpoints
  # participate; NUL framing preserves spaces, quoting characters and newlines.
  $changed = @(((Invoke-Git @('diff','--no-renames','--name-only','-z',$CheckedBase,$CheckedTree)) -join "`n") -split "`0" | Where-Object { $_ })
  # Run the exact conventions evaluator from the trusted base commit that GitHub Actions will use.
  # Do not maintain a second local interpretation: that allowed `UI evidence: deferred` while CI did
  # not, so deterministic publication produced deterministic CI failures (#4203, #4208, #4212).
  $guardRelativePath = '.github/scripts/pr-conventions-guard.mjs'
  $guardText = (Invoke-Git @('show',"$CheckedBase`:$guardRelativePath")) -join "`n"
  if ([string]::IsNullOrWhiteSpace($guardText)) {
    Fail "trusted base does not contain $guardRelativePath; PR convention parity cannot be verified."
  }
  $guardModuleFile = Join-Path ([IO.Path]::GetTempPath()) ("botnexus-pr-guard-$RunId.mjs")
  $guardPacketFile = Join-Path ([IO.Path]::GetTempPath()) ("botnexus-pr-guard-$RunId.json")
  try {
    [IO.File]::WriteAllText($guardModuleFile, $guardText, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($guardPacketFile, (@{ title = $Title; body = $Body; changedPaths = @($changed) } | ConvertTo-Json -Compress -Depth 5), [Text.UTF8Encoding]::new($false))
    $guardRunner = Join-Path $PSScriptRoot 'Invoke-BotNexusPrConventionsGuard.mjs'
    $guardJson = (& node $guardRunner $guardModuleFile $guardPacketFile) -join "`n"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($guardJson)) {
      Fail 'trusted-base PR conventions guard could not be evaluated locally.'
    }
    $guardResult = $guardJson | ConvertFrom-Json
    $blockingGuardViolations = @($guardResult.violations | Where-Object { -not [bool]$_.advisory })
    if ($blockingGuardViolations.Count -gt 0) {
      Fail ('body failed trusted-base PR conventions guard: ' + (($blockingGuardViolations | ForEach-Object message) -join '; '))
    }
  }
  finally {
    foreach ($file in @($guardModuleFile, $guardPacketFile)) {
      if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
  }

  # ------------------------------------------------------------- 4. scope check
  $stat = Invoke-Git @('diff','--stat',$CheckedBase,$CheckedTree)
  $wholeStackStat = Invoke-Git @('diff','--stat',$CheckedMain,$CheckedTree)
  $deletions = Invoke-Git @('diff','--no-renames','--numstat',$CheckedBase,$CheckedTree) |
               Where-Object { $_ -match '^\d+\s+\d+' } |
               Where-Object { ($_ -split '\t')[0] -eq '0' -and [int](($_ -split '\t')[1]) -gt 200 }
  if ($deletions -and -not $SkipScope) {
    # The invariant is "this branch is based on CURRENT origin/main", so the merge-base is compared
    # against origin/main -- NOT against HEAD (#3491). Comparing to HEAD asks "does the branch point
    # equal the branch tip", which is true only for a branch with no commits of its own, so every
    # branch that had actually done work was rejected. A guard that fires exclusively on false
    # positives trains the operator to pass -SkipScope, which disables it for the contaminated
    # worktree it exists to catch.
    $mergeBase = git -C $Worktree merge-base HEAD $BaseRef
    $baseTip = git -C $Worktree rev-parse $BaseRef
    if ($mergeBase -ne $baseTip) {
      Fail ("worktree may be CONTAMINATED - large deletions vs $BaseRef and the branch is not`n" +
            "  based on its current parent. Rebase the stack or rebuild from the expected base before pushing.`n$stat")
    }
    Write-Host "note: large deletions vs $BaseRef, but the branch is based on the current parent. OK." -ForegroundColor Yellow
  }

  # ------------------------------------------------------- 5. commit message
  if (-not $Why) {
    # Default the rationale to the Summary section prose.
    $m = [regex]::Match($visible, '(?ms)^##\s+Summary\s*$(.*?)(?=^##\s|\z)')
    $Why = if ($m.Success) {
      # Drop issue-link sentences: they are already carried by the Refs trailer.
      $prose = $m.Groups[1].Value -replace '(?i)\b(closes|fixes|resolves|refs)\s+#\d+\.?', ''
      ($prose -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 3) -join ' '
    } else { $Subject }
  }
  $Why = ($Why -replace '\s+',' ').Trim()
  if (-not $Validated) { $Validated = 'see PR body' }

  $CommitMsg = @"
$Title

$Why

Refs: #$Issue
Validated-by: $Validated
Co-authored-by: agent-farnsworth[bot] <$BotEmail>
"@

  # $Why and $Validated arrive after the body check above, so the assembled commit
  # message gets its own pass -- a leak in -Validated must not slip through.
  if (-not $NoScrubPaths) { $CommitMsg = Remove-LocalPath -Text $CommitMsg }
  Assert-NoLocalPath @{ 'commit message' = $CommitMsg }
  # Explicit and Summary-derived rationale must pass the same policy before preview or ship.
  Assert-NoInternalReference @{ 'commit message' = $CommitMsg }

  Write-Host "`n=== TITLE ($($Title.Length) chars) ===`n$Title" -ForegroundColor Cyan
  Write-Host "`n=== COMMIT ===`n$CommitMsg" -ForegroundColor Cyan
  Write-Host "=== LAYER SCOPE ($BaseRef...HEAD) ===`n$stat" -ForegroundColor Cyan
  if ($StackLayer) { Write-Host "=== WHOLE STACK (origin/main...HEAD) ===`n$wholeStackStat" -ForegroundColor DarkCyan }
  Write-Host "=== BRANCH ===  $Branch  ->  $RepoSlug (base: $BaseBranch)" -ForegroundColor Cyan
  Write-Host "=== PUBLICATION ===   $(if ($OpenAsDraft) { 'DRAFT (blockers persisted)' } else { 'PUBLICATION-READY (merge still requires human authorization)' })" -ForegroundColor Cyan

  # Scratch guard, evaluated BEFORE the -DryRun return so the preview reaches the same verdict
  # a real ship would (#3250). The source is `git status --porcelain -uall`, which is READ-ONLY:
  # staging for real and resetting afterwards would make a preview capable of losing work if it
  # were interrupted, which the issue calls out explicitly as the wrong fix.
  #
  # Get-ShipIndexPreview reconstructs the set of paths the ship-path index WILL hold, so the
  # preview and the ship feed the SAME predicate the SAME input. Anything less is a second
  # implementation of the rule, and two copies drift.
  $previewScratch = Get-ScratchOffenders (Get-ShipIndexPreview)
  if ($previewScratch.Tmp)  { Fail (Format-ScratchRefusal -Kind 'tmp'  -Paths $previewScratch.Tmp) }
  if ($previewScratch.Root) { Fail (Format-ScratchRefusal -Kind 'root' -Paths $previewScratch.Root) }

  Assert-ShipCandidate
  if ($PreviewOnly) {
    Write-PrEvent -Event 'pr.validation' -Status 'passed' -Code 'ready' -Message 'All pull request checks passed; no mutation performed.' -Data @{
      title = $Title; issue = $Issue; branch = $Branch; baseBranch = $BaseBranch; draft = $OpenAsDraft; changedFiles = $changed.Count
    }
    Write-Host "`nWHAT IF - all checks passed, nothing committed, pushed, or published." -ForegroundColor Green
    return
  }

  # ------------------------------------------------------------ 6. ship
  # Call the auth helper IN-PROCESS (`& script`), never as `pwsh -File`. A child pwsh
  # sets $env:GH_TOKEN in its OWN process and exits, so the parent shell that runs
  # `gh pr create` below still has an EMPTY token -- gh then silently falls back to a
  # keyring account (the EMU `jobullen_microsoft`), which cannot write to Sytone/botnexus.
  # The resulting "Unauthorized: As an Enterprise Managed User..." error names the EMU
  # IDENTITY and never the unset token, which is what steered agents at the banned
  # `gh auth switch --user sytone` and produced 9 PRs falsely authored as Jon (#2674).
  $botAuth = Join-Path $PSScriptRoot 'Use-FarnsworthBot.ps1'
  & $botAuth -RepoPath $Worktree | Out-Null
  # Identity is a PRECONDITION, not a diagnostic. Eight of the nine breaches were merged
  # before anyone read an error, so better error wording is provably insufficient: assert
  # the effective gh identity BEFORE any GitHub write and abort if it is not the bot.
  $who = (& gh api user --jq '.login' 2>$null)
  if (-not $who -or $who -like '*Resource not accessible*') {
    # A GitHub App INSTALLATION token cannot call /user (403 by design), and it also
    # reports every `repos/<slug>.permissions` field as false, so neither is a usable
    # probe. `installation/repositories` is: it succeeds ONLY for an installation token
    # and 403s for any user/keyring account, which is exactly the discrimination needed.
    $repos = (& gh api installation/repositories --jq '.repositories[].full_name' 2>$null)
    if (-not ($repos -and (@($repos) -contains $RepoSlug -or @($repos) -contains $RepoSlug.ToLowerInvariant()))) {
      Fail ("GitHub identity precondition failed: the active token is not an agent-farnsworth[bot] " +
            "installation token with access to $RepoSlug.`n" +
            "  `$env:GH_TOKEN is likely empty, so gh fell back to a keyring account (EMU, cannot write here).`n" +
            "  Fix the TOKEN by running Use-FarnsworthBot.ps1 IN-PROCESS. Do NOT run 'gh auth switch' -- " +
            "authoring as 'sytone' is a hard red line (#2674).")
    }
  }
  elseif ($who -ne 'agent-farnsworth[bot]' -and $who -ne 'app/agent-farnsworth') {
    Fail ("GitHub identity precondition failed: gh is authenticated as '$who', expected 'agent-farnsworth[bot]'.`n" +
          "  Refusing to write. Fix the TOKEN, never the account -- `gh auth switch --user sytone` is banned (#2674).")
  }

  $CommittedHead = $CheckedHead

  # Stage everything EXCEPT tmp/ -- the PR body file and other scratch artefacts are
  # routinely written into the worktree's tmp/ folder, and a bare `git add -A` committed
  # tmp/body-<n>.md into PR #2337. Scratch must never reach the branch.
  Assert-ShipCandidate
  Invoke-Git @('add','-A','--','.',':(exclude)tmp',':(exclude)tmp/*') | Out-Null
  Assert-ShipCandidate
  if (((Invoke-Git @('write-tree')) -join '') -ne $CheckedTree) {
    Fail 'checked candidate changed: staged tree differs from the evidence-gated tree.'
  }

  # Second evaluation, now against the REAL index. The pre-DryRun check above reads
  # `git status`, which is the right source for a preview but is not what actually gets
  # committed; this one is authoritative. Same predicate, so the two cannot disagree about
  # what counts as scratch -- only about which snapshot they inspect (#3250).
  $scratch = Get-ScratchOffenders (Invoke-Git @('diff','--cached','--name-only'))
  if ($scratch.Tmp)  { Fail (Format-ScratchRefusal -Kind 'tmp'  -Paths $scratch.Tmp) }
  if ($scratch.Root) { Fail (Format-ScratchRefusal -Kind 'root' -Paths $scratch.Root) }
  if (Invoke-Git @('diff','--cached','--name-only')) {
    Invoke-CheckedCommit
    Write-Host "committed." -ForegroundColor Green
  } else {
    # Nothing staged means the branch was committed earlier -- the NORMAL path, not an edge case.
    # AGENTS.md tells us to commit between stages so a timeout cannot lose work, and the mutation
    # loop must commit before mutating so the tree can be restored. Both leave a clean tree here.
    #
    # This branch used to just print a note and continue, which silently discarded $CommitMsg and
    # let whatever subject the branch happened to carry become the PR title and, on squash-merge,
    # the changelog entry. Two PRs reached main with `wip(...)` subjects that the validation above
    # would have rejected outright (#3246). Validating a string and then shipping a different one
    # is worse than not validating at all: it produces a green check that means nothing.
    $existing = @(Invoke-Git @('log','--format=%H',"$BaseRef..HEAD"))

    if ($existing.Count -eq 0) {
      Fail ("nothing staged and no commits on this branch relative to $BaseRef -- there is nothing to ship.`n" +
            "  Make the change, then re-run; the script stages and commits it with the validated message.")
    }

    $currentSubject = ((Invoke-Git @('log','-1','--format=%s')) -join '').TrimEnd("`r")
    # PowerShell here-strings use CRLF on Windows; splitting on LF retains a trailing CR.
    # Normalize only that line terminator so an identical multi-commit tip is not refused.
    $wantedSubject  = (($CommitMsg -split "`n")[0]).TrimEnd("`r")

    if ($currentSubject -eq $wantedSubject) {
      Write-Host "nothing staged; existing commit already carries the validated subject." -ForegroundColor Green
    }
    elseif ($existing.Count -eq 1) {
      # A single commit can be reworded losslessly: same tree, same parent, validated message.
      # Amend rather than refuse, because refusing would force every caller to hand-write the
      # exact message the script just derived -- reintroducing the divergence by another route.
      Invoke-CheckedCommit -Amend
      Write-Host "nothing staged; amended the single existing commit to the validated message." -ForegroundColor Green
      Write-Host "  was: $currentSubject" -ForegroundColor DarkGray
      Write-Host "  now: $wantedSubject" -ForegroundColor DarkGray
    }
    else {
      # Multiple commits: squashing is a judgement call about history the script must not make
      # unilaterally, and amending would rewrite only the tip while the PR title still came from
      # somewhere else. Refuse with both strings so the fix is obvious.
      Fail ("refusing to push: this branch has $($existing.Count) commits and the tip subject is not the validated one.`n" +
            "  tip subject : $currentSubject`n" +
            "  validated   : $wantedSubject`n" +
            "  The tip subject becomes the PR title and, on squash-merge, the changelog entry -- so an" +
            " unvalidated one bypasses every convention check above (#3246).`n" +
            "  Squash the branch to a single commit and re-run, or reword the tip to the validated subject.")
    }
  }

  # Keep the exact commit returned by the checked commit path; never adopt an arbitrary new HEAD.
  if (((Invoke-Git @('rev-parse','HEAD^{tree}')) -join '') -ne $CheckedTree) {
    Fail 'checked candidate changed: committed tree differs from the evidence-gated tree.'
  }
  Assert-ShipCandidate -ExpectedHead $CommittedHead

  # Embed the deterministic change profile in the body AFTER the commit exists, so the
  # table describes exactly what ships. `gh`'s +N/-N counts every blank line, every XML doc
  # comment and every test line identically, so a PR reading "+1232" tells a reviewer nothing
  # about how much PRODUCTION code actually changed. This classifies by lexing each file at
  # base and head -- regexing diff text cannot decide a block comment spanning a hunk
  # boundary, a verbatim string, or `//` inside a string literal.
  $profileScript = Join-Path $PSScriptRoot 'Get-BotNexusPullRequestChangeProfile.ps1'
  if (Test-Path $profileScript) {
    try {
      $mergeBase = (Invoke-Git @('merge-base',$BaseRef,'HEAD')).Trim()
      $table = & $profileScript -Repo $Worktree -Base $mergeBase -Head 'HEAD' -Format Markdown
      if ($table) {
        $section = "`n## Change profile`n`n$table`n"
        # Idempotent: replace an existing section rather than appending a second one when a
        # follow-up push re-runs the script against an already-open PR.
        if ($Body -match '(?ms)^## Change profile\r?\n.*?(?=^## |\z)') {
          $Body = [regex]::Replace($Body, '(?ms)^## Change profile\r?\n.*?(?=^## |\z)', $section.TrimStart("`n"))
        } else {
          $Body = $Body.TrimEnd() + "`n" + $section
        }
        Write-Host "change profile embedded in PR body." -ForegroundColor Green
      }
    } catch {
      # A profiling failure must never block shipping validated work.
      Write-Host "change profile skipped: $($_.Exception.Message)" -ForegroundColor Yellow
    }
  }

  $PublicationBodyFile = Join-Path ([IO.Path]::GetTempPath()) ("botnexus-pr-body-$RunId.md")
  [IO.File]::WriteAllText($PublicationBodyFile, $Body, [Text.UTF8Encoding]::new($false))
  Assert-ShipCandidate -ExpectedHead $CommittedHead
  # Git resolves an immutable source OID, not the mutable branch after our final check.
  Invoke-Git -Authenticated -Arguments @('push','origin',"${CommittedHead}:refs/heads/$Branch") | Select-Object -Last 1
  Assert-ShipCandidate -ExpectedHead $CommittedHead

  # An OPEN PR may already exist for this branch -- a prior worker, or a recovery/CI-repair
  # lane pushing a follow-up commit. `gh pr create` fails in that case, and the earlier version
  # of this script printed the failure as if it were a URL, silently leaving a NON-CONFORMANT
  # title/body in place. That is exactly how a `fix` PR with no Root cause section shipped
  # (#2350). The conventions checks above are worthless if they only gate creation, so update
  # the existing PR with the validated title and body instead of no-oping.
  $existing = (& gh pr list --repo $RepoSlug --head $Branch --state open --json number --jq '.[0].number' 2>$null)
  if ($Operation -eq 'Create' -and $existing) { Fail "create operation refused: PR #$existing already exists for $Branch; use Update-BotNexusPullRequest.ps1." }
  if ($Operation -eq 'Update' -and (-not $existing -or [int]$existing -ne $PullRequestNumber)) { Fail "update operation refused: expected open PR #$PullRequestNumber for $Branch." }
  if ($existing) {
    Write-Host "PR #$existing already open for $Branch - updating title/body to the validated form." -ForegroundColor Yellow
    # Check promotion eligibility BEFORE removing the persisted Draft status from the remote body.
    # A refused promotion must leave both GitHub's draft flag and its reason record unchanged.
    $existingState = (& gh pr view $existing --repo $RepoSlug --json isDraft,mergeable,statusCheckRollup | ConvertFrom-Json)
    if (-not $OpenAsDraft -and [bool]$existingState.isDraft) {
      $checkRollup = @($existingState.statusCheckRollup)
      # GitHub retains cancelled runs after a newer run of the same named check completes on the
      # same head. Evaluate only the newest run per check name so superseded cancellations do not
      # permanently block promotion.
      $latestChecks = @($checkRollup | Group-Object name | ForEach-Object {
        @($_.Group | Sort-Object -Property @{ Expression = {
          if ($_.startedAt) { [DateTimeOffset]$_.startedAt }
          elseif ($_.completedAt) { [DateTimeOffset]$_.completedAt }
          else { [DateTimeOffset]::MinValue }
        }; Descending = $true })[0]
      })
      $unacceptableChecks = @($latestChecks | Where-Object {
        ([string]$_.status).ToUpperInvariant() -ne 'COMPLETED' -or
        ([string]$_.conclusion).ToUpperInvariant() -notin @('SUCCESS','NEUTRAL','SKIPPED')
      })
      if ([string]$existingState.mergeable -ne 'MERGEABLE') { Fail "promotion refused: PR #$existing is not currently mergeable." }
      if ($checkRollup.Count -eq 0) { Fail "promotion refused: PR #$existing has no check results." }
      if ($unacceptableChecks.Count -gt 0) { Fail ("promotion refused: PR #$existing has pending or unacceptable checks: " + (($unacceptableChecks | ForEach-Object { $_.name }) -join ', ')) }
    }
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    & gh pr edit $existing --repo $RepoSlug --base $BaseBranch --title $Title --body-file $PublicationBodyFile | Out-Null
    # Reconcile both directions. Demotion is fail-closed; promotion changes review readiness only
    # and never grants merge authority.
    if ($OpenAsDraft -and -not [bool]$existingState.isDraft) {
      & gh pr ready $existing --repo $RepoSlug --undo 2>$null | Out-Null
      Write-Host "PR #$existing demoted to DRAFT by the readiness gate." -ForegroundColor Yellow
    } elseif (-not $OpenAsDraft -and [bool]$existingState.isDraft) {
      & gh pr ready $existing --repo $RepoSlug 2>$null | Out-Null
      if ($LASTEXITCODE -ne 0) { Fail "promotion failed: PR #$existing passed readiness but GitHub did not mark it ready." }
      Write-Host "PR #$existing promoted from DRAFT after body, checks, and mergeability gates cleared." -ForegroundColor Green
    }
    $url = (& gh pr view $existing --repo $RepoSlug --json url --jq '.url')
    Write-Host "`nPR (updated): $url" -ForegroundColor Green
  }
  else {
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    $args = @('pr','create','--repo',$RepoSlug,'--head',$Branch,'--base',$BaseBranch,'--title',$Title,'--body-file',$PublicationBodyFile)
    if ($OpenAsDraft) { $args += '--draft' }
    $url = & gh @args
    Write-Host "`nPR: $url" -ForegroundColor Green
  }

  # Label the PR mechanically. Left to human discipline this never happened: before this
  # was wired in, EVERY open PR in the repo carried zero labels. Derivation is from the
  # conventional-commit type plus the changed-file paths, so it is reproducible and needs
  # no judgement. This is a required lifecycle step: a write/readback failure leaves the PR
  # recoverable, but the helper must fail rather than falsely report complete publication.
  $prNumber = if ($existing) { $existing } else { ($url -split '/')[-1] }
  $labeller = Join-Path $PSScriptRoot 'Set-BotNexusLabel.ps1'
  if ($prNumber -match '^\d+$' -and (Test-Path $labeller)) {
    & $labeller -Action pr -Number ([int]$prNumber) -Repo $RepoSlug | Out-Null
    Write-Host "labels applied to PR #$prNumber" -ForegroundColor Green
  } else { Fail "PR labeller is unavailable for PR #$prNumber." }

  # ok is a FUNCTION of whether a PR actually exists, never a literal (#2928). The caller
  # is an orchestrator that records shipped work from this field; a success shape with no
  # PR number is indistinguishable from a real ship and silently corrupts the run report.
  if ($prNumber -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($url)) {
    Fail "no PR number was obtained for $Branch - refusing to report success. gh output: $url"
  }
  $stored = (& gh pr view $prNumber --repo $RepoSlug --json title,body,headRefOid,baseRefName,author,isDraft,url) | ConvertFrom-Json
  $storedContract = & $contractValidator -Title $stored.title -Body $stored.body -Issue $Issue -ContractPath $ContractPath -PartialWork:([bool]$PartialWork)
  $expectedBody = $Body -replace "`r`n", "`n"
  $storedBody = ([string]$stored.body) -replace "`r`n", "`n"
  if (-not $storedContract.valid -or $stored.title -cne $Title -or $storedBody -cne $expectedBody -or $stored.headRefOid -cne $CommittedHead -or $stored.baseRefName -cne $BaseBranch -or $stored.author.login -notin @('agent-farnsworth[bot]','app/agent-farnsworth') -or [bool]$stored.isDraft -ne $OpenAsDraft) {
    if (-not $stored.isDraft) { & gh pr ready $prNumber --repo $RepoSlug --undo 2>$null | Out-Null }
    Fail 'published-but-nonconformant: GitHub readback failed canonical validation or identity/SHA comparison; PR was demoted to draft when possible.'
  }
  # Release status:in-progress only after the authoritative PR readback converges. A PR that
  # exists but has the wrong contract, identity, SHA, base, or draft disposition is not yet the
  # trustworthy visible work marker and must not cause ownership to disappear prematurely.
  if ($Issue -gt 0) {
    $issueUpdater = Join-Path $PSScriptRoot 'Update-BotNexusIssue.ps1'
    & $issueUpdater -Action Release -Issue $Issue -Repository $RepoSlug | Out-Null
    Write-Host "claim released on #$Issue (verified PR #$prNumber is now the visible work marker)" -ForegroundColor Green
  }

  Write-PrEvent -Event 'pr.publication' -Status 'completed' -Code 'created-or-updated' -Message 'Pull request publication completed.' -Data @{
    number = [int]$prNumber; url = $url; title = $Title; branch = $Branch; baseBranch = $BaseBranch; draft = $OpenAsDraft
  }
  [pscustomobject]@{ ok = $true; url = $url; number = [int]$prNumber; title = $Title; branch = $Branch; baseBranch = $BaseBranch; stackLayer = [bool]$StackLayer }
}
finally {
  # #3070: the scrub used to sit inline as the LAST step of the ship sequence, so every one
  # of the ~dozen `Fail` paths between the auth call and here -- push rejected, gh pr create
  # failure, conventions checks, the label pass -- exited with the credential still live in
  # the shell (and, before the auth helper stopped persisting it, in .git/config). Running
  # it in `finally` makes it unconditional: exceptions, early returns and every Fail alike.
  # In-process (`& $botAuth`) for the same reason the auth call is: a child pwsh cannot
  # clear the PARENT's $env:GH_TOKEN, so `pwsh -File ... -Scrub` left the token live.
  # #3923: scrub is now identity-preserving and safe even with inherited GH_TOKEN.
  # Do not duplicate credential detection here: the old origin-only predicate missed
  # pushurl/other remotes and diverged from the helper's actual cleanup surface.
  try {
    if ($botAuth -and (Test-Path -LiteralPath $botAuth)) {
      & $botAuth -RepoPath $Worktree -Scrub | Out-Null
    }
  } catch { throw 'Credential scrub failed; refusing to report successful cleanup.' }
  finally {
    if ($PublicationBodyFile) { Remove-Item -LiteralPath $PublicationBodyFile -Force -ErrorAction SilentlyContinue }
    Pop-Location
  }
}
