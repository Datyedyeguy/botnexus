[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][int]$Issue,[Parameter(Mandatory)][string]$BodyFile,[string]$Title,[string]$Repository='Sytone/botnexus')
$ErrorActionPreference='Stop'
if(-not(Test-Path -LiteralPath $BodyFile -PathType Leaf)){throw "Body file not found: $BodyFile"}
$item=gh issue view $Issue --repo $Repository --json number,state,title,body,author,url|ConvertFrom-Json
if($LASTEXITCODE){throw "Issue #$Issue read failed."}
$trusted=@('sytone','agent-farnsworth[bot]','app/agent-farnsworth')
if($item.state -ne 'OPEN' -or $item.author.login -notin $trusted){throw 'Grooming mutation is allowed only for trusted-authored open issues.'}
$body=Get-Content -LiteralPath $BodyFile -Raw
if([string]::IsNullOrWhiteSpace($body)){throw 'Groomed issue body is empty.'}
foreach($heading in 'Summary','Why it matters','Example'){if($body -notmatch "(?im)^##\s+$([regex]::Escape($heading))\s*$"){throw "Groomed issue body is missing required section: $heading"}}
$forbidden=@('C:/Users/','C:\\Users\\','\.botnexus','conversationId','sessionId','subscriptionId','tenantId','jobullen@','microsoft\.com')
foreach($pattern in $forbidden){if($body -match $pattern){throw "Disclosure check rejected issue body pattern: $pattern"}}
$nextTitle=if([string]::IsNullOrWhiteSpace($Title)){[string]$item.title}else{$Title.Trim()}
if($PSCmdlet.ShouldProcess("issue #$Issue",'Update trusted issue title/body for grooming')){gh issue edit $Issue --repo $Repository --title $nextTitle --body-file $BodyFile|Out-Null;if($LASTEXITCODE){throw "Issue #$Issue update failed."};$stored=gh issue view $Issue --repo $Repository --json state,title,body,author|ConvertFrom-Json;if($LASTEXITCODE){throw 'Grooming readback failed.'};if($stored.state -ne 'OPEN' -or $stored.author.login -notin $trusted -or $stored.title -cne $nextTitle -or (([string]$stored.body -replace "`r`n","`n") -cne ($body -replace "`r`n","`n"))){throw 'Grooming readback drift.'}}
[pscustomobject]@{status=if($WhatIfPreference){'preview'}else{'updated'};issue=$Issue;title=$nextTitle;url=$item.url}|ConvertTo-Json -Compress
