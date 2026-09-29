# Maintenance phase: shared. Owning contract: references/script-phases.json.
<#
.SYNOPSIS One-shot bot auth for Sytone/botnexus. Fetch fresh agent-farnsworth[bot] token,
  export GH_TOKEN, set worktree identity, and stage a PER-INVOCATION git auth header.
  Replaces token+auth switch+auth status+remote (~963/run).
.DESCRIPTION
  #3070: this helper used to rewrite `origin` to
  `https://x-access-token:<token>@github.com/Sytone/botnexus.git`, which writes a LIVE
  installation token in plaintext into the worktree's `.git/config`. The scrub that removed
  it was the last step of New-BotNexusPullRequest.ps1's ship sequence, so any of the ~dozen
  intermediate failure paths left a working credential readable by every process running as
  the user, indefinitely. It also pointed a test fixture's `origin` at PRODUCTION, which is
  how a scratch clone of a LOCAL bare repo came to attempt a push against Sytone/botnexus.

  The remote is now left as the plain URL and the credential is supplied per-invocation via
  `git -c http.extraHeader=...` on the single push. `-c` values live in the process argv for
  the lifetime of one git call; nothing is ever written to a file on disk. Callers read the
  header out of $env:BOTNEXUS_GIT_AUTH_HEADER, which this script sets IN-PROCESS -- so it
  must be invoked as `& Use-FarnsworthBot.ps1`, never `pwsh -File`, for the same reason
  $env:GH_TOKEN has always had to be (a child pwsh sets its own copy and exits).
.PARAMETER RepoPath worktree/repo to configure.
.PARAMETER Scrub clear the token + auth header, and defensively restore a plain remote
  (pre-#3070 configs may still carry an embedded credential).
.EXAMPLE pwsh -NoProfile -File Use-FarnsworthBot.ps1 -RepoPath Q:\repos\botnexus-wt\feat-x
#>
param([string]$RepoPath,[switch]$Scrub)
$ErrorActionPreference='Stop'
$bot='agent-farnsworth[bot]';$email='293187211+agent-farnsworth[bot]@users.noreply.github.com'

# Strip HTTP(S) userinfo, not repository identity. Do not URI-roundtrip local paths or
# SSH remotes: their username/path is transport identity, not an embedded HTTP token.
function Clear-RepoCredentialConfig([string]$Path) {
  # Linked worktrees reject --worktree unless this extension is enabled. Inspect the
  # effective boolean without changing it; absent/false means only shared local config.
  $worktreeConfig = (& git -C $Path config --bool --get extensions.worktreeConfig 2>$null) -join ''
  if ($LASTEXITCODE -notin @(0, 1)) { throw 'Could not determine worktree configuration scope for credential scrub.' }
  $scopes = @('--local')
  if ($worktreeConfig -eq 'true') { $scopes += '--worktree' }
  foreach ($scope in $scopes) {
    $urlKeys = @(& git -C $Path config $scope --name-only --get-regexp '^remote\..*\.(url|pushurl)$' 2>$null)
    if ($LASTEXITCODE -notin @(0, 1)) { throw 'Could not enumerate remote configuration for credential scrub.' }
    foreach ($key in ($urlKeys | Select-Object -Unique)) {
      $urls = @(& git -C $Path config $scope --get-all $key 2>$null)
      if ($LASTEXITCODE -ne 0) { throw 'Could not read remote configuration for credential scrub.' }
      $clean = @($urls | ForEach-Object { $_ -replace '^(https?://)[^/@\s]+@', '$1' })
      if (@(Compare-Object $urls $clean -SyncWindow 0).Count -eq 0) { continue }
      & git -C $Path config $scope --unset-all $key *>$null
      if ($LASTEXITCODE -ne 0) { throw 'Could not remove credential-bearing remote configuration.' }
      foreach ($url in $clean) {
        & git -C $Path config $scope --add $key $url *>$null
        if ($LASTEXITCODE -ne 0) { throw 'Could not restore credential-free remote configuration.' }
      }
    }
    $keys = @(& git -C $Path config $scope --name-only --get-regexp '^http\..*extraheader$' 2>$null)
    if ($LASTEXITCODE -notin @(0, 1)) { throw 'Could not enumerate HTTP headers for credential scrub.' }
    foreach ($key in ($keys | Select-Object -Unique)) {
      if ($key) {
        & git -C $Path config $scope --unset-all $key *>$null
        if ($LASTEXITCODE -ne 0) { throw 'Could not remove persisted HTTP authentication header.' }
      }
    }
  }
}

if($Scrub){
  # Defensive, not load-bearing for the remote: the auth path no longer embeds a credential,
  # but a worktree configured by a PRE-#3070 run (or stranded by a failed ship) still has one
  # on disk. Purge every place a credential can persist, not just `origin` -- an embedded
  # userinfo URL is only one of the shapes; `http.*.extraHeader` is another, and a scrub that
  # only reset the remote would leave it live.
  if($RepoPath -and (Test-Path -LiteralPath $RepoPath)){
    try { Clear-RepoCredentialConfig $RepoPath }
    finally { $env:GH_TOKEN=$null; $env:BOTNEXUS_GIT_AUTH_HEADER=$null }
  }
  $env:GH_TOKEN=$null; $env:BOTNEXUS_GIT_AUTH_HEADER=$null
  $rp = if($RepoPath){$RepoPath}else{'Q:\repos\botnexus'}
  @{ok=$true;scrubbed=$true;coreBare=(git -C $rp config --get core.bare)}|ConvertTo-Json -Compress; return
}

# A failed refresh must not leave inherited credentials usable. Validate the native
# boundary before publishing auth or allowing any Git mutation; never echo child output.
Remove-Item Env:GH_TOKEN,Env:BOTNEXUS_GIT_AUTH_HEADER -ErrorAction SilentlyContinue
try {
  $tokenRecords = @(pwsh -NoProfile -File 'C:\Users\jobullen\.botnexus\scripts\get-farnsworth-token.ps1' 2>$null)
  $tokenExitCode = $LASTEXITCODE
  if ($tokenExitCode -ne 0) { throw 'Token child failed.' }
  if ($tokenRecords.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$tokenRecords[0]) -or [string]$tokenRecords[0] -match '\s') {
    throw 'Token child returned invalid output.'
  }
  $token = [string]$tokenRecords[0]
} catch {
  Remove-Item Env:GH_TOKEN,Env:BOTNEXUS_GIT_AUTH_HEADER -ErrorAction SilentlyContinue
  throw 'Farnsworth token acquisition failed; authentication was not published.'
}
$env:GH_TOKEN=$token
# Basic auth over HTTPS is what the embedded-credential URL was doing implicitly; doing it
# explicitly is what lets it stay off disk.
$env:BOTNEXUS_GIT_AUTH_HEADER="AUTHORIZATION: basic " +
  [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("x-access-token:$token"))

if($RepoPath){
  git -C $RepoPath config user.name $bot
  git -C $RepoPath config user.email $email
  # Auth never chooses a destination. Remove legacy credentials without repointing a
  # fixture, fork, push URL or SSH remote at production (#3923).
  Clear-RepoCredentialConfig $RepoPath
  git -C $RepoPath config core.bare false
}
@{ok=$true;tokenLen=$token.Length;repo=$RepoPath;authHeaderSet=$true}|ConvertTo-Json -Compress
