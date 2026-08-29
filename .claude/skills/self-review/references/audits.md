# X-Ray Self-Review — Audit Catalog

You are the fresh-context reviewer. Run every audit below as its own pass over
the diff and the changed files. Read a changed file IN FULL whenever a judgment
turns on what the code *does*, not just what a hunk shows — reads are cheap
relative to a missed regression on a device the author cannot easily test on.

## Grounding rules (read first)

- **Flag only what THIS diff introduces or makes newly reachable.** Do not flag
  pre-existing patterns the change merely sits beside, and do not nitpick style
  that matches the surrounding file. Per-file consistency outranks the abstract
  rule. The one exception is a real secret leak or a crash path — flag those even
  when siblings do the same.
- **Severity is the reachable consequence, not a preference.**
  - `CRITICAL` — data loss, a secret leak, or a guaranteed crash on the target device.
  - `HIGH` — a real bug, regression, or security hole with a traceable path.
  - `MEDIUM` — a likely-wrong behavior or a real performance cost on slow e-ink.
  - `LOW` — a minor correctness or clarity issue.
  - `NIT` — pure preference; report in its own non-blocking group.
  A finding must name a concrete consequence to rank MEDIUM or above. "I could
  not think of a consequence" is not evidence there is none — but do not invent one.
- **Every finding cites `file:line`** and gives a concrete fix.

## Reading the automated-check results

The check script already ran syntax, tests, and the i18n audit. Fold its results
into your findings, but judge them:

- **A `busted` failure is a regression ONLY if this diff caused it.** Two specs
  are known to fail under stock LuaJIT and are NOT regressions:
  `xray_crypto_spec.lua` (SHA-256/HMAC) and the FFI-fallback case in
  `xray_aihelper_spec.lua`. CLAUDE.md says to verify those against
  `tools/spec_runner.lua` under KOReader's LuaJIT before treating them as real.
  If the diff did not touch crypto or FFI code, note them as pre-existing and move on.
- **The i18n audit reports repo-wide drift**, including languages this diff never
  touched. Flag only the mismatch your change introduced (a new key without a
  placeholder-matched translation, or a prompt edit that changed placeholders).

---

## Audit 1 — Correctness & Regression

Trace every behavior change to its callers and the specs that guard it.

- What existing callers reach the changed function? Does the change alter a
  return shape, a side effect, or an error path they depend on?
- Does new logic have a spec in `spec/`? New logic without a test is a MEDIUM
  finding — reuse the KOReader mocks in `spec/spec_helper.lua` (device, screen,
  `lfs`, docsettings) rather than inventing new ones.
- Nil-safety: KOReader Lua fails loudly on `nil` indexing. Guard optional fields.

## Audit 2 — E-ink Performance & Cancellability

The reference device is a **2012 Kindle Paperwhite 1** — slow CPU, slow e-ink.

- **Gate heavy work by power class.** Expensive scans/loops must check
  `xray_utils` power-class helpers before running, and prefer cached/offline
  paths. Ungated full-book work on a low-power device is a HIGH finding.
- **Long work must stay cancellable** across suspend and timeout. A new
  blocking loop with no cancellation hook is a real defect here, not a nit.
- Avoid re-scanning or re-parsing the book when a cached result exists
  (`xray_cachemanager` is offline-first). Redundant AI calls cost the user money.

## Audit 3 — Security & Secrets

- **API keys never reach a log or the git tree.** `xray_config.lua` is
  git-ignored; keys also live in `<settings_dir>/xray/config_backup.json`. A new
  log line, error message, or request that could echo a key is CRITICAL.
- Keys go only to the provider the user configured — never to an unrelated host,
  header, or URL. The Cloudflare relay is zero-knowledge by design
  (`xray_crypto.lua`, AES-256-GCM, secret in the URL hash only). Do not add a
  code path that would send plaintext keys through the relay.
- Validate/sanitize anything parsed from an AI response before it drives control
  flow or file paths.

## Audit 4 — Simplification

Every line that could be deleted, deduplicated, or made plainer. Dead branches,
copy-pasted blocks that want a helper, over-clever Lua. Keep it to real wins —
match the surrounding style, do not rewrite for taste.

## Audit 5 — KOReader Plugin Idioms

- New modules must follow the `plugin_path` pattern
  (`((...) or ""):match(...)`) at the top and be addressed relative to the plugin
  path. `main.lua` lazy-`require`s modules on demand and passes the plugin
  instance in — keep that idiom; do not add top-level requires to `main.lua`.

## Audit 6 — UI Style Guide *(only when a UI file changed, e.g. `xray_ui.lua`, `xray_settings_card.lua`, unit scanner UI)*

Read `.agents/rules/style_guide.md` and check the change against it. The ones
that bite most often:

- **No raw emoji** in headers/buttons — e-ink renders them inconsistently. Use
  KOReader/Feather icons or text.
- **No spaces around slashes** in copy: `Fetch/Refresh`, `Phone/PC` — never
  `Fetch / Refresh`.
- **`icon = false` on every `ConfirmBox:new{}`** to block theme-injected icons.
- Double-border card nesting (outer `sc(1)`, inner `sc(2)`) and `sc()`-scaled
  tokens from `xray_theme` — no hardcoded pixel sizes.
- Option labels use `TextBoxWidget` (wraps) with a width that leaves room for the
  selection dot; groups of >3 options split into stacked rows.
- Full-width tap hit-testing via a custom `GestureRange` on option rows.

Flag only deviations this diff introduces.

## Audit 7 — Localization Consistency *(only when `:t()` keys or `prompts/*.lua` changed)*

Read `.agents/rules/localization.md`.

- **Added or removed a `:t("key")`?** `tools/sync_translations.py` must have been
  run so `en.po` (master) and the other `.po` files carry the key. A new key
  missing from `en.po` is a HIGH finding — the string will render as the raw key.
- **Edited a prompt in `prompts/en.lua`?** Variable placeholders (`%s`, `%d`,
  `%%`) and JSON keys must stay identical across every language file, or response
  parsing crashes. A placeholder the diff changed in `en.lua` but not the others
  is HIGH.
- **Added a language?** It must be registered in three tables — two
  `LANGUAGE_NAMES` tables in `xray_ui.lua` and the `supported` table in
  `xray_aihelper.lua`.

---

## Report format

Group findings by audit. One entry per finding:

```
[SEVERITY] <audit> | <file>:<line> | <short title>
<one-line description of the consequence>
Suggested fix: <concrete change, snippet if it helps>
```

Lead with CRITICAL/HIGH. Put NITs in their own group at the end. If an audit
found nothing, say so in one line — a clean pass is a real result. End with a
count line: `N findings — X critical/high, Y medium/low, Z nits`.
