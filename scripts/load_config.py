#!/usr/bin/env python3
"""Shared config loader for the remote-agent skill set.

Every skill in this repo is generic: it contains no host IPs, usernames,
project paths, or owner names. All of those live in ONE config file.

Precedence (highest wins):
    1. Environment variable   (AGENTSSH_TARGET, AGENT_REPO_PATH, AGENT_GITHUB_OWNER, ...)
    2. config.yaml            (your local filled-in copy, next to this file's
                               parent repo root; git-ignored)
    3. config.example.yaml    (placeholders only — the shipped default)

Usage:
    import load_config
    cfg = load_config.load()
    target = cfg["ssh_target"]            # e.g. "user@devbox.internal"
    repo   = cfg["repo_path"]             # e.g. "~/projects/<repo>"
    owner  = cfg["github_owner"]
    repo_n = cfg["github_repo"]

The loader walks UP from this file's directory looking for config.yaml then
config.example.yaml, so the scripts work no matter where they're copied to.
If you set env vars, they always win (useful for CI / one-off overrides).
"""
import os
import re
from pathlib import Path

# Map: config key -> env var that overrides it.
ENV_OVERRIDES = {
    "ssh_target": "AGENTSSH_TARGET",
    "repo_path": "AGENT_REPO_PATH",
    "secondary_host": "AGENTSSH_SECONDARY",
    "github_owner": "AGENT_GITHUB_OWNER",
    "github_repo": "AGENT_GITHUB_REPO",
    "git_credentials_file": "AGENT_GIT_CREDENTIALS",
    "hermes_state_db": "AGENT_STATE_DB",
}


def _parse_simple_yaml(path: Path) -> dict:
    """Minimal flat key: value parser (no external deps).

    Handles `key: value`, `key: "value"`, comments (#), and blank lines.
    This is enough for config.example.yaml / config.yaml — it is NOT a full
    YAML parser; keep the config flat (one level, scalars only).
    """
    data = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip()
        val = val.strip()
        # Strip an inline comment, respecting simple quoting.
        #   `key: value  # comment`  -> value
        #   `key: "value"  # comment` -> "value"
        if val.startswith('"'):
            # value in double quotes: take up to the closing quote
            end = val.find('"', 1)
            val = val[: end + 1] if end != -1 else val
        elif val.startswith("'"):
            end = val.find("'", 1)
            val = val[: end + 1] if end != -1 else val
        else:
            # unquoted: cut at the first ` #` or leading `#`
            idx = val.find(" #")
            if idx != -1:
                val = val[: idx].rstrip()
            elif val.startswith("#"):
                val = ""
        # unquote
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
            val = val[1:-1]
        data[key] = val
    return data


def _find_config_file() -> Path | None:
    """Walk up from this file looking for config.yaml, else config.example.yaml."""
    here = Path(__file__).resolve().parent
    for base in [here, here.parent, here.parent.parent]:
        for name in ("config.yaml", "config.example.yaml"):
            cand = base / name
            if cand.exists():
                return cand
    return None


def load() -> dict:
    """Return the merged config dict (env > config.yaml > config.example.yaml)."""
    merged: dict = {}
    # 3. example defaults (lowest)
    ex = _find_config_file()
    if ex is not None:
        merged.update(_parse_simple_yaml(ex))
    # 2. local config.yaml (middle) — only if a distinct file exists
    local = None
    for base in (Path(__file__).resolve().parent,
                 Path(__file__).resolve().parent.parent,
                 Path(__file__).resolve().parent.parent.parent):
        cand = base / "config.yaml"
        if cand.exists():
            local = cand
            break
    if local is not None:
        merged.update(_parse_simple_yaml(local))
    # 1. env vars (highest)
    for key, env in ENV_OVERRIDES.items():
        v = os.environ.get(env)
        if v:
            merged[key] = v
    # sanity: default the credential file if unset
    merged.setdefault("git_credentials_file", "~/.git-credentials")
    return merged


def target() -> str:
    return load()["ssh_target"]


def repo() -> str:
    return load()["repo_path"]


if __name__ == "__main__":
    import json
    print(json.dumps(load(), indent=2))
