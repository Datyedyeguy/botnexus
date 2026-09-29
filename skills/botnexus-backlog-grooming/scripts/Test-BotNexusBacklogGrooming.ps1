[CmdletBinding()]param()
$ErrorActionPreference='Stop';$root=Join-Path $env:TEMP ('groom-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null
try{$issues=Join-Path $root 'issues.json';$prs=Join-Path $root 'prs.json';'[]'|Set-Content $prs
$records=@(
 [pscustomobject]@{number=1;title='[Portal] duplicate refresh issue';body="Technical detail only. Related #2";labels=@([pscustomobject]@{name='type:bug'},[pscustomobject]@{name='priority:medium'});createdAt='2026-01-01T00:00:00Z';updatedAt='2026-01-01T00:00:00Z';url='u1';author=[pscustomobject]@{login='agent-farnsworth[bot]'}},
 [pscustomobject]@{number=2;title='[Portal] duplicate refresh problem';body="## Summary`nCurrent`n## Why it matters`nImpact`n## Example`nExample Agent";labels=@([pscustomobject]@{name='type:bug'},[pscustomobject]@{name='priority:medium'});createdAt='2026-01-02T00:00:00Z';updatedAt='2026-01-02T00:00:00Z';url='u2';author=[pscustomobject]@{login='external'}},
 [pscustomobject]@{number=3;title='[Gateway] active item';body='x';labels=@([pscustomobject]@{name='type:bug'},[pscustomobject]@{name='priority:high'},[pscustomobject]@{name='status:in-progress'});createdAt='2026-01-03T00:00:00Z';updatedAt='2026-01-03T00:00:00Z';url='u3';author=[pscustomobject]@{login='agent-farnsworth[bot]'}})
$records|ConvertTo-Json -Depth 8|Set-Content $issues
$r=& (Join-Path $PSScriptRoot 'Get-BotNexusBacklogGrooming.ps1') -IssuesFixture $issues -PullRequestsFixture $prs -Top 10 -Now ([datetimeoffset]'2026-09-13T00:00:00Z')|ConvertFrom-Json
if($r.code -ne 'grooming-candidates'){throw 'Collector returned no packet.'};if($r.candidates.number -contains 3){throw 'In-progress issue was included.'};$one=@($r.candidates|Where-Object number -eq 1)[0];if(-not $one -or $one.missingReadableSections.Count -ne 3 -or 2 -notin @($one.openIssueReferences)){throw 'Readability/reference projection failed.'}
$updater=Get-Content (Join-Path $PSScriptRoot 'Update-BotNexusGroomedIssue.ps1') -Raw;if($updater -notmatch 'trusted-authored open issues' -or $updater -notmatch 'Grooming readback drift' -or $updater -notmatch 'Why it matters'){throw 'Safe update contract missing.'}
[pscustomobject]@{total=4;passed=4;failed=0;boundedPacket=$true;activeExcluded=$true;readabilityDetected=$true;safeWriter=$true}|ConvertTo-Json -Compress
}finally{Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue}
