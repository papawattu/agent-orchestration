#!/usr/bin/env bash
# agent-task capture — runs on the remote host (piped over SSH):
#   ssh <ssh_target> 'bash -s' < capture.sh [TARGET] [SCROLLBACK_LINES]
#
# Generic: works for any long-running TUI the agent runs in tmux. Auto-detects
# the agent's window by common names; pass TARGET to override. Prints four
# blocks: ===TARGET=== (chosen), ===META=== (session/window/pane cmd),
# ===SCREEN=== (live bottom of pane), ===SCROLLBACK=== (last N lines).
#
# POSIX-only (bash, awk, tmux) -> linux/macos.
set -euo pipefail

# Default target: session "main" window whose name looks like the agent task.
TARGET="${1:-}"
LINES="${2:-150}"

# Auto-detect a running TUI window by common names (agent, build, coding, etc.)
# or a full-screen command, preferring the most recently used.
if [[ -z "$TARGET" ]]; then
  # Find the default session, then the window that looks like an agent TUI.
  DEFAULT_SESSION="$(tmux list-sessions -F '#{session_name}' | awk 'NR==1{print; exit}')"
  [[ -n "$DEFAULT_SESSION" ]] || DEFAULT_SESSION="main"
  TARGET="$(tmux list-windows -t "$DEFAULT_SESSION" -F ' #{window_index} #{window_name} #{window_activity}' \
    | awk '$2 ~ /(agent|build|review|repl|shell|bash|zsh|coding)/ {print $1; exit}' | sed 's/^ *//' )"
  [[ -n "$TARGET" ]] || TARGET=1
  TARGET="${DEFAULT_SESSION}:${TARGET}"
fi

# Normalise TARGET to a valid pane spec.
if [[ "$TARGET" == *:* && "$TARGET" != *:*.* ]]; then
  TARGET="${TARGET}.0"
fi

echo "===TARGET==="
echo "$TARGET"

echo "===META==="
tmux list-windows -a -F "#{session_name}:#{window_index}.#{window_pane_index} #{window_name} [#{pane_current_command}]" \
  | awk -v t="$TARGET" '
    BEGIN { split(t, a, ":"); sess=a[1]; win=a[2]; sub(/\..*$/, "", win) }
    {
      # $1 = session:win.pane  -> split for comparison
      split($1, p, ":");
      split(p[2], q, ".");
      if (p[1]==sess && q[1]==win) print;
    }
  '

echo "===SCREEN==="
tmux capture-pane -p -t "$TARGET"

echo "===SCROLLBACK==="
tmux capture-pane -p -t "$TARGET" -S "-${LINES}"
