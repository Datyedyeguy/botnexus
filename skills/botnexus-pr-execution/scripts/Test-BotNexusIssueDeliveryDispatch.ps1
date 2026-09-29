[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('botnexus-dispatch-test-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try {
  $contract=Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json') -Raw|ConvertFrom-Json
  $contract.leaseDirectory=Join-Path $root 'leases';$contract.legacyLeasePath=Join-Path $root 'legacy.json';$contract.repositoryRoot='Q:/repos/botnexus';$contract.maximumActiveDeliveries=2;$contract.maximumAdmissionsPerRun=1
  $contractPath=Join-Path $root 'contract.json';$contract|ConvertTo-Json -Depth 8|Set-Content $contractPath
  $empty=Join-Path $root 'empty.json';'[]'|Set-Content $empty
  $issues=Join-Path $root 'issues.json';$prs=Join-Path $root 'prs.json';'[]'|Set-Content $prs
  function Issue([int]$N,[string[]]$Labels){[pscustomobject]@{number=$N;title="[Platform] issue $N";body='verified scope';labels=@($Labels|ForEach-Object{[pscustomobject]@{name=$_}});createdAt='2026-01-01T00:00:00Z';updatedAt='2026-01-01T00:00:00Z';url="https://example/$N";author=[pscustomobject]@{login='agent-farnsworth[bot]'};admissionActor='agent-farnsworth[bot]'}}
  function WriteIssues($x){$items=@($x);if($items.Count -eq 0){'[]'|Set-Content $issues}else{$items|ConvertTo-Json -Depth 8|Set-Content $issues}}
  function RunDispatch(){& (Join-Path $PSScriptRoot 'Invoke-BotNexusIssueDeliveryDispatch.ps1') -ContractPath $contractPath -IssuesFixture $issues -PullRequestsFixture $prs -ConversationsFixture $empty -WorktreesFixture $empty -OwnerRunId test -WhatIf|ConvertFrom-Json}
  $passed=0
  WriteIssues @((Issue 1 @('status:ready-for-agent','type:bug','priority:high')));$r=RunDispatch;if($r.code -ne 'ready-issue-would-start' -or $r.handoff.issue -ne 1){throw 'Ready issue did not use direct dispatch path.'};$passed++
  WriteIssues @((Issue 2 @('type:bug','priority:high')));$r=RunDispatch;if($r.code -ne 'selected-issue-would-start' -or $r.candidate.number -ne 2 -or $r.handoff.issue -ne 2){throw 'Unmarked issue was not deterministically selected for bounded start.'};$passed++
  WriteIssues @();$r=RunDispatch;if($r.code -ne 'no-ready-issue'){throw 'Empty backlog did not return deterministic idle.'};$passed++
  $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-BotNexusIssueDeliveryDispatch.ps1') -Raw
  if($source -match "status='selection-required'" -or $source -notmatch 'selected-issue-would-start' -or $source -notmatch 'ready-issue-reserved'){throw 'Dispatch automatic-selection contract missing.'};$passed++
  if($source -notmatch 'selected-issue-became-ineligible' -or $source -notmatch "-Action Unadmit" -or $source -match 'marked ready but no delivery candidate was returned'){throw 'Dispatch collision recovery contract missing.'};$passed++
  [pscustomobject]@{total=5;passed=$passed;failed=0;directReadyDispatch=$true;automaticBoundedSelection=$true;selectionCollisionIsIdle=$true}|ConvertTo-Json -Compress
}
finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
