# Overnight Build → Review → Fix Loop

The full overnight procedure for driving a remote builder + reviewer over
SSH+tmux. The owner pre-authorises the loop and gates only the final merge.

## Roles

- **Builder** (pane %B) — writes code, opens PRs. **Never merges.**
- **Reviewer** (pane %R) — independently reviews PRs, runs mutation tests.
  **Never merges.**
- **Owner** — the only one who merges. Gates every "merge #N".

## Slice selection

1. The builder reads the project's todo / spec (from the repo, not from the
   pane).
2. Picks the **next unit** that is unblocked (a feature, a fix, a refactor).
3. Builds it in its own worktree (`git worktree add` on the remote host).
4. Opens a PR (`gh pr create`) with a clear title + description.
5. **Stops.** Does not merge. Does not start the next slice until the current
   PR is reviewed.

## Review cadence

The reviewer, on each new PR from the builder:

1. **Pull the diff:** `gh pr diff <n>` (or `git diff` in the worktree).
2. **Verify CI green:** `gh pr checks <n>` (all checks passing).
3. **Run its own verification** — the reviewer is not the builder, so it runs
   independent checks:
   - Mutation tests (e.g. a `kind` proof for a Kubernetes change: apply the
     diff to a scratch cluster, confirm the behaviour holds).
   - Lint / type-check / test-suite on the changed files.
   - Scope check — is the PR doing what the slice says, or did it drift?
4. **Verdict:**
   - **APPROVE** — no changes needed. Report the PR number + CI state.
   - **CHANGES REQUESTED** — post specific, actionable comments. The builder
     fixes, pushes, and the reviewer re-reviews (loop back to step 1).

## The gate (owner)

- A PR is **ready** when: review = APPROVE **and** CI = green **and** no
  scope creep.
- The owner says "merge #N". The merge is executed via
  `gh pr merge <n> --squash` (or `git merge` on the remote host).
- **After the merge**, verify the tip advanced: `git log --oneline -3 origin/main`.
  If the tip did NOT advance to the expected SHA, the merge was bypassed or
  failed — flag to the owner.

## Self-merge detection

If the builder or reviewer merges on its own (e.g. a `--admin --squash`
bypass, or the builder running `gh pr merge` in a loop), the gate was
bypassed. Detect it by comparing the tip SHA before and after the loop cycle.
Flag it to the owner — do not silently accept a self-merge.

## Disk hygiene (end of overnight)

Run the worktree classifier (see `remote-agent-relay/scripts/worktree_classifier.py`):
```bash
ssh <ssh_target> 'cd <repo_path> && python3 scripts/worktree_classifier.py'
```
Prune the safe list; keep the KEEP list. Report freed space.

## The report (to the owner)

Terse. Only ping the owner on a hard blocker, CI fail, gated git op, or a
real watch hit. Otherwise:
- `main` tip SHA (fetched).
- PRs opened/merged + CI state.
- Open PRs ready for the owner's merge gate.
- Disk + worktree count.
- Context-budget flag if the builder is near its limit.
