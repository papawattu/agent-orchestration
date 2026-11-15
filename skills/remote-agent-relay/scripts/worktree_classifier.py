#!/usr/bin/env python3
"""Classify the git worktrees in the current repo: which are safe to prune.

Why this exists: agent build slices typically `git worktree add <repo>-<slice>`
each (plus /tmp/*-deploy worktrees). They accumulate (dozens over a night) and
the host disk climbs. Work is preserved by the branch refs, not the worktree,
so a merged/landed worktree is safe to `git worktree remove --force`. But a
worktree with a detached head that is NOT on the base branch may hold the only
reachable copy of unpushed work — keep it.

Run it in the target repo (the one whose worktrees you want to classify):
  ssh <ssh_target> 'cd <repo_path> && python3 worktree_classifier.py'

Output: a classification block, then the exact safe-prune list.

Rules:
  - base-branch checkout (HEAD == base tip, or branch == base) -> KEEP (always).
  - HEAD is an ancestor of base -> MERGED (safe to prune).
  - a NAMED branch whose commit subject is on base -> SQUASH-MERGED (safe — the
    branch ref still holds the commit).
  - a detached head NOT on base -> KEEP (unreachable commit; do not prune).

NOTE: a `git worktree remove --force` on a worktree dir holding root-owned
build artifacts can return permission-denied — use `sudo rm -rf <path>` then
`git worktree prune`. The classifier tells you WHICH dirs are safe; it does not
delete them.
"""
import subprocess
import sys


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.stdout.strip()


def main():
    if not git("rev-parse", "--is-inside-work-tree"):
        sys.stderr.write("Run from inside a git repository.\n")
        sys.exit(2)

    # Default base to the repo's current branch (usually 'main').
    base = git("rev-parse", "--abbrev-ref", "HEAD") or "main"

    # --porcelain: blocks of `worktree <path>\nHEAD <sha>\n[branch refs/heads/<name>]`.
    out = git("worktree", "list", "--porcelain")
    blocks = []
    cur = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            if cur:
                blocks.append(cur)
            cur = {"path": line.split(" ", 1)[1], "head": None, "branch": None}
        elif line.startswith("HEAD ") and cur is not None:
            cur["head"] = line.split(" ", 1)[1]
        elif line.startswith("branch ") and cur is not None:
            cur["branch"] = line.split(" ", 1)[1]
    if cur:
        blocks.append(cur)

    base_head = git("rev-parse", base)
    base_log = git("log", "--format=%s", base, "-500")
    safe = []
    keep = []
    for b in blocks:
        head = b["head"]
        path = b["path"]
        branch_name = (b["branch"] or "").rsplit("/", 1)[-1]
        # 1) The base-branch checkout (branch == base OR HEAD == base tip) is
        #    always KEEP.
        if branch_name == base or head == base_head:
            verdict, reason = "KEEP", "base-branch checkout"
            print(f"  {verdict:14} {reason:32} {path}")
            keep.append(path)
            continue
        # 2) HEAD is an ancestor of base => fully merged, safe to prune.
        anc = subprocess.run(
            ["git", "merge-base", "--is-ancestor", head, base], capture_output=True
        ).returncode == 0
        if anc:
            verdict, reason = "MERGED", "HEAD is an ancestor of base"
        # 3) A named branch: safe only if its tip commit subject is on base
        #    (squash-merged — the branch ref still holds the commit).
        elif b["branch"]:
            subj = git("log", "--format=%s", "-1", head)
            on_base = subj in base_log
            verdict, reason = (
                "SQUASH-MERGED", "named branch, subject on base"
            ) if on_base else ("KEEP", f"named branch not on base: {b['branch']}")
        # 4) Detached head not on base => may hold the only reachable copy.
        else:
            verdict, reason = "KEEP", "detached head not on base (unreachable commit?)"
        line = f"  {verdict:14} {reason:32} {path}"
        print(line)
        if verdict in ("MERGED", "SQUASH-MERGED"):
            safe.append(path)
        else:
            keep.append(path)

    print()
    if safe:
        print("Safe to prune (work preserved by branch refs). Use `git worktree remove --force <path>`,")
        print("or `sudo rm -rf <path> && git worktree prune` when build artifacts block it:")
        for p in safe:
            print(f"  {p}")
    else:
        print("Nothing safe to prune right now.")
    if keep:
        print()
        print("KEPT (do NOT prune — base checkout or unreachable commit):")
        for p in keep:
            print(f"  {p}")


if __name__ == "__main__":
    main()
