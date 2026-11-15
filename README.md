# agent-orchestration

Generic, shareable agent skills for **orchestrating long-running agent tasks**
via **tmux** — with a **build → review → fix → re-review** loop in which a
*separate* reviewer independently gates the builder's output. Works over **SSH**
(orchestrator on a different host) **or locally** (orchestrator in its own tmux
window on the same host, `orchestrator: local`).

Built around the [GitHub Blog's "Build once, run on any agent" guide to agent
skills](https://github.blog/ai-and-ml/github-copilot/build-once-run-on-any-agent-a-practical-guide-to-agent-skills/). The key practice this repo follows: **keep project config out of the skill** — every host IP, username, project path, and owner name lives in ONE config file, not in the skill bodies. The skills are product-agnostic: they work for any agent that runs as a full-screen TUI inside tmux.

## The model

```
                 +----------------------------------------------------+
                 |  remote host (ssh_target)                          |
                 |   tmux session "main":                             |
                 |     window "build"   -> builder pane (writes code) |
                 |     window "review"  -> reviewer pane (gates PRs)  |
                 |  repo: <repo_path>                                  |
                 +----------------------------------------------------+
                          ^                       ^
        relay status      |                       |  hand a brief
        / send a brief    |                       |  ("build", "open PR",
   (Hermes agent) <-------+                       +------->  "review", "fix")
```

- **Builder** — writes code, opens PRs. **Never merges.**
- **Reviewer** — a *separate* pane that independently reviews PRs. **Self-verification is not verification.** **Never merges.**
- **Owner** — the only one who merges. Gates every "merge #N".

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
ssh_target: user@devbox.internal   # the remote host (SSH, key-based)
repo_path: ~/projects/myrepo       # the repo on the remote host
github_owner: yourghusername
github_repo: your-repo
git_credentials_file: ~/.git-credentials
```

Precedence (highest wins): env var (`AGENTSSH_TARGET`, `AGENT_REPO_PATH`, …) →
`config.yaml` → `config.example.yaml`. The `config.yaml` with your real values
is **git-ignored** — never commit it.

| Env var | Config key | Meaning |
|---------|-----------|---------|
| `AGENTSSH_TARGET` | `ssh_target` | `user@host` for the remote host |
| `AGENT_REPO_PATH` | `repo_path` | repo path on the remote host |
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
    scripts/ssh_safe_send.py       # quoting-safe tmux send (base64 path)
    scripts/worktree_classifier.py # classify worktrees: safe-to-prune vs KEEP
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

# Safe send a brief to the builder pane (Unicode-safe):
COXSSH_TARGET=user@host python3 skills/remote-agent-relay/scripts/ssh_safe_send.py %15 'Open the PR now. Report the number + CI. Do NOT merge.'

# Classify worktrees (safe-to-prune vs KEEP):
ssh user@host 'cd ~/projects/myrepo && python3 skills/remote-agent-relay/scripts/worktree_classifier.py'

# Read-only status capture of a remote TUI:
ssh user@host 'bash -s' < skills/agent-task-monitor/scripts/capture.sh
```

## License

MIT. See [LICENSE](LICENSE).
