[CmdletBinding(SupportsShouldProcess)]
param([string]$ContractPath,[string]$GatewayUrl='http://localhost:5005',[string]$AgentId='farnsworth',[datetimeoffset]$Now=[datetimeoffset]::UtcNow,[string]$ConversationsFixture,[string]$PullRequestsFixture,[string]$WorktreesFixture)
$ErrorActionPreference='Stop'
if(-not $ContractPath){$ContractPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'references/issue-delivery-contract.json'}
$contract=Get-Content -LiteralPath $ContractPath -Raw|ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Import-BotNexusIssueLease.ps1')
function Read-Json([string]$Fixture,[scriptblock]$Live){if($Fixture){@(Get-Content -LiteralPath $Fixture -Raw|ConvertFrom-Json)}else{@(& $Live)}}
$leases=@(Get-BotNexusIssueLeases $contract)
# One-time compatibility: retain an old global lease until its live evidence is represented
# by the normal conversation/worktree/PR filters; do not silently discard it.
if($contract.PSObject.Properties.Name -contains 'legacyLeasePath' -and (Test-Path -LiteralPath ([string]$contract.legacyLeasePath))){
  $legacy=Get-Content -LiteralPath ([string]$contract.legacyLeasePath) -Raw|ConvertFrom-Json
  $newPath=Get-BotNexusIssueLeasePath $contract ([int]$legacy.issue)
  if(-not(Test-Path -LiteralPath $newPath)){
    [IO.Directory]::CreateDirectory((Split-Path -Parent $newPath))|Out-Null
    Move-Item -LiteralPath ([string]$contract.legacyLeasePath) -Destination $newPath
    $leases=@(Get-BotNexusIssueLeases $contract)
  }
}
if(-not $leases.Count){[pscustomobject]@{status='idle';code='no-leases';active=@();retained=@();released=@()}|ConvertTo-Json -Depth 8 -Compress;return}
$expired=@($leases|Where-Object{[datetimeoffset]$_.expiresAt -le $Now})
$active=@($leases|Where-Object{[datetimeoffset]$_.expiresAt -gt $Now})
if(-not $expired.Count){[pscustomobject]@{status='active';code='leases-not-expired';active=$active;retained=@();released=@()}|ConvertTo-Json -Depth 8 -Compress;return}
$conversations=Read-Json $ConversationsFixture {
  try {
    $effectiveAgent=if([string]::IsNullOrWhiteSpace($AgentId)){[string]$contract.agentId}else{$AgentId}
    $uri=$GatewayUrl.TrimEnd('/')+"/api/conversations?agentId=$([uri]::EscapeDataString($effectiveAgent))"
    @(Invoke-RestMethod -Uri $uri -Method Get)
  }
  catch { throw "Conversation query failed: $($_.Exception.Message)" }
}
$prs=Read-Json $PullRequestsFixture {$raw=gh pr list --repo $contract.repository --state open --limit 500 --json number,headRefName,title,body;if($LASTEXITCODE){throw 'PR query failed.'};$raw|ConvertFrom-Json}
$worktrees=if($WorktreesFixture){@(Get-Content -LiteralPath $WorktreesFixture -Raw|ConvertFrom-Json)}else{@(& git -C $contract.repositoryRoot worktree list --porcelain|Where-Object{$_ -like 'worktree *'}|ForEach-Object{[pscustomobject]@{path=($_ -replace '^worktree ','')}})}
$retained=@();$released=@()
foreach($lease in $expired){
  $n=[int]$lease.issue;$evidence=@()
  if(@($conversations|Where-Object{$_.status -eq 'Active' -and ([string]$_.title -match "^$n\s+-\s+" -or $_.conversationId -eq $lease.conversationId)}).Count){$evidence+='active-conversation'}
  if(@($prs|Where-Object{"$($_.headRefName)`n$($_.title)`n$($_.body)" -match "(?i)(?:#|/)$n(?:\b|-)"}).Count){$evidence+='open-pr'}
  if(@($worktrees|Where-Object{[string]$_.path -match "(?i)(?:[/\\]|-)$n-"}).Count){$evidence+='worktree'}
  if($evidence.Count){$retained+=[pscustomobject]@{issue=$n;evidence=$evidence;lease=$lease};continue}
  $path=Get-BotNexusIssueLeasePath $contract $n
  if($PSCmdlet.ShouldProcess($path,"Remove expired issue #$n lease with no live evidence")){Remove-Item -LiteralPath $path -Force;if(Test-Path -LiteralPath $path){throw "Reconciled lease removal failed for issue #$n."}}
  $released+=$n
}
[pscustomobject]@{status=if($retained.Count){'retained'}elseif($released.Count){'released'}else{'active'};code=if($retained.Count){'stale-leases-have-live-evidence'}elseif($released.Count){'stale-leases-released'}else{'leases-not-expired'};active=$active;retained=$retained;released=$released}|ConvertTo-Json -Depth 8 -Compress
