# EvalOps Codex CI Failure Triage

Investigate the failing GitHub Actions run for this repository and produce a
minimal fix plan or patch.

Required checks:

- Start from the exact failing run, job, and step. Do not infer from workflow
  names alone.
- Fetch failed logs with `gh run view --log-failed` and fall back to the
  Actions jobs API when the log output is empty.
- Distinguish stale failures on superseded SHAs from failures on the live PR or
  `main` tip.
- Group related failures by root cause and avoid unrelated refactors.
- If the failure is a workflow issue, inspect path filters, generated workflow
  surfaces, branch protection expectations, and pinned action policy.
- If the failure is test or code behavior, run the smallest local reproduction
  before proposing broader gates.

Output:

- Root cause with run/job evidence.
- Minimal fix or the exact reason no code change is appropriate.
- Commands run locally.
- Remaining CI or review-thread work.
