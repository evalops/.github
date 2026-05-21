# GitHub Actions Quota Hygiene

EvalOps repositories should keep CI evidence useful without letting GitHub
Actions minute or artifact quotas block unrelated pull requests.

## Blanket Static Analysis

Do not add CodeQL or GitHub default code-scanning workflows. EvalOps does not
use them, and they should not become required checks, scheduled jobs, or
generated default-setup runs.

Security checks need an owner and a runtime budget before they belong in CI.
Prefer narrow repository-owned checks that answer a concrete question:

- Semgrep custom rules for known repo-local failure modes.
- Contract, migration, schema, and architecture checks with small inputs.
- Secret scanning and Dependabot alerts handled through the security SLO.
- One-shot diagnostic scripts that are not required merge gates unless the
  signal is high-yield and fast.

When a scanner is slow, noisy, or ownerless, remove it instead of tuning the
required status list around it.

## Artifacts

Every `actions/upload-artifact` step must set `retention-days`.

Use short retention for diagnostics:

- PR logs, flaky-test logs, coverage HTML, drift previews: `3` to `7` days.
- Release candidate packages, SBOMs, promotion inventories: `7` to `14` days.
- Audit evidence needed for compliance review: keep the documented compliance
  retention window and make the degradation path explicit.

Diagnostic uploads should use `continue-on-error: true` when the prior command
already produced the gate result. Artifact quota exhaustion must not turn a
passing coverage, lint, or drift check into a failed required status.

## Runner Budget

Prefer Blacksmith runners for normal CI unless a vendor workflow requires
GitHub-hosted OIDC or trusted publishing. When a job stays on `ubuntu-latest`,
leave a comment explaining the dependency so later runner migrations do not
re-introduce quota or authentication failures.
