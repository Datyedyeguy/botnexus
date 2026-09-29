# Maintenance phase: 05-validation. Owning contract: references/script-phases.json.
<#
.SYNOPSIS
    Deterministic per-PR change accounting: real code vs test vs docs vs comments.

.DESCRIPTION
    Classifies every ADDED and REMOVED line of a diff into (bucket x kind):
      bucket = prod | test | docs | config | generated
      kind   = code | comment          (blank lines are discarded)

    DETERMINISM: comment detection lexes the WHOLE FILE at the base and head
    revisions and records, per line index, whether that line carries code
    and/or comment. The diff is used ONLY to select which line indices moved.
    Regexing diff text alone cannot decide block comments that span hunk
    boundaries, verbatim/raw strings, or '//' inside a string literal.

    A line can be BOTH code and comment (e.g. `x = 1; // why`) and is counted
    once in each column, so columns deliberately do not sum to the raw diff.

.PARAMETER Repo
    Path to the git repository (or worktree).

.PARAMETER Base
    Base ref/OID. Comparison is a three-dot merge-base diff (Base...Head).

.PARAMETER Head
    Head ref/OID.

.PARAMETER Format
    Markdown (default), Json, or Object.

.PARAMETER IncludeFiles
    Append a collapsed per-file breakdown to the markdown output.

.EXAMPLE
    ./Get-BotNexusPullRequestChangeProfile.ps1 -Repo Q:\repos\botnexus -Base origin/main -Head HEAD
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Repo,
    [Parameter(Mandatory)][string]$Base,
    [Parameter(Mandatory)][string]$Head,
    [ValidateSet('Markdown', 'Json', 'Object')][string]$Format = 'Markdown',
    [switch]$IncludeFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- git helper

function Invoke-Git {
    param([string[]]$GitArgs, [switch]$AllowFailure)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'git'
    foreach ($a in @('-C', $Repo) + $GitArgs) { $null = $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $null = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) {
        if ($AllowFailure) { return $null }
        throw "git $($GitArgs -join ' ') failed with exit code $($p.ExitCode)"
    }
    return $out
}

# ---------------------------------------------------------------- extensions

$script:CLike = @('.cs', '.js', '.mjs', '.cjs', '.ts', '.tsx', '.jsx', '.java', '.go',
    '.c', '.h', '.cpp', '.hpp', '.css', '.scss', '.less')
$script:HashLike = @('.ps1', '.psm1', '.psd1', '.py', '.sh', '.bash', '.yml', '.yaml', '.toml')
$script:XmlLike = @('.xml', '.csproj', '.props', '.targets', '.html', '.htm', '.slnx', '.config', '.resx')
$script:RazorLike = @('.razor', '.cshtml')
$script:DocExt = @('.md', '.mdx', '.rst', '.adoc')
$script:NoComment = @('.json', '.lock', '.txt', '.sql')

# ---------------------------------------------------------------- lexer

function Get-LineClassification {
    <# Returns an array of [int] flags per line: bit0 = has code, bit1 = has comment. #>
    param([AllowNull()][string]$Text, [string]$Ext)

    if ($null -eq $Text) { return @() }
    $lines = $Text -split "`n"

    if ($script:DocExt -contains $Ext -or $script:NoComment -contains $Ext) {
        # Prose IS the payload for docs; comment-less formats have no comment syntax.
        return @($lines | ForEach-Object { if ($_.Trim()) { 1 } else { 0 } })
    }

    $lineTokens = @(); $blockOpen = $null; $blockClose = $null
    $xmlOpen = $null; $xmlClose = $null
    $quotes = @(); $escape = $null; $verbatim = $false

    if ($script:CLike -contains $Ext -or $script:RazorLike -contains $Ext) {
        $lineTokens = @('//'); $blockOpen = '/*'; $blockClose = '*/'
        $quotes = @('"', "'", '`'); $escape = '\'
        if ($Ext -eq '.cs' -or $script:RazorLike -contains $Ext) { $verbatim = $true }
        if ($script:RazorLike -contains $Ext) { $xmlOpen = '<!--'; $xmlClose = '-->' }
    }
    elseif ($script:HashLike -contains $Ext) {
        $lineTokens = @('#')
        if ($Ext -in @('.ps1', '.psm1', '.psd1')) {
            $blockOpen = '<#'; $blockClose = '#>'; $escape = '`'
        }
        else { $escape = '\' }
        $quotes = @('"', "'")
    }
    elseif ($script:XmlLike -contains $Ext) {
        $blockOpen = '<!--'; $blockClose = '-->'
    }
    else {
        return @($lines | ForEach-Object { if ($_.Trim()) { 1 } else { 0 } })
    }

    $result = [System.Collections.Generic.List[int]]::new()
    $pendingClose = $null          # closing token currently sought across lines
    $inString = $null              # @{ Quote; Verbatim }

    foreach ($raw in $lines) {
        $hasCode = $false; $hasComment = $false
        $i = 0; $n = $raw.Length

        while ($i -lt $n) {
            if ($null -ne $pendingClose) {
                $hasComment = $true
                $idx = $raw.IndexOf($pendingClose, $i)
                if ($idx -lt 0) { $i = $n }
                else { $i = $idx + $pendingClose.Length; $pendingClose = $null }
                continue
            }

            if ($null -ne $inString) {
                $hasCode = $true
                $ch = $raw[$i]
                if ($inString.Verbatim) {
                    if ($ch -eq '"') {
                        if ($i + 1 -lt $n -and $raw[$i + 1] -eq '"') { $i += 2; continue }
                        $inString = $null
                    }
                    $i++; continue
                }
                if ($escape -and $ch -eq $escape) { $i += 2; continue }
                if ($ch -eq $inString.Quote) { $inString = $null }
                $i++; continue
            }

            $ch = $raw[$i]
            if ([char]::IsWhiteSpace($ch)) { $i++; continue }

            $matched = $false
            foreach ($tok in $lineTokens) {
                if ($i + $tok.Length -le $n -and $raw.Substring($i, $tok.Length) -eq $tok) {
                    $hasComment = $true; $i = $n; $matched = $true; break
                }
            }
            if ($matched) { continue }

            foreach ($pair in @(@($blockOpen, $blockClose), @($xmlOpen, $xmlClose))) {
                $o = $pair[0]; $c = $pair[1]
                if (-not $o) { continue }
                if ($i + $o.Length -le $n -and $raw.Substring($i, $o.Length) -eq $o) {
                    $hasComment = $true
                    $j = $raw.IndexOf($c, $i + $o.Length)
                    if ($j -lt 0) { $pendingClose = $c; $i = $n }
                    else { $i = $j + $c.Length }
                    $matched = $true; break
                }
            }
            if ($matched) { continue }

            if ($verbatim -and $i + 1 -lt $n -and $ch -eq '@' -and $raw[$i + 1] -eq '"') {
                $inString = @{ Quote = '"'; Verbatim = $true }
                $hasCode = $true; $i += 2; continue
            }

            if ($quotes -contains [string]$ch) {
                $inString = @{ Quote = $ch; Verbatim = $false }
                $hasCode = $true; $i++; continue
            }

            $hasCode = $true; $i++
        }

        $flags = 0
        if ($hasCode) { $flags = $flags -bor 1 }
        if ($hasComment) { $flags = $flags -bor 2 }
        $result.Add($flags)
    }
    return $result.ToArray()
}

# ---------------------------------------------------------------- buckets

$script:TestPattern = '(^|/)(tests?|e2e|__tests__)/|\.tests?\.|[Tt]ests?\.(cs|ps1)$|\.(spec|test)\.(ts|js|tsx|jsx)$'
$script:DocPattern = '(^|/)docs?/|\.(md|mdx|rst|adoc)$'
$script:GenPattern = '\.(g|designer)\.cs$|package-lock\.json$|\.min\.(js|css)$|\.generated\.'
$script:ConfigExt = @('.json', '.yml', '.yaml', '.xml', '.csproj', '.props', '.targets',
    '.slnx', '.config', '.editorconfig', '.toml', '.lock', '.resx')

function Get-PathBucket {
    param([string]$Path)
    if ($Path -match $script:GenPattern) { return 'generated' }
    if ($Path -match $script:DocPattern) { return 'docs' }
    if ($Path -match $script:TestPattern) { return 'test' }
    if ($script:ConfigExt -contains ([System.IO.Path]::GetExtension($Path).ToLowerInvariant())) { return 'config' }
    return 'prod'
}

# ---------------------------------------------------------------- analysis

function Get-ChangeProfile {
    param([string]$BaseRef, [string]$HeadRef)

    $nameStatus = Invoke-Git @('diff', '--name-status', '-M', "$BaseRef...$HeadRef")
    $totals = @{}
    $perFile = [System.Collections.Generic.List[object]]::new()

    foreach ($line in ($nameStatus -split "`n")) {
        $line = $line.TrimEnd("`r")
        if (-not $line) { continue }
        $parts = $line -split "`t"
        $status = $parts[0].Substring(0, 1)
        $newPath = $parts[-1]
        $oldPath = if ($status -eq 'R') { $parts[1] } else { $newPath }

        $ext = [System.IO.Path]::GetExtension($newPath).ToLowerInvariant()
        $bucket = Get-PathBucket -Path $newPath

        $oldText = if ($status -eq 'A') { $null } else { Invoke-Git @('show', "${BaseRef}:${oldPath}") -AllowFailure }
        $newText = if ($status -eq 'D') { $null } else { Invoke-Git @('show', "${HeadRef}:${newPath}") -AllowFailure }
        $oldCls = Get-LineClassification -Text $oldText -Ext $ext
        $newCls = Get-LineClassification -Text $newText -Ext $ext

        $diff = Invoke-Git @('diff', '--unified=0', '--no-color', '-M',
            "$BaseRef...$HeadRef", '--', $oldPath, $newPath) -AllowFailure
        if (-not $diff) { continue }

        $oln = 0; $nln = 0
        $fileStats = @{}
        foreach ($d in ($diff -split "`n")) {
            $d = $d.TrimEnd("`r")
            if ($d -match '^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@') {
                $oln = [int]$Matches[1]; $nln = [int]$Matches[2]; continue
            }
            if ($d.StartsWith('---') -or $d.StartsWith('+++')) { continue }

            if ($d.StartsWith('-')) {
                $flags = if ($oln -ge 1 -and $oln -le $oldCls.Count) { $oldCls[$oln - 1] }
                         elseif ($d.Substring(1).Trim()) { 1 } else { 0 }
                Add-Tally -Stats $fileStats -Bucket $bucket -Flags $flags -Sign 'removed'
                $oln++
            }
            elseif ($d.StartsWith('+')) {
                $flags = if ($nln -ge 1 -and $nln -le $newCls.Count) { $newCls[$nln - 1] }
                         elseif ($d.Substring(1).Trim()) { 1 } else { 0 }
                Add-Tally -Stats $fileStats -Bucket $bucket -Flags $flags -Sign 'added'
                $nln++
            }
        }

        foreach ($k in $fileStats.Keys) {
            if (-not $totals.ContainsKey($k)) { $totals[$k] = 0 }
            $totals[$k] += $fileStats[$k]
        }
        if ($fileStats.Count -gt 0) {
            $perFile.Add([pscustomobject]@{ Path = $newPath; Bucket = $bucket; Stats = $fileStats })
        }
    }
    return [pscustomobject]@{ Totals = $totals; Files = $perFile }
}

function Add-Tally {
    param([hashtable]$Stats, [string]$Bucket, [int]$Flags, [string]$Sign)
    if ($Flags -eq 0) { return }   # blank line -> discarded
    if ($Flags -band 1) {
        $k = "$Bucket.code.$Sign"
        if (-not $Stats.ContainsKey($k)) { $Stats[$k] = 0 }
        $Stats[$k]++
    }
    if ($Flags -band 2) {
        $k = "$Bucket.comment.$Sign"
        if (-not $Stats.ContainsKey($k)) { $Stats[$k] = 0 }
        $Stats[$k]++
    }
}

# ---------------------------------------------------------------- rendering

function Format-ProfileMarkdown {
    param([hashtable]$Totals, [object[]]$Files, [switch]$WithFiles)

    $order = @('prod', 'test', 'docs', 'config', 'generated')
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine('| Bucket | Code + | Code - | Comment + | Comment - | Net |')
    $null = $sb.AppendLine('|---|---:|---:|---:|---:|---:|')

    # Running totals as discrete variables. Do NOT collapse these into
    # `@($ta + $a, $tr + $r, ...)`: in PowerShell the comma operator binds TIGHTER than `+`,
    # so that expression parses as `$ta + ($a, $tr) + ($r, ...)` and silently builds nested
    # arrays instead of summing. (Python's precedence is the opposite, which is how this
    # survived the port.)
    $ta = 0; $tr = 0; $tca = 0; $tcr = 0
    foreach ($b in $order) {
        $a = [int]($Totals["$b.code.added"]); $r = [int]($Totals["$b.code.removed"])
        $ca = [int]($Totals["$b.comment.added"]); $cr = [int]($Totals["$b.comment.removed"])
        if (($a + $r + $ca + $cr) -eq 0) { continue }
        $ta += $a; $tr += $r; $tca += $ca; $tcr += $cr
        $net = $a - $r + $ca - $cr
        $null = $sb.AppendLine("| $b | $a | $r | $ca | $cr | $('{0:+#;-#;0}' -f $net) |")
    }
    $netAll = $ta - $tr + $tca - $tcr
    $null = $sb.AppendLine("| **total** | **$ta** | **$tr** | **$tca** | **$tcr** | **$('{0:+#;-#;0}' -f $netAll)** |")
    $null = $sb.AppendLine()
    $null = $sb.AppendLine('<sub>Blank lines discarded. A line that is both code and comment is counted in both columns, so columns do not sum to the raw diff.</sub>')

    if ($WithFiles -and $Files) {
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('<details><summary>Per file</summary>')
        $null = $sb.AppendLine()
        foreach ($f in ($Files | Sort-Object { -($_.Stats.Values | Measure-Object -Sum).Sum })) {
            $detail = ($f.Stats.GetEnumerator() | Sort-Object Name |
                ForEach-Object { "$($_.Key -replace '^[^.]+\.', '')=$($_.Value)" }) -join ', '
            $null = $sb.AppendLine("- ``$($f.Path)`` [$($f.Bucket)] $detail")
        }
        $null = $sb.AppendLine()
        $null = $sb.AppendLine('</details>')
    }
    return $sb.ToString().TrimEnd()
}

# ---------------------------------------------------------------- entry

$changeProfile = Get-ChangeProfile -BaseRef $Base -HeadRef $Head

switch ($Format) {
    'Json' { $changeProfile | ConvertTo-Json -Depth 6 }
    'Object' { $changeProfile }
    default { Format-ProfileMarkdown -Totals $changeProfile.Totals -Files $changeProfile.Files -WithFiles:$IncludeFiles }
}
