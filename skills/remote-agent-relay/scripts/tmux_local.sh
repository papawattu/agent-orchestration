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
#   tmux_local.sh send    <window> <msg...>   # brief + submit (Enter); [ --noenter ]
#   tmux_local.sh enter   <window>          # send a bare Enter
#   tmux_local.sh select  <window> <opt>    # pick a numbered option (Enter)
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
# Settle delay (ms) before the trailing Enter. `send-keys -l` injects the
# whole line into the pane's input buffer in one shot; the TUI's event loop
# still has to drain it. For long briefs the newline can arrive before the TUI
# has parsed the preceding characters, so the line lands un-submitted (or the
# Enter interleaves mid-line). A short settle fixes that. Override with
# TMUX_LOCAL_DELAY=0 to disable.
SEND_DELAY="${TMUX_LOCAL_DELAY:-250}"

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

# send_into <window> [--noenter] <text...>
# Inject <text> literally (any bytes), then — UNLESS --noenter — settle and
# send a real Enter so the TUI submits the line. This is the fix for the
# "send-keys does not always send Enter" bug: `send-keys -l` alone only inserts
# the text; it never submits.
send_into() {
  local w="$1"; shift
  local noenter=0
  [[ "${1:-}" == "--noenter" ]] && { noenter=1; shift; }
  # tmux send-keys -l rejects a leading "--" flag; a brief never starts with it,
  # so just strip a stray one if present.
  [[ "${1:-}" == "--" ]] && shift
  local text="$*"
  local t
  t="$(resolve_target "$w")"
  tmux send-keys -t "$t" -l "$text"
  if [[ "$noenter" -eq 0 ]]; then
    [[ "$SEND_DELAY" -gt 0 ]] && sleep "$(awk "BEGIN{printf \"%.3f\", $SEND_DELAY/1000}")"
    tmux send-keys -t "$t" Enter
  fi
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
    # Appends a settling Enter by default (the brief must actually submit).
    # Pass --noenter to insert the text without submitting.
    send_into "$w" "$@"
    ;;
  enter)
    tmux send-keys -t "$(resolve_target "${1:?window}")" Enter
    ;;
  select)
    # Pick a numbered option: send the option string then a real Enter.
    w="${1:?window}"; opt="${2:?option}"
    send_into "$w" "$opt"
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
    # Send the SAME brief to several windows (multi-builder fan-out), each
    # submitted with a settling Enter. `multi b1 b2 b3 -- "Open PRs..."`.
    # Windows first, then a literal `--`, then the brief (any bytes).
    # Per-pane settle (TMUX_LOCAL_DELAY) avoids the Enter-interleave race.
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
      send_into "$w" "${brief[*]}"
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
