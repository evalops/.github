# GitHub Actions Quota Hygiene

EvalOps repositories should keep CI evidence useful without letting GitHub
Actions minute or artifact quotas block unrelated pull requests.

## CodeQL

Run CodeQL on `main`, on a weekly schedule, and through manual dispatch. For
pull requests, scope CodeQL with `paths` so documentation, GitOps metadata, and
workflow-only changes do not spend full multi-language analysis capacity.

Recommended PR path set:

```yaml
on:
  pull_request:
    paths:
      - ".github/workflows/codeql.yml"
      - "go.mod"
      - "go.sum"
      - "**/*.go"
      - "package.json"
      - "package-lock.json"
      - "pnpm-lock.yaml"
      - "yarn.lock"
      - "bun.lock"
      - "bun.lockb"
      - "**/*.js"
      - "**/*.jsx"
      - "**/*.mjs"
      - "**/*.cjs"
      - "**/*.ts"
      - "**/*.tsx"
      - "pyproject.toml"
      - "poetry.lock"
      - "requirements*.txt"
      - "**/*.py"
```

Keep the checked-in CodeQL workflow explicit. Do not rely on generated CodeQL
runs when runner placement, matrix languages, or branch behavior matter.

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
