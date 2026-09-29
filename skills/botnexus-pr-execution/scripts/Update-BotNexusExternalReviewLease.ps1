[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Acquire','Release')][string]$Action='Acquire',[string]$OwnerRunId=([guid]::NewGuid().ToString('N')),[string]$Nonce,[string]$LeasePath=(Join-Path $HOME '.botnexus/agents/farnsworth/workspace/state/botnexus-external-review-lease.json'),[int]$LeaseMinutes=45,[datetimeoffset]$Now=[datetimeoffset]::UtcNow)
$ErrorActionPreference='Stop'
if($Action -eq 'Acquire'){
  if(Test-Path -LiteralPath $LeasePath){
    $existing=Get-Content -LiteralPath $LeasePath -Raw|ConvertFrom-Json
    if([datetimeoffset]$existing.expiresAt -gt $Now){[pscustomobject]@{status='blocked';code='review-lease-active';lease=$existing}|ConvertTo-Json -Depth 6 -Compress;return}
    if($PSCmdlet.ShouldProcess($LeasePath,'Remove expired external-review lease')){Remove-Item -LiteralPath $LeasePath -Force}
  }
  $lease=[ordered]@{version=1;ownerRunId=$OwnerRunId;nonce=[guid]::NewGuid().ToString('N');acquiredAt=$Now.ToString('o');expiresAt=$Now.AddMinutes($LeaseMinutes).ToString('o')}
  if(-not $PSCmdlet.ShouldProcess($LeasePath,'Atomically acquire external-review lease')){[pscustomobject]@{status='preview';code='review-lease-would-acquire';lease=$lease}|ConvertTo-Json -Depth 6 -Compress;return}
  [IO.Directory]::CreateDirectory((Split-Path -Parent $LeasePath))|Out-Null
  try{$s=[IO.File]::Open($LeasePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$b=[Text.UTF8Encoding]::new($false).GetBytes(($lease|ConvertTo-Json));$s.Write($b,0,$b.Length);$s.Flush($true)}finally{$s.Dispose()}}catch [IO.IOException]{throw 'External-review lease collision.'}
  [pscustomobject]@{status='acquired';code='review-lease-acquired';lease=(Get-Content $LeasePath -Raw|ConvertFrom-Json)}|ConvertTo-Json -Depth 6 -Compress;return
}
if(-not(Test-Path -LiteralPath $LeasePath)){[pscustomobject]@{status='absent';code='review-lease-absent'}|ConvertTo-Json -Compress;return}
$lease=Get-Content -LiteralPath $LeasePath -Raw|ConvertFrom-Json
if($lease.ownerRunId -cne $OwnerRunId -or $lease.nonce -cne $Nonce){throw 'External-review lease ownership mismatch.'}
if($PSCmdlet.ShouldProcess($LeasePath,'Release external-review lease')){Remove-Item -LiteralPath $LeasePath -Force;if(Test-Path $LeasePath){throw 'External-review lease release failed.'}}
[pscustomobject]@{status='released';code='review-lease-released'}|ConvertTo-Json -Compress
