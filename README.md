# evalops/.github

Org-level defaults for EvalOps repositories live here. Changes in this repo can
alter issue intake, pull request review prompts, reusable workflow behavior,
dependency update policy, and the public organization profile.

Treat this repository as a small control plane: conventions should be explicit,
validated, and easy for downstream repos to adopt without copying private
operational assumptions.

## What Lives Here

| Path | Purpose |
|---|---|
| `.github/ISSUE_TEMPLATE/` | Default issue forms for EvalOps repos that do not override them. |
| `.github/pull_request_template.md` | Default PR evidence checklist. |
| `.github/workflows/` | Reusable or self-validating workflows owned by the org defaults repo. |
| `.github/workflow-templates/` | Workflow picker templates for downstream adoption. |
| `.github/scripts/` | Small helper scripts used by reusable workflows and validation rails. |
| `profile/` | Public organization profile and operating conventions. |
| `renovate-config.json` | Shared Renovate preset for dependency update policy. |
| `services.yaml` | Lightweight service catalog for ownership, topology, and runtime tiering. |

## Maintainer Workflow

1. Start from fresh `origin/main`. This repo is small, but its effects are
   broad, so avoid stacking process changes on stale branches.
2. Check open issues and recent PRs in `evalops/.github` before adding a new
   convention. If the change is really a downstream rollout, open tracking
   issues in the owning repos instead of hiding the work here.
3. Keep defaults portable. Do not include repo-specific secrets, one-off runner
   assumptions, or private environment details.
4. Pair every new convention with a validation path. Prefer a reusable workflow,
   test, or script over prose-only policy when the rule can be checked.
5. Publish via PR and let downstream owners object if the wording or guardrail is
   too broad.

## Reusable Workflows

### Codex Workflow Templates

Use the workflow templates under `.github/workflow-templates/` to add Codex
lanes to downstream repositories:

- `codex-pr-review.yml` reviews PR diffs and posts focused findings.
- `codex-ci-triage.yml` triages a specific failed Actions run.
- `codex-post-merge-verify.yml` checks default-branch health after merges.
- `codex-label-churn-audit.yml` audits PR label mutation loops.

Each template expects an `OPENAI_API_KEY` repository secret. Repositories that
need stronger, repo-specific behavior should copy the matching prompt from
`.github/codex/prompts/` into their own `.github/codex/prompts/` directory and
point the workflow at that file.

### Agent Authorship Labels

Use `.github/workflows/agent-authorship-label.yml` to apply one authorship label
to each PR from commit trailers:

- `agent-authored`
- `agent-assisted`
- `mixed-authorship`

Downstream repos can adopt it from the workflow template picker or with:

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

For production repos, pin the reusable workflow to a reviewed commit SHA and
pass the same SHA as `helper_ref`. That keeps the workflow and helper scripts on
one immutable revision.

### Codex Rails Check

Use `.github/workflows/codex-rails-check.yml` to validate repository operating
rails:

- issue template YAML
- workflow and workflow-template YAML
- workflow template metadata
- `AGENTS.md` presence and non-empty content
- skill frontmatter
- `services.yaml` catalog shape
- Ruby tests under `test/`

The workflow can be called by downstream repos:

```yaml
jobs:
  codex-rails:
    uses: evalops/.github/.github/workflows/codex-rails-check.yml@main
    with:
      require_agents: true
```

## Service Catalog

`services.yaml` is intentionally lightweight. It should answer:

- which repo owns a service or tool
- which team is accountable for it
- whether it is critical, standard, or experimental
- where it runs
- which other catalog entries it depends on
- whether it consumes shared protobuf contracts

Validate it locally with:

```bash
ruby .github/scripts/validate-services-catalog.rb services.yaml
```

Use `depends_on` only for entries that also appear in `services.yaml`. Use
external links or notes in the owning repo for third-party dependencies.

## Local Verification

Before opening a PR from this repo, run the narrow checks that match the change:

```bash
ruby -Itest -e 'ARGV.each { |path| require "./#{path}" }' test/*_test.rb
ruby .github/scripts/validate-services-catalog.rb services.yaml
git diff --check
```

If workflows changed and `actionlint` is available, run it on touched workflow
files. Then check the PR's live GitHub Actions results before merging.
