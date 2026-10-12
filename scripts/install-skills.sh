#!/usr/bin/env bash
# Fetch pstack (MIT, github.com/cursor/plugins/tree/main/pstack) and the official herdr skill,
# then install into ~/.claude/skills, ~/.hermes/skills and every Hermes profile's skills dir.
# Not vendored: pstack is ~1.2 MB and upstream-maintained. Pin with PSTACK_REF (default: main).
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
PSTACK_REF="${PSTACK_REF:-main}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

git clone -q --depth 1 --filter=blob:none --sparse -b "$PSTACK_REF" https://github.com/cursor/plugins "$WORK/plugins"
git -C "$WORK/plugins" sparse-checkout set pstack/skills
SRC="$WORK/plugins/pstack/skills"

HERDR_SKILL="$WORK/herdr/SKILL.md"; mkdir -p "$(dirname "$HERDR_SKILL")"
if command -v herdr >/dev/null; then herdr --skill > "$HERDR_SKILL"
else curl -fsSL https://raw.githubusercontent.com/herdrdev/herdr/master/skills/herdr/SKILL.md -o "$HERDR_SKILL"; fi

targets=("$HOME/.claude/skills" "$HOME/.hermes/skills/pstack")
for p in "$HOME"/.hermes/profiles/*/; do [[ -d "$p" ]] && targets+=("${p}skills/pstack"); done
for t in "${targets[@]}"; do mkdir -p "$t"; cp -r "$SRC"/. "$t"/; done

htargets=("$HOME/.claude/skills/herdr" "$HOME/.hermes/skills/herdr")
for p in "$HOME"/.hermes/profiles/*/; do [[ -d "$p" ]] && htargets+=("${p}skills/herdr"); done
for t in "${htargets[@]}"; do mkdir -p "$t"; cp "$HERDR_SKILL" "$t/SKILL.md"; done
echo "skills installed: pstack ($(ls "$SRC" | wc -l) skills) + herdr"
