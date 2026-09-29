[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Worktree,
  [Parameter(Mandatory)][string]$Type,
  [string]$Scope,
  [Parameter(Mandatory)][string]$Subject,
  [Parameter(Mandatory)][int]$Issue,
  [Parameter(Mandatory)][string]$BodyFile,
  [string]$Why,
  [string]$Validated,
  [switch]$Breaking,
  [switch]$Draft,
  [string]$DraftReasonCode,
  [string]$DraftReasonDetail,
  [switch]$SkipScope,
  [string]$BaseBranch='main',
  [switch]$StackLayer,
  [string]$PartialWork,
  [switch]$NoScrubPaths,
  [switch]$WhatIf,
  [switch]$DryRun,
  [string]$ContractPath=''
)
$publisher=Join-Path $PSScriptRoot 'Publish-BotNexusPullRequest.ps1'
& $publisher @PSBoundParameters -Operation Create
exit $LASTEXITCODE
