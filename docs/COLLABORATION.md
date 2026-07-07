# Claude + Codex collaboration model (this repo)

This was the first project to try Claude/Codex coordination through K2. The early
runs struggled, not because of bad judgment but because of four fixable causes:

1. The repo lived under `~/Documents`, which is macOS TCC-protected. Codex runs a
   `workspace-write` sandbox and could not write in place there. Its sessions threw
   ~1,700 `Operation not permitted` errors and it fell back to editing throwaway
   clones under `/private/tmp`, so it could never actually own or land work.
2. Confirm-first push rules meant Codex always stalled at the finish line
   ("local commit ready, not pushed"), waiting on a human relay.
3. The domain is a LIVE base (safereboot drains, AP-detach crashes, queue
   lifecycle). That rewards interactive, live-feedback coherence — Claude's edge —
   and punishes fire-and-forget.
4. Two agents both building the same prerequisite produced divergent
   implementations that conflicted on merge (the job-id fork of 2026-07).

Fix 1 is done: the repo now lives at `~/Projects/personal/mc-atm-scripts`
(local-only, no TCC block). The rest is the contract below.

## Roles

**Claude leads the live loop.** Anything that touches the running base or needs
long multi-step coherence is Claude's: safereboot / drain handshakes, AP-detach
guards, queue lifecycle and craft-failure handling, deploy to computer 6, and the
final diff review before any deploy. Claude owns `main` and all merges into it.

**Codex is the scoped async builder.** Codex takes bounded sub-tasks that have a
clear done-gate (tests + smoke). It is strong at mechanical multi-file work and
has kept the suite green (940+ tests). Codex does **not** own the live loop and
does **not** reconcile divergent branches on its own — it surfaces a conflict and
hands back.

Routing default (from the global rules): interactive / live / judgment → Claude;
specifiable, test-checkable, no-back-and-forth → Codex. Either may hand off when
the other clearly fits better.

## Git protocol (prevents the fork-divergence that happened)

- `main` is always the single source of truth.
- Codex works and commits on branch **`codex`** only. Before starting anything,
  Codex rebases `codex` onto `main`. If a prerequisite already exists on `main`,
  Codex **extends it** — it never builds a parallel implementation of something
  main already has.
- **Codex MAY `git push origin codex` without asking.** A feature branch push is
  reversible and lets Codex close its own loop instead of stalling. This is a
  project-scoped exception to the global "confirm before push" rule in
  `~/Projects/SHARED_AGENT_RULES.md`, authorized by Zach for this repo.
- Codex must **not** push, merge, or force-push `main`. Merges to `main` are
  Claude + Zach, after Claude reviews the `codex` diff (`main..codex`).
- No `--force` on any shared branch without explicit confirmation.

## Environment

- Repo home: `~/Projects/personal/mc-atm-scripts` (main) and
  `~/Projects/personal/mc-atm-scripts-codex` (the `codex` git worktree).
- Both are outside `~/Documents`, so Codex's `workspace-write` sandbox writes in
  place. **Do not work from `/private/tmp` clones anymore** — that was a symptom of
  the old TCC block and it detaches work from the real repo.
- Old `~/Documents/Codex/.../work/` paths are temporary compat symlinks for
  retired Codex sessions; remove them at the next storage-audit pass.

## Handoff

- Async handoffs go through `.k2/inbox` (async, any length). Keep the done-note
  format Codex already uses: commit hash, scope, and verification actually run
  (`lua tests/run.lua`, `lua tests/smoke*.lua`, mirror check).
- Claude relays and reviews; the human is not the relay.
- "Done" means the gate command was run and its output is in the note — not
  "should work."
