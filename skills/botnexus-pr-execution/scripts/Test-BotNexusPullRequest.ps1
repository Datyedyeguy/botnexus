[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Title,
  [Parameter(Mandatory)][string]$Body,
  [Parameter(Mandatory)][int]$Issue,
  [string]$ContractPath = 'Q:/repos/botnexus/.github/pr-contract.json',
  [switch]$PartialWork
)
$ErrorActionPreference='Stop'
if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) { throw "PR contract not found: $ContractPath" }
$contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
$violations = [Collections.Generic.List[object]]::new()
function Add-Violation([string]$Code,[string]$Property,[string]$Message) { $violations.Add([pscustomobject]@{code=$Code;property=$Property;message=$Message}) }
$titleMatch = [regex]::Match($Title,'^(?<type>[a-z]+)(\((?<scope>[^)]+)\))?(?<bang>!)?: (?<subject>.+)$')
$type = if($titleMatch.Success){$titleMatch.Groups['type'].Value}else{$null}
if(-not $titleMatch.Success){ Add-Violation 'invalid-title' 'Title' 'Title must use Conventional Commits format.' }
elseif($type -notin @($contract.allowedTypes)){ Add-Violation 'invalid-type' 'Title' "Unsupported PR type: $type" }
if($Title.Length -gt [int]$contract.maximumTitleLength){ Add-Violation 'title-too-long' 'Title' "Title exceeds $($contract.maximumTitleLength) characters." }
if($titleMatch.Success -and $titleMatch.Groups['subject'].Value -match '\.$'){ Add-Violation 'invalid-title' 'Title' 'Title subject must not end with a period.' }
$visible=[regex]::Replace($Body,'(?s)<!--.*?-->','')
$headings=@([regex]::Matches($visible,'(?m)^#{1,4}\s+(.+?)\s*$')|ForEach-Object{$_.Groups[1].Value.Trim().ToLowerInvariant()})
$required=[Collections.Generic.List[string]]::new(); foreach($x in @($contract.requiredSections.base)){$required.Add([string]$x)}
if($type -and $type -notin @($contract.typesWithoutTests)){ foreach($x in @($contract.requiredSections.tested)){$required.Add([string]$x)} }
if($type -eq 'fix'){ foreach($x in @($contract.requiredSections.fix)){$required.Add([string]$x)} }
foreach($section in @($required|Select-Object -Unique)){
  if($section -notin $headings){ Add-Violation 'missing-section' 'Body' "Missing required section: $section"; continue }
  $escaped=[regex]::Escape($section); $match=[regex]::Match($visible,"(?ims)^#{1,4}\s+$escaped\s*`r?`n(?<content>.*?)(?=^#{1,4}\s+|\z)")
  if(-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups['content'].Value)){ Add-Violation 'empty-section' 'Body' "Required section is empty: $section" }
  else { foreach($pattern in @($contract.placeholderPatterns)){ if($match.Groups['content'].Value -match [string]$pattern){ Add-Violation 'placeholder-content' 'Body' "Required section contains placeholder content: $section"; break } } }
}
$linkPattern = if($PartialWork){[string]$contract.issueLink.partial}else{[string]$contract.issueLink.full}
$link=[regex]::Match($visible,$linkPattern,'IgnoreCase')
if(-not $link.Success){ Add-Violation 'invalid-issue-link' 'Body' $(if($PartialWork){"Partial work must use Refs #$Issue."}else{"Full work must use Closes #$Issue (or Fixes/Resolves)."}) }
elseif([int]$link.Groups['issue'].Value -ne $Issue){ Add-Violation 'invalid-issue-link' 'Body' "Body links issue #$($link.Groups['issue'].Value), expected #$Issue." }
if($PartialWork -and $visible -match [string]$contract.issueLink.full){ Add-Violation 'invalid-issue-link' 'Body' 'Partial work must not auto-close an issue.' }
[pscustomobject]@{valid=($violations.Count -eq 0);type=$type;requiredSections=@($required|Select-Object -Unique);violations=@($violations)}
