# EvalOps Codex Label Churn Audit

Audit PR labels that are being added and removed repeatedly by automation.

Required checks:

- Inspect the PR timeline, issue events, workflow runs, bot comments, and
  repository workflows that can mutate labels.
- Group label changes by actor, label, timestamp, and likely workflow source.
- Distinguish intended mutually exclusive labels from automation loops.
- Check whether human-authored code is expected to be agent-authored in this
  repo before treating agent labels as suspicious.
- Identify the smallest durable fix: workflow condition, label ownership rule,
  branch filter, debounce, or documentation update.

Output:

- A concise timeline of label mutations.
- The likely source workflow or automation.
- The durable fix and how to verify it.
