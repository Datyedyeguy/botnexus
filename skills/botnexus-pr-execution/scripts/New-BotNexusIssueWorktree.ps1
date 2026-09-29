[CmdletBinding()]
param(
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][string]$Type,
  [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$ShortName,
  [string]$RepoRoot = 'Q:/repos/botnexus',
  [string]$ContractPath = ''
)
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($ContractPath)){
  $repoContract=Join-Path $RepoRoot '.github/pr-contract.json'
  $skillContract=Join-Path (Split-Path -Parent $PSScriptRoot) 'reference/pr-contract.json'
  $ContractPath=if(Test-Path -LiteralPath $repoContract){$repoContract}else{$skillContract}
}
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
if($Type -notin @($contract.allowedTypes)){throw "Type '$Type' is not allowed by $ContractPath."}
$root = 'Q:/repos/botnexus-wt'
$path = Join-Path $root "$Issue-$ShortName"
$branch = "$Type/$Issue-$ShortName"
New-Item -ItemType Directory -Path $root -Force | Out-Null
if (Test-Path -LiteralPath $path) { throw "Worktree path exists: $path" }
git -C $RepoRoot fetch origin main
if ($LASTEXITCODE -ne 0) { throw 'Fetch failed.' }
git -C $RepoRoot worktree add $path -b $branch origin/main
if ($LASTEXITCODE -ne 0) { throw 'Worktree creation failed.' }
[pscustomobject]@{ issue=$Issue; path=($path -replace '\\','/'); branch=$branch; base='origin/main' } | ConvertTo-Json
