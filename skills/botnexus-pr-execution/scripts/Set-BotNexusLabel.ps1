# Maintenance phase: housekeeping. Owning contract: references/script-phases.json.
<#
.SYNOPSIS
  The ONLY sanctioned writer of GitHub labels for Sytone/botnexus.

.DESCRIPTION
  Every label write - issue or PR, by a human or an agent - goes through this script.
  Hand-rolled incremental label writes are how the repo ended up with two competing
  taxonomies (bug vs type:bug), near-duplicates (tests vs testing) and 87 labels of
  which ~30 were in use. A closed allow-list makes that failure mode impossible by
  construction rather than by discipline.

  The taxonomy lives in reference/label-taxonomy.json, NOT in this file, so the script,
  SKILL.md and any agent brief all read one source of truth.

.PARAMETER Action
  audit    - report drift: legacy labels still in use, dead labels, cardinality violations.
  sync     - create/update label definitions in the repo to match the taxonomy.
  migrate  - rewrite legacy labels to canonical ones across all issues and PRs.
  reap     - delete dead labels. Destructive; requires -Confirm.
  apply    - set labels on one issue or PR explicitly (validated against the allow-list).
  pr       - derive labels for a PR mechanically from its title + changed files.

.EXAMPLE
  Set-BotNexusLabel.ps1 -Action audit
.EXAMPLE
  Set-BotNexusLabel.ps1 -Action pr -Number 2540
.EXAMPLE
  Set-BotNexusLabel.ps1 -Action apply -Number 2530 -Labels type:bug,area:channels,priority:high
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('audit', 'sync', 'migrate', 'reap', 'apply', 'pr', 'dedupe')]
  [string]$Action,

  [int]$Number,
  [string[]]$Labels,
  [string]$Repo = 'Sytone/botnexus',
  [string]$TaxonomyPath,
  [switch]$WhatIf,
  [switch]$Confirm
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Taxonomy loading
# ---------------------------------------------------------------------------

function Get-Taxonomy {
  param([string]$Path)
  if (-not $Path) {
    $Path = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'reference/label-taxonomy.json'
  }
  if (-not (Test-Path $Path)) { throw "Taxonomy not found at $Path" }
  Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Get-CanonicalNames {
  param($Taxonomy)
  @($Taxonomy.labels.PSObject.Properties.Name)
}

# ---------------------------------------------------------------------------
# Validation - the whole point of the script
# ---------------------------------------------------------------------------

<#
  Rejects anything outside the allow-list AND enforces per-namespace cardinality.
  Cardinality matters: two `type:` labels on one issue is exactly the ambiguity the
  namespacing exists to remove, and it is invisible on the GitHub UI until you sort by it.
#>
function Test-LabelSet {
  param($Taxonomy, [string[]]$Names)

  $canonical = Get-CanonicalNames -Taxonomy $Taxonomy
  $problems = @()

  foreach ($n in $Names) {
    if ($n -notin $canonical) {
      $migrateTo = $Taxonomy.migrate.PSObject.Properties[$n]
      if ($migrateTo) {
        $problems += "'$n' is a LEGACY label; use '$($migrateTo.Value)'"
      }
      elseif ($n -in $Taxonomy.dead) {
        $problems += "'$n' is a DEAD label and must not be applied"
      }
      else {
        $problems += "'$n' is not in the taxonomy"
      }
    }
  }

  foreach ($ns in $Taxonomy.namespaces.PSObject.Properties) {
    $card = $ns.Value.cardinality
    if ($card -notin @('exactly-one', 'at-most-one')) { continue }
    $inNs = @($Names | Where-Object { $_ -like "$($ns.Name):*" })
    if ($inNs.Count -gt 1) {
      $problems += "namespace '$($ns.Name)' allows $card but got: $($inNs -join ', ')"
    }
    if ($card -eq 'exactly-one' -and $inNs.Count -eq 0) {
      $problems += "namespace '$($ns.Name)' requires exactly one label; none supplied"
    }
  }

  # Return a plain array. A unary-comma wrap here would make an EMPTY result read as a
  # one-element array at the call site, so every "is this set valid?" check would be
  # false. Callers wrap in @() to normalise the single/none cases instead.
  [string[]]$problems
}

<#
  Resolves an over-specified namespace down to a single label using the taxonomy's
  precedence order. Returns the labels to REMOVE. Deterministic by construction:
  the same label set always collapses the same way, so re-running is a no-op.
#>
function Get-CardinalityFix {
  param($Taxonomy, [string[]]$Names)
  $remove = @()
  foreach ($ns in $Taxonomy.namespaces.PSObject.Properties) {
    if ($ns.Value.cardinality -notin @('exactly-one', 'at-most-one')) { continue }
    $inNs = @($Names | Where-Object { $_ -like "$($ns.Name):*" })
    if ($inNs.Count -le 1) { continue }
    $order = $Taxonomy.precedence.PSObject.Properties[$ns.Name]
    if (-not $order) { continue }
    $winner = @($order.Value | Where-Object { $_ -in $inNs }) | Select-Object -First 1
    if (-not $winner) { continue }
    $remove += @($inNs | Where-Object { $_ -ne $winner })
  }
  [string[]]$remove
}

# ---------------------------------------------------------------------------
# Mechanical PR derivation - reproducible, no judgement
# ---------------------------------------------------------------------------

<#
  Converts a glob like **/BlazorClient*/** into a regex. Deliberately simple:
  ** crosses separators, * does not. A full glob engine is not warranted and would
  be another thing to get subtly wrong.
#>
function ConvertTo-GlobRegex {
  param([string]$Glob)
  $s = [regex]::Escape($Glob)
  $s = $s -replace '\\\*\\\*/', '(?:.*/)?'
  $s = $s -replace '\\\*\\\*', '.*'
  $s = $s -replace '\\\*', '[^/]*'
  "^$s$"
}

function Get-PrLabel {
  param($Taxonomy, [string]$Title, [string[]]$Files)

  $result = @()

  # type comes from the conventional-commit type in the title. The title is already
  # validated by New-BotNexusPullRequest.ps1, so this is a safe thing to key on.
  if ($Title -match '^(?<t>[a-z]+)(\([^)]*\))?!?:') {
    $ct = $Matches['t']
    $mapped = $Taxonomy.prTypeFromCommitType.PSObject.Properties[$ct]
    if ($mapped) { $result += $mapped.Value }
  }

  foreach ($rule in $Taxonomy.prAreaFromPath.PSObject.Properties) {
    foreach ($glob in $rule.Value) {
      $rx = ConvertTo-GlobRegex -Glob $glob
      if ($Files | Where-Object { $_ -match $rx }) {
        $result += $rule.Name
        break
      }
    }
  }

  , @($result | Select-Object -Unique)
}

function Get-IssueSchema {
  param([string]$Path)
  if (-not $Path) {
    $Path = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'reference/issue-schema.json'
  }
  if (-not (Test-Path $Path)) { throw "Issue schema not found at $Path" }
  Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Test-TitleConformance {
  <#
    Returns the subset of $Items whose title violates the '[Area] description' convention.

    Why this lives in the AUDIT as well as at the filing path: the canonical issue creator refuses a
    bad title only when the issue is filed there. A title typed into the GitHub UI, edited after filing,
    or filed before that gate existed is never re-examined -- so title drift accrued unseen while
    label drift sat at zero, and three separate maintenance cycles each re-derived the same probe by
    hand. A convention with a filing gate but no standing audit is only half-enforced.

    Prefix membership is built as a -match over [regex]::Escape'd alternatives, NEVER -like: a
    '[Docs]*' -like pattern treats the brackets as a wildcard CHARACTER CLASS and matches any title
    beginning with D, o, c or s, which silently reports most of the board as conforming.
  #>
  param($Schema, $Items)

  $prefixes = @($Schema.lint.titlePrefixes)
  if (-not $prefixes) { return @() }   # schema opted out; nothing to enforce
  $alt = ($prefixes | ForEach-Object { [regex]::Escape($_) }) -join '|'
  $rx = '^\[(?:' + $alt + ')\]\s*\S'

  @($Items | Where-Object { (($_.title ?? '').Trim()) -notmatch $rx })
}

# ---------------------------------------------------------------------------
# GitHub I/O
# ---------------------------------------------------------------------------

function Invoke-Gh {
  param([string[]]$GhArgs, [string]$InputJson, [switch]$AllowFail)
  if ($WhatIf) { Write-Host "  WHATIF: gh $($GhArgs -join ' ')" -ForegroundColor DarkYellow; return $null }
  if ($PSBoundParameters.ContainsKey('InputJson')) {
    $out = $InputJson | & gh @GhArgs 2>&1
  }
  else {
    $out = & gh @GhArgs 2>&1
  }
  if ($LASTEXITCODE -ne 0 -and -not $AllowFail) { throw "gh $($GhArgs -join ' ') failed: $out" }
  $out
}

function Get-AllItem {
  param([string]$Kind)  # issue | pr
  $json = & gh $Kind list --repo $Repo --state all --limit 4000 --json number,title,labels,state
  if ($LASTEXITCODE -ne 0) { throw "failed to list $Kind" }
  $json | ConvertFrom-Json
}

<#
  GitHub's issue-label REST endpoint also serves pull requests. One exact-set PUT
  avoids the GraphQL labelable mutations, which Enterprise Managed User bot
  identities cannot invoke. The post-write GET is authoritative: a successful exit
  code without exact convergence is still a failed label write.
#>
function Get-ItemLabelNames {
  param([int]$ItemNumber)
  $endpoint = "repos/$Repo/issues/$ItemNumber/labels?per_page=100"
  $raw = Invoke-Gh -GhArgs @('api', '--method', 'GET', $endpoint)
  if ($null -eq $raw) { return @() }
  @((($raw -join "`n") | ConvertFrom-Json).name | Where-Object { $_ })
}

function Set-ExactItemLabels {
  param([int]$ItemNumber, [string[]]$Names)

  $target = @($Names | Where-Object { $_ } | Select-Object -Unique)
  if ($WhatIf) {
    Write-Host "  WHATIF: REST exact label set for #${ItemNumber}: $($target -join ', ')" -ForegroundColor DarkYellow
    return
  }

  $before = @(Get-ItemLabelNames -ItemNumber $ItemNumber)
  $expected = @($target | Sort-Object)
  if ((@($before | Sort-Object) -join "`n") -ne ($expected -join "`n")) {
    $endpoint = "repos/$Repo/issues/$ItemNumber/labels"
    $body = @{ labels = @($target) } | ConvertTo-Json -Compress
    Invoke-Gh -GhArgs @('api', '--method', 'PUT', $endpoint, '--input', '-') -InputJson $body | Out-Null
  }

  $observed = @(Get-ItemLabelNames -ItemNumber $ItemNumber | Sort-Object)
  if (($observed -join "`n") -ne ($expected -join "`n")) {
    throw "label verification failed for #${ItemNumber}: requested [$($expected -join ', ')] observed [$($observed -join ', ')]"
  }
}

# ---------------------------------------------------------------------------
# Reap-only I/O. Do not reuse Invoke-Gh: preview still needs authoritative reads,
# and neither stderr nor unchecked native output is evidence of convergence.
# ---------------------------------------------------------------------------
function Get-ReapLabelNames {
  $raw = @(& gh label list --repo $Repo --limit 300 --json name 2>$null)
  if ($LASTEXITCODE -ne 0) { throw 'reap listing failed' }
  try { $records = ConvertFrom-Json -InputObject ($raw -join "`n") -NoEnumerate -ErrorAction Stop }
  catch { throw 'reap listing invalid' }
  # A saturated bounded list cannot establish absence. Refuse rather than treating
  # an unseen label as absent; gh must finish its pagination below this limit.
  if ($records -isnot [array] -or $records.Count -ge 300) { throw 'reap listing incomplete or invalid' }
  $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($record in $records) {
    if ($record -isnot [pscustomobject] -or $record.name -isnot [string] -or
        [string]::IsNullOrWhiteSpace($record.name) -or -not $names.Add($record.name)) {
      throw 'reap listing contains invalid or duplicate labels'
    }
  }
  return ,@($names)
}

function Remove-ReapLabel {
  param([string]$Name)
  # Defence in depth: this helper itself never mutates under preview/no-confirm.
  if ($WhatIf -or -not $Confirm) { throw 'reap deletion requires confirmation without preview' }
  & gh label delete $Name --repo $Repo --yes 1>$null 2>$null
  if ($LASTEXITCODE -ne 0) { throw 'reap deletion failed' }
  $observed = Get-ReapLabelNames
  if ($Name -in $observed) { throw 'reap deletion remains unverified' }
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

$tax = Get-Taxonomy -Path $TaxonomyPath
$canonical = Get-CanonicalNames -Taxonomy $tax

switch ($Action) {

  'audit' {
    $issues = Get-AllItem -Kind 'issue'
    $prs = Get-AllItem -Kind 'pr'
    $all = @($issues) + @($prs)

    $legacyHits = @{}
    $deadHits = @{}
    $unknownHits = @{}
    $cardProblems = @()

    foreach ($it in $all) {
      $names = @($it.labels.name | Where-Object { $_ })
      foreach ($n in $names) {
        if ($n -in $canonical) { continue }
        if ($tax.migrate.PSObject.Properties[$n]) { $legacyHits[$n] = 1 + ($legacyHits[$n] ?? 0) }
        elseif ($n -in $tax.dead) { $deadHits[$n] = 1 + ($deadHits[$n] ?? 0) }
        else { $unknownHits[$n] = 1 + ($unknownHits[$n] ?? 0) }
      }
      $problems = Test-LabelSet -Taxonomy $tax -Names @($names | Where-Object { $_ -in $canonical })
      $realCard = @($problems | Where-Object { $_ -like 'namespace*allows*' })
      if ($realCard) { $cardProblems += "#$($it.number): $($realCard -join '; ')" }
    }

    Write-Host "=== LABEL AUDIT ($Repo) ===" -ForegroundColor Cyan
    Write-Host "items scanned: $($all.Count)  (issues $($issues.Count), prs $($prs.Count))"

    Write-Host "`nLEGACY labels still in use: $($legacyHits.Keys.Count)" -ForegroundColor $(if ($legacyHits.Keys.Count) { 'Yellow' } else { 'Green' })
    foreach ($k in ($legacyHits.Keys | Sort-Object)) { "  {0,-28} {1,5}  -> {2}" -f $k, $legacyHits[$k], $tax.migrate.$k }

    Write-Host "`nDEAD labels still in use: $($deadHits.Keys.Count)" -ForegroundColor $(if ($deadHits.Keys.Count) { 'Yellow' } else { 'Green' })
    foreach ($k in ($deadHits.Keys | Sort-Object)) { "  {0,-28} {1,5}" -f $k, $deadHits[$k] }

    Write-Host "`nUNKNOWN labels (not canonical, not mapped): $($unknownHits.Keys.Count)" -ForegroundColor $(if ($unknownHits.Keys.Count) { 'Red' } else { 'Green' })
    foreach ($k in ($unknownHits.Keys | Sort-Object)) { "  {0,-28} {1,5}" -f $k, $unknownHits[$k] }

    Write-Host "`nCARDINALITY violations: $($cardProblems.Count)" -ForegroundColor $(if ($cardProblems.Count) { 'Yellow' } else { 'Green' })
    $cardProblems | Select-Object -First 40 | ForEach-Object { "  $_" }

    $openNoType = @($issues | Where-Object { $_.state -eq 'OPEN' -and -not (@($_.labels.name) | Where-Object { $_ -like 'type:*' }) })
    Write-Host "`nOPEN issues with no type: label: $($openNoType.Count)" -ForegroundColor $(if ($openNoType.Count) { 'Yellow' } else { 'Green' })
    $openNoType | Select-Object -First 30 | ForEach-Object { "  #$($_.number) $($_.title)" }

    $openPrNoType = @($prs | Where-Object { $_.state -eq 'OPEN' -and -not (@($_.labels.name) | Where-Object { $_ -like 'type:*' }) })
    Write-Host "`nOPEN PRs with no type: label: $($openPrNoType.Count)" -ForegroundColor $(if ($openPrNoType.Count) { 'Yellow' } else { 'Green' })
    $openPrNoType | ForEach-Object { "  #$($_.number) $($_.title)" }

    $openIssues = @($issues | Where-Object { $_.state -eq 'OPEN' })
    $badTitles = Test-TitleConformance -Schema (Get-IssueSchema) -Items $openIssues
    Write-Host "`nOPEN issues with a non-conforming title: $($badTitles.Count)" -ForegroundColor $(if ($badTitles.Count) { 'Yellow' } else { 'Green' })
    $badTitles | Select-Object -First 30 | ForEach-Object { "  #$($_.number) $($_.title)" }

    # Missing types are counted only for open items, in their separate report categories.
    # Keep them out of cardProblems (overfull namespaces) to avoid double-counting;
    # historical closed/merged items without a type remain non-blocking.
    $exit = $legacyHits.Keys.Count + $deadHits.Keys.Count + $unknownHits.Keys.Count + $cardProblems.Count + $badTitles.Count + $openNoType.Count + $openPrNoType.Count
    Write-Host "`nDRIFT TOTAL: $exit" -ForegroundColor $(if ($exit) { 'Yellow' } else { 'Green' })
    exit ([Math]::Min($exit, 1))
  }

  'sync' {
    Write-Host "=== SYNC LABEL DEFINITIONS ===" -ForegroundColor Cyan
    $existing = (& gh label list --repo $Repo --limit 300 --json name | ConvertFrom-Json).name
    foreach ($p in $tax.labels.PSObject.Properties) {
      $name = $p.Name
      $desc = $p.Value.description
      $color = $p.Value.color
      if ($name -in $existing) {
        Invoke-Gh -GhArgs @('label', 'edit', $name, '--repo', $Repo, '--description', $desc, '--color', $color) | Out-Null
        Write-Host "  updated  $name"
      }
      else {
        Invoke-Gh -GhArgs @('label', 'create', $name, '--repo', $Repo, '--description', $desc, '--color', $color) | Out-Null
        Write-Host "  created  $name" -ForegroundColor Green
      }
    }
  }

  'migrate' {
    Write-Host "=== MIGRATE LEGACY -> CANONICAL ===" -ForegroundColor Cyan
    $changed = 0
    foreach ($kind in @('issue', 'pr')) {
      foreach ($it in (Get-AllItem -Kind $kind)) {
        # Guard against a null/empty label name: PSObject.Properties[$null] throws
        # "array index evaluated to null", which halts a 2500-item migration mid-run.
        $names = @($it.labels.name | Where-Object { $_ })
        $legacy = @($names | Where-Object { $tax.migrate.PSObject.Properties[$_] })
        if (-not $legacy) { continue }

        $add = @()
        foreach ($l in $legacy) {
          $t = $tax.migrate.$l
          if ($t -and $t -notin $names -and $t -notin $add) { $add += $t }
        }

        $final = @(@($names | Where-Object { $_ -notin $legacy }) + @($add) | Select-Object -Unique)
        Write-Host "  #$($it.number) +[$($add -join ',')] -[$($legacy -join ',')]"
        Set-ExactItemLabels -ItemNumber $it.number -Names $final
        $changed++
      }
    }
    Write-Host "items changed: $changed"
  }

  'dedupe' {
    Write-Host "=== RESOLVE CARDINALITY VIOLATIONS ===" -ForegroundColor Cyan
    $changed = 0
    foreach ($kind in @('issue', 'pr')) {
      foreach ($it in (Get-AllItem -Kind $kind)) {
        $names = @($it.labels.name | Where-Object { $_ -and $_ -in $canonical })
        $remove = Get-CardinalityFix -Taxonomy $tax -Names $names
        if (-not $remove) { continue }
        $allNames = @($it.labels.name | Where-Object { $_ })
        $final = @($allNames | Where-Object { $_ -notin $remove })
        Write-Host "  #$($it.number) -[$($remove -join ',')]  (kept $($final -join ','))"
        Set-ExactItemLabels -ItemNumber $it.number -Names $final
        $changed++
      }
    }
    Write-Host "items changed: $changed"
  }

  'reap' {
    Write-Host "=== REAP DEAD LABELS ===" -ForegroundColor Cyan
    $counts = @{ deleted = 0; absent = 0; 'would-delete' = 0; failed = 0 }
    $dead = @($tax.dead)
    $ready = $false
    try {
      if (-not $Confirm -and -not $WhatIf) { throw 'reap requires -Confirm or -WhatIf' }
      $existing = Get-ReapLabelNames
      $ready = $true
    }
    catch { Write-Host 'reap preflight failed: confirmation or complete label listing required' }
    foreach ($d in $dead) {
      if (-not $ready) { $outcome = 'failed' }
      elseif ($d -notin $existing) { $outcome = 'absent' }
      elseif ($WhatIf) { $outcome = 'would-delete' }
      else {
        try {
          Remove-ReapLabel -Name $d
          $outcome = 'deleted'
        }
        catch { $outcome = 'failed' }
      }
      $counts[$outcome]++
      Write-Host "  $outcome  $d"
    }
    Write-Host "REAP TOTAL: deleted=$($counts.deleted) absent=$($counts.absent) would-delete=$($counts['would-delete']) failed=$($counts.failed)"
    exit $(if (-not $ready -or $counts.failed -gt 0) { 1 } else { 0 })
  }

  'apply' {
    if (-not $Number) { throw "-Number is required for apply" }
    if (-not $Labels) { throw "-Labels is required for apply" }
    $problems = @(Test-LabelSet -Taxonomy $tax -Names $Labels)
    if ($problems) { $problems | ForEach-Object { Write-Error $_ }; throw "refusing to apply an invalid label set" }
    Set-ExactItemLabels -ItemNumber $Number -Names $Labels
    Write-Host "applied exact set to #${Number}: $($Labels -join ', ')" -ForegroundColor Green
  }

  'pr' {
    if (-not $Number) { throw "-Number is required for pr" }
    $meta = & gh pr view $Number --repo $Repo --json number,title,files,labels | ConvertFrom-Json
    $files = @($meta.files.path)
    $derived = Get-PrLabel -Taxonomy $tax -Title $meta.title -Files $files

    # Carry over any canonical priority/status the PR already has - those are human
    # judgement and must not be clobbered by a mechanical pass.
    $keep = @($meta.labels.name | Where-Object { $_ -in $canonical -and ($_ -like 'priority:*' -or $_ -like 'status:*') })
    $final = @(@($derived) + @($keep) | Select-Object -Unique)

    Write-Host "PR #${Number}: $($meta.title)"
    Write-Host "  files: $($files.Count)"
    Write-Host "  derived: $($derived -join ', ')"
    if ($keep) { Write-Host "  preserved: $($keep -join ', ')" }

    $problems = @(Test-LabelSet -Taxonomy $tax -Names $final)
    if ($problems) { $problems | ForEach-Object { Write-Error $_ }; throw "derived label set is invalid" }
    if (-not $final) { Write-Host "  nothing to apply"; return }

    Set-ExactItemLabels -ItemNumber $Number -Names $final
    Write-Host "  applied exact set: $($final -join ', ')" -ForegroundColor Green
  }
}
