# Tmux-Only Mode (no SSH)

Drive the agent panes from a **tmux window on the same host** — no ssh hop, no
base64, no quoting traps. Use this when the orchestrator (the relay/monitor
pane) and the builder/reviewer panes all live in one tmux session on one box.

## When to use which mode

| Mode | Orchestrator location | Every action | Unicode briefs |
|------|----------------------|--------------|----------------|
| **ssh+tmux** (default) | Off-box (a different host) | ssh round-trip | base64 required |
| **tmux-only** | On-box (same host, same or sibling session) | local `tmux` call | safe as-is |

Config toggle in `config.yaml`:
```yaml
orchestrator: local     # local = tmux-only (same host)  |  remote = ssh+tmux (default)
```
Or override per-run with the `AGENT_ORCHESTRATOR` env var.

## The layout

```
tmux session "main" (ONE host):
  window "orchestrator"   <- this skill runs here (or you attach and drive it)
  window "build"          <- builder agent TUI
  window "review"         <- reviewer agent TUI
```

Target by **window name**, not index — immune to pane renumbering:
`build`, `review`, or fully-qualified `main:build.0`.

## Commands (via scripts/tmux_local.sh)

```bash
# List all panes (id / session:win / name / current command):
tmux_local.sh panes

# Status — live screen of the build window:
tmux_local.sh status build

# Scrollback — last 200 lines:
tmux_local.sh back build 200

# Send a brief to the builder (literal mode, any bytes safe — no base64):
tmux_local.sh send build "Open the PR now. Report the number + CI. Do NOT merge."

# Accept a default / continue (bare Enter):
tmux_local.sh enter build

# Pick a numbered option (e.g. option 2) from a menu:
tmux_local.sh select build 2

# Tee the build pane's output to a log the orchestrator tails (no repeated
# capture-pane calls needed):
tmux_local.sh pipeon build /tmp/build.log
# ... later, stop the tee:
tmux_local.sh pipeoff build

# Close a window when its task is done:
tmux_local.sh kill build
```

## The three tmux-native tricks

1. **Target by window name.** `main:build` instead of a pane index — the
   orchestrator never has to re-resolve a churning `%N`.

2. **`pipe-pane`** — tee a pane's output to a file *from inside tmux*, so the
   orchestrator tails a stream instead of polling `capture-pane`:
   ```bash
   tmux pipe-pane -t build -o 'cat >> /tmp/build.log 2>&1'
   tmux pipe-pane -t build          # no command = disable
   ```

3. **A dedicated tmux socket** — if the orchestrator and the agents share a
   host but you want isolation, run them on their own socket:
   ```bash
   tmux -L agents new-session -d -s main -n orchestrator
   tmux -L agents new-window -t main: -n build
   # then target with: tmux -L agents capture-pane -t main:build
   ```
   Set `TMUX_LOCAL_SESSION=main` (or the socket via the tmux `-L` flag) to
   match. The `tmux_local.sh` helper honours `TMUX_LOCAL_SESSION` for the
   default session name.

## No-ssh send-keys is safe

In tmux-only mode there is **no nested-ssh quoting trap** — `tmux send-keys -l`
runs locally and takes the literal argument verbatim. Em-dashes, arrows,
middle-dots: all fine. The base64 path in `ssh_safe_send.py` is only needed
for the **ssh+tmux** mode.

## State handoff (same session)

When orchestrator and agents share a session, they share the tmux socket, so
state can be passed without a file:
- `tmux set-environment -t main KEY value` / `tmux show-environment -t main KEY`
  (session-scoped env vars visible to all panes in that session).
- Or a plain file in a scratch dir (simplest; `pipe-pane` already does this
  for output).

## Tradeoffs vs ssh+tmux

- **Pro:** no ssh round-trip per action, no quoting traps, `pipe-pane` tee,
  trivial to attach and watch (`tmux attach` / `select-window`).
- **Con:** the orchestrator must run on the same host as the agents. If the
  relay skill is driven from a *different* box (e.g. Hermes on a laptop, agent
  on a devbox), you need the ssh+tmux mode.
