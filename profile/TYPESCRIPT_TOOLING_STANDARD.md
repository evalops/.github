# EvalOps TypeScript Tooling Standard

EvalOps TypeScript repos should converge on a small shared toolchain instead of
copying bespoke lint, format, and script orchestration rules repo by repo.

## Default Direction

- Use `gts` as the baseline style, lint, and formatting convention for new or
  lightly customized TypeScript repos.
- Use `wireit` for package scripts whose outputs can be cached by input hash,
  especially build, typecheck, codegen, and test shards.
- Keep migrations opt-in for repos with heavy custom lint rules. Do not force
  churn into active product work unless the touched area already needs tooling
  cleanup.
- Prefer a shared `@evalops/ts-config` package once two pilots prove the
  overrides are stable.

## Pilot Criteria

Pick one small repo for `gts` and one slow-build repo for `wireit`.

For each pilot, record:

- current lint/typecheck/build commands
- cold and warm runtime before and after
- changed config files
- rules that needed EvalOps-specific overrides
- CI failures avoided or introduced
- whether the repo should stay migrated

## Rollout Shape

1. Pilot `gts` in a small active repo such as `explorer`.
2. Pilot `wireit` in a slow TypeScript repo such as `console` or `maestro`.
3. Package shared overrides as `@evalops/ts-config` after the first successful
   pilot.
4. Add template guidance here and in downstream repo templates so new TypeScript
   repos inherit the standard.

## Non-Goals

- Migrating all TypeScript repos in one sweep.
- Replacing working repo-specific lint rules without a measured benefit.
- Turning this into a monorepo or Turborepo decision.
