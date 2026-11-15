#!/usr/bin/env python3
"""Send a tmux message to a pane on the remote host via ssh, quoting-safely.

Why: a message containing em-dashes / arrows / middle-dots inside a nested
`ssh '... tmux send-keys ...'` breaks the outer bash quoting (syntax error) and
the message never lands. This script base64-encodes the brief and ships it to
the remote host, so Unicode in the brief is safe.

The remote target is read from the shared config (see load_config.py):
    ssh_target  -> env AGENTSSH_TARGET  >  config.yaml  >  config.example.yaml
Keep plain-ASCII hyphens (-) in any inline message you type by hand; reserve
Unicode for this scripted path.

Usage:
  python3 ssh_safe_send.py <pane_id> <message> [--enter] [--select]

  <pane_id>   tmux pane id (e.g. %15). Resolve it live with:
                ssh <ssh_target> 'tmux list-panes -s -F "#{pane_id} #{window_name} #{pane_current_command}"'
  <message>   the brief/instruction (may contain Unicode; it's base64'd).
  --enter     append a bare Enter (accept default / continue) — for a resume.
  --select    append a bare Enter after a numbered/checkbox menu selection.

Examples:
  # Hand a brief to the builder pane (safe, Unicode ok):
  python3 ssh_safe_send.py %15 'Open the PR now. Report the PR number + CI, then stop. Do NOT merge.'

  # Resume a paused agent at a gate:
  python3 ssh_safe_send.py %15 '' --enter

  # Pick a numbered option from a confirmation menu (e.g. option 2):
  python3 ssh_safe_send.py %15 '2' --select
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import load_config  # noqa: E402


def main():
    args = sys.argv[1:]
    enter = "--enter" in args
    select = "--select" in args
    args = [a for a in args if a not in ("--enter", "--select")]
    if len(args) < 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    pane, msg = args[0], args[1]
    target = load_config.target()

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
    # no key interpretation), then optionally a bare Enter.
    remote = (
        "#!/usr/bin/env bash\nset -euo pipefail\n"
        f"BRIEF=$(echo '{b64}' | base64 -d)\n"
        f"tmux send-keys -t {pane} -l \"$BRIEF\"\n"
    )
    if enter:
        remote += f"tmux send-keys -t {pane} Enter\n"
    if select:
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
