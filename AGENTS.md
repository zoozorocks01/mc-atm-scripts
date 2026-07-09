# Agent contract — mc-atm-scripts

Full model: [`docs/COLLABORATION.md`](docs/COLLABORATION.md). The essentials:

## Roles
- **Rescope in progress (2026-07-09, see COLLABORATION.md):** Codex is being
  staged toward project lead — Phase 1 grants it live-loop clearance (deploy,
  restarts, soaks, live verification); Phase 2 (after a clean restart-night +
  ~a week of live ops) hands it `main` and day-to-day lead, with Claude as
  consulted reviewer. Safety rails are role-agnostic and transfer intact.
- **Claude leads the live loop** (safereboot/drain, AP-detach, queue lifecycle,
  deploy, review before deploy) and owns `main` + all merges into it — until
  the rescope's Phase 2 lands.
- **Codex is the scoped builder** — bounded sub-tasks with a test/smoke done-gate,
  on branch `codex`. Does not own the live loop; does not reconcile divergent
  branches solo (surface the conflict and hand back).
- **Either agent may pull the other in.** Leading is not going solo. Codex should
  request Claude for live/interactive moments, judgment calls, or a diff review
  before deploy; Claude should hand Codex scoped, test-checkable chunks. Whoever
  asks states what they need and why (a `.k2/inbox` note or a direct message). The
  lead still owns the merge.

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
- **Policy changes** (craft-gating, queue admission, failure handling, mode/soak
  lifecycle) gate on `tools/atm10-iterate.sh test` and ship with their rationale —
  a real commit body or a `docs/DECISIONS.md` entry. The sim discovers; the live
  pass confirms (add the reproducing scenario BEFORE fixing a live-found bug).
- Bounded live auto proof = the agent-driven soak channel
  (`tools/atm10-iterate.sh soak`, `docs/DECISIONS.md` #2), not asking Zach to
  toggle modes.

## K2 (evaluation phase)
- `.k2/inbox` notes are the agent↔agent channel. No sync `k2 msg` injection
  between agents (screen-scrape delivery is unreliable); Zach is the only
  sync-interrupt path.

Global rules still apply: `~/Projects/SHARED_AGENT_RULES.md`.
