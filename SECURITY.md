# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in any EvalOps repository, please report it responsibly.

**Do not open a public GitHub issue for security vulnerabilities.**

Instead, email **security@evalops.dev** with:

- A description of the vulnerability
- Steps to reproduce
- The affected service(s) and version(s)
- Any potential impact assessment

We will acknowledge receipt within 48 hours and provide an initial assessment within 5 business days.

## Supported Versions

We support security patches for the latest release of each actively maintained service.

## Scope

This policy applies to all repositories in the [evalops](https://github.com/evalops) GitHub organization.

## Code Scanning

EvalOps does not enable GitHub CodeQL. Every repository is attached to the
**EvalOps Blacksmith recommended** code security configuration
(`id=245233`), which sets `code_scanning_default_setup: disabled` and is the
default for new repositories.

Equivalent static analysis lives elsewhere:

- `semgrep`-based custom rules in service repos (see `.semgrep/` directories
  and the `semgrep-custom` workflows).
- Service-specific gates such as `architecture-review`, `contract-skew-check`,
  and `migration-check` in `evalops/platform`.
- The [`codeql-guard`](.github/workflows/codeql-guard.yml) workflow in this
  repo enforces the policy: it rejects PRs that introduce
  `github/codeql-action` here, and it sweeps every `evalops/*` repo daily,
  opening an issue if a CodeQL workflow file appears anywhere in the org.

To request a policy change, open a PR against this file and the guard
workflow.
