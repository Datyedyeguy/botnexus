Set-StrictMode -Version Latest
function Get-BotNexusIssueLeaseDirectory([object]$Contract) {
  if ($Contract.PSObject.Properties.Name -contains 'leaseDirectory' -and -not [string]::IsNullOrWhiteSpace([string]$Contract.leaseDirectory)) { return [string]$Contract.leaseDirectory }
  if ($Contract.PSObject.Properties.Name -contains 'leasePath' -and -not [string]::IsNullOrWhiteSpace([string]$Contract.leasePath)) { return (Split-Path -Parent ([string]$Contract.leasePath)) }
  throw 'Issue-delivery contract does not define a lease directory.'
}
function Get-BotNexusIssueLeasePath([object]$Contract,[int]$Issue) {
  Join-Path (Get-BotNexusIssueLeaseDirectory $Contract) ("issue-{0}.json" -f $Issue)
}
function Get-BotNexusIssueLeases([object]$Contract) {
  $directory=Get-BotNexusIssueLeaseDirectory $Contract
  if(-not(Test-Path -LiteralPath $directory -PathType Container)){return @()}
  @(
    Get-ChildItem -LiteralPath $directory -Filter 'issue-*.json' -File |
      ForEach-Object {
        try { Get-Content -LiteralPath $_.FullName -Raw|ConvertFrom-Json }
        catch { throw "Invalid issue delivery lease: $($_.FullName): $($_.Exception.Message)" }
      }
  )
}
