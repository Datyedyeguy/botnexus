[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][string]$OwnerRunId,
  [Parameter(Mandatory)][string]$Nonce,
  [string]$ConversationId,
  [string]$ContractPath,
  [datetimeoffset]$Now=[datetimeoffset]::UtcNow
)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
$path=Get-BotNexusIssueLeasePath $contract $Issue
if(-not(Test-Path -LiteralPath $path)){throw "Delivery lease does not exist for issue #$Issue."}
$lease=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
if([int]$lease.issue -ne $Issue -or $lease.ownerRunId -cne $OwnerRunId -or $lease.nonce -cne $Nonce){throw 'Lease ownership mismatch; refusing renewal.'}
if(-not [string]::IsNullOrWhiteSpace($ConversationId)){$lease.conversationId=$ConversationId;$lease.state='active'}
$lease.acquiredAt=$Now.ToString('o')
$lease.expiresAt=$Now.AddMinutes([int]$contract.leaseMinutes).ToString('o')
if($PSCmdlet.ShouldProcess($path,"Renew issue #$Issue delivery lease after successful recovery wake")){
  $temp="$path.$([guid]::NewGuid().ToString('N')).tmp"
  try{
    [IO.File]::WriteAllText($temp,($lease|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temp -Destination $path -Force
  }finally{Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
}
$readback=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
if($readback.ownerRunId -cne $OwnerRunId -or $readback.nonce -cne $Nonce -or [datetimeoffset]$readback.acquiredAt -ne $Now){throw 'Lease renewal readback mismatch.'}
[pscustomobject]@{status='renewed';code='stale-lane-recovery-renewed';issue=$Issue;lease=$readback}|ConvertTo-Json -Depth 8 -Compress
