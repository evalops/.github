# EvalOps Codex PR Review

Review the pull request as an EvalOps maintainer. Focus on defects, behavioral
regressions, missing tests, generated artifact drift, security footguns, and
operational risk. Prefer concise findings over broad summaries.

Required checks:

- Inspect the diff against the PR base and identify the affected repos,
  services, workflows, contracts, generated files, and deployment surfaces.
- Read any `AGENTS.md` files that apply to changed paths before reviewing.
- Use live GitHub context when available: PR description, labels, checks,
  review comments, unresolved review threads, and recent CI failures.
- For generated code, verify whether the generator or checked-in output is the
  source of truth before recommending direct edits.
- For infrastructure or workflow changes, call out whether the change affects
  labels, branch protection, automation, release trains, or GitOps desired
  state.
- For tracing or event-bus changes, verify trace context, subject/catalog
  alignment, and local simulation coverage.

Output:

- Start with actionable findings ordered by severity.
- Include file paths and line references when possible.
- Include a short residual-risk note when the diff looks clean.
- Do not approve a PR solely because tests pass if unresolved review threads or
  failing checks remain.
