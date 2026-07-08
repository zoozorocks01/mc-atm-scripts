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

**Mutual help (both directions).** Leading a project does not mean going solo.
Either agent can pull the other in when the other's edge fits, and neither should
push through a task that clearly suits the other:
- Codex → Claude: live/interactive debugging, a judgment call, or a diff review
  before deploy.
- Claude → Codex: a scoped, test-checkable chunk (a feature, a refactor, a test
  suite) that needs no back-and-forth.
The one who asks states what they need and why (a `.k2/inbox` note or a direct
message). The project's lead still owns the merge and the final call.

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

## Policy changes carry their reasoning (added 2026-07-08)

The 2026-07-07 queue-failure work revised one policy five times in an afternoon
with bare-subject commits — the end state was fine, but the WHY lived nowhere.
Rule going forward:

- Any change to **craft-gating, queue admission, failure handling, or mode/soak
  lifecycle** ships with its rationale: a real commit body (root cause + chosen
  policy), or an entry in `docs/DECISIONS.md` for anything policy-shaped.
- **The simulator discovers; the live pass confirms.** The pre-deploy gate for
  policy changes is `tools/atm10-iterate.sh test` (unit suite + all smokes + the
  failure-injection sim scenarios). If a live pass surfaces a failure mode the
  sim lacks, FIRST add the scenario that reproduces it, then fix — one live pass
  to confirm, not five to discover.
- For bounded live proof of auto behavior, use the agent-driven soak channel
  (`tools/atm10-iterate.sh soak`, DECISIONS.md #2) instead of asking Zach to
  toggle modes.

## Handoff

**Reaching each other (K2, evaluation-phase posture — revised 2026-07-08):**
- Claude runs in the K2 workspace **`mc-atm-scripts`** (the main repo); Codex runs
  in **`mc-atm-scripts-codex`** (the `codex` worktree).
- **`.k2/inbox` notes are the primary channel** (async, any length). Sync
  injection (`k2 msg` without `--inbox`) is OFF for agent→agent use during the
  evaluation phase: its screen-scrape delivery false-fails, duplicates, and
  spawns stray sessions when a pane sits on a menu. If something is urgent
  enough to interrupt, write the inbox note and let Zach (who types directly
  into panes) decide to interrupt. Revisit when K2's delivery has proven itself.

- Async handoffs go through `.k2/inbox` (async, any length). Keep the done-note
  format Codex already uses: commit hash, scope, and verification actually run
  (`lua tests/run.lua`, `lua tests/smoke*.lua`, mirror check).
- Claude relays and reviews; the human is not the relay for work products (git
  is the handoff bus) — Zach is only the sync-interrupt path above.
- "Done" means the gate command was run and its output is in the note — not
  "should work."
