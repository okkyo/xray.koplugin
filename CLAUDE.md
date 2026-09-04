# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A KOReader plugin (pure Lua) that adds Kindle-style "X-Ray" features to the
e-reader: AI-tracked characters, plot timelines, glossary, mention scanning, and
in-text lookups. The AI calls go to Gemini, OpenAI, DeepSeek, Claude, or any
custom OpenAI/Anthropic-compatible endpoint.

Only the `xray.koplugin/` directory ships. It is zipped and installed into
KOReader's `plugins/` folder. Everything else (`spec/`, `tools/`,
`cloudflare-worker/`) is development or infrastructure support.

## Environment note

The plugin author develops on **Windows + PowerShell + WSL**, so `.agents/rules/`
and `tools/wsl_test.ps1` assume that. This checkout runs on **Linux**, where the
tests run directly with `busted` (see below). Do not blindly copy PowerShell
commands from the rule files — adapt them.

## Commands

Run tests (Linux, this machine):
```bash
busted spec/                         # whole suite
busted spec/xray_utils_spec.lua      # one file
busted spec/ --filter "low power"    # one test by name
```

Note: the **canonical** runner is `tools/spec_runner.lua` executed under
KOReader's bundled LuaJIT (it needs `SQUASHFS_ROOT` pointing at a KOReader
install). Plain `busted` passes for almost everything, but a few specs
(e.g. `xray_crypto_spec.lua`) depend on KOReader's runtime and can differ under
stock LuaJIT. If a crypto/bit-operation test fails only under `busted`, verify
against `spec_runner.lua` before treating it as a real regression.

Check Lua syntax (needs the `luaparser` Python package):
```bash
python3 tools/check_syntax.py xray.koplugin
```

Bump version + build the release zip locally:
```bash
python3 tools/release.py 26.8.30-beta   # rewrites version in _meta.lua
```
Pushing any git tag triggers `.github/workflows/release.yml`, which copies the
example config to a blank `xray_config.lua`, zips `xray.koplugin/`, and creates a
draft GitHub release (tags containing `-beta` are marked prerelease).

## Config and secrets

`xray.koplugin/xray_config.lua` holds the user's API keys and is **git-ignored**.
A fresh checkout has none. Copy `xray_config.example.lua` to `xray_config.lua` if
a module fails to load complaining about the missing config. Never commit real
keys. At runtime, keys are also backed up to
`<settings_dir>/xray/config_backup.json` and restored after updates overwrite the
Lua file.

## Architecture

`main.lua` is the plugin entry point (a KOReader `WidgetContainer`). It lazy-`require`s
the other modules on demand rather than at the top, passing the plugin instance
into them. Modules are addressed relative to the plugin path — see the
`plugin_path` pattern (`((...) or ""):match(...)`) at the top of most files; keep
that idiom when adding modules.

Rough responsibilities:

- **`main.lua`** — lifecycle, menu wiring, event hooks, gesture registration.
- **`xray_aihelper.lua`** — talks to every AI provider; builds requests, parses
  responses, handles cancellation across suspend/timeout. Largest logic file.
- **`xray_fetch.lua`** — orchestrates fetching X-Ray data (full-book scan,
  background auto-fetch, inline/partial-match "fetch more" enrichment).
- **`xray_data.lua`** — parses and normalizes the AI's structured output into the
  stored data model.
- **`xray_cachemanager.lua`** — persists per-book X-Ray data to the book's `.sdr`
  sidecar directory; offline-first reads.
- **`xray_ui.lua`** — all menus, cards, and popups (largest file overall). Follow
  `.agents/rules/style_guide.md` religiously for any UI change.
- **`xray_settings_card.lua`, `xray_theme.lua`** — reusable settings-card widget
  and the design tokens (`sc()`, borders, colors) the style guide references.
- **`xray_chapteranalyzer.lua`** — maps characters/events to the current
  chapter/page; drives spoiler-free ("read up to current page only") logic.
- **`xray_mentions.lua`** — finds every occurrence of an entity in the book with
  page numbers and context snippets.
- **`xray_lookupmanager.lua`** — text-selection/dictionary lookups, confidence
  scoring, re-lookup prompts (`LOW_CONFIDENCE_THRESHOLD`).
- **`xray_seriesmanager.lua`** — series-level recap across multiple books.
- **`xray_units.lua` / `xray_unitscanner.lua`** — unit detection and conversion;
  scanner also does page underline rendering and tooltip UI.
- **`xray_websetup.lua` + `cloudflare-worker/`** — the phone/PC quick-setup flow.
  The Cloudflare Worker is a zero-knowledge relay: keys are AES-256-GCM encrypted
  in the browser, the secret lives only in the URL hash, so the relay never sees
  plaintext. `xray_crypto.lua` is the reader-side crypto (pure-Lua with optional
  OpenSSL FFI).
- **`xray_updater.lua`** — weekly silent OTA check against GitHub Releases.
- **`xray_logger.lua` / `xray_utils.lua`** — rotating log (512KB cap) and shared
  helpers, including device power-class detection that gates expensive operations.

### Localization is a two-part system

1. **UI strings**: `self.loc:t("key")` in Lua, backed by `languages/*.po`.
   `en.po` is the master. After adding/removing any `:t("...")` key you MUST run
   `python tools/sync_translations.py` to propagate keys to all languages.
   `tools/check_translations.py` gates this in CI/the workflow.
2. **AI prompts**: `prompts/*.lua`, one file per language. Edit `en.lua` first,
   then sync/translate/audit with `tools/translate_all.py`. Variable
   placeholders (`%s`, `%d`, `%%`) and JSON keys must stay **identical** across
   all languages or the AI response parsing crashes.

Registering a new language touches three tables — two `LANGUAGE_NAMES` tables in
`xray_ui.lua` and a `supported` table in `xray_aihelper.lua`. See
`.agents/rules/localization.md` for the exact steps.

## Conventions that bite if ignored

- **Target hardware is slow e-ink.** The reference device is a 2012 Kindle
  Paperwhite 1. Use `xray_utils` power-class checks to gate heavy work; prefer
  cached/offline paths. Long-running work must be cancellable.
- **UI must follow `.agents/rules/style_guide.md`** — double-border card nesting,
  `sc()`-scaled tokens from `xray_theme`, no raw emoji (e-ink renders them
  inconsistently), no spaces around slashes in copy (`Fetch/Refresh`), and
  never `icon = false` on a `ConfirmBox` (it crashes KOReader; see the style guide).
- **Add tests for new logic** in `spec/`. The `spec/spec_helper.lua` mocks the
  KOReader environment (device, screen, `lfs`, docsettings); reuse those mocks.
- **Release notes**: no emoji, end-user-friendly, not robotic — see
  `.agents/rules/release_notes.md`.

## Do not elevate privileges

`tools/install_test_deps.sh` calls `sudo`. Do not run it in this session — print
the command and let the user run it. (See the global sudo policy.)
