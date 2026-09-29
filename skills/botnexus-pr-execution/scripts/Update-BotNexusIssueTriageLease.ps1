[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Acquire','Release')][string]$Action='Acquire',[string]$OwnerRunId=([guid]::NewGuid().ToString('N')),[string]$Nonce,[string]$LeasePath='C:/Users/jobullen/.botnexus/agents/farnsworth/workspace/state/botnexus-issue-triage-lease.json',[int]$LeaseMinutes=25,[datetimeoffset]$Now=[datetimeoffset]::UtcNow)
$ErrorActionPreference='Stop'
if($Action -eq 'Acquire'){
  if(Test-Path $LeasePath){$old=Get-Content $LeasePath -Raw|ConvertFrom-Json;if([datetimeoffset]$old.expiresAt -gt $Now){[pscustomobject]@{status='blocked';code='triage-lease-active';lease=$old}|ConvertTo-Json -Depth 5 -Compress;return};if($PSCmdlet.ShouldProcess($LeasePath,'Remove expired triage lease')){Remove-Item $LeasePath -Force}}
  $lease=[ordered]@{version=1;ownerRunId=$OwnerRunId;nonce=[guid]::NewGuid().ToString('N');acquiredAt=$Now.ToString('o');expiresAt=$Now.AddMinutes($LeaseMinutes).ToString('o')}
  if(-not $PSCmdlet.ShouldProcess($LeasePath,'Acquire issue-triage lease')){[pscustomobject]@{status='preview';code='triage-lease-would-acquire';lease=$lease}|ConvertTo-Json -Depth 5 -Compress;return}
  [IO.Directory]::CreateDirectory((Split-Path -Parent $LeasePath))|Out-Null
  try{$s=[IO.File]::Open($LeasePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$b=[Text.UTF8Encoding]::new($false).GetBytes(($lease|ConvertTo-Json));$s.Write($b,0,$b.Length);$s.Flush($true)}finally{$s.Dispose()}}catch [IO.IOException]{throw 'Issue-triage lease collision.'}
  [pscustomobject]@{status='acquired';code='triage-lease-acquired';lease=(Get-Content $LeasePath -Raw|ConvertFrom-Json)}|ConvertTo-Json -Depth 5 -Compress;return
}
if(-not(Test-Path $LeasePath)){[pscustomobject]@{status='absent';code='triage-lease-absent'}|ConvertTo-Json -Compress;return}
$lease=Get-Content $LeasePath -Raw|ConvertFrom-Json;if($lease.ownerRunId -cne $OwnerRunId -or $lease.nonce -cne $Nonce){throw 'Issue-triage lease ownership mismatch.'}
if($PSCmdlet.ShouldProcess($LeasePath,'Release issue-triage lease')){Remove-Item $LeasePath -Force;if(Test-Path $LeasePath){throw 'Issue-triage lease release failed.'}}
[pscustomobject]@{status='released';code='triage-lease-released'}|ConvertTo-Json -Compress
