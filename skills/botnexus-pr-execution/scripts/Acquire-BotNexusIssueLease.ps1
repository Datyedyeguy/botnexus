[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][string]$ShortName,
  [string]$ContractPath,
  [string]$OwnerRunId = ([guid]::NewGuid().ToString('N')),
  [datetimeoffset]$Now = [datetimeoffset]::UtcNow
)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
$path=Get-BotNexusIssueLeasePath $contract $Issue;$dir=Split-Path -Parent $path
$lease=[ordered]@{version=1;issue=$Issue;shortName=$ShortName;agentId=$contract.agentId;ownerRunId=$OwnerRunId;nonce=[guid]::NewGuid().ToString('N');conversationId=$null;state='reserved';acquiredAt=$Now.ToString('o');expiresAt=$Now.AddMinutes([int]$contract.leaseMinutes).ToString('o')}
if(-not $PSCmdlet.ShouldProcess($path,"Atomically acquire issue #$Issue delivery lease")){[pscustomobject]@{status='preview';code='lease-would-acquire';lease=$lease}|ConvertTo-Json -Depth 6 -Compress;return}
[IO.Directory]::CreateDirectory($dir)|Out-Null
$json=$lease|ConvertTo-Json -Depth 6
try{
  $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes($json);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}catch [IO.IOException]{throw "Delivery lease already exists: $path"}
$readback=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
if([int]$readback.issue -ne $Issue -or $readback.ownerRunId -cne $OwnerRunId -or $readback.nonce -cne $lease.nonce){throw 'Lease readback mismatch.'}
[pscustomobject]@{status='acquired';code='lease-acquired';lease=$readback;path=$path}|ConvertTo-Json -Depth 6 -Compress
