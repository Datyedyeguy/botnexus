<!-- This is an unfilled template, not validation evidence. Replace every placeholder with current, verified facts and remove these instructions before shipping. Never copy success counts or receipt IDs from another PR. -->

## Summary

<Describe the problem and the outcome of this change.>

<!-- Choose exactly one issue-link form after a clause-by-clause acceptance audit:
Full scope: Closes #<issue> only when every clause is verified or its remainder was separately filed and explicitly linked.
Partial scope: Refs #<issue>, name every unmet clause and its owner, and pass -PartialWork '<specific remaining scope>' to New-BotNexusPullRequest.ps1. Partial work must not auto-close the issue.
The commit's Refs trailer is a separate artifact emitted by the helper.
-->

## Root cause

<For a fix, explain the verified mechanism and relevant source. Otherwise remove this section if not applicable.>

## Changes

- <Describe a behavioral change, not a list of filenames.>

## Anti-reinvention

<Name the existing seams and tests reused, the searches performed, and why any new abstraction is necessary.>

## Tests

<Name happy/error/boundary regressions and actual proven-red or mutation evidence. State limitations; do not imply tests ran when they did not. Docs/chore changes may explain why code tests are not applicable.>

## Validation

<Record commands, source fingerprint, actual numeric results, and real receipt IDs from this change. For code: local changed-project compilation followed by the task's authoritative remote gate; inspect result.json tests total, executed, passed, failed, skipped, fixtureFailures, and isComplete. Exit status alone is not proof. For docs-only: npm run docs:build. Never run local test hosts on a live-gateway workstation.>

## UI evidence

<For visible UI changes, provide appropriately redacted real-agent screenshots/recordings and covered states. For a genuinely non-visible UI refactor state: No visible UI change — pure refactor. Remove this section for non-UI changes.>

## Risk & rollback

- <Describe blast radius and remaining uncertainty.>
- <Describe rollback.>
- <Account explicitly for test/assertion changes and prove that no assertion, skip, threshold, or baseline was weakened to obtain green.>

## Merge notes

<State dependencies and ordering, new files/stores, migration implications, supported setup/prerequisites, and scope exclusions. Do not claim a merge is authorized by passing checks.>

<!-- Drafts only: the publication helper inserts a visible `## Draft status` section and a machine-readable marker. Do not hand-author or edit either. Resolve the named blocker, update the normal sections with current evidence, and rerun Update-BotNexusPullRequest.ps1 without -Draft; the helper alone promotes after all gates pass. -->
