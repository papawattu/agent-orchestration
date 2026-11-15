---
name: remote-agent-relay
description: >
  Drive and report on a long-running remote agent task over SSH+tmux without
  attaching. Use when the user asks "how's the build going / check on it / is
  it up / what's it doing / update me / is the agent waiting on me", or gives a
  go-merge. Relays status back and hands a short instruction (e.g. "build now",
  "open the PR") to the agent's tmux pane. Works for any agent that runs as a
  full-screen TUI inside tmux on the configured remote host.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [tmux, ssh, relay, status, agent, long-running]
    related_skills: [agent-task-monitor, github-pr-workflow, remote-cli-ssh-tmux]
---

# Remote Agent Relay

A **long-running agent task** (a full-screen TUI) runs inside tmux on a remote
host, configured as `ssh_target` in `config.yaml` (or the `AGENTSSH_TARGET`
env var). The user pings the Hermes agent to *relay* — get the agent's status
and, when asked, hand it a short instruction. The task is NOT attached; it is
read and steered through tmux over ssh.

**Two modes** (set `orchestrator:` in `config.yaml`, or `AGENT_ORCHESTRATOR`):
- **`remote`** (default) — orchestrator on a *different* host; every action is
  an ssh round-trip to the remote's tmux. Use `scripts/ssh_safe_send.py` for
  briefs (base64 path, because of the nested-ssh quoting trap).
- **`local`** (tmux-only) — orchestrator on the *same* host as the agents, in
  its own tmux window. No ssh, no base64, no quoting traps. Use
  `scripts/tmux_local.sh` and see `references/tmux-local-mode.md`.

This skill is **product-agnostic**: it does not assume any particular agent
name. The roles are:
- **build agent** — the pane that builds / writes code / opens PRs.
- **review agent** — a *separate* pane/agent that independently reviews the
  build agent's output. **Self-verification is not verification** — the
  build agent must never be the one that rubber-stamps its own work.

The user is the **owner** and gates every merge / destructive step.

## When to Use

- User asks "how's the build going", "check on it", "is it up", "what's it
  doing", "update me", "what's the status", "is the agent waiting on me",
  "did the review pass".
- User gives a go-merge / go-build / go-review instruction to relay to the
  build agent's pane.
- User asks for a clean-up of accumulated build worktrees / stale sessions.

## Prerequisites

- SSH reachability to `ssh_target` (key-based, no password prompt).
- A tmux session on the remote host (default `main`) with a **build** window
  and a **review** window (pane ids shift as panes are closed/reopened — see
  "Pane ids churn below").
- The repo lives at `repo_path` (config) on the remote host.
- The **owner** (user) has signed off on any merge / destructive action.

## Core Model: Two Roles, One Owner

```
                 +----------------------------------------------------+
                 |  remote host (ssh_target)                          |
                 |   tmux session "main":                             |
                 |     window "build"   -> pane builds code, opens PRs|
                 |     window "review"  -> pane independently reviews |
                 |  repo: <repo_path>                                  |
                 +----------------------------------------------------+
                          ^                       ^
        relay status     |                       |  hand a short brief
        / send a brief   |                       |  ("build", "open PR",
   (Hermes agent) <------+                       +------->  "fix review")
        (ssh + tmux capture / send-keys)
```

**The owner-gate.** The build agent and the review agent must NOT merge or
perform any destructive step without the owner's explicit sign-off. A brief
that says "open the PR and report the number, do NOT merge" enforces the
gate; a brief that says "merge it" is the owner's instruction and may
proceed. **Never relay a merge instruction to the review pane** — the
review agent is the gate, not the executor.

## Pane IDs Churn

Pane ids (`%3`, `%15`, `%30`) are **not stable** — they shift every time a
pane is closed and a new one is opened on the remote host. So:

- **Always resolve pane ids live** before acting:

  ```bash
  ssh <ssh_target> 'tmux list-panes -s -F "#{pane_id} #{window_name} #{window_index} #{pane_current_command}"'
  ```

  Find the pane whose `window_name` is the build window and whose command is
  the agent's TUI. Do **not** hardcode a pane id from a previous turn.

- If a pane id you had earlier no longer exists, re-resolve. A "no such pane"
  error is a churn signal, not a failure.

- **Builder drift detection:** a pane labelled `build` may have drifted to
  another task. Before relaying, confirm the pane's `pane_current_command`
  and the last visible line (capture-pane) still match the task you expect.
  If the pane is showing a different project or has gone idle on a different
  branch, it has drifted — flag it to the owner, don't relay into it.

## Relaying Status (read-only)

To answer "how's it going", capture the build pane's live screen and the last
N lines of scrollback:

```bash
# Live screen (what the agent is doing right now):
ssh <ssh_target> 'tmux capture-pane -p -t <build_pane_id>'

# Scrollback (last 200 lines — what it just finished / what it produced):
ssh <ssh_target> 'tmux capture-pane -p -t <build_pane_id> -S -200'
```

Classify the state from the live screen (same table as `agent-task-monitor`):

| State | Tells |
|-------|-------|
| Busy / working | Spinner glyph, `Working…`/`Thinking`, streaming tool output, a running command. |
| Waiting on owner | Empty prompt, last message ends in a question / `(y/n)` / `Proceed?`. |
| Finished | No spinner; idle prompt; last line is a wrap-up, a PR/commit link, or "Done". |
| Errored / stuck | Traceback, `Error`, rate/context-limit notice, or identical screen across two captures. |

Report to the owner in 2–4 lines: state, what it's doing (or waiting on),
and the relevant tail. If the task produced a PR, include the PR number and
the CI state (fetch the PR from the GitHub API — see `github-pr-workflow`).

## Handing a Brief to the Build Agent (write)

To relay an instruction (a short brief — a few lines, not a paragraph), use
the **quoting-safe** path. See `scripts/ssh_safe_send.py` for the full
implementation; the pattern is:

1. Write the brief to a local temp file (Unicode-safe).
2. `base64 -w0` it.
3. Ship the base64 to the remote host over ssh; decode + `tmux send-keys -l`
   (literal mode — no key interpretation).
4. Optionally append a bare `Enter` to accept a default / continue.

```bash
# Safe send (the script handles base64 + quoting):
python3 scripts/ssh_safe_send.py <build_pane_id> 'Open the PR now. Report the PR number + CI, then stop. Do NOT merge.'
```

**Plain-ASCII in inline messages.** If you must type the brief inline (not via
the script), use hyphens (`-`) instead of em-dashes (`—`), `->` instead of
`→`, and avoid middle-dots (`·`). Unicode in a nested `ssh '… tmux send-keys …'`
breaks the outer bash quoting and the message never lands.

## The Build → Review → Fix → Re-Review Loop

The standard overnight cycle (when the owner has pre-authorised the loop and
gated only the final merge):

```
  build agent (build pane)          review agent (review pane)          owner (you)
  ─────────────────────────          ─────────────────────────          ─────────────
  1. Get a slice from the todo /    4. Review the PR:                  8. Owner says
     spec, pick the next unit.       - pull the diff (gh pr diff)       "merge #N"
  2. Build it.                       - verify CI is green (gh pr        → squash-merge
  3. Open a PR (gh pr create).       checks), run the reviewer's        the PR, report
     Do NOT merge.                   mutation tests (kind proof if       the new tip.
                                      applicable).
                    ──────────────────────────────►
                    5. Verdict: APPROVE / CHANGES REQUESTED.
                    CHANGES REQUESTED ────────────►  6. Build agent fixes,
                    7. Push fix, re-trigger review.     pushes, re-opens.
```

**Rules:**
- The build agent **never merges**. It opens PRs and stops.
- The review agent **never merges**. It approves or requests changes.
- The owner **gates the merge**. A PR is merged only on the owner's explicit
  "merge #N" after a green review + green CI.
- **Self-merge detection:** after any merge, verify the repo tip actually
  advanced to the expected SHA. If the build agent (or review agent) merged
  on its own (e.g. via a `--admin --squash` bypass), flag it to the owner —
  the gate was bypassed. Check: `git log --oneline -3 main` on the remote
  host, and compare the tip SHA to what the review verdict expected.
- **Builder drift:** before relaying the next slice, confirm the build pane
  is still on the right branch / project. A pane that has gone idle on a
  different branch has drifted — don't relay into it.

## Repo Tip Is the Source of Fact

The **repo's `main` tip** (fetched from the remote, not read from a pane's
scrollback) is the authoritative state. The pane is a snapshot that may be
stale. Always:

```bash
ssh <ssh_target> 'cd <repo_path> && git fetch origin && git log --oneline -5 origin/main'
```

before reporting "main is at X" or deciding whether a PR has landed.

## Disk Cleanup (build worktrees)

Over a night, the build agent's slices leave `git worktree add` dirs that
accumulate and climb the host disk. Clean them with the classifier (see
`scripts/worktree_classifier.py`):

```bash
ssh <ssh_target> 'cd <repo_path> && python3 scripts/worktree_classifier.py'
```

The classifier prints which worktrees are **safe to prune** (merged into base,
or squash-merged with the branch ref still holding the commit) vs **KEEP**
(base-branch checkout, or a detached head not on base that may hold the only
reachable copy of unpushed work). Prune the safe list:

```bash
ssh <ssh_target> 'cd <repo_path> && git worktree remove --force <safe_path>'
# If a worktree dir holds root-owned build artifacts and remove --force
# returns permission-denied:
ssh <ssh_target> 'sudo rm -rf <safe_path> && cd <repo_path> && git worktree prune'
```

**Never prune a KEEP worktree.** A detached head not on base may be the only
reachable copy of unpushed work. When in doubt, keep it and flag it to the
owner.

## Token / Context Budget

The build agent's pane has a **context window** that fills as it works.
Watch for:
- A context-limit / rate-limit notice in the scrollback (the agent is
  degraded, not finished).
- The spinner running but no new output for several minutes (stuck on a
  large tool result or a network hang).

When the context budget is ~80% consumed, the build agent should be stopped
and a **fresh pane** started for the next slice (the "fresh builder" pattern).
This is an owner decision — flag it, don't auto-restart the pane.

## Tmux-Only Mode (orchestrator: local)

When the orchestrator and the agents run on the **same host** (set
`orchestrator: local` in `config.yaml`), drive the panes with plain local
`tmux` — no ssh, no base64, no quoting traps. Use `scripts/tmux_local.sh`
and `references/tmux-local-mode.md`. The key differences from the default
ssh+tmux mode:

- **Send a brief** — `tmux_local.sh send build "…"`. Local `send-keys -l`
  takes the literal argument verbatim, so Unicode is safe (no base64 hop).
- **Read a pane** — `tmux_local.sh status build` / `tmux_local.sh back build 200`.
- **Tee the builder's output** — `tmux_local.sh pipeon build /tmp/build.log`
  (and `pipeoff` to stop). Tail the file instead of polling `capture-pane`.
- **Target by window name** (`build`, `review`, `main:build.0`) — immune to
  pane-index churn.
- **Optional dedicated socket** — `tmux -L agents` for isolation; set
  `TMUX_LOCAL_SESSION` in the helper to match the session name.

The build→review→fix loop, the owner gate, and the self-merge detection are
identical in both modes — only the transport (ssh vs local tmux) differs.

## Pitfalls

- **Em-dashes / Unicode in inline `send-keys` through nested SSH.** A message
  containing `—` / `→` / `·` inside `ssh '… tmux send-keys -l "…" …'` breaks
  the outer bash quoting. Use `scripts/ssh_safe_send.py` (base64 path) for
  any non-ASCII brief; use plain-ASCII hyphens/arrows for inline sends.

- **Pane-id churn.** Never hardcode a pane id across turns. Resolve live with
  `tmux list-panes -s -F "…"`. A "no such pane" error = churn, not failure.

- **Builder drift.** A pane labelled `build` may have drifted. Confirm
  `pane_current_command` + the last visible line before relaying.

- **Repo tip is the fact.** Read `origin/main` tip, not the pane's scrollback,
  before reporting state.

- **Self-merge detection.** After any merge, verify the tip advanced to the
  expected SHA. If the agent self-merged, flag the gate bypass.

- **Root-owned worktree artifacts.** `git worktree remove --force` on a dir
  with root-owned files returns permission-denied. Use `sudo rm -rf <path> &&
  git worktree prune`.

- **Nested-SSH quoting.** A multi-line `bash`/`awk` script piped straight
  through `ssh '…'` gets mangled. Write the script to a local temp file,
  base64 it, and ship it (see `scripts/ssh_safe_send.py` for the pattern).
  The worktree classifier uses the same pattern when shipped over ssh.

- **Context budget.** A context/rate-limit notice means the agent is
  degraded, not finished. At ~80% ctx, flag for a fresh pane (owner decision).

## Related Skills

- **`agent-task-monitor`** — read-only status capture for any long-running
  remote TUI (the "how's it going" skill, generic).
- **`github-pr-workflow`** — the PR lifecycle (create, CI, review, merge)
  via `gh` / GitHub API.
- **`remote-cli-ssh-tmux`** — the generic build→review loop for any CLI agent
  over ssh+tmux.
