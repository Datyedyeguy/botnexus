[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$Repository='Sytone/botnexus',
  [string]$PullRequestsJson='',
  [switch]$SelfTest
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Import-BotNexusPullRequestDraftState.ps1')

function Get-Reconciliation([object[]]$PullRequests) {
  @(
    foreach($pr in $PullRequests) {
      if(-not [bool]$pr.draft){continue}
      $state = if ($null -ne $pr.PSObject.Properties['draftState']) { $pr.draftState } elseif ($null -ne $pr.PSObject.Properties['body']) { Get-BotNexusPullRequestDraftState ([string]$pr.body) } else { [pscustomobject]@{managed=$false;version=$null;reasons=@()} }
      [pscustomobject]@{
        number=[int]$pr.number
        headSha=[string]$pr.head.sha
        primaryIssue=$pr.primaryIssue
        linkedIssues=@($pr.linkedIssues)
        managed=[bool]$state.managed
        draftReasons=@($state.reasons)
        problemCodes=@('draft-reconciliation-required') + $(if(-not $state.managed){'draft-state-unmanaged'})
        requestedAction='Re-evaluate each persisted draft reason against current source, checks, issue scope, and external gates. If every blocker is resolved, update the PR through Update-BotNexusPullRequest.ps1 without -Draft; the helper must pass the full readiness/readback gate and explicitly promote it. Never merge.'
      }
    }
  )
}

if($SelfTest){
  $managedBody=Set-BotNexusPullRequestDraftState '## Summary
x
' @([pscustomobject]@{code='remaining-work';detail='finish tests'})
  $rows=Get-Reconciliation @(
    [pscustomobject]@{number=1;draft=$true;body=$managedBody;head=[pscustomobject]@{sha='abc'};primaryIssue=10;linkedIssues=@(10)},
    [pscustomobject]@{number=2;draft=$true;body='legacy';head=[pscustomobject]@{sha='def'};primaryIssue=20;linkedIssues=@(20)},
    [pscustomobject]@{number=3;draft=$false;body='ready';head=[pscustomobject]@{sha='ghi'};primaryIssue=30;linkedIssues=@(30)}
  )
  if($rows.Count -ne 2 -or -not $rows[0].managed -or $rows[1].managed -or 'draft-state-unmanaged' -notin @($rows[1].problemCodes)){throw 'Draft reconciliation self-test failed.'}
  [pscustomobject]@{total=3;passed=3;failed=0;draftsIncluded=$true;readyExcluded=$true;legacyFlagged=$true}|ConvertTo-Json -Compress
  return
}
if([string]::IsNullOrWhiteSpace($PullRequestsJson)){throw 'PullRequestsJson is required. Pass the single collector result; this script does not fan out GitHub reads.'}
$payload=$PullRequestsJson|ConvertFrom-Json
$rows=Get-Reconciliation (@($payload.attention)+@($payload.healthyPullRequests))
[pscustomobject]@{generatedAt=[DateTimeOffset]::UtcNow.ToString('o');repository=$Repository;drafts=$rows.Count;items=@($rows)}|ConvertTo-Json -Depth 10 -Compress
