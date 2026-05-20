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
| `.github/agent-mcp/` | Canonical EvalOps MCP client config templates for public repo rollout. |
| `.github/codex/hooks/` | Example Codex hook pack for local EvalOps agent guardrails. |
| `.github/pull_request_template.md` | Default PR evidence checklist. |
| `.github/workflows/` | Reusable or self-validating workflows owned by the org defaults repo. |
| `.github/workflow-templates/` | Workflow picker templates for downstream adoption. |
| `.github/contracts/` | Versioned org-default contracts and conformance expectations. |
| `.github/scripts/` | Small helper scripts used by reusable workflows and validation rails. |
| `profile/` | Public organization profile and operating conventions. |
| `labels.yml` | Canonical additive label taxonomy for EvalOps repositories. |
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

### EvalOpsBot Review Requests

Use the EvalOpsBot webhook relay as the primary bridge from GitHub review
requests to the deep PR lens workflow. The relay receives
`pull_request.review_requested`, filters for `requested_reviewer.login ==
EvalOpsBot`, and dispatches `.github/workflows/evalops-pr-lens-review.yml` for
that exact `repo#PR`.

`.github/workflows/evalopsbot-review-request-dispatch.yml` remains as the
hourly fallback. It searches open EvalOps PRs with
`review-requested:EvalOpsBot`, skips head SHAs that already have an
`evalops-pr-lens/meta-review` signal, marks new matches as pending, and
dispatches the same workflow contract.

### Codex Workflow Templates

Use the workflow templates under `.github/workflow-templates/` to add Codex
lanes to downstream repositories:

- `codex-pr-review.yml` reviews PR diffs and posts focused findings.
- `codex-structured-pr-review.yml` reviews PR diffs with a JSON schema and
  posts actionable findings as inline review comments.
- `review-thread-guard.yml` fails PRs that still have unresolved, non-outdated
  high-priority review threads.
- `codex-ci-triage.yml` triages a specific failed Actions run.
- `codex-post-merge-verify.yml` checks default-branch health after merges.
- `codex-label-churn-audit.yml` audits PR label mutation loops.
- `pysa.yml` runs Pyre/Pysa taint analysis for Python repos.

Each template expects an `OPENAI_API_KEY` repository secret. Repositories that
need stronger, repo-specific behavior should copy the matching prompt from
`.github/codex/prompts/` into their own `.github/codex/prompts/` directory and
point the workflow at that file.

For deeper adoption patterns beyond PR comments, see
`profile/CODEX_HIGH_LEVERAGE_WORKFLOWS.md`.

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

### Review Thread Guard

Use `.github/workflow-templates/review-thread-guard.yml` on repos where review
threads should be merge blockers:

```yaml
name: Review thread guard

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

permissions:
  contents: read
  pull-requests: read

jobs:
  unresolved-review-threads:
    uses: evalops/.github/.github/workflows/review-thread-guard.yml@main
    with:
      pr_number: ${{ github.event.pull_request.number }}
```

The guard blocks unresolved, non-outdated review threads at `high` severity or
above by default. Use `workflow_dispatch` with `min_severity=p1` for repos that
only want release-blocking findings to fail.

### Codex Rails Check

Use `.github/workflows/codex-rails-check.yml` to validate repository operating
rails:

- issue template YAML
- workflow and workflow-template YAML
- workflow template metadata
- org control-plane contract shape and evidence chain
- engineering-practices contract shape and live-audit entrypoint
- canonical `labels.yml` shape
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

### Pysa Static Analysis

Use `.github/workflows/pysa.yml` to add Pyre/Pysa taint analysis to Python
repositories. Downstream repos can adopt it from the workflow template picker or
with:

```yaml
name: Pysa static analysis

on:
  pull_request:
    paths:
      - "**/*.py"
      - "pyproject.toml"
      - "requirements*.txt"
      - ".pyre_configuration*"
      - ".pysa/**"
  workflow_dispatch:

permissions:
  contents: read

jobs:
  pysa:
    uses: evalops/.github/.github/workflows/pysa.yml@main
    with:
      source_directories: "."
      taint_models_path: ".pysa"
```

Repos with custom dependency bootstrapping can pass `requirements_file` or
`setup_command`. Repos without committed Pyre configuration get a minimal
generated `.pyre_configuration` from `source_directories`.

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
ruby .github/scripts/verify-org-control-plane-contract.rb \
  --json-output org-control-plane-contract-report.json \
  --markdown-output org-control-plane-contract-report.md
ruby -Itest -e 'ARGV.each { |path| require "./#{path}" }' test/*_test.rb
ruby .github/scripts/validate-services-catalog.rb services.yaml
git diff --check
```

If workflows changed and `actionlint` is available, run it on touched workflow
files. Then check the PR's live GitHub Actions results before merging.

### Org Control Plane Contract

The contract in `.github/contracts/org-control-plane.yml` turns the repo's
agent-facing defaults into explicit conformance requirements. It names the
correctness model, threat model, SLO dimensions, provenance IDs, and adversarial
fixtures for prompt, tool, and data poisoning. The verifier emits JSON and
Markdown reports with source digests so downstream agents can cite the exact
inputs and decisions behind an org-default change.

See `profile/ORG_CONTROL_PLANE_CONTRACT.md` for the design note.

### Engineering Practices Audit

`.github/contracts/engineering-practices.yml` turns the current EvalOps
engineering-practice standard into an auditable contract. It covers org
rulesets, generated backlog lifecycle, release-train state, agent review,
security SLOs, repo operating rails, and evidence-first completion.

Validate only the contract shape locally:

```bash
ruby .github/scripts/audit-engineering-practices.rb --contract-only
```

Run the live audit with `gh` authenticated to EvalOps:

```bash
ruby .github/scripts/audit-engineering-practices.rb \
  --json-output engineering-practices-audit.json \
  --markdown-output engineering-practices-audit.md
```

`.github/workflows/engineering-practices-audit.yml` validates the contract on
PRs and runs the live, non-mutating audit on schedule or manual dispatch with
`EVALOPS_ORG_READ_TOKEN`.

### Label Taxonomy Sync

`labels.yml` is the canonical EvalOps label set, seeded from
`evalops/platform`. `.github/workflows/sync-labels.yml` dry-runs on PRs and
comments a per-repo diff. On `main`, weekly schedule, or manual dispatch with
`apply=true`, it reconciles active `evalops/*` repos additively: missing labels
are created, matching names get color/description updates, and repo-local labels
are left alone. A repo can opt out by committing `.github/labels-sync.disabled`.

Validate the taxonomy without touching GitHub:

```bash
ruby .github/scripts/sync-labels.rb --validate-only --labels labels.yml
```

### Agent MCP Config Rollout

The templates in `.github/agent-mcp/templates/` define the committed client
config for public repos:

- `.mcp.json` for Claude Code and other MCP clients that read the common JSON
  shape.
- `.codex/config.toml` for Codex.
- `.cursor/mcp.json` for Cursor.
- an `AGENTS.md` section explaining the EvalOps integration.
- `.gitignore` entries for local API-key fallbacks.

Check or write those files in any repo checkout with:

```bash
ruby .github/scripts/sync-agent-mcp-config.rb --workspace /path/to/repo --check
ruby .github/scripts/sync-agent-mcp-config.rb --workspace /path/to/repo --write
```

`.github/workflows/agent-mcp-config-rollout.yml` validates the templates on PRs.
Manual dispatch with `apply=true` and `EVALOPS_MCP_ROLLOUT_TOKEN` (or
`EVALOPS_ORG_WRITE_TOKEN`) opens rollout PRs against either the requested repos
or all active public `evalops/*` repos.

### Codex Hook Guardrails

`.github/scripts/evalops-codex-hook-guard.rb` implements warning-first local
guardrails for EvalOps agent work: session-start process reminders, dirty
worktree warnings before destructive git commands, and merge/readiness nudges
when review-thread evidence is missing. The example hook config is
`.github/codex/hooks/evalops-hooks.toml`.

See `profile/CODEX_HOOK_GUARDRAILS.md` for install notes and limitations.

### Strategy And Tooling Profiles

`profile/GOVERN_EXISTING_AI_FLEET.md` records the current EvalOps positioning
thesis and concrete retrofit surfaces. `profile/TYPESCRIPT_TOOLING_STANDARD.md`
captures the `gts`/`wireit` standardization path, including pilot criteria and
non-goals.

### Archived Dependabot Audit

`.github/workflows/archived-dependabot-audit.yml` runs a read-only audit for
archived EvalOps repos that still have `.github/dependabot.yml` or open
Dependabot PRs. The pre-archive checklist in `profile/ARCHIVAL_RUNBOOK.md`
requires removing Dependabot config and clearing bot PRs before setting
`archived=true`.

Run the audit locally with:

```bash
ruby .github/scripts/audit-archived-dependabot.rb \
  --owner evalops \
  --json-output archived-dependabot-audit.json \
  --markdown-output archived-dependabot-audit.md
```

### EvalOps PR Lens Review

`.github/workflows/evalops-pr-lens-review.yml` sweeps open PRs in
`evalops/platform`, `evalops/deploy`, and `evalops/maestro-internal` every two
hours, can be run manually for specific `repo#number` targets, and accepts
machine dispatches for on-demand EvalOpsBot review requests. It fans out one
reviewer per lens:

- migration safety
- NATS contract drift
- Argo manifest skew
- IAM blast radius
- generated SDK delta
- eval regression risk

Each lens writes a stable commit status context and best-effort Check Run named
`evalops-pr-lens/<lens>`. The meta-review step ranks findings by confidence,
updates `evalops-pr-lens/meta-review`, writes an operator summary to the workflow
run, and only posts a PR comment when findings clear the configured
high-confidence threshold.

Required secrets in `evalops/.github`:

- `EVALOPS_PR_LENS_TOKEN`: GitHub token with read/write access to the target
  repos for statuses and PR comments. This is the fallback path.
- `EVALOPS_PR_LENS_APP_ID`, `EVALOPS_PR_LENS_APP_PRIVATE_KEY`, and
  `EVALOPS_PR_LENS_APP_INSTALLATION_ID`: preferred GitHub App auth path for
  dispatch, comments, statuses, and Checks.
- `ANTHROPIC_API_KEY` or `EVALOPS_ANTHROPIC_API_KEY`: Anthropic key for Opus
  lens reviewers.
- `OPENAI_API_KEY` or `EVALOPS_OPENAI_API_KEY`: optional fallback when manually
  dispatching with `provider=openai`.

#### EvalOpsBot Review Requests

`EvalOpsBot` review requests should enter through a small webhook relay, not
per-repository workflow copies. The relay should listen for GitHub
`pull_request` webhook deliveries where:

- `action` is `review_requested`
- `requested_reviewer.login` is `EvalOpsBot`
- `repository.full_name` is an EvalOps repository
- `pull_request.number` is present

`.github/scripts/evalopsbot-webhook-relay.rb` is the checked-in relay core for
that endpoint. It verifies `X-Hub-Signature-256` when `GITHUB_WEBHOOK_SECRET`
is set, ignores non-matching deliveries, and dispatches this repository's
review workflow:

```bash
gh api --method POST repos/evalops/.github/dispatches --input - <<'JSON'
{
  "event_type": "evalopsbot-review-requested",
  "client_payload": {
    "target_repo": "evalops/deploy",
    "target_pr": "deploy#1234",
    "requested_reviewer": "EvalOpsBot"
  }
}
JSON
```

The workflow also accepts `target_prs`, `target_repos`, `provider`, `model`,
`max_diff_bytes`, and `min_confidence` in `client_payload` for controlled
operator overrides. Keep the relay token scoped to dispatching workflows in
`evalops/.github`; the review workflow itself owns the cross-repo read/write
token and model-provider credentials. Lens-specific routing defaults live in
`.github/pr-lens-routing.yml`.

`.github/workflows/evalopsbot-review-canary.yml` creates a harmless canary PR,
requests review from `EvalOpsBot`, waits for the deep-review meta signal, and
then closes the canary PR. `.github/workflows/evalopsbot-review-setup-audit.yml`
checks the configured target repository list, fallback workflows, and selected
review secret coverage so onboarding drift is visible before a real review
request is missed.
