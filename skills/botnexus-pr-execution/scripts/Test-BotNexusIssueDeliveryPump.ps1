[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$pump=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-BotNexusIssueDeliveryPump.ps1') -Raw
$checks=@(
  @{name='uses-deterministic-dispatcher';ok=$pump -match 'Invoke-BotNexusIssueDeliveryDispatch\.ps1'},
  @{name='serializes-coordinator-invocations';ok=$pump -match 'farnsworth-pump\.lock' -and $pump -match 'pump-already-running' -and $pump -match 'FileShare\]::None'},
  @{name='passes-gateway-census-route';ok=$pump -match 'GatewayUrl=\$GatewayUrl' -and $pump -match 'AgentId=\$AgentId'},
  @{name='creates-conversation-through-local-api';ok=$pump -match "Invoke-Api Post '/api/conversations'"},
  @{name='binds-delivery-lease';ok=$pump -match 'Set-BotNexusIssueLeaseConversation\.ps1'},
  @{name='posts-asynchronous-kickoff';ok=$pump -match '/api/agents/\$AgentId/conversations/\$conversationId/messages' -and $pump -match 'wake=\$true'},
  @{name='forbids-pr-specific-cron';ok=$pump -match 'Do not create a PR-specific cron'},
  @{name='whatif-does-not-mutate';ok=$pump -match '\$dispatchArgs\.WhatIf=\$true' -and $pump -match "'preview'"},
  @{name='failed-handoff-releases-owned-reservation';ok=$pump -match 'Release-BotNexusIssueLease\.ps1' -and $pump -match 'A reservation without a bound execution conversation'}
)
foreach($c in $checks){if(-not $c.ok){throw "Pump contract failed: $($c.name)"}}
[pscustomobject]@{total=$checks.Count;passed=$checks.Count;failed=0;checks=$checks.name}|ConvertTo-Json -Compress
