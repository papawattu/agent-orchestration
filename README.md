# Local and remote agent-orchestration using tmux

Generic, shareable agent skills for **orchestrating long-running agent tasks**
via **tmux** — with a **build → review → fix → re-review** loop in which a
*separate* reviewer independently gates the builder's output. Works over **SSH**
(orchestrator on a different host) **or locally** (orchestrator in its own tmux
window on the same host, `orchestrator: local`).

Built around the [GitHub Blog's "Build once, run on any agent" guide to agent
skills](https://github.blog/ai-and-ml/github-copilot/build-once-run-on-any-agent-a-practical-guide-to-agent-skills/). The key practice this repo follows: **keep project config out of the skill** — every host IP, username, project path, and owner name lives in ONE config file, not in the skill bodies. The skills are product-agnostic: they work for any agent that runs as a full-screen TUI inside tmux.

## Install

**Requirements:** `tmux` and `git` on the host where the agents run. Python 3
(≥3.8) if you use the helper scripts. In **local** mode the orchestrator is a
tmux window on the *same* host as the agents (no ssh); in **remote** mode you
also need key-based ssh to `ssh_target`.

**1. Get the skills into your agent's skill dir.** Any agent that reads
`SKILL.md` files (Hermes, Claude, Codex, …) picks these up from a `skills/`
directory. Point it at this repo — either symlink, copy, or clone:

```bash
# Hermes (default skill dir) — run this FROM INSIDE the clone so the symlink
# points at this repo, or link the fixed clone path (~/agent-orchestration):
ln -s ~/agent-orchestration ~/.hermes/skills/agent-orchestration
#   (or, from inside the clone:  ln -s "$(pwd)" ~/.hermes/skills/agent-orchestration)

# Or just copy the skill folders you want:
mkdir -p ~/.hermes/skills
cp -r skills/remote-agent-relay skills/agent-task-monitor ~/.hermes/skills/

# Or clone (the path above is assumed):
git clone https://github.com/papawattu/agent-orchestration ~/agent-orchestration
```

The skill names and frontmatter are standard, so an agent that scans `SKILL.md`
will list them automatically. The bundled `scripts/` travel with each skill.

**2. Configure.** One file holds all host-specific values:

```bash
cd <repo>                     # the clone above
cp config.example.yaml config.yaml
$EDITOR config.yaml           # fill in ssh_target, repo_path, github_owner/repo, orchestrator
```

`config.yaml` is git-ignored — never commit it. You can also set values per-run
via `AGENT_*` env vars (see the table below) instead of editing the file.

**3. Smoke-test.**

```bash
# Local mode: confirm the helper sees your agent panes.
bash skills/remote-agent-relay/scripts/tmux_local.sh panes

# Remote mode: confirm the capture helper reaches the remote TUI.
ssh <ssh_target> 'bash -s' < skills/agent-task-monitor/scripts/capture.sh
```

If both print sensible output, you're wired up.

## The model

```
                 +----------------------------------------------------+
                 |  host running the agents (tmux session "main")     |
                 |     window "build"   -> builder pane (writes code) |
                 |     window "review"  -> reviewer pane (gates PRs)  |
                 |  repo: <repo_path>                                  |
                 +----------------------------------------------------+
                          ^                       ^
        relay status      |                       |  hand a brief
        / send a brief    |                       |  ("build", "open PR",
   (orchestrator) <-------+                       +------->  "review", "fix")
        local: same host (tmux)   |   remote: different host (ssh + tmux)
```

- **Builder** — writes code, opens PRs. **Never merges.**
- **Reviewer** — a *separate* pane that independently reviews PRs. **Self-verification is not verification.** **Never merges.**
- **Owner** — the only one who merges. Gates every "merge #N".

## Guardrails (what this is *not*)

These skills are a **relay**, not an autopilot. The human checkpoint stays:

- **The owner's `y/n` and every `y/n/s` answer is the gate.** Nothing in this
  repo auto-types instructions into the agent's tmux pane. A Mac-side watcher
  that reads `/workspace` and feeds prompts to tmux on its own would *remove*
  that checkpoint — don't build that.
- **A separate reviewer is the point, not decoration.** The real failure
  this design exists to catch: an agent that stops the real local service,
  swaps in a fake one (a stub script), and self-reports "tests pass". A
  reviewer whose job includes *"is this the real service?"* catches it.
  **Self-verification is not verification** — the builder must never
  rubber-stamp its own output.
- **The repo tip is the fact, not the pane.** Report `origin/main` (fetched),
  not a pane's scrollback, before claiming a PR landed.
- **Detect self-merges.** After any merge, verify the tip advanced to the
  expected SHA. If the agent merged on its own (a `--admin --squash` bypass),
  flag the gate bypass — don't normalise it.

In short: the skills *read* the agent and *hand it a brief*; they never
replace the owner's decision to merge.

## Skills

| Skill | What it does |
|-------|-------------|
| `remote-agent-relay` | Drive + report on the remote build agent: relay status, hand a brief, the build→review→fix loop, worktree cleanup. The primary skill. |
| `agent-task-monitor` | Read-only status capture for *any* long-running remote TUI (generic "how's it going"). |
| `remote-cli-ssh-tmux` | The generic build→review loop + the send-keys/base64 quoting patterns. |
| `github-pr-workflow` | The PR lifecycle (create, CI, review, merge) via `gh` / GitHub API. |

## Configuration

All host-specific values live in **ONE** file — copy `config.example.yaml` to
`config.yaml` and fill it in:

```yaml
orchestrator: local                # local (default, same-host tmux) | remote
ssh_target: user@your-host   # the remote host (SSH, key-based) — remote mode
repo_path: ~/projects/myrepo       # the repo on the host running the agents
github_owner: yourghusername
github_repo: your-repo
git_credentials_file: ~/.git-credentials
```

Precedence (highest wins): env var (`AGENT_SSH_TARGET`, `AGENT_REPO_PATH`, …) →
`config.yaml` → `config.example.yaml`. The `config.yaml` with your real values
is **git-ignored** — never commit it.

| Env var | Config key | Meaning |
|---------|-----------|---------|
| `AGENT_ORCHESTRATOR` | `orchestrator` | `local` (default) or `remote` — where the orchestrator runs |
| `AGENT_SSH_TARGET` | `ssh_target` | `user@host` for the remote host (remote mode) |
| `AGENT_REPO_PATH` | `repo_path` | repo path on the host running the agents |
| `AGENT_GITHUB_OWNER` | `github_owner` | GitHub owner/org |
| `AGENT_GITHUB_REPO` | `github_repo` | GitHub repo name |
| `AGENT_GIT_CREDENTIALS` | `git_credentials_file` | PAT store (git credential-store format) |

## Layout

```
config.example.yaml          # the one config template (fill -> config.yaml)
.gitignore
LICENSE
README.md
scripts/load_config.py       # shared config loader (env > config.yaml > example)
skills/
  remote-agent-relay/
    SKILL.md
    scripts/ssh_safe_send.py       # quoting-safe tmux send (base64 path, remote)
    scripts/worktree_classifier.py # classify worktrees: safe-to-prune vs KEEP
    scripts/tmux_local.sh          # local-mode helper (same-host, no ssh)
    references/tmux-local-mode.md  # local-mode mechanics + pipe-pane tee
  agent-task-monitor/
    SKILL.md
    scripts/capture.sh             # read-only TUI capture (screen + scrollback)
  remote-cli-ssh-tmux/
    SKILL.md
    references/overnight-build-review-loop.md
    references/send-keys-remote-cli.md
  github-pr-workflow/
    SKILL.md                       # as-is (already generic)
```

## Using the scripts

```bash
# Configure (once):
cp config.example.yaml config.yaml
$EDITOR config.yaml    # fill in your ssh_target, repo_path, github_owner/repo

# Safe send a brief to the builder pane (Unicode-safe) — remote mode:
AGENT_SSH_TARGET=user@host python3 skills/remote-agent-relay/scripts/ssh_safe_send.py %15 'Open the PR now. Report the number + CI. Do NOT merge.'
# ...or local mode (no ssh, no env needed):
bash skills/remote-agent-relay/scripts/tmux_local.sh send build 'Open the PR now. Report the number + CI. Do NOT merge.'

# Classify worktrees (safe-to-prune vs KEEP):
ssh user@host 'cd ~/projects/myrepo && python3 skills/remote-agent-relay/scripts/worktree_classifier.py'

# Read-only status capture of a remote TUI:
ssh user@host 'bash -s' < skills/agent-task-monitor/scripts/capture.sh
```

## License

MIT. See [LICENSE](LICENSE).
