# High-Leverage Codex Workflows

EvalOps should use Codex as a control-plane collaborator, not only as a chatty
PR commenter. The highest-yield patterns are the ones that turn Codex output
into structured review data, repeatable local diagnostics, or durable evidence.

## Structured PR Review

Use `.github/workflow-templates/codex-structured-pr-review.yml` for repositories
where inline review comments are more useful than one summary comment. The
workflow:

- checks out the PR merge ref and fetches base/head SHAs
- builds a prompt with the changed-file list and unified diff
- runs Codex with `.github/codex/schemas/pr-review.schema.json`
- posts schema-backed findings as GitHub inline review comments
- upserts one summary comment with the overall verdict and residual risk

This is best for Platform, Deploy, Maestro, Conductor, Chat, and other repos
where missed review feedback or generated drift is expensive.

## Codex As Evidence Producer

Use `codex exec --json` or the Codex GitHub Action output file when a workflow
needs machine-readable evidence. Good fits:

- failed CI logs into a small root-cause JSON object
- release-train diffs into a risk register
- local traffic simulation into trace/event coverage findings
- label-event timelines into automation-owner hints

Prefer a JSON Schema whenever a later step will parse the result. Store the
schema next to the prompt under `.github/codex/schemas/`.

## Repo Skills

Check in repo-scoped skills under `.agents/skills/` for repeated workflows that
need local conventions. Good EvalOps candidates:

- PR feedback follow-through: query unresolved review threads, inspect checks,
  patch only actionable feedback, and re-poll before merge
- distributed tracing canary: run the local traffic simulator, locate trace
  artifacts, and verify trace-id propagation across service boundaries
- generated-contract drift: run the generator, compare checked-in output, and
  explain which side is source of truth

Keep the description narrow so Codex can trigger the skill implicitly without
loading too much context.

## Hooks For Footgun Prevention

Codex hooks are useful for local guardrails that are awkward to remember:

- warn before running destructive Git commands in dirty worktrees
- add session context that points agents at repo-specific local tooling
- stop a turn that tries to merge a PR before unresolved review threads were
  checked
- remind agents to use fresh worktrees for broad EvalOps sweeps

Hooks should be lightweight and local-first. Use them to warn or block obvious
process mistakes, not to encode business logic that belongs in CI.

## MCP For Local Introspection

Use repo-local MCP servers when Codex needs live local context that is hard to
recover from source alone:

- service status and local port inventory
- trace and event-log lookup by trace id
- generated OpenAPI/protobuf catalog lookup
- safe wrappers around `gh`, `kubectl`, or local simulators

Expose small read-heavy tools first. Add write tools only when the action is
explicit, reversible, and already protected by repo tests or CI.

## App Server For Product Integration

Codex app-server is the deeper product-integration path. It is worth exploring
for Maestro or Platform if we want a native EvalOps "agent console" that streams
turn events, approvals, and tool calls into our own UI. For CI and scheduled
jobs, use the Codex SDK, `codex exec`, or the GitHub Action instead.
