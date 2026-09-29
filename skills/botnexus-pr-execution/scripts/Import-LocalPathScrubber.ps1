<#
.SYNOPSIS
  Shared machine-local path scrubber for anything Farnsworth publishes to GitHub.

.DESCRIPTION
  PR bodies, PR titles, commit messages and issue/PR comments routinely quote local
  paths because the explanation genuinely needs them -- the deployment repo
  (`$HOME\botnexus`) and the dev repo (Q:\repos\botnexus) are different things
  and a fix often turns on which one is meant. The paths are load-bearing prose; they
  just must not carry the operator's username or the machine's disk topology into a
  public repo.

  This file is dot-sourced, NOT executed. It deliberately lives apart from
  New-BotNexusPullRequest.ps1 so the `gh issue comment` / `gh pr comment` paths -- which bypass
  the PR shipper entirely -- can adopt the identical rules instead of re-deriving them.

  Rule ordering is longest-prefix-first and is load-bearing: without it
  `$HOME\.botnexus` degrades to `~\.botnexus` under the bare-home rule and the
  intended `~/.botnexus` token is lost. Rules are case-insensitive (paths appear as
  with either drive-letter case) and separator-agnostic (forward-slash home paths
  show up in JSON snippets and stack traces).

  The username segment is matched generically as [A-Za-z0-9_.-]+ rather than pinned to
  $env:USERNAME: pinning means the scrubber silently stops working the moment anyone
  else runs it, which is precisely when nobody would notice.

.EXAMPLE
  . "$PSScriptRoot\Import-LocalPathScrubber.ps1"
  $hits = Get-LocalPathMatch -Text $body
  $clean = Remove-LocalPath -Text $body
#>

# Ordered longest-prefix-first. Each entry: a regex and the generic token it collapses to.
$script:LocalPathScrubRules = @(
  # --- Windows user profile -------------------------------------------------------
  # The agent runtime root, before the bare-home rule can eat the prefix.
  @{ Name = 'user-botnexus-runtime'; Pattern = '[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9_.-]+[\\/]\.botnexus'; Replacement = '~/.botnexus' }
  # The deployment repo -- distinct from the dev repo and usually the point of the sentence.
  @{ Name = 'deployment-repo';       Pattern = '[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9_.-]+[\\/]botnexus';   Replacement = '<deployment-repo>' }
  # Residual home directory.
  @{ Name = 'windows-home';          Pattern = '[A-Za-z]:[\\/]Users[\\/][A-Za-z0-9_.-]+';                Replacement = '~' }

  # --- Dev repo and worktrees -----------------------------------------------------
  # Worktree slug first: it is a longer prefix than the repo path it sits beside.
  @{ Name = 'worktree';              Pattern = '[A-Za-z]:[\\/]repos[\\/]botnexus-wt[\\/][A-Za-z0-9_.-]+'; Replacement = '<worktree>' }
  @{ Name = 'worktree-root';         Pattern = '[A-Za-z]:[\\/]repos[\\/]botnexus-wt';                     Replacement = '<worktree-root>' }
  @{ Name = 'dev-repo';              Pattern = '[A-Za-z]:[\\/]repos[\\/]botnexus';                        Replacement = '<repo>' }
  @{ Name = 'repos-root';            Pattern = '[A-Za-z]:[\\/]repos';                                     Replacement = '<repos-root>' }

  # --- POSIX home directories -----------------------------------------------------
  # The lookbehind keeps this off the tail of an already-handled Windows path and off
  # URL paths such as https://example.com/home/x.
  @{ Name = 'posix-home';            Pattern = '(?<![A-Za-z0-9:/\\.-])/(?:home|Users)/[A-Za-z0-9_.-]+';   Replacement = '~' }
)

function Get-LocalPathScrubRule {
  <#
  .SYNOPSIS Returns the ordered rule table. Exposed so tests can pin the ordering.
  #>
  [CmdletBinding()]
  param()
  $script:LocalPathScrubRules
}

function Get-LocalPathMatch {
  <#
  .SYNOPSIS
    Reports every machine-local path in $Text with a 1-based line number and the
    replacement that would be applied. Returns an empty array for clean text.
  #>
  [CmdletBinding()]
  param([AllowEmptyString()][AllowNull()][string]$Text)

  $results = @()
  if ([string]::IsNullOrEmpty($Text)) { return $results }

  $lines = $Text -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    # Consume left-to-right per line so an earlier (longer) rule claims its span and a
    # later, shorter rule cannot re-report the same characters as a second finding.
    $remaining = $lines[$i]
    foreach ($rule in $script:LocalPathScrubRules) {
      $ms = [regex]::Matches($remaining, $rule.Pattern, 'IgnoreCase')
      foreach ($m in $ms) {
        $results += [pscustomobject]@{
          Line        = $i + 1
          Rule        = $rule.Name
          Match       = $m.Value
          Replacement = $rule.Replacement
        }
      }
      if ($ms.Count) { $remaining = [regex]::Replace($remaining, $rule.Pattern, $rule.Replacement, 'IgnoreCase') }
    }
  }
  , $results
}

function Remove-LocalPath {
  <#
  .SYNOPSIS
    Returns $Text with every machine-local path collapsed to a generic token.
    Idempotent: the replacement tokens contain no path that any rule matches.
  #>
  [CmdletBinding()]
  param([AllowEmptyString()][AllowNull()][string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $out = $Text
  foreach ($rule in $script:LocalPathScrubRules) {
    $out = [regex]::Replace($out, $rule.Pattern, $rule.Replacement, 'IgnoreCase')
  }
  $out
}

function Format-LocalPathReport {
  <#
  .SYNOPSIS Renders Get-LocalPathMatch output as an operator-readable report.
  #>
  [CmdletBinding()]
  param([Parameter(ValueFromPipeline)][object[]]$Match, [string]$Label = 'content')
  end {
    if (-not $Match -or $Match.Count -eq 0) { return '' }
    $lines = $Match | ForEach-Object { "    line {0,-4} {1}  ->  {2}   [{3}]" -f $_.Line, $_.Match, $_.Replacement, $_.Rule }
    "  $Label contains $($Match.Count) machine-local path(s):`n" + ($lines -join "`n")
  }
}
