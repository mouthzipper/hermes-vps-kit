#!/usr/bin/env python3
"""Block local build commands for the automated PR reviewer."""

import json
import os
import re
import sys

if os.environ.get("PR_REVIEWER_NO_BUILD") != "1":
    raise SystemExit(0)

raw = os.environ.get("CLAUDE_TOOL_INPUT", "")
try:
    payload = json.loads(raw) if raw else {}
except json.JSONDecodeError:
    payload = {}

command = str(payload.get("command", ""))
pattern = re.compile(
    r"(?:^|[;&|]\s*|\n)\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+|export\s+[^\n;]+\n\s*)*"
    r"(?:npx\s+(?:--yes\s+)?|npm\s+exec\s+)?"
    r"(?:bun|bunx|npm|pnpm|yarn|vite|next|nuxt|turbo|make)\b[^\n;&|]*\bbuild\b",
    re.IGNORECASE,
)

if pattern.search(command):
    print("Blocked: the PR-reviewer policy forbids local build commands. Use GitHub checks for build evidence.", file=sys.stderr)
    raise SystemExit(2)

raise SystemExit(0)
