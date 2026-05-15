# Codex Hook Guardrails

EvalOps repos benefit from a few warning-first local hooks: remind agents to use
fresh worktrees and live GitHub state, warn before destructive git commands in a
dirty worktree, and nudge merge/readiness tasks to include review-thread
evidence.

The hook implementation lives in
`.github/scripts/evalops-codex-hook-guard.rb`. It has three modes:

- `session-start`: prints EvalOps process rails when the current repo appears to
  belong to `evalops/*`.
- `pretool-git`: warns when a destructive git command is about to run in a dirty
  worktree.
- `stop-readiness`: warns when a transcript mentions merge/readiness but lacks
  recent review-thread or status-check evidence.

An example hook config is available at `.github/codex/hooks/evalops-hooks.toml`.
Install it at user scope or copy it into a repo-level Codex config, then adjust
the script path if the repo consumes this file outside `evalops/.github`.

## Limitations

These hooks are intentionally warning-first and local-only. They do not carry
production credentials, do not replace branch protection, and do not guarantee
that every merge blocker has been handled. They are a prompt to gather the right
evidence before acting.

The `pretool-git` mode can block explicit destructive git commands when the
worktree is dirty because that condition has a low false-positive rate. Bypass by
cleaning/stashing unrelated work or by running the command manually after
reviewing `git status --short`.
