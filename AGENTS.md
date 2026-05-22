# Repository Instructions

This repository provides org-level defaults for EvalOps repositories: default issue templates, PR templates, reusable workflow assets, community health files, and service catalog metadata.

## Codex App Operating Rails

- Treat changes here as org-wide process changes. Keep them small, explicit, and easy for downstream repos to override.
- Before editing templates, check live issues and PRs in `evalops/.github` so updates do not duplicate an existing convention effort.
- Template changes should improve evidence quality without making every PR or issue feel heavy. Prefer optional fields for specialized work and required fields only when missing them would block triage.
- When adding org-default guidance for agents, include concrete verification prompts: live `gh` checks, affected repos, generated artifacts, CI status, and release or deploy impact.
- Do not put repo-specific secrets, private environment details, or one-off local workflow assumptions in org defaults.

## EvalOps-on-EvalOps Agent Practice

- Start from live evidence: exact GitHub run, job, PR, log line, production signal, or runtime failure. Do not begin from repo guesses when `gh` can show current truth.
- Convert every actionable signal into either a merged PR or an accounted blocker. Accounted blockers must name the failing system, exact command or API, status, failure reason, and next unblocker.
- Prefer small action-factory PRs: one failure mode, one bounded fix, focused tests, clear rollback.
- Every PR must include `Summary`, `Test Plan`, and `Rollback`. Production or CI-failure PRs must also include the source signal URL or concrete runtime evidence.
- Never trust stale GitHub event payloads when enforcing gates. Refresh current PR metadata, current run state, and review-thread state from GitHub before deciding.
- After merge, verify the live follow-up surface. PR merge is not deployment proof. Check the relevant `main`, scheduled, dispatch, GitOps, Argo, or runtime workflow.
- A successful post-merge result may be resolved or transformed. If the original opaque or tooling failure moves to a real domain failure, record the new blocker explicitly.
- For EvalOps action-factory work, record shipped actions in Cerebro with lineage: repo, PR, branch, source signal, lane, checks, verifier artifact, policy flags, rollback, terminal state, and yield impact.
- Create independent verifier artifacts for shipped lanes under `outputs/evalops-action-factory/` when useful, especially for production or runtime fixes.
- No direct `main` mutation, no direct Kubernetes patching, and no `:latest` image tags. Use PRs and GitOps.
- Do not enable CodeQL, GitHub Code Scanning, SARIF upload, `github/codeql-action`, `upload-sarif`, or `security-events: write`. EvalOps does not use that surface.
- If touching GitHub Actions workflows that call Go, ensure Go is set up before the first `go run`, `go test`, `go build`, or `go install`, and add or prefer tests that enforce ordering.
- Use bounded one-shot polling only. Do not use `gh run watch`, `gh pr checks --watch`, or unbounded shell loops.

## Verification

- Validate YAML syntax for files under `.github/ISSUE_TEMPLATE/`.
- Inspect rendered Markdown for `.github/pull_request_template.md`.
- Run `ruby .github/scripts/validate-services-catalog.rb services.yaml` when touching the service catalog or catalog validation.
- Run `ruby -Itest -e 'ARGV.each { |path| require "./#{path}" }' test/*_test.rb` when touching helper scripts or validation rails.
- For default-template changes, create a PR and let repository maintainers review whether the org-wide wording is too broad.
