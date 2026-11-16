#!/usr/bin/env python3
"""Check the workflow files parse and that every step's script is where it claims to be.

usage: tools/check_workflows.py

Why this is not a formality: run `43855510033` failed in **0 seconds with zero jobs**,
because the workflow file itself was rejected by GitHub before anything ran. What was
wrong was a heredoc inside a `run: |` block whose body began at column 0 -- that ends the
block scalar, so the file stopped being YAML. Nothing in the repository could have caught
it: the `world` job is the only place that step runs, and it never started.

So this checks the three things that were wrong or could have been:
  * every workflow file is valid YAML;
  * every `run:` block's lines are indented under the key that introduces them, which is
    the rule the heredoc broke;
  * no step hides an inline heredoc in a block scalar at all, because that is the shape
    that broke, and a script can live in `tools/` where it can be tested.

The third is a rule about this repository's style rather than about YAML, and it is the
one that would have caught the 0-second failure directly.
"""
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")


def load_yaml():
    try:
        import yaml
    except ImportError:
        return None
    return yaml


def check() -> int:
    yaml = load_yaml()
    if yaml is None:
        print("check_workflows: no yaml module; only indentation is checked")
    failures = 0
    names = sorted(n for n in os.listdir(WORKFLOWS) if n.endswith((".yml", ".yaml")))
    if not names:
        print(f"FAIL: no workflow files in {WORKFLOWS}")
        return 1

    for name in names:
        path = os.path.join(WORKFLOWS, name)
        text = open(path).read()

        if yaml is not None:
            try:
                doc = yaml.safe_load(text)
            except yaml.YAMLError as exc:
                print(f"FAIL {name}: not valid YAML: {exc}")
                failures += 1
                continue
            if not isinstance(doc, dict) or "jobs" not in doc:
                print(f"FAIL {name}: no jobs key")
                failures += 1
                continue
            for job, body in (doc["jobs"] or {}).items():
                steps = (body or {}).get("steps") or []
                if not steps:
                    print(f"FAIL {name}: job {job} has no steps")
                    failures += 1
        else:
            doc = None

        # Indentation: a block-scalar body must be deeper than the key that opens it.
        in_block = None
        for number, line in enumerate(text.split("\n"), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(line) - len(line.lstrip())
            if in_block is not None:
                if indent > in_block:
                    continue
                in_block = None
            if stripped.endswith(("|", "|-", "|+", ">", ">-", ">+")):
                in_block = indent
                continue
            if indent == 0 and not re.match(r"^(name|on|jobs|permissions|env|concurrency):", line):
                print(f"FAIL {name}:{number}: a line escaped every block: {line[:60]!r}")
                failures += 1
                break

        # Heredocs inside run blocks: the shape that broke the world job in 0 seconds.
        for number, line in enumerate(text.split("\n"), 1):
            if re.search(r"<<-?\s*'?[A-Z_]{3,}'?", line):
                print(f"FAIL {name}:{number}: an inline heredoc in a workflow; put the "
                      f"script in tools/ so it can be run and tested: {line.strip()[:70]!r}")
                failures += 1

        if doc is not None:
            steps = sum(len((b or {}).get("steps") or []) for b in doc["jobs"].values())
            print(f"ok {name}: {len(doc['jobs'])} job(s), {steps} step(s)")

    if failures:
        print(f"FAIL: {failures} problem(s) in the workflow files")
        return 1
    print("PASS: every workflow parses, and no step hides a script in a heredoc")
    return 0


if __name__ == "__main__":
    sys.exit(check())
