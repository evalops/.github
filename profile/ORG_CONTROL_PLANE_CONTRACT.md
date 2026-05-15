# EvalOps Org Control Plane Contract

This repository owns EvalOps org defaults: issue templates, pull request
templates, reusable workflow assets, workflow templates, public profile
guidance, and the service catalog. Those files act as agent-facing control
inputs, so changes need a small but explicit contract rather than prose-only
convention.

## Correctness Model

An org-default change is correct when it is portable, backed by live GitHub
context, and paired with a runnable check. The check should produce
machine-readable evidence first, then a human-readable summary. This lets
downstream agents cite source records, decisions, and outputs without smuggling
private operational assumptions into every repo.

## Threat Model

The sensitive path is any workflow, prompt, template, or catalog change that can
cause a downstream repo or agent to take privileged action. The expected failure
mode is fail-closed: missing secrets, missing provenance, dropped request bodies,
invalid catalog references, or prompt/template instructions that bypass live
GitHub checks must stop before publishing misleading artifacts or mutating GitHub
state.

Allowed degraded behavior is non-mutating reporting. For example, a local
contract report may still render markdown when optional operator tooling is not
available, but it must not claim a healthy sentinel run when the org-wide token
is absent.

## Evidence Chain

The contract in `.github/contracts/org-control-plane.yml` defines three stable
identifier groups:

- `source_records`: source files such as `AGENTS.md`, `README.md`, and
  `services.yaml`.
- `derived_decisions`: workflows or scripts that encode the policy choice.
- `emitted_outputs`: JSON or markdown artifacts that downstream agents and
  operators can cite.

Run the verifier before shipping changes that touch org-default policy:

```bash
ruby .github/scripts/verify-org-control-plane-contract.rb \
  --json-output org-control-plane-contract-report.json \
  --markdown-output org-control-plane-contract-report.md
```

The report includes source digests, counts for requirements and adversarial
fixtures, and explicit errors when a contract path or evidence field drifts.

## Research Assumptions

The generated mining issues that led to this contract referenced
retrieval-augmented and graph-backed evaluation work. The practical assumption
for this repo is modest: org-default automation should preserve cited source
records, keep derived decisions inspectable, and make degraded cases observable.
This repo remains standalone because it distributes GitHub defaults; when a
workflow needs runtime state, it should link to the owning EvalOps platform
primitive instead of pretending the state lives here.
