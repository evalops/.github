# EvalOps Codex Local Traffic Canary

Investigate a failure in local developer tooling, traffic simulation, or
distributed tracing.

Required checks:

- Start from the failing command and preserve its output.
- Inspect `AGENTS.md`, Makefile targets, local compose files, traffic profiles,
  and tracing docs before changing behavior.
- Prefer dry-run validations first, then dependency-backed local smoke only
  when Docker and local ports are available.
- Verify that generated trace IDs, `traceparent`, NATS subjects, and manifest
  paths match the repo contract.
- Keep fixes local-tooling focused unless the failure exposes a production
  contract bug.

Output:

- Failing command and root cause.
- Patch or precise follow-up if credentials/local services are unavailable.
- Verification commands that future developers can run.
