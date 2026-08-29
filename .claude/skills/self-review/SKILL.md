---
name: self-review
description: "Review your own local changes to the X-Ray KOReader plugin with a cold, fresh-context read — before you commit or push. Auto-detects scope (uncommitted changes, else the current branch vs main), runs the project's real checks (luac/luaparser syntax, busted specs, translation placeholder audit), then a fresh subagent audits the diff for correctness/regression, e-ink performance and cancellability, secret leaks, KOReader plugin idioms, UI style-guide compliance, and localization key/placeholder parity — and optionally applies fixes. Stays local: prints findings, never posts to GitHub. Use this whenever the user says 'self review', 'review my changes', 'review my code', 'check my code', 'pre-commit review', or wants their in-progress Lua/plugin changes checked before submission — even if they don't name the skill or mention KOReader explicitly."
argument-hint: "[areas to focus on, or a specific concern]"
user-invocable: true
---

You are a skeptical senior reviewer reading a **stranger's** change to the X-Ray
KOReader plugin. You wrote none of it, you have no "ship it" pressure, and you
will be blamed if a regression reaches a user's e-reader — a device that is slow,
offline much of the time, and hard to debug remotely. Default to flagging, not
skipping. Your job is to find what is broken, not to reassure the author.

The scripts and reference below live under the skill directory. Resolve
`SKILL_DIR` to this skill's folder (`.claude/skills/self-review/` in the repo).

## Step 1 — Detect scope

Run the scope resolver and parse its JSON (never show it raw):

```bash
bash "$SKILL_DIR/scripts/detect_scope.sh"
```

Route on `suggested_scope`:

- **`uncommitted`** — Review the working-tree changes. Tell the user: "Reviewing
  N uncommitted file(s)." Proceed. No prompt needed.
- **`committed`** — The working tree is clean but the branch is ahead of
  `base_branch`. Tell the user you are reviewing the branch's committed changes
  (`commits_ahead` commits vs the base) and proceed.
- **`nothing`** — Tell the user there is nothing to review (on the base branch,
  clean tree) and stop.

Bind the `files[]` list — the changed files feed Steps 2–4.

## Step 2 — Generate the diff

Write the full diff for the scope to a patch file the reviewer will read:

- **`uncommitted`**: `git diff HEAD > /tmp/xray-selfreview.patch`
- **`committed`**: `git diff <base_branch>...HEAD > /tmp/xray-selfreview.patch`

## Step 3 — Run the automated checks

These are the authoritative signals — a reviewer should never catch a syntax
error or a broken spec by eye. Pass the changed `.lua` files so the syntax check
scopes to them:

```bash
bash "$SKILL_DIR/scripts/run_checks.sh" <changed .lua files from Step 1>
```

Parse the JSON. Keep the results for the reviewer — do NOT judge them yourself
yet; the audit catalog explains which failures are real regressions and which are
known stock-LuaJIT artifacts (`xray_crypto_spec`, the FFI-fallback case) or
pre-existing translation drift. If a check reports `ran:false`, its tool is
missing — that is "could not verify", not a pass; tell the user.

## Step 4 — Audit in a fresh-context subagent

A review done in the same conversation that wrote the code inherits the author's
blind spots. Always run the audit in a **fresh subagent** that reads the diff
cold — do not audit inline, regardless of how small or clean the change looks.

Spawn one subagent (Explore or general-purpose) with a prompt that embeds:

- The absolute path to `/tmp/xray-selfreview.patch` (tell it to read the patch in
  full, and to read any changed file in full when a judgment needs it).
- The changed-file list and their statuses from Step 1.
- The automated-check results from Step 3 (verbatim JSON is fine).
- The absolute path to `$SKILL_DIR/references/audits.md` — instruct it to read
  that file and run **every** audit pass it defines, in order.
- Any focus areas or specific concern from the invocation arguments.
- The instruction: **read-only** — analyze and report, never edit files, never
  run git writes, never post anywhere. Return the findings report as its final
  message.

Relay the returned report to the user **verbatim**.

## Step 5 — Present findings

Show the relayed report. Lead with CRITICAL/HIGH, then MEDIUM/LOW, then NITs in
their own group. Include the automated-check outcomes (tests passed/failed, with
the known-artifact caveat applied), and a one-line count.

If nothing was found, say so plainly — a clean review is a real outcome, and the
checks and audits all ran.

## Step 6 — Offer to fix

Use `AskUserQuestion`:

> Found X issues (Y critical/high, Z medium/low, N nits). How to proceed?
> 1. **Fix all** — every issue that can be resolved automatically, nits included.
> 2. **Fix high-severity only** — CRITICAL/HIGH and any secret-leak finding.
> 3. **One by one** — walk through each and decide.
> 4. **Don't fix** — just note them, I'll handle it.

If the user chooses to fix, **you are now the fixer, and the audit is closed**:

- Patch **only** the findings on the list. Do not hunt for new issues, refactor
  adjacent code, or "improve" anything the review did not name — mixing the two
  jobs is what turns a review into a tail-chase.
- Apply each fix with the Edit tool and say in one line what changed.
- A finding whose fix needs an architectural decision or a new dependency is
  **surfaced, not attempted** — leave it OPEN and say why.
- After fixing, **re-run the relevant checks once** for the files you touched
  (`run_checks.sh <files>`), and — if the diff touched `:t()` keys — remind the
  user to run `python3 tools/sync_translations.py`. Report what now passes vs
  what stays OPEN. Do not re-audit your own patches; that belongs to the next run.

## Step 7 — Clean up

```bash
rm -f /tmp/xray-selfreview.patch
```

End with a short summary: what was reviewed, the check outcomes, findings by
severity, what was fixed, and any follow-up the user still owes (e.g. run
`sync_translations.py`, verify a crypto spec under `spec_runner.lua`).

## Guardrails

- **Local only.** This skill never posts to GitHub, submits a review, or pushes.
  Findings stay in the terminal.
- **Fresh-context audit, always.** No inline mode, no "the change is small" exception.
- **Auditing and fixing are separate jobs, and neither loops.** One pass over the
  diff; the fixer touches only named findings; no re-audit of the fixes.
- **Flag only what the diff introduces.** Pre-existing drift, sibling-file
  patterns, and stock-LuaJIT test artifacts are context, not findings — except a
  real secret leak or crash path, which is always in scope.
