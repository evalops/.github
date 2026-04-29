# EvalOps Codex Post-Merge Verification

Verify that a recently merged PR is actually healthy on the default branch.

Required checks:

- Identify the merge commit and affected workflows on `main`.
- Check the latest default-branch GitHub Actions runs, not stale PR checks.
- For deploy or runtime changes, describe the GitOps or live-state validation
  path and whether credentials were available.
- For local tooling, run the relevant local smoke or dry-run target.
- For tracing/event-bus work, verify trace propagation, subject/catalog
  alignment, and local simulation manifests.
- If a follow-up is needed, create or describe a precise issue with acceptance
  criteria.

Output:

- Healthy / unhealthy / inconclusive status.
- Evidence links or command outputs summarized in prose.
- Follow-up PR or issue recommendations.
