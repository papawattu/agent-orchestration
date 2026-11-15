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
#
# <window> is a tmux target: "build", "review", "main:build", "main:build.0",
# or a pane id "%15". Window names are stable; pane ids churn — prefer names.
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
  help|*)
    sed -n '2,20p' "$0"
    ;;
esac
