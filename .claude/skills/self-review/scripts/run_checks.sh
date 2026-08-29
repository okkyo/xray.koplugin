#!/usr/bin/env bash
#
# run_checks.sh — Run the X-Ray plugin's automated checks and report results.
#
# These are the concrete, authoritative signals a reviewer must never catch by
# eye. Run them all; report each one's outcome. The skill decides severity.
#
# Emits ONE JSON object to stdout; human progress goes to stderr.
#
# Usage:
#   run_checks.sh [changed_lua_file ...]
#     - Pass the changed .lua files (from detect_scope.sh) so the syntax check
#       scopes to them. With no args, it checks the whole plugin dir.
#
# Checks (each degrades gracefully when its tool is absent):
#   syntax   — luaparser (tools/check_syntax.py) if installed, else `luac -p`.
#              luac uses stock Lua 5.1; it catches real syntax errors but may
#              warn on LuaJIT-only constructs — treat those as low-confidence.
#   tests    — `busted spec/` (the real regression signal).
#   i18n     — `tools/check_translations.py` (missing/stale .po keys) and
#              `tools/translate_all.py --audit all` (placeholder/JSON-key parity).
#
# Each check reports: {name, ran (bool), passed (bool|null), summary, detail_tail}.
# ran=false means the tool was missing — that is a "could not verify", not a pass.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"

# Collect changed .lua files passed as args (for scoped syntax check).
LUA_FILES=()
for f in "$@"; do
  case "$f" in *.lua) [ -f "$f" ] && LUA_FILES+=("$f") ;; esac
done

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
tail_lines() { tail -n 40 2>/dev/null | json_escape; }

RESULTS=()
add_result() { # name ran passed summary detail_tail_json
  RESULTS+=("{\"name\":\"$1\",\"ran\":$2,\"passed\":$3,\"summary\":$(printf '%s' "$4" | json_escape),\"detail_tail\":$5}")
}

# ---- 1. Syntax --------------------------------------------------------------
echo "[checks] syntax..." >&2
if python3 -c 'import luaparser' 2>/dev/null; then
  OUT="$(python3 tools/check_syntax.py xray.koplugin 2>&1)"; RC=$?
  TAIL="$(printf '%s' "$OUT" | tail_lines)"
  if [ $RC -eq 0 ]; then add_result "syntax" true true "luaparser: all files parse" "$TAIL"
  else add_result "syntax" true false "luaparser: syntax error(s)" "$TAIL"; fi
elif command -v luac >/dev/null 2>&1; then
  TARGETS=("${LUA_FILES[@]}")
  [ ${#TARGETS[@]} -eq 0 ] && while IFS= read -r ff; do TARGETS+=("$ff"); done < <(find xray.koplugin -maxdepth 1 -name '*.lua')
  FAILED=""
  for f in "${TARGETS[@]}"; do
    ERR="$(luac -p "$f" 2>&1)" || FAILED="${FAILED}${f}: ${ERR}\n"
  done
  if [ -z "$FAILED" ]; then add_result "syntax" true true "luac -p: ${#TARGETS[@]} file(s) OK (luaparser not installed)" '""'
  else add_result "syntax" true false "luac -p: syntax error(s) — verify under LuaJIT if construct is JIT-only" "$(printf "$FAILED" | tail_lines)"; fi
else
  add_result "syntax" false null "no luaparser and no luac — syntax not verified" '""'
fi

# ---- 2. Tests ---------------------------------------------------------------
echo "[checks] busted spec/..." >&2
if command -v busted >/dev/null 2>&1; then
  OUT="$(busted spec/ 2>&1)"; RC=$?
  TAIL="$(printf '%s' "$OUT" | tail_lines)"
  SUM="$(printf '%s' "$OUT" | grep -E '[0-9]+ success|[0-9]+ failure|[0-9]+ error' | tail -1)"
  [ -z "$SUM" ] && SUM="busted finished (rc=$RC)"
  if [ $RC -eq 0 ]; then add_result "tests" true true "$SUM" "$TAIL"
  else add_result "tests" true false "$SUM" "$TAIL"; fi
else
  add_result "tests" false null "busted not installed — tests not run" '""'
fi

# ---- 3. i18n ----------------------------------------------------------------
echo "[checks] translations..." >&2
if [ -f tools/check_translations.py ]; then
  OUT="$(python3 tools/check_translations.py 2>&1)"; RC=$?
  T1="$(printf '%s' "$OUT" | tail_lines)"
  A_OUT=""; A_RC=0
  if [ -f tools/translate_all.py ]; then
    A_OUT="$(python3 tools/translate_all.py --audit all 2>&1)"; A_RC=$?
  fi
  TAIL="$(printf '%s\n---audit---\n%s' "$OUT" "$A_OUT" | tail_lines)"
  if [ $RC -eq 0 ] && [ $A_RC -eq 0 ]; then add_result "i18n" true true "translation keys + placeholders consistent" "$TAIL"
  else add_result "i18n" true false "translation drift: missing keys or placeholder mismatch" "$TAIL"; fi
else
  add_result "i18n" false null "check_translations.py missing — i18n not verified" '""'
fi

# ---- Emit -------------------------------------------------------------------
IFS=,; printf '{"error":"","checks":[%s]}\n' "${RESULTS[*]}"
