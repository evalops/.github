# EvalOps Repository Archival Runbook

Before archiving an EvalOps repository, remove automation that can continue
opening work against the read-only archive.

## Pre-Archive Checklist

- Confirm the replacement location is documented in the archived repository
  description.
- Remove `.github/dependabot.yml` or otherwise disable Dependabot version
  updates before setting `archived=true`.
- Close or migrate open Dependabot PRs while the repository is still writable.
- Make sure org-wide PR dashboards and ship-digest style tools filter archived
  repositories.
- Record any intentionally stranded PRs in the archival issue.

## Audit

Run the archived Dependabot audit from this repo:

```bash
ruby .github/scripts/audit-archived-dependabot.rb \
  --owner evalops \
  --json-output archived-dependabot-audit.json \
  --markdown-output archived-dependabot-audit.md
```

The audit is read-only. It reports archived repos that still contain a
Dependabot config and any open Dependabot PRs that need temporary unarchive,
manual closure, or org-level Dependabot disablement.
