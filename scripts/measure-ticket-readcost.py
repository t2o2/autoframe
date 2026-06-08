#!/usr/bin/env python3
"""measure-ticket-readcost.py — decide whether a cross-stage ticket digest is worth building.

For each stream-json stage log it answers one question: how much of the agent's
context footprint is spent re-reading the Linear ticket + comment thread, versus
the actual work (exploration, implementation, tool results)?

Ticket-thread reads are the tool results from the calls a stage makes to load the
ticket at startup: get_issue / get-issue.sh and list_comments / list-comments.sh
(both the MCP linear-server variant and the shell-script variant are matched).

The denominator is `cache_creation_input_tokens` from the final result event —
the *unique* context the run wrote into the prompt cache (NOT cache_read, which is
just that prefix re-multiplied across turns). That makes the fraction "share of the
stage's real context footprint that is ticket re-read".

Decision rule (from the design discussion):
  < ~10-15%  -> digest is over-engineering; just read artifacts-first.
  >= ~30%    -> build the cumulative pointer-rich digest (esp. review/retro).

Usage:
  python3 measure-ticket-readcost.py <logdir> [<logdir> ...]
  python3 measure-ticket-readcost.py --glob '/path/autonomous-*-logs'
"""
import json
import os
import sys
import glob
import re
from collections import defaultdict

CHARS_PER_TOKEN = 4  # rough heuristic; fine for an order-of-magnitude decision

# tool names (MCP or shell) that load the ticket thread into context
THREAD_READ_RE = re.compile(
    r"(get[_-]?issue|list[_-]?comments|get[_-]?comments|read[_-]?ticket)", re.I
)


def est_tokens(chars: int) -> int:
    return chars // CHARS_PER_TOKEN


def result_text(block) -> str:
    c = block.get("content", "")
    if isinstance(c, list):
        return "".join(x.get("text", "") for x in c if isinstance(x, dict))
    return str(c)


def analyze_log(path: str) -> dict | None:
    names: dict[str, str] = {}            # tool_use_id -> tool name
    thread_chars = 0
    thread_calls = 0
    other_tool_chars = 0
    usage = {}
    saw_result = False

    with open(path, errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            t = e.get("type")
            if t == "assistant":
                for b in (e.get("message") or {}).get("content", []):
                    if b.get("type") == "tool_use":
                        names[b.get("id")] = b.get("name", "?")
            elif t == "user":
                for b in (e.get("message") or {}).get("content", []):
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        nm = names.get(b.get("tool_use_id"), "?")
                        n = len(result_text(b))
                        if THREAD_READ_RE.search(nm):
                            thread_chars += n
                            thread_calls += 1
                        else:
                            other_tool_chars += n
            elif t == "result":
                usage = e.get("usage") or {}
                usage["_total_cost_usd"] = e.get("total_cost_usd")
                usage["_num_turns"] = e.get("num_turns")
                saw_result = True

    if not saw_result:
        return None

    footprint = usage.get("cache_creation_input_tokens", 0) or 0
    thread_tok = est_tokens(thread_chars)
    frac = (thread_tok / footprint * 100) if footprint else 0.0
    return {
        "thread_tok": thread_tok,
        "thread_calls": thread_calls,
        "other_tool_tok": est_tokens(other_tool_chars),
        "footprint": footprint,
        "cache_read": usage.get("cache_read_input_tokens", 0) or 0,
        "output": usage.get("output_tokens", 0) or 0,
        "turns": usage.get("_num_turns"),
        "cost": usage.get("_total_cost_usd"),
        "frac": frac,
    }


def stage_of(path: str) -> str:
    m = re.search(r"autonomous-(?:agent-)?([a-z]+)?-?logs", os.path.dirname(path))
    return (m.group(1) or "process") if m else "?"


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    dirs = []
    if argv[0] == "--glob":
        dirs = glob.glob(argv[1])
    else:
        dirs = argv
    files = []
    for d in dirs:
        files += [f for f in glob.glob(os.path.join(d, "*.log"))
                  if not f.endswith("agent.log")]
    if not files:
        print("No ticket logs found in:", *dirs, sep="\n  ")
        return 1

    by_stage = defaultdict(list)
    print(f"{'stage':9} {'ticket':14} {'thread_tok':>10} {'calls':>5} "
          f"{'footprint':>10} {'frac%':>6} {'cost$':>6} {'turns':>5}")
    print("-" * 78)
    for f in sorted(files):
        r = analyze_log(f)
        if not r:
            continue
        stage = stage_of(f)
        tid = re.sub(r"-\d{8}-\d{6}\.log$", "", os.path.basename(f))
        by_stage[stage].append(r)
        cost = f"{r['cost']:.2f}" if r["cost"] is not None else "?"
        print(f"{stage:9} {tid:14} {r['thread_tok']:>10} {r['thread_calls']:>5} "
              f"{r['footprint']:>10} {r['frac']:>5.1f}% {cost:>6} "
              f"{str(r['turns']):>5}")

    print("\n=== per-stage medians ===")
    print(f"{'stage':9} {'n':>3} {'med thread_tok':>14} {'med footprint':>13} {'med frac%':>9}")
    print("-" * 52)
    for stage, rs in sorted(by_stage.items()):
        def med(key):
            xs = sorted(x[key] for x in rs)
            return xs[len(xs) // 2]
        print(f"{stage:9} {len(rs):>3} {med('thread_tok'):>14} "
              f"{med('footprint'):>13} {med('frac'):>8.1f}%")

    allr = [x for rs in by_stage.values() for x in rs]
    worst = max(allr, key=lambda x: x["frac"])
    print(f"\nworst-case thread re-read fraction: {worst['frac']:.1f}% "
          f"(thread={worst['thread_tok']} tok, footprint={worst['footprint']} tok)")
    print("decision: <10-15% -> skip digest, read artifacts-first | "
          ">=30% -> build cumulative digest")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
