#!/usr/bin/env python3
"""Canonical language names for the .po `Language-Team` headers.

The names live in the LANGUAGE_NAMES tables in xray.koplugin/xray_ui.lua, which
is what the reader shows in its language menu. Read them from there instead of
keeping a fourth copy in the tools: a separate table drifts, and .agents/rules/
localization.md already lists three places a new language must be registered.

Do not take the name from the .po header. The header is what the tools write,
so a bad value there survives every later sync -- that is how every file came
to say "Language-Team: Ar" instead of the real name.
"""

import os
import re

UI_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    '..', 'xray.koplugin', 'xray_ui.lua')

# `local LANGUAGE_NAMES = {` up to its closing brace. xray_ui.lua holds two
# identical copies; the first one is enough.
_TABLE_RE = re.compile(r'local LANGUAGE_NAMES\s*=\s*\{(.*?)\n\s*\}', re.DOTALL)
_ENTRY_RE = re.compile(r'([\w]+)\s*=\s*"([^"\\]*)"')

_cache = None


def language_names():
    """Return {lang_code: display_name}. Empty when the table cannot be read."""
    global _cache
    if _cache is not None:
        return _cache
    names = {}
    try:
        with open(UI_FILE, 'r', encoding='utf-8') as f:
            block = _TABLE_RE.search(f.read())
        if block:
            for m in _ENTRY_RE.finditer(block.group(1)):
                names[m.group(1)] = m.group(2)
    except OSError:
        pass
    _cache = names
    return names


def language_name(lang_code, fallback=None):
    """Name for one language code.

    Falls back to the caller's value, then to the code with its first letter
    capitalized -- the old behaviour, kept so a new language still gets a name
    before somebody adds it to xray_ui.lua.
    """
    name = language_names().get(lang_code)
    if name:
        return name
    if fallback:
        return fallback
    return lang_code.capitalize()


if __name__ == '__main__':
    found = language_names()
    print(f'{len(found)} language name(s) read from xray_ui.lua:')
    for code in sorted(found):
        print(f'  {code:6} {found[code]}')
