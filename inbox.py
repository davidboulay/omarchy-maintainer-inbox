#!/usr/bin/env python3
"""Collector for the Maintainer Inbox widget.

Asks GitHub directly for every open issue and pull request on the repositories
you own, instead of relying on GitHub notifications. Notifications only exist
for repositories you are watching, with the right watch level, and an item
marked read anywhere (email, phone, web) disappears from them, so a
notification inbox cannot answer "is anything on my repos waiting for me?".
Search can.

An item needs you when someone other than you has been active on it (opened
it, commented, reviewed, pushed a commit) more recently than you have. Once
you reply it moves to "waiting on them" by itself; new activity from them
moves it back.

Commands, all printing one JSON object on stdout:

  collect  --state FILE [--owners a,b] [--exclude-bots]
  dismiss  --state FILE --id NODE_ID      hide until the next outside activity
  restore  --state FILE --id NODE_ID

Only the GitHub CLI's existing login is used; no token is read or stored.
"""

import argparse
import contextlib
import fcntl
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time



def find_gh():
    """gh is often installed through mise, whose shims are not on the shell's
    PATH when Hyprland starts it, so look in the usual places too."""
    found = shutil.which("gh")
    if found:
        return found
    home = os.path.expanduser("~")
    candidates = ["/usr/bin/gh", "/usr/local/bin/gh",
                  home + "/.local/bin/gh",
                  home + "/.local/share/mise/shims/gh"]
    candidates += sorted(glob.glob(home + "/.local/share/mise/installs/gh/*/*/bin/gh"), reverse=True)
    for c in candidates:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None


GH = find_gh()
GH_TIMEOUT = 25
MAX_PAGES = 5          # 500 open items is far past what one maintainer can triage
LOGIN_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
TRANSIENT_RE = re.compile(r"timeout|unexpected EOF|connection reset|connection refused|no such host|temporarily|502|503|504", re.IGNORECASE)
REPO_RE = re.compile(r"^[A-Za-z0-9._-]{1,100}$")

QUERY = """
query($q: String!, $cursor: String) {
  viewer { login }
  search(type: ISSUE, query: $q, first: 100, after: $cursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      __typename
      ... on Issue {
        id number title url createdAt
        repository { nameWithOwner }
        author { __typename login }
        comments(last: 30) { nodes { author { __typename login } createdAt } }
      }
      ... on PullRequest {
        id number title url createdAt isDraft
        repository { nameWithOwner }
        author { __typename login }
        comments(last: 30) { nodes { author { __typename login } createdAt } }
        reviews(last: 30) { nodes { author { __typename login } submittedAt } }
        commits(last: 1) { nodes { commit { committedDate author { user { login } } } } }
      }
    }
  }
}
"""


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")))
    sys.stdout.write("\n")


def fail(message):
    emit({"ok": False, "error": message})
    sys.exit(0)


# ------------------------------------------------------------------ state


@contextlib.contextmanager
def locked_state(path):
    """Read-modify-write the state file under an exclusive lock.

    collect and dismiss can overlap (a click while a refresh runs); without the
    lock the slower writer would drop the other's change."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                state = json.load(f)
            if not isinstance(state, dict):
                state = {}
        except (OSError, ValueError):
            state = {}
        state.setdefault("seen", {})
        state.setdefault("dismissed", {})
        state.setdefault("muted", {})
        yield state
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".state-")
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, indent=1, sort_keys=True)
        os.replace(tmp, path)


# ------------------------------------------------------------------ GitHub


def viewer_login():
    return gh_graphql(None, None, "query { viewer { login } }")["viewer"]["login"]


def gh_graphql(q, cursor, query=QUERY):
    if not GH:
        fail("GitHub CLI (gh) is not installed")
    cmd = [GH, "api", "graphql", "-f", "query=" + query]
    if q is not None:
        cmd += ["-f", "q=" + q]
    if cursor:
        cmd += ["-f", "cursor=" + cursor]
    # One retry: a single dropped TLS handshake on a weak connection (phone
    # hotspot, hotel Wi-Fi) should not fail the whole check.
    for attempt in (1, 2):
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=GH_TIMEOUT)
        except FileNotFoundError:
            fail("GitHub CLI (gh) is not installed")
        except subprocess.TimeoutExpired:
            if attempt == 2:
                fail("GitHub did not answer within %ds" % GH_TIMEOUT)
            continue
        if proc.returncode == 0 or attempt == 2 or not TRANSIENT_RE.search(proc.stderr or ""):
            break
        time.sleep(3)
    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout).strip().splitlines()
        msg = err[-1] if err else "gh exited %d" % proc.returncode
        if "auth login" in msg or "not logged" in msg.lower():
            msg = "gh is not logged in: run gh auth login"
        fail(msg[:300])
    try:
        data = json.loads(proc.stdout)
    except ValueError:
        fail("gh returned something that is not JSON")
    if data.get("errors") and not data.get("data"):
        fail(str(data["errors"][0].get("message", "GraphQL error"))[:300])
    return data["data"]


BOT_LOGIN_RE = re.compile(r"(\[bot\]|[-_]?bot|-apps)$", re.IGNORECASE)


def is_bot(author):
    """GitHub Apps are typed Bot; plenty of bots are plain user accounts named
    like one (omarchybot, greptile-apps), so the name counts too."""
    if not author:
        return False
    return author.get("__typename") == "Bot" or bool(BOT_LOGIN_RE.search(str(author.get("login", ""))))


def activity(node, me):
    """Latest outside activity and latest activity of mine, as ISO strings.

    ISO-8601 UTC timestamps from GitHub compare correctly as strings."""
    me = me.lower()
    other = (None, None)
    mine = None

    def note(login, at):
        nonlocal other, mine
        if not at:
            return
        login = login or "ghost"
        if login.lower() == me:
            if mine is None or at > mine:
                mine = at
        elif other[0] is None or at > other[0]:
            other = (at, login)

    # Opening the item always counts, even by a bot (a Dependabot PR on your
    # repo is work). Bot comments and reviews never do: CI summaries and AI
    # reviewers are not someone waiting for an answer.
    note((node.get("author") or {}).get("login"), node.get("createdAt"))
    for c in (node.get("comments") or {}).get("nodes") or []:
        if not is_bot(c.get("author")):
            note((c.get("author") or {}).get("login"), c.get("createdAt"))
    for r in (node.get("reviews") or {}).get("nodes") or []:
        if not is_bot(r.get("author")):
            note((r.get("author") or {}).get("login"), r.get("submittedAt"))
    for c in (node.get("commits") or {}).get("nodes") or []:
        commit = c.get("commit") or {}
        user = ((commit.get("author") or {}).get("user") or {}).get("login")
        # A commit with no linked GitHub user is someone else's push; a bot's
        # (rebases, formatting) is not.
        if not is_bot({"login": user or ""}):
            note(user or "unknown", commit.get("committedDate"))
    return other[0], other[1], mine


def build_item(node, me):
    other_at, other_by, mine_at = activity(node, me)
    if other_at is None:
        return None   # only my own activity: nothing to answer
    author = node.get("author") or {}
    return {
        "id": node["id"],
        "kind": "pr" if node["__typename"] == "PullRequest" else "issue",
        "repo": node["repository"]["nameWithOwner"],
        "number": node["number"],
        "title": node["title"],
        "url": node["url"],
        "author": author.get("login") or "ghost",
        "bot": is_bot(author),
        "draft": bool(node.get("isDraft")),
        "createdAt": node["createdAt"],
        "lastOtherAt": other_at,
        "lastOtherBy": other_by,
        "lastMineAt": mine_at,
    }


def classify(item, state):
    if item["id"] in state["muted"]:
        return "muted"
    if item["lastMineAt"] and item["lastMineAt"] >= item["lastOtherAt"]:
        return "waiting"
    d = state["dismissed"].get(item["id"])
    if d and d >= item["lastOtherAt"]:
        return "dismissed"
    return "needs"


def search_all(q):
    nodes, cursor, total = [], None, 0
    for _ in range(MAX_PAGES):
        search = gh_graphql(q, cursor)["search"]
        total = search["issueCount"]
        nodes += [n for n in search["nodes"] if n and n.get("id")]
        if not search["pageInfo"]["hasNextPage"]:
            break
        cursor = search["pageInfo"]["endCursor"]
    return nodes, total > len(nodes)


def parse_watch(raw):
    """Extra entries: an owner ("lojel") watches all of its repositories,
    owner/name ("lojel/lojel-wp") just that one."""
    owners, repos = [], []
    for entry in (raw or "").split(","):
        entry = entry.strip().strip("/")
        if not entry:
            continue
        parts = entry.split("/")
        if len(parts) == 1 and LOGIN_RE.match(parts[0]):
            owners.append(parts[0])
        elif len(parts) == 2 and LOGIN_RE.match(parts[0]) and REPO_RE.match(parts[1]):
            repos.append(entry)
        else:
            fail("not an owner or owner/repo: %r" % entry)
    return owners, repos


def collect(args):
    owners, repos = parse_watch(args.owners)
    me = viewer_login()
    if me.lower() not in [o.lower() for o in owners]:
        owners = [me] + owners

    # Qualifiers of one kind are OR-ed, but user: and repo: together are not,
    # so owners and single repositories are separate searches.
    base = "is:open archived:false "
    owned, truncated = search_all(base + " ".join("user:" + o for o in owners))
    if repos:
        more, t = search_all(base + " ".join("repo:" + r for r in repos))
        owned += more
        truncated = truncated or t
    participating = []
    if args.participating:
        # Conversations elsewhere: anything you opened, commented on, were
        # mentioned or assigned in.
        participating, t = search_all(base + "involves:" + me)
        truncated = truncated or t

    items, ids = [], set()
    for source, nodes in (("owned", owned), ("participating", participating)):
        for n in nodes:
            if n["id"] in ids:
                continue
            ids.add(n["id"])
            item = build_item(n, me)
            if item is None:
                continue
            if source == "owned" and args.exclude_bots and item["bot"]:
                continue
            item["source"] = source
            items.append(item)

    with locked_state(args.state) as state:
        state.setdefault("muted", {})
        fresh = []
        for item in items:
            item["state"] = classify(item, state)
            seen = state["seen"].get(item["id"])
            if item["state"] == "needs" and (seen is None or item["lastOtherAt"] > seen):
                fresh.append(item["id"])
            state["seen"][item["id"]] = item["lastOtherAt"]
        # Forget closed items so state cannot grow without bound. With
        # conversations switched off their mutes are kept, not lost.
        for key in ("seen", "dismissed", "muted"):
            if key == "muted" and not args.participating:
                continue
            state[key] = {k: v for k, v in state[key].items() if k in ids}
        state["lastSuccess"] = int(time.time())

    items.sort(key=lambda i: i["lastOtherAt"], reverse=True)
    emit({
        "ok": True,
        "viewer": me,
        "owners": owners,
        "repos": repos,
        "generatedAt": int(time.time()),
        "truncated": truncated,
        "items": items,
        "fresh": fresh,
    })


def set_flag(args, key, on):
    with locked_state(args.state) as state:
        state.setdefault("muted", {})
        if not on:
            state[key].pop(args.id, None)
        elif key == "dismissed":
            # Dismiss up to "now", so only activity after this moment brings it back.
            state[key][args.id] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        else:
            state[key][args.id] = True
    emit({"ok": True})


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("collect")
    c.add_argument("--state", required=True)
    c.add_argument("--owners", default="")
    c.add_argument("--exclude-bots", action="store_true")
    c.add_argument("--participating", action="store_true")
    for name in ("dismiss", "restore", "mute", "unmute"):
        d = sub.add_parser(name)
        d.add_argument("--state", required=True)
        d.add_argument("--id", required=True)
    args = p.parse_args()
    if args.cmd == "collect":
        collect(args)
    elif args.cmd in ("dismiss", "restore"):
        set_flag(args, "dismissed", args.cmd == "dismiss")
    else:
        set_flag(args, "muted", args.cmd == "mute")


if __name__ == "__main__":
    main()
