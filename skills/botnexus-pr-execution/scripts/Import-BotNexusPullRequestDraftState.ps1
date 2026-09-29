Set-StrictMode -Version Latest

$script:DraftStateMarkerPattern = '(?m)^<!-- botnexus:draft-state:v1:(?<payload>[A-Za-z0-9_-]+) -->\r?\n?'
$script:DraftStatusSectionPattern = '(?ms)^## Draft status\r?\n.*?(?=^## |\z)'

function ConvertTo-Base64Url([byte[]]$Bytes) {
  [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function ConvertFrom-Base64Url([string]$Value) {
  $padded = $Value.Replace('-','+').Replace('_','/')
  switch ($padded.Length % 4) { 2 { $padded += '==' } 3 { $padded += '=' } 1 { throw 'Invalid base64url draft-state payload.' } }
  [Convert]::FromBase64String($padded)
}

function Remove-BotNexusPullRequestDraftState([string]$Body) {
  $withoutMarker = [regex]::Replace([string]$Body, $script:DraftStateMarkerPattern, '')
  ([regex]::Replace($withoutMarker, $script:DraftStatusSectionPattern, '').TrimEnd() + "`n")
}

function Get-BotNexusPullRequestDraftState([string]$Body) {
  $match = [regex]::Match([string]$Body, $script:DraftStateMarkerPattern)
  if (-not $match.Success) {
    return [pscustomobject]@{ managed=$false; version=$null; reasons=@(); body=(Remove-BotNexusPullRequestDraftState $Body) }
  }
  try {
    $json = [Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $match.Groups['payload'].Value))
    $state = $json | ConvertFrom-Json
    $reasons = @($state.reasons | ForEach-Object {
      [pscustomobject]@{ code=([string]$_.code); detail=([string]$_.detail) }
    })
    [pscustomobject]@{ managed=$true; version=[int]$state.version; reasons=$reasons; body=(Remove-BotNexusPullRequestDraftState $Body) }
  } catch {
    [pscustomobject]@{ managed=$false; version=$null; reasons=@([pscustomobject]@{code='invalid-draft-state';detail=$_.Exception.Message}); body=(Remove-BotNexusPullRequestDraftState $Body) }
  }
}

function Set-BotNexusPullRequestDraftState([string]$Body,[object[]]$Reasons) {
  $normalized = @($Reasons | Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.code) } | ForEach-Object {
    [ordered]@{ code=([string]$_.code).Trim(); detail=([string]$_.detail).Trim() }
  } | Sort-Object code,detail -Unique)
  $clean = Remove-BotNexusPullRequestDraftState $Body
  if ($normalized.Count -eq 0) { return $clean }
  $json = [ordered]@{ version=1; reasons=$normalized } | ConvertTo-Json -Compress -Depth 5
  $payload = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($json))
  $lines = @('## Draft status','', 'This pull request remains draft for the following persisted reason(s):','')
  foreach ($reason in $normalized) { $lines += "- **$($reason.code):** $($reason.detail)" }
  $section = ($lines -join "`n") + "`n"
  "$clean`n$section`n<!-- botnexus:draft-state:v1:$payload -->`n"
}
