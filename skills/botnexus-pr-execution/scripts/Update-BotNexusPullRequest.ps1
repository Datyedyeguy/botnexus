[CmdletBinding()]
param(
  [Parameter(Mandatory)][int]$PullRequestNumber,
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
  [switch]$MetadataOnly,
  [switch]$DraftMetadataOnly,
  [string]$DraftReasonCode,
  [string]$DraftReasonDetail,
  [string[]]$ResolveDraftReasonCode = @(),
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
& $publisher @PSBoundParameters -Operation Update
exit $LASTEXITCODE
