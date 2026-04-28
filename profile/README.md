# EvalOps

The organizational operating system for AI agent workforces — evaluation, governance, and observability for shipping accountable AI.

## Operating Conventions

- [Agent authorship attribution](AGENT_AUTHORSHIP.md) — git trailers, PR labels, and audit indexing for Maestro-authored code.
- [GitHub Actions quota hygiene](GITHUB_ACTIONS_QUOTA.md) — CodeQL scoping, artifact retention, and quota-safe diagnostics.

## Platform Services

Discover repos by topic:

- [`evalops-platform`](https://github.com/search?q=topic%3Aevalops-platform+org%3Aevalops&type=repositories) — Core Go microservices (identity, governance, metering, approvals, and more)
- [`evalops-product`](https://github.com/search?q=topic%3Aevalops-product+org%3Aevalops&type=repositories) — Product frontends (console, admin, maestro)
- [`evalops-infra`](https://github.com/search?q=topic%3Aevalops-infra+org%3Aevalops&type=repositories) — Deployment and infrastructure
- [`evalops-data`](https://github.com/search?q=topic%3Aevalops-data+org%3Aevalops&type=repositories) — Data pipelines and analytics
- [`evalops-docs`](https://github.com/search?q=topic%3Aevalops-docs+org%3Aevalops&type=repositories) — Documentation

## Key Repos

| Repo | Description |
|---|---|
| [proto](https://github.com/evalops/proto) | Canonical protobuf contracts across all services |
| [service-runtime](https://github.com/evalops/service-runtime) | Shared Go runtime for platform services |
| [deploy](https://github.com/evalops/deploy) | GitOps delivery: K8s manifests, Terraform, ArgoCD |
| [console](https://github.com/evalops/console) | Fleet dashboard — mission control UI |
