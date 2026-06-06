# EvalOps

The control plane for AI agent workforces — see which agents, assistants, and tools are running, govern what each one is allowed to do through policy, approvals, evaluation, cost, and audit, and measure how much of their real action surface is actually covered. Widen autonomy only as the record supports it.

## Operating Conventions

- [Agent authorship attribution](AGENT_AUTHORSHIP.md) — git trailers, PR labels, and audit indexing for Maestro-authored code.
- [GitHub Actions quota hygiene](GITHUB_ACTIONS_QUOTA.md) — scanner budget, artifact retention, and quota-safe diagnostics.
- [Engineering practices](ENGINEERING_PRACTICES.md) — tiered merge policy, backlog lifecycle, release trains, security SLOs, and evidence-first completion.

## Platform Services

Discover repos by topic:

- [`evalops-platform`](https://github.com/search?q=topic%3Aevalops-platform+org%3Aevalops&type=repositories) — Core Go microservices (identity, governance, metering, approvals, and more)
- [`evalops-product`](https://github.com/search?q=topic%3Aevalops-product+org%3Aevalops&type=repositories) — Product frontends (maestro, conductor, admin)
- [`evalops-infra`](https://github.com/search?q=topic%3Aevalops-infra+org%3Aevalops&type=repositories) — Deployment and infrastructure
- [`evalops-data`](https://github.com/search?q=topic%3Aevalops-data+org%3Aevalops&type=repositories) — Data pipelines and analytics
- [`evalops-docs`](https://github.com/search?q=topic%3Aevalops-docs+org%3Aevalops&type=repositories) — Documentation

## Key Repos

| Repo | Description |
|---|---|
| [platform](https://github.com/evalops/platform) | Control-plane monorepo — Go services, protobuf contracts, and the console UI |
| [maestro](https://github.com/evalops/maestro) | Multi-model coding agent (TUI, IDE, Slack, GitHub) |
| [deploy](https://github.com/evalops/deploy) | GitOps delivery: K8s manifests, Terraform, ArgoCD |
| [hopper](https://github.com/evalops/hopper) | Marketing site |
