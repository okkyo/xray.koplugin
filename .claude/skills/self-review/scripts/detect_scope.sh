#!/usr/bin/env bash
#
# detect_scope.sh — Report the review scope for the X-Ray plugin repo.
#
# Emits ONE JSON object to stdout; progress/errors go to stderr.
# A non-empty "error" field means: stop and report it.
#
# Usage:
#   detect_scope.sh                     # auto-detect base branch
#   detect_scope.sh --base-ref main     # force a base branch
#
# Output fields:
#   branch            current branch name
#   base_branch       branch the committed range is compared against
#   uncommitted_count number of tracked files with staged+unstaged changes
#   commits_ahead     commits on this branch not on base_branch
#   suggested_scope   "uncommitted" | "committed" | "nothing"
#   files[]           {status, path} for the SUGGESTED scope only
#
# Scope logic:
#   - Any uncommitted change  -> "uncommitted" (files = working-tree changes)
#   - Else commits ahead of base -> "committed" (files = branch vs base)
#   - Else -> "nothing"
set -euo pipefail

BASE_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base-ref) BASE_REF="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

emit_error() { printf '{"error":%s}\n' "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"; exit 1; }

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit_error "not a git repository"
fi

BRANCH="$(git branch --show-current 2>/dev/null || echo 'DETACHED')"

# Resolve the base branch: explicit flag, else first existing of main/master/trunk.
if [ -z "$BASE_REF" ]; then
  for cand in main master trunk; do
    if git show-ref --verify --quiet "refs/heads/$cand"; then BASE_REF="$cand"; break; fi
  done
  [ -z "$BASE_REF" ] && BASE_REF="main"
fi

# Uncommitted = tracked files changed in working tree or index (exclude untracked noise).
UNCOMMITTED_COUNT="$(git diff --name-only HEAD 2>/dev/null | grep -c . || true)"
UNCOMMITTED_COUNT="${UNCOMMITTED_COUNT:-0}"

# Commits ahead of base (0 when on base itself or base missing).
COMMITS_AHEAD=0
if [ "$BRANCH" != "$BASE_REF" ] && git rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1; then
  COMMITS_AHEAD="$(git rev-list --count "$BASE_REF..HEAD" 2>/dev/null || echo 0)"
fi

if [ "$UNCOMMITTED_COUNT" -gt 0 ]; then
  SCOPE="uncommitted"
  RAW_FILES="$(git diff --name-status HEAD 2>/dev/null || true)"
elif [ "$COMMITS_AHEAD" -gt 0 ]; then
  SCOPE="committed"
  RAW_FILES="$(git diff --name-status "$BASE_REF...HEAD" 2>/dev/null || true)"
else
  SCOPE="nothing"
  RAW_FILES=""
fi

BRANCH="$BRANCH" BASE_REF="$BASE_REF" SCOPE="$SCOPE" \
UNCOMMITTED_COUNT="$UNCOMMITTED_COUNT" COMMITS_AHEAD="$COMMITS_AHEAD" \
RAW_FILES="$RAW_FILES" python3 <<'PY'
import json, os
raw = os.environ.get("RAW_FILES", "")
files = []
for line in raw.splitlines():
    line = line.strip()
    if not line:
        continue
    parts = line.split("\t")
    status = parts[0][:1]           # first char: M/A/D/R
    path = parts[-1]                # renames: take the new path
    files.append({"status": status, "path": path})
print(json.dumps({
    "error": "",
    "branch": os.environ["BRANCH"],
    "base_branch": os.environ["BASE_REF"],
    "uncommitted_count": int(os.environ["UNCOMMITTED_COUNT"]),
    "commits_ahead": int(os.environ["COMMITS_AHEAD"]),
    "suggested_scope": os.environ["SCOPE"],
    "files": files,
}))
PY
