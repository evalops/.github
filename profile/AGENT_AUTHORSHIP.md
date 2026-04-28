# Agent Authorship Attribution

EvalOps uses agent-written code in the same systems that sell audit, approvals,
and governance. Our own repositories should therefore answer a basic operating
question: which production changes were written by an agent, under which human's
direction, and through which approval chain?

This convention makes agent authorship git-native, visible in GitHub, and ready
for audit-service indexing.

## Commit Trailers

Every Maestro-authored commit must include these trailers:

```text
Co-Authored-By: Maestro <maestro@evalops.dev>
Maestro-Version: <maestro-version> / <model-identifier>
Maestro-Prompt-Id: <prompt-registry-id>
Maestro-Approvals-Id: <approvals-service-request-id>
```

Use one trailer block per commit. If a human materially edits agent output before
commit, keep the human as the git author and keep the Maestro trailers so the
chain remains visible.

### Field Rules

| Trailer | Required | Purpose |
|---|---:|---|
| `Co-Authored-By` | Yes | Lets GitHub render Maestro as a co-author and gives git-native provenance. |
| `Maestro-Version` | Yes | Records the Maestro build and model identifier used for the change. |
| `Maestro-Prompt-Id` | Yes | Links the commit to the prompt registry entry that shaped the work. |
| `Maestro-Approvals-Id` | Yes | Links the commit to the approvals request that authorized the change. |

If an identifier is not available, do not invent one. Use the best durable
identifier the producing system has and file a follow-up against that system.

## Pull Request Labels

The reusable workflow in this repository applies exactly one authorship label to
each PR:

| Label | Meaning |
|---|---|
| `agent-authored` | Every commit in the PR carries Maestro authorship metadata. |
| `human-authored` | No commit in the PR carries Maestro authorship metadata. |
| `mixed-authorship` | Some commits carry Maestro metadata and some do not. |

The labels are a GitHub UI affordance. The commit trailers remain the source of
truth because they travel with the git history.

## Reusable Workflow

Adopt the org workflow from the GitHub Actions template picker, or add this file
to a repository as `.github/workflows/agent-authorship-labels.yml`:

```yaml
name: Agent authorship labels

on:
  pull_request_target:
    types: [opened, synchronize, reopened, ready_for_review, edited]

permissions:
  contents: read
  pull-requests: write
  issues: write

jobs:
  label:
    uses: evalops/.github/.github/workflows/agent-authorship-label.yml@main
```

The workflow creates the three labels if they are missing, removes stale
authorship labels, and applies the label that matches the current PR commit set.

## Audit Indexing

Audit ingestion should parse trailers from every commit merged to protected
branches and index at least:

- commit SHA
- git author and committer
- `Maestro-Version`
- `Maestro-Prompt-Id`
- `Maestro-Approvals-Id`
- merged PR number and repository

The target product query is:

```text
For this production line, show the commit, Maestro version, prompt, approvals
request, human author, and merge PR that produced it.
```

## Backfill

Do not rewrite old commit history to add trailers. For pre-convention PRs, use
best-effort labels only when evidence is clear. If evidence is heuristic, prefer
a separate `agent-authored-pre-convention` follow-up instead of weakening the
meaning of the three current labels.
