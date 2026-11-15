#!/usr/bin/env python3
"""Send a tmux message to a pane on the remote host via ssh, quoting-safely.

Why: a message containing em-dashes / arrows / middle-dots inside a nested
`ssh '... tmux send-keys ...'` breaks the outer bash quoting (syntax error) and
the message never lands. This script base64-encodes the brief and ships it to
the remote host, so Unicode in the brief is safe.

Sends SUBMIT BY DEFAULT: the brief is sent with `send-keys -l`, then a short
settle, then a real Enter — because `send-keys -l` alone only *inserts* the
text and never submits, so a brief without an Enter never reaches the agent.
Pass --noenter to insert the text without submitting (e.g. to edit a line the
agent is mid-typing). Settle is 250 ms; override with RELAY_SEND_DELAY (ms)
or RELAY_SEND_DELAY=0 to disable (use a higher value for slow-rendering TUIs).

The remote target is read from the shared config (see load_config.py):
    ssh_target  -> env AGENT_SSH_TARGET  >  config.yaml  >  config.example.yaml
Keep plain-ASCII hyphens (-) in any inline message you type by hand; reserve
Unicode for this scripted path.

Usage:
  python3 ssh_safe_send.py <pane_id> <message> [--noenter]

  <pane_id>   tmux pane id (e.g. %15). Resolve it live with:
                ssh <ssh_target> 'tmux list-panes -s -F "#{pane_id} #{window_name} #{pane_current_command}"'
  <message>   the brief/instruction (may contain Unicode; it's base64'd).
  --noenter   insert the text WITHOUT a trailing Enter (submit it yourself later
              with `ssh <t> 'tmux send-keys -t <pane> Enter'`, or a second call
              with an empty message + no --noenter).

Examples:
  # Hand a brief to the builder pane (safe, Unicode ok, SUBMITTED):
  python3 ssh_safe_send.py %15 'Open the PR now. Report the PR number + CI, then stop. Do NOT merge.'

  # Insert text without submitting (edit a mid-typed line / stage input):
  python3 ssh_safe_send.py %15 'partial text' --noenter
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import load_config  # noqa: E402


def main():
    args = sys.argv[1:]
    noenter = "--noenter" in args
    args = [a for a in args if a != "--noenter"]
    if len(args) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    pane, msg = args[0], args[1]
    target = load_config.target()
    # Settle (ms) before the trailing Enter, so a long brief's newline doesn't
    # interleave mid-line before the TUI has parsed the preceding characters.
    settle = int(os.environ.get("RELAY_SEND_DELAY", "250"))

    # Write the brief to a local temp file (Unicode-safe; the base64 hop is
    # what protects it from the nested-ssh quoting trap).
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False, encoding="utf-8") as f:
        f.write(msg)
        brief_path = f.name
    try:
        b64 = subprocess.run(
            ["base64", "-w0", brief_path], capture_output=True, check=True
        ).stdout.decode().strip()
    finally:
        os.unlink(brief_path)

    # Remote script: decode the brief, send it with send-keys -l (literal —
    # no key interpretation), then — UNLESS --noenter — settle + a real Enter.
    remote = (
        "#!/usr/bin/env bash\nset -euo pipefail\n"
        f"BRIEF=$(echo '{b64}' | base64 -d)\n"
        f"tmux send-keys -t {pane} -l \"$BRIEF\"\n"
    )
    if not noenter:
        if settle > 0:
            remote += f"sleep 0.{max(settle // 10, 1)}\n" if settle < 1000 else f"sleep {settle / 1000:.3f}\n"
        remote += f"tmux send-keys -t {pane} Enter\n"

    # Ship the script base64'd and run it on the remote host (same quoting-safe
    # pattern as the worktree classifier).
    script_b64 = subprocess.run(
        ["base64", "-w0"], input=remote.encode(), capture_output=True, check=True
    ).stdout.decode().strip()
    ssh_cmd = (
        f"echo '{script_b64}' | base64 -d > /tmp/relay_send.sh "
        f"&& bash /tmp/relay_send.sh && rm -f /tmp/relay_send.sh"
    )
    r = subprocess.run(["ssh", target, ssh_cmd], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(r.returncode)


if __name__ == "__main__":
    main()
