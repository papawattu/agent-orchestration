#!/usr/bin/env bash
# tmux_local — drive tmux panes on THIS host (no ssh hop).
#
# Use when the orchestrator (this script's caller) and the agent panes run in
# the SAME tmux session on the SAME host. No ssh, no base64, no quoting traps —
# local `tmux send-keys -l` is safe for any bytes.
#
# Targets by WINDOW NAME (not index) so pane renumbering is a non-issue:
#   tmux_local.sh status  <window>          # live screen of <window>
#   tmux_local.sh back    <window> [lines]  # scrollback (default 200)
#   tmux_local.sh send    <window> <msg...> # send a brief (literal mode)
#   tmux_local.sh enter   <window>          # send a bare Enter
#   tmux_local.sh select  <window>          # pick a numbered option (Enter)
#   tmux_local.sh pipeon  <window> <file>   # tee the pane's output to <file>
#   tmux_local.sh pipeoff <window>          # stop the tee
#   tmux_local.sh interrupt <window>        # send C-c to a pane
#   tmux_local.sh panes                         # list all panes (id/name/cmd)
#   tmux_local.sh kill    <window>          # close the window
#   tmux_local.sh multi   <win>... -- <brief...> # fan one brief out to N windows
#   tmux_local.sh reorder <name>=<idx>...  # rename + renumber windows (start of loop)
#
# <window> is a tmux target: "build", "review", "b1", "b2", "main:build",
# "main:build.0", or a pane id "%15". Window names are stable; pane ids churn —
# prefer names. For multi-builder, name panes b1..bN and drive them all with
# `multi` (or loop over them). `reorder` renames + renumbers at the START of
# the loop so the names are predictable: b1, b2, ..., then review.
set -euo pipefail

SESSION="${TMUX_LOCAL_SESSION:-main}"   # override the session name if needed

resolve_target() {
  # Accept a bare window name and turn it into <session>:<window>.
  local w="$1"
  case "$w" in
    %*) echo "$w" ;;                       # already a pane id
    *:*:*.*) echo "$w" ;;                   # already s:w.pane
    *:*:*) echo "${w}.0" ;;                 # s:w -> s:w.0
    *:*:*) echo "$w" ;;
    *) echo "${SESSION}:${w}" ;;            # bare name -> main:name
  esac
}

cmd="${1:-help}"; shift || true
case "$cmd" in
  panes)
    tmux list-panes -s -F "#{pane_id}  #{session_name}:#{window_index} #{window_name}  [#{pane_current_command}]"
    ;;
  status)
    tmux capture-pane -p -t "$(resolve_target "${1:?window}")"
    ;;
  back)
    lines="${2:-200}"
    tmux capture-pane -p -t "$(resolve_target "${1:?window}")" -S "-${lines}"
    ;;
  send)
    w="${1:?window}"; shift
    tmux send-keys -t "$(resolve_target "$w")" -l "$*"
    ;;
  enter)
    tmux send-keys -t "$(resolve_target "${1:?window}")" Enter
    ;;
  select)
    # Pick a numbered option: send the option string then Enter.
    w="${1:?window}"; opt="${2:?option}"
    tmux send-keys -t "$(resolve_target "$w")" -l "$opt"
    tmux send-keys -t "$(resolve_target "$w")" Enter
    ;;
  pipeon)
    w="${1:?window}"; f="${2:?file}"
    tmux pipe-pane -t "$(resolve_target "$w")" -o "cat >> $f 2>&1"
    ;;
  pipeoff)
    tmux pipe-pane -t "$(resolve_target "${1:?window}")"
    ;;
  interrupt)   # send C-c to a pane
    tmux send-keys -t "$(resolve_target "${1:?window}")" C-c
    ;;
  kill)
    tmux kill-window -t "$(resolve_target "${1:?window}")"
    ;;
  multi)
    # Send the SAME brief to several windows (multi-builder fan-out).
    # `multi b1 b2 b3 -- "Open PRs, report numbers. Do NOT merge."`
    # Windows come first, then a literal `--`, then the brief (any bytes).
    # `send-keys -l` is literal, so Unicode is safe (local, no quoting trap).
    windows=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do windows+=("$1"); shift; done
    [[ $# -gt 0 && "$1" == "--" ]] && shift
    brief=("$@")
    if [[ ${#windows[@]} -lt 1 || ${#brief[@]} -lt 1 ]]; then
      echo "usage: tmux_local.sh multi <win>... -- <brief...>" >&2
      exit 2
    fi
    for w in "${windows[@]}"; do
      printf '[->] %s: %s\n' "$w" "${brief[*]}"
      tmux send-keys -t "$(resolve_target "$w")" -l "${brief[*]}"
    done
    ;;
  reorder)
    # Rename + (re)number windows AT THE START of the loop so names are
    # predictable: `reorder b1=0 b2=1 review=2`.
    #   b1,b2,...  = the builder windows, in fan-out order (renumbered 0,1,...)
    #   review     = the reviewer window (renamed last so it stays distinct)
    # Renames by CURRENT index (stable, no collisions). Pass the windows in
    # the ORDER you want them — the first arg gets index 0, the second 1, etc.
    # We rename in place; if you also need to physically re-order the tab bar,
    # the indices here already define the desired order (rename 0->b1, 1->b2…).
    pairs=("$@")
    [[ ${#pairs[@]} -lt 1 ]] && { echo "usage: tmux_local.sh reorder <name>=<idx>..." >&2; exit 2; }
    # Validate all pairs first (fail before touching anything).
    for p in "${pairs[@]}"; do
      [[ "$p" == *=* ]] || { echo "reorder: bad pair '$p' (want name=idx)" >&2; exit 2; }
    done
    # Rename by current index. Two passes: first to a unique temp name, then to
    # the real name — so swapping names (e.g. two windows both wanting 'b1')
    # never collides mid-pass.
    i=0
    for p in "${pairs[@]}"; do
      IFS='=' read -r name idx <<<"$p"
      tmux rename-window -t "${SESSION}:${idx}" "__reorder_${i}__"
      i=$((i+1))
    done
    i=0
    for p in "${pairs[@]}"; do
      IFS='=' read -r name idx <<<"$p"
      tmux rename-window -t "${SESSION}:${idx}" "$name"
      i=$((i+1))
    done
    # Report the resulting order.
    tmux list-windows -t "$SESSION" -F "  #{window_index}  #{window_name}  [#{pane_current_command}]"
    ;;
  help|*)
    sed -n '2,24p' "$0"
    ;;
esac
