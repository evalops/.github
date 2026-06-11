# evalops/.github

Public organization defaults for EvalOps. This repository hosts the
organization profile and a set of operating-convention documents.

## What Lives Here

| Path | Purpose |
|---|---|
| `profile/README.md` | The public organization profile shown on github.com/evalops. |
| `profile/*.md` | EvalOps operating-convention notes (engineering practices, archival runbook, Codex workflow notes, tooling standards). |
| `SECURITY.md` | How to report a vulnerability in an EvalOps repository. |

## Org Automation

The org automation engine (review pipeline, guardrail workflows, helper
scripts, contracts, and the service catalog) lives in the private repository
`evalops/.github-private`. It was moved out of this public repository to reduce
public exposure of internal operational detail. Maintainers with access work in
`evalops/.github-private`.

## Security

See [`SECURITY.md`](SECURITY.md) to report a vulnerability. Report to
security@evalops.dev; do not open a public issue.
