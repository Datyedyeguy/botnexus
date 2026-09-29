[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ('botnexus-delivery-metrics-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
try {
  $now=[datetimeoffset]'2026-09-29T18:00:00Z'
  $issues=@(
    [pscustomobject]@{number=1;title='new issue';state='OPEN';createdAt='2026-09-29T12:00:00Z';closedAt=$null;updatedAt='2026-09-29T12:00:00Z';url='https://example/1';labels=@('type:bug','priority:high')},
    [pscustomobject]@{number=2;title='closed issue';state='CLOSED';createdAt='2026-09-20T12:00:00Z';closedAt='2026-09-29T10:00:00Z';updatedAt='2026-09-29T10:00:00Z';url='https://example/2';labels=@('type:bug','priority:high')},
    [pscustomobject]@{number=3;title='blocked issue';state='OPEN';createdAt='2026-09-20T12:00:00Z';closedAt=$null;updatedAt='2026-09-29T09:00:00Z';url='https://example/3';labels=@('type:bug','priority:high','status:blocked')}
  )
  $prs=@(
    [pscustomobject]@{number=10;title='recent';state='OPEN';author=[pscustomobject]@{login='agent-farnsworth[bot]'};createdAt='2026-09-29T16:30:00Z';closedAt=$null;mergedAt=$null;url='https://example/10';isDraft=$false},
    [pscustomobject]@{number=11;title='merged';state='MERGED';author=[pscustomobject]@{login='app/agent-farnsworth'};createdAt='2026-09-29T08:00:00Z';closedAt='2026-09-29T14:00:00Z';mergedAt='2026-09-29T14:00:00Z';url='https://example/11';isDraft=$false},
    [pscustomobject]@{number=12;title='external';state='OPEN';author=[pscustomobject]@{login='external'};createdAt='2026-09-29T16:00:00Z';closedAt=$null;mergedAt=$null;url='https://example/12';isDraft=$false}
  )
  $leases=@(
    [pscustomobject]@{issue=20;acquiredAt='2026-09-29T17:30:00Z';conversationId='healthy'},
    [pscustomobject]@{issue=21;acquiredAt='2026-09-29T12:00:00Z';conversationId='stale'}
  )
  $triage=[pscustomobject]@{status='ready';code='triage-candidates';count=2;candidates=@([pscustomobject]@{number=30},[pscustomobject]@{number=31})}
  $contract=[pscustomobject]@{agentPullRequestAuthors=@('agent-farnsworth[bot]','app/agent-farnsworth');maximumActiveDeliveries=8;staleLaneHours=4;leaseDirectory=(Join-Path $root 'leases')}
  $paths=@{IssuesFixture='issues.json';PullRequestsFixture='prs.json';LeasesFixture='leases.json';TriageFixture='triage.json';ContractPath='contract.json'}
  foreach($pair in $paths.GetEnumerator()){
    $value=switch($pair.Key){'IssuesFixture'{$issues};'PullRequestsFixture'{$prs};'LeasesFixture'{$leases};'TriageFixture'{$triage};'ContractPath'{$contract}}
    $value|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $root $pair.Value) -Encoding utf8
  }
  $args=@{NowUtc=$now;WindowHours=24;NoPullRequestHours=4;BlockedIssueWarningCount=1}
  foreach($pair in $paths.GetEnumerator()){$args[$pair.Key]=Join-Path $root $pair.Value}
  $result=& (Join-Path $PSScriptRoot 'Get-BotNexusDeliveryMetrics.ps1') @args|ConvertFrom-Json
  $checks=[ordered]@{
    'counts-agent-prs-only'=$result.metrics.pullRequestsCreated -eq 2
    'calculates-pr-rate'=$result.metrics.pullRequestsPerHour -eq 0.08
    'counts-issue-flow'=$result.metrics.issuesCreated -eq 1 -and $result.metrics.issuesClosed -eq 1 -and $result.metrics.issueNetChange -eq 0
    'separates-healthy-and-stale-leases'=$result.metrics.healthyDeliveryLeases -eq 1 -and $result.metrics.staleDeliveryLeases -eq 1
    'stale-lane-does-not-consume-capacity'=$result.metrics.freeDeliverySlots -eq 7
    'reports-triage-capacity-anomaly'='unused-capacity-with-ready-work' -in @($result.anomalies.code)
    'reports-stale-lane-anomaly'='stale-delivery-lanes' -in @($result.anomalies.code)
    'reports-blocker-spike'='blocked-issue-spike' -in @($result.anomalies.code)
    'recent-pr-suppresses-no-progress'='no-pull-request-progress' -notin @($result.anomalies.code)
  }
  foreach($entry in $checks.GetEnumerator()){if(-not $entry.Value){throw "Delivery metrics contract failed: $($entry.Key)"}}
  [pscustomobject]@{total=$checks.Count;passed=$checks.Count;failed=0;checks=@($checks.Keys)}|ConvertTo-Json -Compress
}
finally {Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}
