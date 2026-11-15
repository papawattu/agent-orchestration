---
name: agent-task-monitor
description: Summarise a long-running remote agent task (full-screen TUI) via SSH + tmux.
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos]
metadata:
  hermes:
    tags: [monitoring, tmux, ssh, agent, status, relay]
    related_skills: [remote-agent-relay, github-pr-workflow]
---

# Remote Agent Task Monitor

Peek at a long-running **agent task** that runs as a full-screen TUI inside
tmux on a remote host (configured as `ssh_target` in `config.yaml`), and
report a *short* status back to the user — not the raw scrollback. It answers
three things: what is it doing, does it need the user, and (if finished) what
did it produce. It does **not** attach or steal the TUI; capture is read-only
unless the user explicitly asks you to answer a prompt.

> **Generic:** this skill does not assume any particular agent product. It
> works for any long-running TUI the agent runs in tmux (a build agent, a
> coding agent, a REPL, a wizard). The completion markers in
> `scripts/capture.sh` are agent-agnostic; adapt them if you watch a different
> TUI.

## When to Use

- User asks "check on the task", "how's the build going", "is the agent waiting on me", "monitor my agent".
- User wants a running-status summary or to be told when the task needs input / is done.
- Don't use for: driving the agent from scratch (use `remote-agent-relay`), or any host other than the configured `ssh_target`'s tmux session.

## Prerequisites

- **tmux-only mode** (`orchestrator: local`, DEFAULT): the orchestrator runs on
  the *same host* as the agent TUI, in its own tmux window. No ssh needed — use
  `remote-agent-relay/scripts/tmux_local.sh` instead of the ssh-wrapped capture
  below. **The common case.**
- **ssh+tmux mode** (`orchestrator: remote`): SSH reachability to `ssh_target`
  (key-based; no prompt). Set it in `config.yaml` (`ssh_target: user@host`) or
  the `AGENT_SSH_TARGET` env var.
- A tmux session on the host (default `main`) with a window running the
  agent's TUI.
- The helper `scripts/capture.sh` (bundled, remote mode) — auto-detects the
  agent window.

## How to Run

**Local mode (default)** — drive the pane with `remote-agent-relay/scripts/tmux_local.sh`
(same host, no ssh):

```bash
# Live screen:
tmux_local.sh status <window>
# Scrollback (last 200 lines):
tmux_local.sh back <window> 200
```

**Remote mode** — pipe the bundled helper over SSH (it runs on the remote host
and auto-detects the agent window):

```bash
ssh <ssh_target> 'bash -s' < scripts/capture.sh
```

Custom target window/pane and more scrollback (e.g. `main:2` and 250 lines for
a final-output dump):

```bash
ssh <ssh_target> 'bash -s -- main:2 250' < scripts/capture.sh
```

**Remote fallback** if the helper can't run — capture directly:

```bash
ssh <ssh_target> 'tmux list-windows -a -F "#{session_name}:#{window_index} #{window_name} [#{pane_current_command}]"'
ssh <ssh_target> 'tmux capture-pane -p -t main:1'          # live screen
ssh <ssh_target> 'tmux capture-pane -p -t main:1 -S -200'  # scrollback
```

In remote mode the helper prints four blocks — `===TARGET===`, `===META===`,
`===SCREEN===`, `===SCROLLBACK===`. Read **SCREEN** for live state;
**SCROLLBACK** for context and the final output. In local mode the two
commands above give you SCREEN and SCROLLBACK directly.

## Classify the State

Judge from the **SCREEN** block (the live bottom of the pane):

| State | Tells |
|-------|-------|
| Busy / working | Spinner glyph (`⠋ ⠙ ⠸ ⠇ …`) with `Working...`/`Thinking`, `Took 0.7s`, streaming tool output, or a running `$ command`. |
| Waiting on user | Empty input prompt (`❯`/`>`) with the last message ending in a question (`?`), a `(y/n)` or `[1]…[2]…` choice, `Do you want`, `Proceed?`, `Allow`, or a permission/tool-use prompt. |
| Finished | No spinner; clean idle prompt; last message reads like a wrap-up/result, a final PR/commit link, or "Done". |
| Errored / stuck | A traceback, `Error`, `panic`, rate/context-limit notice, or the same screen unchanged across two captures. |

If it's unclear whether it's still moving, capture **twice ~15–20s apart** and
diff SCREEN — a changed spinner/line means still busy; identical means
idle / waiting / stuck.

## Report

- **Busy** — one or two lines: the task/file/PR and current sub-step. No input needed.
- **Waiting** — lead with it, quote the exact question, and lay out the options so the user can answer in one message.
- **Errored / stuck** — say so plainly, quote the error, suggest the next move (retry, clear context, attach).
- **Finished** — only now expand: a 2–4 line summary of what it did, the relevant tail of SCROLLBACK as the final output (trim noise, keep links/results), and 2–4 concrete follow-ups.

## Answer a Prompt (only on explicit instruction)

When — and only when — the user tells you what to send, send keys to the
agent input and re-capture to confirm it took:

**Local mode (default):**
```bash
tmux_local.sh send <window> "y" && tmux_local.sh enter <window>   # type then Enter
tmux_local.sh enter <window>                                      # bare Enter
tmux_local.sh interrupt <window>                                  # C-c
```

**Remote mode:**
```bash
ssh <ssh_target> "tmux send-keys -t main:1 'y' Enter"   # type then Enter
ssh <ssh_target> "tmux send-keys -t main:1 Enter"       # bare Enter
ssh <ssh_target> "tmux send-keys -t main:1 C-c"         # interrupt
```

Never send keys speculatively — a wrong keystroke can derail a long task.
Confirm intent, send, then re-run the capture to verify.

## Pitfalls

- `capture-pane` is read-only and does not disturb the agent; sending keys is not — gate it behind explicit user intent.
- POSIX-only helper (bash `-s`, `awk`, tmux) → `platforms: [linux, macos]`.
- Multiple agent tasks: pass an explicit target (`main:1`, `main:2.0`, or another session) as the first helper arg.
- To watch continuously, schedule this skill on a cron/loop rather than sleeping inside one run.
- Human attach (not for you): `ssh <ssh_target> -t 'tmux attach -t main'`.
