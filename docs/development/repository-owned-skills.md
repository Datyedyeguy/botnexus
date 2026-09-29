# Repository-owned BotNexus workflow skills

BotNexus-specific workflow automation is maintained in this repository under `skills/`.
The repository is the only editable source of truth for these skills:

- `skills/botnexus-pr-execution/`
- `skills/botnexus-backlog-grooming/`

The installed copies under `<BOTNEXUS_HOME>/skills/` are deployment output. Do not edit those copies as the durable source; make a branch and pull request against this repository instead.

## Installation and updates

The `BotNexus.Cli` dotnet-tool package contains the repository-owned skill trees.

- `botnexus init` synchronizes the packaged copies into the selected BotNexus home, including when `config.json` already exists.
- `botnexus update` synchronizes from the updated source checkout after `git pull` and before any rebuild/restart decision.
- Unrelated global skills are preserved.
- Files inside the two repository-owned skill directories are replaced from source, and stale files inside those managed directories are removed. This prevents installed copies from drifting away from reviewed source.
- Repeating synchronization over identical content is a no-op.

A custom home selected through `--target` or `BOTNEXUS_HOME` receives the same synchronization behavior.

## Validation

PowerShell contract scripts stored inside each skill remain executable tests. Repository changes to these skills must run their applicable contract scripts and the ordinary authoritative repository validation gate. The CLI tests also pin cross-platform synchronization behavior, managed-directory cleanup, preservation of unrelated skills, and idempotency.
