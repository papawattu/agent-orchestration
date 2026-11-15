# send-keys / base64 quoting patterns (remote CLI over SSH)

The full quoting-safe patterns for sending input to a remote tmux pane over
ssh. This is the reference for `scripts/ssh_safe_send.py` (in the
`remote-agent-relay` skill) and for any inline send.

## Rule 1: Plain-ASCII in inline sends

If you type the brief inline (not via the script), use:
- hyphens (`-`) not em-dashes (`—`)
- `->` not `→`
- avoid middle-dots (`·`) and other non-ASCII

Unicode in a nested `ssh '… tmux send-keys -l "…" …'` breaks the outer bash
quoting. The message silently never lands (no error, just a no-op).

## Rule 2: Base64 the script for anything multi-line

A multi-line `bash`/`awk` script piped straight through `ssh '…'` gets mangled
by two quote layers (bash on the local side, bash on the remote side). The
pattern:

```python
import subprocess, tempfile, os, sys, base64

# 1. Write the remote script to a local temp file (Unicode-safe).
with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False, encoding="utf-8") as f:
    f.write(remote_script)
    script_path = f.name
try:
    # 2. base64-encode it (no wrapping).
    b64 = subprocess.run(
        ["base64", "-w0", script_path], capture_output=True, check=True
    ).stdout.decode().strip()
finally:
    os.unlink(script_path)

# 3. Ship it to the remote host, decode + run, clean up.
target = os.environ.get("AGENTSSH_TARGET")  # or load_config.target()
ssh_cmd = (
    f"echo '{b64}' | base64 -d > /tmp/remote_script.sh "
    f"&& bash /tmp/remote_script.sh && rm -f /tmp/remote_script.sh"
)
r = subprocess.run(["ssh", target, ssh_cmd], capture_output=True, text=True)
print(r.stdout, end="")
if r.returncode != 0:
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode)
```

The remote script itself uses `tmux send-keys -t <pane> -l "$BRIEF"` (literal
mode — no key interpretation), so the decoded brief is sent byte-for-byte.

## Rule 3: The safe-send for a single message

For a single brief (not a multi-line script), the pattern is the same but the
remote script is just the `tmux send-keys`:

```python
# remote_script = f'tmux send-keys -t {pane} -l "$BRIEF"\n'
#                + (f'tmux send-keys -t {pane} Enter\n' if accept_default else '')
# where BRIEF is the base64-decoded brief.
```

See `remote-agent-relay/scripts/ssh_safe_send.py` for the full implementation
with `--enter` / `--select` flags.

## Resolving pane ids

Pane ids churn — always resolve live:
```bash
ssh <ssh_target> 'tmux list-panes -s -F "#{pane_id} #{window_name} #{pane_current_command}"'
```
Find the pane whose `window_name` matches the role (build / review) and whose
command is the agent's TUI. Do **not** hardcode a pane id from a previous turn.

## Common failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Message never lands, no error | Unicode in inline send-keys broke quoting | Use the base64 path or plain-ASCII. |
| `no such pane` | Pane-id churn (pane closed/reopened) | Re-resolve pane ids live. |
| Script mangled on remote | Multi-line script piped through nested ssh | Base64 the script, don't pipe it raw. |
| `permission denied` on worktree remove | Root-owned build artifacts | `sudo rm -rf <path> && git worktree prune`. |
| Same screen across two captures | Agent stuck (network hang, rate limit) | Flag to owner; consider a fresh pane. |
