[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][string]$OwnerRunId,
  [Parameter(Mandatory)][string]$Nonce,
  [Parameter(Mandatory)][string]$ConversationId,
  [string]$ContractPath
)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
$path=Get-BotNexusIssueLeasePath $contract $Issue
if(-not (Test-Path -LiteralPath $path)){throw 'Delivery lease is missing.'}
$lease=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
if([int]$lease.issue -ne $Issue -or $lease.ownerRunId -cne $OwnerRunId -or $lease.nonce -cne $Nonce){throw 'Lease ownership mismatch.'}
$lease.conversationId=$ConversationId;$lease.state='active'
if($PSCmdlet.ShouldProcess($path,"Bind conversation $ConversationId to issue #$Issue lease")){
  $tmp="$path.$([guid]::NewGuid().ToString('N')).tmp";try{[IO.File]::WriteAllText($tmp,($lease|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath $tmp -Destination $path -Force}finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
  $observed=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  if($observed.conversationId -cne $ConversationId -or $observed.state -cne 'active'){throw 'Lease conversation readback mismatch.'}
}
[pscustomobject]@{status='bound';issue=$Issue;conversationId=$ConversationId;ownerRunId=$OwnerRunId;nonce=$Nonce}|ConvertTo-Json -Compress
