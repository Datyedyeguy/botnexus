[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][string]$OwnerRunId,
  [Parameter(Mandatory)][string]$Nonce,
  [string]$ContractPath
)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
$path=Get-BotNexusIssueLeasePath $contract $Issue
if(-not (Test-Path -LiteralPath $path)){[pscustomobject]@{status='absent';code='already-released';issue=$Issue}|ConvertTo-Json -Compress;return}
$lease=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
if([int]$lease.issue -ne $Issue -or $lease.ownerRunId -cne $OwnerRunId -or $lease.nonce -cne $Nonce){throw 'Lease ownership mismatch; refusing release.'}
if($PSCmdlet.ShouldProcess($path,"Release issue #$Issue delivery lease")){Remove-Item -LiteralPath $path -Force;if(Test-Path -LiteralPath $path){throw 'Lease release readback failed.'}}
[pscustomobject]@{status='released';code='lease-released';issue=$Issue}|ConvertTo-Json -Compress
