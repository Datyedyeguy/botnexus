[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Body,
  [switch]$ExplicitDraft,
  [string]$DraftReasonCode = 'explicit-draft',
  [string]$DraftReasonDetail = 'The publisher was invoked with -Draft; the owning conversation must explicitly clear this reason after confirming completion.',
  [string[]]$ResolveDraftReasonCode = @(),
  [switch]$SelfTest
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Import-BotNexusPullRequestDraftState.ps1')

function Get-Readiness([string]$CandidateBody,[bool]$WasExplicitDraft,[string]$ReasonCode,[string]$ReasonDetail,[string[]]$ResolvedCodes) {
  $existing = Get-BotNexusPullRequestDraftState $CandidateBody
  $visibleBody = $existing.body
  $reasons = [Collections.Generic.List[object]]::new()
  if ($WasExplicitDraft) {
    if ([string]::IsNullOrWhiteSpace($ReasonCode) -or [string]::IsNullOrWhiteSpace($ReasonDetail)) { throw 'Explicit draft reason code and detail are required.' }
    $reasons.Add([pscustomobject]@{code=$ReasonCode.Trim();detail=$ReasonDetail.Trim()})
  }
  $patterns = [ordered]@{
    'unchecked-task'='(?im)^\s*[-*]?\s*\[ \]'
    'todo-marker'='(?m)\bTODO\b'
    'wip-marker'='(?m)\bWIP\b'
    'fixme-marker'='(?m)\bFIXME\b'
    'not-yet-complete'='(?im)\bnot yet (implemented|done|tested|validated)\b'
    'follow-up-required'='(?im)\bfollow-?up (commit|PR) (is )?(required|needed|to come)\b'
    'remaining-work'='(?im)\bremaining work\b'
  }
  foreach($entry in $patterns.GetEnumerator()) {
    $matches=@([regex]::Matches($visibleBody,[string]$entry.Value)|ForEach-Object{$_.Value.Trim()}|Select-Object -Unique)
    if($matches.Count -gt 0){$reasons.Add([pscustomobject]@{code=$entry.Key;detail=("PR body declares outstanding work: " + ($matches -join ', '))})}
  }
  $validation = (($visibleBody -split '(?m)^##\s+' | Where-Object { $_ -match '^Validation' }) -join "`n")
  if($validation -notmatch '\d'){$reasons.Add([pscustomobject]@{code='validation-counts-missing';detail='Validation does not contain concrete numeric evidence.'})}
  if($validation -match '(?i)\b(tbd|pending|n/?a|none)\b'){$reasons.Add([pscustomobject]@{code='validation-incomplete';detail='Validation declares TBD, pending, N/A, or none.'})}
  $computedCodes = @('unchecked-task','todo-marker','wip-marker','fixme-marker','not-yet-complete','follow-up-required','remaining-work','validation-counts-missing','validation-incomplete')
  $knownExistingCodes = @($existing.reasons | ForEach-Object { [string]$_.code })
  $unknownResolved = @($ResolvedCodes | Where-Object { $_ -notin $knownExistingCodes })
  if($unknownResolved.Count -gt 0){throw "Cannot resolve draft reason code(s) not present in the PR: $($unknownResolved -join ', ')."}
  $persisted = @($existing.reasons | Where-Object { $_.code -notin $computedCodes -and $_.code -notin $ResolvedCodes })
  foreach($reason in $persisted){
    if($reason.code -eq 'explicit-draft' -and (-not $WasExplicitDraft -or $ReasonCode -ne 'explicit-draft')){continue}
    $reasons.Add($reason)
  }
  $final=@($reasons|Sort-Object code,detail -Unique)
  [pscustomobject]@{ready=($final.Count -eq 0);reasons=$final;body=(Set-BotNexusPullRequestDraftState $visibleBody $final)}
}

if($SelfTest){
  $complete="## Summary`nDone. Closes #1`n## Changes`n- done`n## Tests`n- 1 passed`n## Validation`n- 1 passed, 0 failed`n## Risk & rollback`n- revert`n"
  $draft=Get-Readiness ($complete+"`n- [ ] outstanding`n") $false $DraftReasonCode $DraftReasonDetail @()
  if($draft.ready -or $draft.body -notmatch 'botnexus:draft-state:v1:' -or $draft.body -notmatch '## Draft status'){throw 'Draft persistence self-test failed.'}
  $parsed=Get-BotNexusPullRequestDraftState $draft.body
  if(-not $parsed.managed -or 'unchecked-task' -notin @($parsed.reasons.code)){throw 'Draft readback self-test failed.'}
  $ready=Get-Readiness $draft.body $false $DraftReasonCode $DraftReasonDetail @()
  if($ready.ready){throw 'Unresolved visible blocker was incorrectly cleared.'}
  $cleared=Get-Readiness ($draft.body -replace '(?m)^- \[ \] outstanding\r?\n?','') $false $DraftReasonCode $DraftReasonDetail @()
  if(-not $cleared.ready -or $cleared.body -match 'botnexus:draft-state:v1:'){throw 'Draft clearing self-test failed.'}
  $explicit=Get-Readiness $complete $true $DraftReasonCode $DraftReasonDetail @()
  if($explicit.ready -or 'explicit-draft' -notin @($explicit.reasons.code)){throw 'Explicit draft self-test failed.'}
  $manual=Get-Readiness $complete $true 'external-blocker' 'waiting for a gate' @()
  $resolved=Get-Readiness $manual.body $false $DraftReasonCode $DraftReasonDetail @('external-blocker')
  if(-not $resolved.ready){throw 'Explicit resolved-reason self-test failed.'}
  $unknownRejected=$false;try{Get-Readiness $manual.body $false $DraftReasonCode $DraftReasonDetail @('not-present')|Out-Null}catch{$unknownRejected=$true}
  if(-not $unknownRejected){throw 'Unknown resolved-reason self-test failed.'}
  [pscustomobject]@{total=6;passed=6;failed=0;markerRoundTrip=$true;visibleStatus=$true;blockerClearing=$true;explicitDraft=$true;resolvedReason=$true;unknownReasonRejected=$true}|ConvertTo-Json -Compress
  return
}
Get-Readiness $Body ([bool]$ExplicitDraft) $DraftReasonCode $DraftReasonDetail @($ResolveDraftReasonCode)
