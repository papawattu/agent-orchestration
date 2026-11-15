---
name: remote-cli-ssh-tmux
description: Drive a long-running CLI agent on a remote host via ssh + tmux (send-keys/capture-pane), and run a build→review→fix loop where a SEPARATE reviewer pane gates the builder. Use when the owner asks to "build X on the remote box", "keep it building overnight", "review what the builder produced", or needs a status report on an existing remote agent pane. Covers tmux send-keys quoting traps, the owner-gate merge loop, and the overnight report.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [ssh, tmux, remote, agent, build-loop, code-review, long-running, send-keys]
    related_skills: [remote-agent-relay, agent-task-monitor, github-pr-workflow]
---

# Remote CLI via SSH + tmux

Drive a **long-running CLI agent** running on a **remote host** (configured as
`ssh_target` in `config.yaml` / `AGENTSSH_TARGET`) by talking to its **tmux
session** over ssh. This is the workhorse for "build X on the remote box and
keep it going" plus a **build → review → fix → re-review** loop in which a
*separate* reviewer pane independently gates the builder's output.

This skill is **product-agnostic**: it works for any agent that runs as an
interactive CLI (a full-screen TUI) inside tmux. The two roles are:
- **builder** — the pane that writes code and opens PRs.
- **reviewer** — a *separate* pane that reviews the builder's PRs. **A real
  gate, not decoration**: the reviewer runs its own mutation tests and
  independently verifies the fix. **Self-verification is not verification.**

The **owner** (user) gates every merge / destructive step.

**Two modes / which skill to read:**
- **`local`** (tmux-only, DEFAULT — orchestrator on the *same host* as the
  agents) → read **`remote-agent-relay`**, which leads with the local
  `tmux_local.sh` path. This skill's loop model (two roles, owner gate,
  self-merge detection) is identical — only the transport is ssh here.
- **`remote`** (ssh+tmux — orchestrator on a *different* host) → this skill is
  the reference. Every action below is an ssh round-trip; use
  `remote-agent-relay/scripts/ssh_safe_send.py` for briefs (base64 path,
  because of the nested-ssh quoting trap).

## When to Use

- Owner says "build X on the remote box" / "keep it building" / "run it
  overnight" / "review what the builder opened".
- Owner asks for a status update on an existing remote agent pane ("how's it
  going", "is it up", "what's it doing", "is it waiting on me").
- You must send input or read output of a remote full-screen CLI you can't
  attach to interactively.
- **Do NOT use for**: a one-shot remote command (plain `ssh host 'cmd'`
  suffices), or a task where the agent should run locally.

## Prerequisites

- SSH reachability to `ssh_target` (key-based; no password prompt).
- A tmux session on the remote host (default `main`) with a **builder** window
  and a **reviewer** window.
- The repo at `repo_path` (config) on the remote host.
- The owner has signed off on the build scope and the merge gate.

## Core: One tmux session, two roles

```
                 +----------------------------------------------------+
                 |  remote host (ssh_target)                          |
                 |   tmux session "main":                             |
                 |     window "build"   -> builder pane (pane %B)     |
                 |     window "review"  -> reviewer pane (pane %R)    |
                 |  repo: <repo_path>                                  |
                 +----------------------------------------------------+
                          ^                       ^
        relay status      |                       |  hand a brief
        / send a brief    |                       |  ("build", "open PR",
   (Hermes agent) <-------+                       +------->  "review", "fix")
        (ssh + tmux capture / send-keys)
```

- **Builder pane** — writes code, commits, opens PRs. **Never merges.**
- **Reviewer pane** — pulls the builder's PR diff, verifies CI green, runs
  its own mutation tests / verification, and returns **APPROVE** or
  **CHANGES REQUESTED**. **Never merges.**
- **Owner** — the only one who merges. Says "merge #N" after a green review
  + green CI.

## The Build → Review → Fix → Re-Review Loop

```
  builder (pane %B)                reviewer (pane %R)                 owner
  ───────────────────                ────────────────────────           ────────
  1. Pick the next slice/unit.      4. Review the PR:
  2. Build it.                        - pull the diff (gh pr diff)
  3. Open a PR (gh pr create).        - verify CI green (gh pr checks)
     Do NOT merge.                    - run the reviewer's mutation
                                        tests (kind proof if applicable).
                    ──────────────────────────────►
                    5. Verdict: APPROVE / CHANGES REQUESTED.
                    CHANGES REQUESTED ────────────►  6. Builder fixes,
                    7. Push fix, re-trigger review.     pushes, re-opens.
                                                       8. Owner says "merge #N"
                                                          → squash-merge, report tip.
```

**Rules:**
- Builder **never merges**. Opens PRs, stops.
- Reviewer **never merges**. Approves or requests changes.
- Owner **gates the merge**. A PR merges only on the owner's explicit "merge
  #N" after green review + green CI.
- **Never relay a merge instruction to the reviewer pane.** The reviewer is
  the gate, not the executor.
- **Self-merge detection:** after any merge, verify the repo tip advanced to
  the expected SHA (`ssh <ssh_target> 'cd <repo_path> && git fetch origin &&
  git log --oneline -3 origin/main'`). If the builder or reviewer merged on
  its own, flag the gate bypass to the owner.

## send-keys Quoting Traps (the main reason this exists)

`tmux send-keys` over ssh is where things break. Two rules:

1. **Plain-ASCII in inline sends.** If you type the brief inline (not via the
   safe-send script), use hyphens (`-`) not em-dashes (`—`), `->` not `→`,
   and avoid middle-dots (`·`). Unicode in a nested `ssh '… tmux send-keys …'`
   breaks the outer bash quoting and the message never lands.

2. **Base64 the script for anything multi-line.** A multi-line `bash`/`awk`
   script piped straight through `ssh '…'` gets mangled by two quote layers.
   Write it to a local temp file, `base64 -w0` it, ship it, decode + run on
   the remote. See `references/send-keys-remote-cli.md` for the full pattern.

**Resolving pane ids.** Pane ids churn — always resolve live:
```bash
ssh <ssh_target> 'tmux list-panes -s -F "#{pane_id} #{window_name} #{pane_current_command}"'
```

## Reading the Pane (status)

```bash
# Live screen:
ssh <ssh_target> 'tmux capture-pane -p -t <pane_id>'
# Scrollback (last 200 lines):
ssh <ssh_target> 'tmux capture-pane -p -t <pane_id> -S -200'
```

Classify the state (busy / waiting / finished / errored) from the live screen
— same table as `agent-task-monitor`. Report to the owner in 2–4 lines:
state, what it's doing (or waiting on), and the relevant tail. If it produced
a PR, include the PR number and CI state.

## Overnight Report

At the end of an overnight build loop, deliver a **terse** report:
- `main` tip SHA (fetched, not from a pane).
- PRs opened/merged, with CI state.
- Anything that needs the owner's gate (open PRs ready to merge).
- Disk usage + worktree count (run the classifier from `remote-agent-relay`).
- Context-budget flag if the builder is approaching its limit.

Stay silent unless the owner needs to be pinged (hard blocker, CI fail,
gated git op, or a real watch hit).

## Pitfalls

- **Em-dash / Unicode in inline send-keys** → base64 path or plain-ASCII.
- **Pane-id churn** → resolve live, never hardcode.
- **Builder drift** → confirm `pane_current_command` + last line before relaying.
- **Repo tip is the fact** → read `origin/main`, not the pane's scrollback.
- **Self-merge detection** → verify tip after any merge.
- **Context budget** → at ~80% ctx, flag for a fresh pane (owner decision).
- **Nested-SSH quoting** → base64 multi-line scripts, don't pipe them raw.

## References

- **`references/overnight-build-review-loop.md`** — the full overnight loop
  procedure (slice selection, PR cadence, CI verification, the report).
- **`references/send-keys-remote-cli.md`** — the send-keys / base64 quoting
  patterns in detail, with the safe-send script inline.

## Related Skills

- **`remote-agent-relay`** — the status-relay + worktree-cleanup skill (the
  "how's it going" side of this workflow).
- **`agent-task-monitor`** — generic read-only status capture for any remote
  TUI.
- **`github-pr-workflow`** — the PR lifecycle via `gh` / GitHub API.
