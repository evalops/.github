# EvalOps Engineering Practices

EvalOps should run engineering like an agent-native control system: high
throughput is welcome, but every repeated decision needs a durable contract,
live evidence, and a clear close condition.

The contract lives in `.github/contracts/engineering-practices.yml`. The audit
entrypoint is `.github/scripts/audit-engineering-practices.rb`.

## Org Rulesets

Use GitHub-native org rulesets as the central merge-safety layer. Repo-local
branch protection can stay for special cases, but the baseline should be tiered
from `services.yaml` and this contract:

- critical repos: evaluate rulesets first, then require the matching checks once
  each repo has adopted them
- standard repos: report missing rails and promote to enforcement after a clean
  adoption window
- experimental repos: keep lightweight reporting unless they become customer or
  production paths

The first rule should be boring: protect default branches from deletion and
non-fast-forward updates, require PRs for critical repos, and only add required
status checks after their workflows are present.

## Backlog Lifecycle

Generated issues are operational data, not a parking lot. Every generated
guardrail, conformance, telemetry, or evidence issue should carry:

- stable class key
- source fingerprints or representative feedback URLs
- owner repo
- smallest guardrail location
- last-seen window
- close condition with merged PR or audit evidence

If a bot comments that an issue is closing, the issue should actually close in
the same mutation. A "closing" comment on an open issue is stale state.

## Release Trains

Deploy PRs should change desired state, not serve as the state machine. Release
train holds, image syncs, rollback requests, and gate decisions should converge
on one active train record per environment.

Each active train record should include:

- environment and train id
- owner and TTL
- current desired image or artifact revision
- hold reason and unblock condition
- release receipt
- rollback receipt or explicit no-rollback note
- latest PR number that mutated the record

Automation should update the existing train record when possible instead of
opening repeated hold PRs with the same intent.

## Agent Review

Agent-assisted work should have an agent-native review lane:

- `EvalOpsBot` review requests route to the PR lens workflow
- review-thread guard blocks unresolved high-severity feedback
- CODEOWNERS names risky surfaces
- stable check contexts make the result queryable

The point is not more comments. The point is fewer missed regressions, faster
review-thread closure, and a durable query surface for follow-through.

## Security SLO

Security alerts need owners and burn-down windows, but the baseline must stay
cheap and targeted. Do not enable CodeQL, GitHub default code scanning, or any
other long-running blanket scanner as part of this practice. Use existing alert
state, Dependabot, secret scanning, and tuned lightweight analyzers only when
they have a clear owner and runtime budget.

Default SLO:

- critical: 1 day
- high: 7 days
- medium: 30 days

Suppressions need a reason, expiry, and artifact link. If an expensive scanner
is already producing bad signal, the practice is to disable or replace it with a
bounded check, not to make it required.

## Operating Rails

Repos should adopt rails by class rather than by memory:

- `AGENTS.md` for local agent behavior
- CODEOWNERS for risky surfaces
- dependency policy through Dependabot or Renovate
- Codex rails check for org-default contracts
- review-thread guard where review feedback should block
- EvalOpsBot review request workflow on high-churn repos
- shared runner-label/actionlint config for custom runner labels
- Pysa on active Python repos, or a documented exception

Critical repos should have all of the above unless an exception is captured in
the audit output.

## Evidence First

Done means the operator can see why the change is safe. For critical repos,
user-visible or production-visible PRs should carry at least one of:

- runtime smoke fixture
- artifact or release receipt
- telemetry or SLO gate
- rollback evidence
- explicit withheld-data note when customer data cannot be included

This makes EvalOps engineering practice reinforce the product promise: governed
work, with evidence, across human and agent operators.

## Local Audit

Validate the static contract without GitHub access:

```bash
ruby .github/scripts/audit-engineering-practices.rb --contract-only
```

Run the live audit with an authenticated `gh` session:

```bash
ruby .github/scripts/audit-engineering-practices.rb \
  --json-output engineering-practices-audit.json \
  --markdown-output engineering-practices-audit.md
```
