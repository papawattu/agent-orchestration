---
name: remote-agent-relay
description: >
  Drive and report on a long-running agent task via tmux — local (same host,
  default) or over SSH — without attaching. Use when the user asks "how's the
  build going / check on it / is it up / what's it doing / update me / is the
  agent waiting on me", or gives a go-merge. Relays status back and hands a
  short instruction (e.g. "build now", "open the PR") to the agent's tmux
  pane. Works for any agent that runs as a full-screen TUI inside tmux.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [tmux, ssh, relay, status, agent, long-running, local, remote]
    related_skills: [agent-task-monitor, github-pr-workflow, remote-cli-ssh-tmux]
---

# Agent Relay

A **long-running agent task** (a full-screen TUI) runs inside tmux. The user
pings the Hermes agent to *relay* — get the agent's status and, when asked,
hand it a short instruction. The task is NOT attached; it is read and steered
through tmux, either on the **same host** (default — tmux-only, no ssh) or
**over ssh** to another host (set `orchestrator:` in `config.yaml` /
`AGENT_ORCHESTRATOR`).

**Two modes** (set `orchestrator:` in `config.yaml`, or `AGENT_ORCHESTRATOR`):

- **`local`** (DEFAULT, tmux-only) — the orchestrator runs on the **same host**
  as the agents, in its own tmux window. No ssh, no base64, no quoting traps.
  **This is the common case — the instructions below lead with it.** Use
  `scripts/tmux_local.sh` and `references/tmux-local-mode.md`.
- **`remote`** (ssh+tmux) — the orchestrator runs on a **different host** and
  drives the remote's tmux over ssh. Every action is an ssh round-trip; use
  `scripts/ssh_safe_send.py` for briefs (base64 path, because of the
  nested-ssh quoting trap). Needed only when the orchestrator can't run on the
  same box as the agents.

Both modes drive the **same** model (two roles, one owner gate, the
build→review→fix loop) — only the transport differs. Read the mode that
matches your setup; the shared rules (owner gate, self-merge detection, repo
tip is the fact) apply to both.

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

**Local mode (default):**
- tmux installed on the host where the agents run (the same host as the
  orchestrator).
- A tmux session (default `main`) with a **build** window and a **review**
  window.
- The repo lives at `repo_path` (config) on that host.

**Remote mode:**
- SSH reachability to `ssh_target` (key-based, no password prompt).
- A tmux session on the remote host (default `main`) with a **build** window
  and a **review** window (pane ids shift as panes are closed/reopened — see
  "Pane IDs Churn").
- The repo lives at `repo_path` (config) on the remote host.

**Both modes:**
- The **owner** (user) has signed off on any merge / destructive action.

## Core Model: Two Roles, One Owner

```
                 +----------------------------------------------------+
                 |  host running the agents (tmux session "main")     |
                 |     window "build"   -> pane builds code, opens PRs|
                 |     window "review"  -> pane independently reviews |
                 |  repo: <repo_path>                                  |
                 +----------------------------------------------------+
                          ^                       ^
        relay status     |                       |  hand a short brief
        / send a brief   |                       |  ("build", "open PR",
   (orchestrator) <------+                       +------->  "fix review")
        local: plain tmux  |  (same host)          remote: ssh + tmux (other host)
```

**The owner-gate.** The build agent and the review agent must NOT merge or
perform any destructive step without the owner's explicit sign-off. A brief
that says "open the PR and report the number, do NOT merge" enforces the
gate; a brief that says "merge it" is the owner's instruction and may
proceed. **Never relay a merge instruction to the review pane** — the
review agent is the gate, not the executor.

## Pane IDs Churn

Pane ids (`%3`, `%15`, `%30`) are **not stable** — they shift every time a
pane is closed and a new one is opened. **In local mode you don't hit this**:
target by window name (`build`, `review`, `main:build.0`) via
`scripts/tmux_local.sh`, which is immune to pane-index churn. In remote mode
you must resolve pane ids live before acting:

```bash
# Remote mode:
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

**Local mode (default):**
```bash
# Live screen (what the agent is doing right now):
tmux_local.sh status build
# Scrollback (last 200 lines — what it just finished / what it produced):
tmux_local.sh back build 200
```

**Remote mode:**
```bash
# Live screen:
ssh <ssh_target> 'tmux capture-pane -p -t <build_pane_id>'
# Scrollback (last 200 lines):
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

**Local mode (default)** — plain `send-keys -l`, any bytes safe (no base64, no
quoting trap). **Sends submit by default**: `tmux_local.sh send`/`multi`
append a real Enter after a short settle (250 ms), so the brief actually
reaches the agent — `send-keys -l` alone only *inserts* the text and never
submits.

```bash
# Send a brief (inserts the text, then submits with Enter):
tmux_local.sh send build "Open the PR now. Report the number + CI. Do NOT merge."
# Fan the same brief to every builder (each submitted):
tmux_local.sh multi b1 b2 b3 -- "Take slice <id>. Build it, open a PR, report the number. Do NOT merge."
# Insert the text WITHOUT submitting (e.g. to edit an in-progress line, or to
# stage two half-lines): then submit deliberately with `enter`.
tmux_local.sh send build --noenter "partial text here"
tmux_local.sh enter build
# Pick a numbered option from a menu (option string + Enter):
tmux_local.sh select build 2
```

**Enter-reliability rules** (why `--noenter` and the settle exist):
- **Default is "submit".** A brief that doesn't get an Enter never reaches the
  agent — the pane just shows un-entered text. If you send a brief and the
  agent doesn't react, the first thing to check is whether the Enter landed.
- **Settle before Enter.** `send-keys -l` dumps the whole line into the pane's
  input buffer in one shot; a very long brief can have the trailing Enter
  arrive before the TUI has parsed the preceding characters, so it interleaves
  mid-line. The 250 ms settle (override `TMUX_LOCAL_DELAY=0`) drains the buffer
  first. If a particular TUI is slow to render, raise `TMUX_LOCAL_DELAY` (e.g.
  `=500`).
- **`--noenter`** is for the two cases where you want the text without a
  submit: editing a line the agent is mid-typing, or deliberately staging
  input across two `send` + one `enter`.
- **Verify a critical brief landed.** After a consequential send (a merge
  instruction, a "stop"), capture the pane and confirm the agent reacted
  (a new line appeared / it started working), rather than assuming the Enter
  got through. `tmux_local.sh status build`.

**Remote mode** — the **quoting-safe** base64 path (because of the nested-ssh
quoting trap). See `scripts/ssh_safe_send.py`. **It also submits by default**
(same fix as local mode): the brief is sent with `send-keys -l`, then a settle,
then a real Enter. Pass `--noenter` to insert without submitting.
```bash
# Hand a brief to the builder pane (safe, Unicode ok, SUBMITTED):
python3 scripts/ssh_safe_send.py <pane_id> 'Open the PR now. Report the PR number + CI, then stop. Do NOT merge.'
# Insert text without submitting (edit a mid-typed line / stage input):
python3 scripts/ssh_safe_send.py <pane_id> 'partial text' --noenter
# Slow-rendering TUI? Raise the settle: RELAY_SEND_DELAY=500 python3 ...
```
**Plain-ASCII in inline remote messages.** If you must type the brief inline
(not via the script), use hyphens (`-`) not em-dashes (`—`), `->` not `→`,
avoid middle-dots (`·`). Unicode in a nested `ssh '… tmux send-keys …'` breaks
the outer bash quoting and the message never lands. (Local mode has no such
trap.)

## The Build → Review → Fix → Re-Review Loop

The standard overnight cycle (when the owner has pre-authorised the loop and
gated only the final merge). **Identical in both modes** — only the send/read
commands above change with the mode:

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

**Rules (both modes):**
- The build agent **never merges**. It opens PRs and stops.
- The review agent **never merges**. It approves or requests changes.
- The owner **gates the merge**. A PR is merged only on the owner's explicit
  "merge #N" after a green review + green CI.
- **Self-merge detection:** after any merge, verify the repo tip actually
  advanced to the expected SHA. If the build agent (or review agent) merged
  on its own (e.g. via a `--admin --squash` bypass), flag it to the owner —
  the gate was bypassed.
- **Builder drift:** before relaying the next slice, confirm the build pane
  is still on the right branch / project. A pane that has gone idle on a
  different branch has drifted — don't relay into it.

## Multi-Builder (N builders, one reviewer)

Scale the loop to **N parallel builders** sharing **one** reviewer. Each
builder gets its own window; all fan out the same brief at once; the single
reviewer reviews each PR independently.

### 1. Rename + renumber at the START of the loop

Names must be predictable before you start. Run this **once, at the top of the
loop**, to name the builder windows `b1..bN` (in fan-out order) and keep
`review` distinct:

```bash
# e.g. three builders + one reviewer, already sitting at indices 0,1,2,3:
tmux_local.sh reorder b1=0 b2=1 b3=2 review=3
```

`reorder` renames in place by current index (collision-safe via a temp-name
pass) and prints the resulting order. The first arg gets the lowest index, so
`b1` is always the first builder, `review` is always last. If you add builders
mid-loop, spawn them, then re-run `reorder` with the full set (append the new
`bN=<idx>` before `review=<idx>`).

### 2. Fan a brief out to all builders at once

One brief → every builder pane (and you can include `review` to nudge the
reviewer too):

```bash
# Hand the next slice to every builder simultaneously:
tmux_local.sh multi b1 b2 b3 -- "Take slice <id> from the todo. Build it, open a PR, report the number. Do NOT merge."

# Nudge all builders to stop-and-report after the owner says so:
tmux_local.sh multi b1 b2 b3 -- "Stop. Report your PR number + CI state. Do NOT merge."
```

`multi` uses `send-keys -l` per pane, so Unicode is safe (no base64, no quoting
trap). Each pane is addressed by **window name**, immune to pane-index churn.

### 3. Read each builder's state individually

`multi` is send-only; for status, capture each pane by name:

```bash
for w in b1 b2 b3; do
  echo "=== $w ==="
  tmux_local.sh back "$w" 40
done
```

### 4. The loop rules still hold (one reviewer, N builders)

- **N builders, 1 reviewer.** Each builder opens **its own PR** and stops.
  The single reviewer reviews each PR independently — one reviewer is still the
  gate for the whole batch.
- **The owner gates every merge.** "merge #N" applies per PR; the owner reviews
  each verdict before it lands.
- **Self-merge detection is per-PR.** After each merge, verify the repo tip
  advanced to that PR's expected SHA.
- **Builder drift is per-pane.** A builder that drifted to a different branch
  must be excluded from the next `multi` fan-out (or reset) — don't send a
  brief into a drifted pane.
- **Fresh-builder budget is per-pane.** When one builder hits ~80% ctx, flag it
  and restart **that** pane; the other builders keep going. (Owner decision.)

**Remote mode equivalent:** `multi` and `reorder` are local-only (they drive a
local tmux server). In remote mode, fan out with a loop of
`ssh_safe_send.py <pane> <brief>` and rename with `ssh <target> 'tmux
rename-window -t <idx> <name>'` — the same model, the ssh transport.

## Repo Tip Is the Source of Fact

The **repo's `main` tip** (fetched, not read from a pane's scrollback) is the
authoritative state. The pane is a snapshot that may be stale. Always check
before reporting "main is at X" or deciding whether a PR has landed.

**Local mode (default):**
```bash
cd <repo_path> && git fetch origin && git log --oneline -5 origin/main
```
**Remote mode:**
```bash
ssh <ssh_target> 'cd <repo_path> && git fetch origin && git log --oneline -5 origin/main'
```

## Disk Cleanup (build worktrees)

Over a night, the build agent's slices leave `git worktree add` dirs that
accumulate and climb the host disk. Clean them with the classifier (see
`scripts/worktree_classifier.py`):

**Local mode (default):**
```bash
cd <repo_path> && python3 /path/to/scripts/worktree_classifier.py
```
**Remote mode:**
```bash
ssh <ssh_target> 'cd <repo_path> && python3 <path>/worktree_classifier.py'
```

The classifier prints which worktrees are **safe to prune** (merged into base,
or squash-merged with the branch ref still holding the commit) vs **KEEP**
(base-branch checkout, or a detached head not on base that may hold the only
reachable copy of unpushed work). Prune the safe list (add the `ssh <ssh_target>`
prefix in remote mode):

```bash
cd <repo_path> && git worktree remove --force <safe_path>
# If a worktree dir holds root-owned build artifacts and remove --force
# returns permission-denied:
sudo rm -rf <safe_path> && cd <repo_path> && git worktree prune
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
