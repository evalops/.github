# Repository Instructions

This repository provides org-level defaults for EvalOps repositories: default issue templates, PR templates, reusable workflow assets, community health files, and service catalog metadata.

## Codex App Operating Rails

- Treat changes here as org-wide process changes. Keep them small, explicit, and easy for downstream repos to override.
- Before editing templates, check live issues and PRs in `evalops/.github` so updates do not duplicate an existing convention effort.
- Template changes should improve evidence quality without making every PR or issue feel heavy. Prefer optional fields for specialized work and required fields only when missing them would block triage.
- When adding org-default guidance for agents, include concrete verification prompts: live `gh` checks, affected repos, generated artifacts, CI status, and release or deploy impact.
- Do not put repo-specific secrets, private environment details, or one-off local workflow assumptions in org defaults.

## Verification

- Validate YAML syntax for files under `.github/ISSUE_TEMPLATE/`.
- Inspect rendered Markdown for `.github/pull_request_template.md`.
- For default-template changes, create a PR and let repository maintainers review whether the org-wide wording is too broad.
