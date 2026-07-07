# Agent contract — mc-atm-scripts

Full model: [`docs/COLLABORATION.md`](docs/COLLABORATION.md). The essentials:

## Roles
- **Claude leads the live loop** (safereboot/drain, AP-detach, queue lifecycle,
  deploy, review before deploy) and owns `main` + all merges into it.
- **Codex is the scoped builder** — bounded sub-tasks with a test/smoke done-gate,
  on branch `codex`. Does not own the live loop; does not reconcile divergent
  branches solo (surface the conflict and hand back).

## Git
- `main` is the single source of truth. Codex rebases `codex` onto `main` before
  starting, and **extends** what main already has instead of building a parallel
  version.
- Codex **may `git push origin codex` without asking** (reversible feature branch;
  project-scoped exception to the global confirm-before-push rule).
- Codex must **not** push/merge/force `main`. Merges to `main` = Claude + Zach after
  Claude reviews `main..codex`.

## Environment
- Repo lives at `~/Projects/personal/mc-atm-scripts` (+ `-codex` worktree on branch
  `codex`). Both are outside `~/Documents`, so the `workspace-write` sandbox writes
  in place. **Never work from `/private/tmp` clones.**

## Done
- "Done" = `lua tests/run.lua` (+ relevant smokes) run and output pasted. Not
  "should work."

Global rules still apply: `~/Projects/SHARED_AGENT_RULES.md`.
