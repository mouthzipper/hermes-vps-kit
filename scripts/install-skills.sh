#!/usr/bin/env bash
# Fetch pstack (MIT, github.com/cursor/plugins/tree/main/pstack) and the official herdr skill,
# then install into ~/.claude/skills, ~/.hermes/skills and every Hermes profile's skills dir.
# Bump these SHAs after reviewing upstream diffs; do not use floating branches.
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
PSTACK_REF="${PSTACK_REF:-ae5650febf4320793844c12c4adaa937f417f8da}"
HERDR_SKILL_REF="${HERDR_SKILL_REF:-ee5bfb5041bb3e4a49d591c72308aae3c81ecdde}"
[[ "$PSTACK_REF" =~ ^[0-9a-f]{40}$ && "$HERDR_SKILL_REF" =~ ^[0-9a-f]{40}$ ]] || { echo "Skill refs must be full commit SHAs" >&2; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

git init -q "$WORK/plugins"
git -C "$WORK/plugins" remote add origin https://github.com/cursor/plugins
git -C "$WORK/plugins" fetch -q --depth 1 --filter=blob:none origin "$PSTACK_REF"
git -C "$WORK/plugins" sparse-checkout init --cone
git -C "$WORK/plugins" checkout -q --detach FETCH_HEAD
git -C "$WORK/plugins" sparse-checkout set pstack/skills
SRC="$WORK/plugins/pstack/skills"

HERDR_SKILL="$WORK/herdr/SKILL.md"; mkdir -p "$(dirname "$HERDR_SKILL")"
curl -fsSL "https://raw.githubusercontent.com/herdrdev/herdr/$HERDR_SKILL_REF/skills/herdr/SKILL.md" -o "$HERDR_SKILL"

targets=("$HOME/.claude/skills" "$HOME/.hermes/skills/pstack")
for p in "$HOME"/.hermes/profiles/*/; do [[ -d "$p" ]] && targets+=("${p}skills/pstack"); done
for t in "${targets[@]}"; do mkdir -p "$t"; cp -r "$SRC"/. "$t"/; done

htargets=("$HOME/.claude/skills/herdr" "$HOME/.hermes/skills/herdr")
for p in "$HOME"/.hermes/profiles/*/; do [[ -d "$p" ]] && htargets+=("${p}skills/herdr"); done
for t in "${htargets[@]}"; do mkdir -p "$t"; cp "$HERDR_SKILL" "$t/SKILL.md"; done
echo "skills installed: pstack ($(find "$SRC" -mindepth 1 -maxdepth 1 -type d | wc -l) skills) + herdr"
