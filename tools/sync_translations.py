#!/usr/bin/env python3
import os
import re
import sys
import json
import urllib.request
import time
import hashlib

# Configuration
if sys.version_info >= (3, 7):
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except Exception:
        pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from env_loader import load_env_file
from lang_names import language_name

# Read GEMINI_API_KEY (and anything else) from a .env file at the repo root.
load_env_file()

LANGUAGES_DIR = os.path.join(os.path.dirname(__file__), '..', 'xray.koplugin', 'languages')
SOURCE_DIR = os.path.join(os.path.dirname(__file__), '..', 'xray.koplugin')
MASTER_LANG = 'en'

# Narrow allowlist of keys that legitimately don't need translations (symbols, paths, brand names, etc.)
ALLOWLIST = {
    'mention_dismiss_btn',     # "✕"
    'mention_return_btn',      # "← Back"
    'mention_return_label',    # "← Back to p.%d"
    'merge_back',              # "← Back"
    'path',                    # "plugins/xray.koplugin"
    'current_language',        # "en" (or specific code)
    'menu_xray',               # "X-Ray" (brand name)
}

def get_md5(text):
    return hashlib.md5(text.encode('utf-8')).hexdigest()

# --- Escaping ---------------------------------------------------------------
# Values are held DECODED in memory (real newlines, bare double quotes) and are
# encoded only when written to a .po file. parse_po used to hand back the raw,
# still-encoded text while save_po encoded it again, so every sync added one
# more backslash in front of each embedded quote. Keep these two functions
# exact inverses of each other.
#
# The alphabet matches the reader in xray.koplugin/localization_xray.lua:
# backslash, double quote, newline, tab.
_PO_DECODE = {'\\': '\\', '"': '"', 'n': '\n', 't': '\t'}

def po_unescape(text):
    """Decode a .po (or Lua) string body. Single pass, so `\\n` decodes to a
    backslash followed by the letter n, not to a newline."""
    if not text:
        return text
    return re.sub(r'\\(.)', lambda m: _PO_DECODE.get(m.group(1), m.group(0)), text)

def po_escape(text):
    """Encode a value for a .po string body. Backslash first, or the escapes
    added after it would be escaped a second time."""
    if not text:
        return text
    return (text.replace('\\', '\\\\')
                .replace('"', '\\"')
                .replace('\n', '\\n')
                .replace('\t', '\\t'))

# Format specifiers a translation must keep: %s, %d, and the positional %1$s.
_PLACEHOLDER_RE = re.compile(r'%(?:(\d+)\$)?([a-zA-Z])')

def _placeholders(text):
    """Multiset of conversion types a string consumes, e.g. ('d', 's').

    The position prefix is dropped on purpose. A translation is free to rewrite
    `Book %d of %s` as `%2$s no %1$d` when the target language needs the other
    word order -- Localization:t supports that, and it is correct localization,
    not drift. What must match is which argument types get consumed.
    """
    # `%%` is a literal percent sign, so `%%s` must not count as a `%s`.
    text = (text or '').replace('%%', '')
    return tuple(sorted(m.group(2) for m in _PLACEHOLDER_RE.finditer(text)))

def en_hash(text):
    """Hash the ENCODED form, so the stored en-hash values stay comparable with
    the ones written before decoding was introduced."""
    return get_md5(po_escape(text))

# A loc:t call, with its optional `or "fallback"` default.
#
# Three traps here:
#  - The fallback body must be matched escape-aware. A non-greedy `(.*?)` stops
#    at the first \" and stores a value ending in a stray backslash.
#  - The argument tail must not cross a line. With re.DOTALL a `.*?` there runs
#    past the end of the call and pairs the key with some later call's fallback.
#  - The `or` group must stay OPTIONAL, or a key with no fallback drags the
#    match forward to the next one that has one.
#  - The call may be wrapped in grouping parentheses, as in
#    `(p and p.loc:t("k")) or "fallback"`, so extra `)` before the `or` are
#    allowed -- but only when each one closes a grouping paren on the same
#    line. In `foo(loc:t("k")) or "x"` the `)` closes a CALL, and "x" is the
#    fallback for foo(), not for the key. A `(` preceded by an identifier,
#    `)`, `]` or a string is a call; anything else groups. Every inline
#    fallback for a key must agree across files: files are walked in sorted
#    order and the last one wins.
_STR_BODY = r'(?:\\.|[^%s\\\n])*'
LOC_KEY_RE = re.compile(r'loc:t\(\s*["\']([^"\']*)["\']')
FALLBACK_TAIL_RE = re.compile(
    r'\s*or\s*(?:"(' + (_STR_BODY % '"') + r')"'
    r"|'(" + (_STR_BODY % "'") + r")')"
)
# A provider table field, `loc_key = "img_key_x"`. The UI reads these as
# loc:t(p.loc_key), which the call scanner cannot see; without this the sync
# drops the key from every .po file and the settings row shows the raw key.
LOC_FIELD_RE = re.compile(r'\bloc_key\s*=\s*["\']([^"\']+)["\']')


def _walk_parens(text, start, stop=None):
    """Walk `text` from `start` (to `stop`, or the end of the line), skipping
    string bodies and tracking parens. Return (close_idx, unmatched_opens):
    close_idx is the index of the first `)` with no matching `(` inside the
    walk (None when the walk ends first); unmatched_opens lists the indices of
    `(` still open at that point."""
    opens = []
    quote = None
    i = start
    n = len(text) if stop is None else stop
    while i < n:
        c = text[i]
        if quote:
            if c == '\\':
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in '"\'':
            quote = c
        elif c == '\n':
            break
        elif c == '(':
            opens.append(i)
        elif c == ')':
            if not opens:
                return i, opens
            opens.pop()
        i += 1
    return None, opens


def _is_grouping_paren(text, open_idx):
    j = open_idx - 1
    while j >= 0 and text[j] in ' \t':
        j -= 1
    return j < 0 or not (text[j].isalnum() or text[j] in '_)]"\'')


def iter_loc_calls(content):
    """Yield (key, fallback-or-None) for every loc:t("key") call."""
    for m in LOC_KEY_RE.finditer(content):
        key = m.group(1)
        # From just after the key, the first unmatched `)` closes loc:t(.
        end, _ = _walk_parens(content, m.end())
        if end is None:
            yield key, None
            continue
        i = end + 1
        extra = 0
        while i < len(content) and content[i] == ')':
            extra += 1
            i += 1
        if extra:
            # Each extra `)` must close a grouping paren opened earlier on
            # this line. If it closes a call, the fallback belongs to that
            # call, not to the key.
            line_start = content.rfind('\n', 0, m.start()) + 1
            _, unmatched = _walk_parens(content, line_start, m.start())
            if extra > len(unmatched) or not all(
                    _is_grouping_paren(content, o) for o in unmatched[-extra:]):
                yield key, None
                continue
        t = FALLBACK_TAIL_RE.match(content, i)
        if not t:
            yield key, None
            continue
        yield key, (t.group(1) if t.group(1) is not None else t.group(2))

# One `key = "value"` line inside the hardcoded fallback table.
FALLBACK_ENTRY_RE = re.compile(r'(\w+)\s*=\s*"(' + (_STR_BODY % '"') + r')"')

# An escape cannot span two lines, so decode only after every continuation
# line has been concatenated.
def _decode_entry(entry):
    entry['msgid'] = po_unescape(entry['msgid'])
    entry['msgstr'] = po_unescape(entry['msgstr'])
    return entry

def parse_po(file_path):
    entries = []
    current_entry = {'msgid': '', 'msgstr': '', 'comments': [], 'en_hash': None}
    current_field = None
    if not os.path.exists(file_path): return []
    with open(file_path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                if current_entry['msgid'] or current_entry['msgstr']:
                    entries.append(_decode_entry(current_entry))
                    current_entry = {'msgid': '', 'msgstr': '', 'comments': [], 'en_hash': None}
                current_field = None
                continue
            if line.startswith('#'):
                current_entry['comments'].append(line)
                # Parse English content hash comment
                m = re.match(r'^#\s*en-hash:\s*([a-f0-9]+)$', line)
                if m:
                    current_entry['en_hash'] = m.group(1)
            elif line.startswith('msgid '):
                m = re.match(r'^msgid "(.*)"$', line)
                if m:
                    current_entry['msgid'] = m.group(1)
                current_field = 'msgid'
            elif line.startswith('msgstr '):
                m = re.match(r'^msgstr "(.*)"$', line)
                if m:
                    current_entry['msgstr'] = m.group(1)
                current_field = 'msgstr'
            elif line.startswith('"'):
                m = re.match(r'^"(.*)"$', line)
                if m:
                    if current_field == 'msgid':
                        current_entry['msgid'] += m.group(1)
                    elif current_field == 'msgstr':
                        current_entry['msgstr'] += m.group(1)
        if current_entry['msgid'] or current_entry['msgstr']:
            entries.append(_decode_entry(current_entry))
    return entries

def save_po(file_path, lang_name, lang_code, keys, translations, fallback_map, en_final,
            stored_hashes=None, updated_keys=None):
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(f'msgid ""\nmsgstr ""\n"Language-Team: {lang_name}\\n"\n"Language: {lang_code}\\n"\n"Content-Type: text/plain; charset=UTF-8\\n"\n"Content-Transfer-Encoding: 8bit\\n"\n\n')
        for key in sorted(keys):
            if not key: continue
            if lang_code == 'en':
                val = translations.get(key) or fallback_map.get(key) or key
            else:
                val = translations.get(key, "")
            escaped_val = po_escape(val)

            # For non-English languages, write the hash of the English value
            # this translation was actually made from.
            #
            # Do NOT stamp the current English hash on a translation that was
            # not updated this run. Skip mode used to do that, which told the
            # next run the stale translation was fresh -- real drift then went
            # unreported for good. Keep the stored hash instead, so the key
            # stays stale until somebody translates it. A key that had no
            # stored hash gets none: stamping the current one would make the
            # same false claim of freshness.
            if lang_code != 'en':
                en_val = en_final.get(key, "")
                if en_val:
                    if updated_keys is not None and key not in updated_keys:
                        keep = (stored_hashes or {}).get(key)
                    else:
                        keep = en_hash(en_val)
                    if keep:
                        f.write(f'# en-hash: {keep}\n')
            f.write(f'msgid "{po_escape(key)}"\nmsgstr "{escaped_val}"\n\n')

def get_gemini_key():
    return os.environ.get("GEMINI_API_KEY")

def call_gemini(prompt):
    import urllib.error
    key = get_gemini_key()
    if not key: return None
    
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite:generateContent?key={key}"
    headers = {"Content-Type": "application/json"}
    data = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"responseMimeType": "application/json"}
    }
    
    req = urllib.request.Request(url, data=json.dumps(data).encode('utf-8'), headers=headers, method='POST')
    
    max_retries = 3
    for attempt in range(max_retries):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                res_data = json.loads(response.read().decode('utf-8'))
                text = res_data['candidates'][0]['content']['parts'][0]['text']
                text_stripped = text.strip()
                first_brace = text_stripped.find('{')
                last_brace = text_stripped.rfind('}')
                if first_brace != -1 and last_brace != -1:
                    json_str = text_stripped[first_brace:last_brace+1]
                    return json.loads(json_str)
                return json.loads(text_stripped)
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503, 504) and attempt < max_retries - 1:
                # For 429, respect Retry-After header if present, otherwise use backoff
                if e.code == 429:
                    retry_after = e.headers.get('Retry-After')
                    sleep_time = int(retry_after) if retry_after else 10 * (attempt + 1)
                else:
                    sleep_time = 5 * (attempt + 1)
                print(f"  - HTTP {e.code}, waiting {sleep_time}s before retry {attempt + 1}/{max_retries - 1}...")
                time.sleep(sleep_time)
            else:
                print(f"API Error calling Gemini: {e}")
                return None
        except urllib.error.URLError as e:
            # Covers socket timeouts and connection errors
            print(f"API Connection Error (timeout or network): {e}")
            if attempt < max_retries - 1:
                time.sleep(5)
            else:
                return None
        except Exception as e:
            print(f"API Error: {e}")
            return None
    return None

def translate_all_gemini(all_untranslated, lang_names, max_pairs=60):
    """
    Translates all untranslated keys across all languages in batches.
    all_untranslated: {lang_code: {key: en_val}}
    lang_names: {lang_code: lang_name}
    """
    # Flatten all translation targets to batch them
    flat_pairs = []
    for lang_code, keys in all_untranslated.items():
        for key, en_val in keys.items():
            flat_pairs.append((lang_code, key, en_val))
            
    if not flat_pairs:
        return {}
        
    all_results = {} # lang_code -> {key: translated_val}
    
    # Process flat_pairs in chunks
    for i in range(0, len(flat_pairs), max_pairs):
        chunk = flat_pairs[i:i+max_pairs]
        
        # Group by language code within this chunk to present clean prompt input
        batch_dict = {}
        for lang_code, key, en_val in chunk:
            if lang_code not in batch_dict:
                batch_dict[lang_code] = []
            batch_dict[lang_code].append({"key": key, "english": en_val})
            
        targets = []
        for lang_code, strings in batch_dict.items():
            name = lang_names.get(lang_code, lang_code.capitalize())
            targets.append({
                "language_code": lang_code,
                "language_name": name,
                "strings": strings
            })
            
        prompt = f"""You are a professional translator and localization expert. Translate the following English key-value pairs for a KOReader e-reader plugin UI into their respective target languages.

For each target language, you will receive its language name, language code, and a list of key-value pairs where the values are in English. Translate the English values into the target language, keeping them short, clear, and natural for e-reader menus.

CRITICAL rules:
1. Retain all format specifiers such as %s, %d, %1$s, %2$d, etc. exactly in the translated output.
2. Retain all literal escaped newlines (\\n) and tabs (\\t) exactly.
3. Keep the translation concise, natural, and suited for a mobile e-reader display.
4. Return ONLY a valid JSON object matching this exact schema:
{{
  "translations": {{
    "<language_code>": {{
      "key_name": "translated_value"
    }}
  }}
}}
Do not add markdown blocks, explanations, or backticks.

Target languages and strings to translate:
{json.dumps(targets, indent=2)}
"""
        print(f"  - Requesting translations for batch {i // max_pairs + 1} ({len(chunk)} strings)...")
        result = call_gemini(prompt)
        
        if result and "translations" in result:
            translations = result["translations"]
            for lang_code, tr_map in translations.items():
                if lang_code not in all_results:
                    all_results[lang_code] = {}
                for k, v in tr_map.items():
                    all_results[lang_code][k] = v
        else:
            print(f"  - WARNING: Batch {i // max_pairs + 1} failed or returned invalid response.")
            
        # Short rate-limiting recovery sleep between batches (if multiple exist)
        if i + max_pairs < len(flat_pairs):
            time.sleep(2.0)
            
    return all_results

def manual_translate_languages(all_untranslated, lang_names, all_existing_tr,
                               updated=None):
    """
    Prompts the user interactively in the terminal to translate keys.
    """
    print("\n=== Interactive Manual Translation ===")
    print("For each language, you can type translations. Press Enter to skip a key.")
    print("Type 'exit' to stop translating and save all progress so far.")
    
    for lang_code in sorted(all_untranslated.keys()):
        keys = all_untranslated[lang_code]
        lang_name = lang_names.get(lang_code, lang_code.capitalize())
        
        print(f"\n--- {lang_name} ({lang_code}) - {len(keys)} keys need translation ---")
        try:
            choice = input(f"Translate keys for {lang_name}? [Y/n/skip-all]: ").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nExiting manual translation mode.")
            break
            
        if choice in ('skip-all', 's'):
            print("Skipping all remaining languages.")
            break
        elif choice == 'n':
            print(f"Skipping {lang_name}.")
            continue
            
        existing_tr = all_existing_tr.get(lang_code, {})
        aborted = False
        
        for idx, (key, en_val) in enumerate(keys.items(), 1):
            print(f"\n[{idx}/{len(keys)}] Key: {key}")
            print(f"      English: {en_val}")
            curr = existing_tr.get(key, "")
            if curr:
                print(f"      Current: {curr}")
            try:
                val = input("      Translation: ").strip()
            except (KeyboardInterrupt, EOFError):
                print("\nExiting manual translation mode.")
                aborted = True
                break
                
            if val.lower() == 'exit':
                print("Exiting manual translation mode.")
                aborted = True
                break
                
            if val:
                existing_tr[key] = val
                if updated is not None:
                    updated.setdefault(lang_code, set()).add(key)
                print(f"      Saved: {val}")
            else:
                print("      Skipped.")
                
        if aborted:
            break

def sync():
    import argparse
    parser = argparse.ArgumentParser(description="Synchronize and translate KOReader X-Ray plugin localizations.")
    parser.add_argument("-m", "--mode", choices=["auto", "manual", "skip"], help="Translation mode: auto (Gemini), manual (interactive CLI), or skip.")
    args = parser.parse_args()

    print("--- Starting Translation Sync ---")
    
    # 1. Scan Source for Used Keys
    #
    # Two places hold an English default: the inline `or "..."` on a loc:t call,
    # and the hardcoded fallbacks table in localization_xray.lua. They disagree
    # for 30 keys, and this used to read them in os.walk order, so which one
    # reached en.po was arbitrary -- that is how `fetching_ai` ended up with a
    # different placeholder set than every translation of it.
    #
    # Precedence is now fixed: the inline default wins, because that is the copy
    # that gets maintained (it carries the [B]markup[/B] and the current wording).
    # The table only fills in keys that have no inline default. Walk in sorted
    # order too, so two runs cannot disagree.
    inline_defaults = {}   # key -> English from an `or "..."` on the call
    table_defaults = {}    # key -> English from the hardcoded fallbacks table
    keys_seen = set()
    for root, _, files in os.walk(SOURCE_DIR):
        for file in sorted(files):
            if file.endswith('.lua'):
                with open(os.path.join(root, file), 'r', encoding='utf-8', errors='ignore') as f:
                    content = f.read()
                    for m in LOC_FIELD_RE.finditer(content):
                        keys_seen.add(m.group(1))
                    for key, fb in iter_loc_calls(content):
                        keys_seen.add(key)
                        if fb:
                            fb = po_unescape(fb)
                            prev = inline_defaults.get(key)
                            if prev is not None and prev != fb:
                                # Two call sites disagree. The later file in
                                # sorted order wins; say so, or the choice is
                                # silent and looks arbitrary from en.po.
                                print(f"  ! {key}: inline defaults differ, {file} wins")
                                print(f"      using   {fb!r}")
                                print(f"      ignored {prev!r}")
                            inline_defaults[key] = fb
                    if 'localization_xray.lua' in file:
                        # Read the hardcoded fallback table only. Scanning the
                        # whole file matched every `name = "value"` assignment
                        # in it and invented keys out of module fields and
                        # locals (`path`, `current_language`, `val`).
                        blk = re.search(r'local fallbacks = \{(.*?)\n\s*\}', content, re.DOTALL)
                        if blk:
                            for m in re.finditer(FALLBACK_ENTRY_RE, blk.group(1)):
                                table_defaults[m.group(1)] = po_unescape(m.group(2))
                                keys_seen.add(m.group(1))

    used_keys = {} # key -> default_string
    for key in keys_seen:
        used_keys[key] = inline_defaults.get(key) or table_defaults.get(key) or ""

    # A default that takes an argument must keep its placeholder, or the
    # argument is dropped and every translation of the key drifts against it.
    for key, val in sorted(used_keys.items()):
        other = table_defaults.get(key) if inline_defaults.get(key) else inline_defaults.get(key)
        if other and _placeholders(val) != _placeholders(other):
            print(f"  ! {key}: the two English defaults disagree on placeholders")
            print(f"      using   {val!r}")
            print(f"      ignored {other!r}")

    print(f"Found {len(used_keys)} keys in source code.")

    # 2. Update English Master
    en_path = os.path.join(LANGUAGES_DIR, f'{MASTER_LANG}.po')
    en_entries = parse_po(en_path)
    en_existing = {e['msgid']: e['msgstr'] for e in en_entries if e['msgid']}
    
    en_final = {}
    for key in used_keys:
        code_fallback = used_keys.get(key, "")
        en_final[key] = (code_fallback if code_fallback else en_existing.get(key)) or key
    
    save_po(en_path, 'English', 'en', en_final.keys(), en_final, used_keys, en_final)
    print(f"Updated {MASTER_LANG}.po")

    # 3. Read and Prepare other languages
    lang_files = [f for f in os.listdir(LANGUAGES_DIR) if f.endswith('.po') and not f.startswith(MASTER_LANG)]
    lang_files_codes = [f.split('.')[0] for f in lang_files]
    
    lang_names = {}
    all_existing_tr = {}
    all_existing_hashes = {}
    all_untranslated = {}
    
    for file in lang_files:
        lang_code = file.split('.')[0]
        path = os.path.join(LANGUAGES_DIR, file)
        entries = parse_po(path)
        
        # Language name, from xray_ui.lua. The header is only a fallback for a
        # language that is not registered there yet: the tools write that header
        # themselves, so a bad value in it survives every later sync. That is
        # how every file came to say "Language-Team: Ar".
        header_name = None
        for e in entries:
            if e['msgid'] == '':
                m = re.search(r'Language-Team: (.*?)\n', e['msgstr'])
                if m and m.group(1) != lang_code.capitalize():
                    header_name = m.group(1)

        lang_names[lang_code] = language_name(lang_code, header_name)
        
        existing_tr = {e['msgid']: e['msgstr'] for e in entries if e['msgid'] and e['msgstr']}
        existing_hashes = {e['msgid']: e['en_hash'] for e in entries if e['msgid']}
        
        all_existing_tr[lang_code] = existing_tr
        all_existing_hashes[lang_code] = existing_hashes
        
        # Find missing or untranslated/stale keys
        untranslated = {}
        for key in en_final:
            if key != 'language_name' and key != "":
                current_val = existing_tr.get(key, "")
                en_val = en_final.get(key, "")
                stored_hash = existing_hashes.get(key)
                current_hash = en_hash(en_val) if en_val else None
                
                is_missing = (current_val == "")
                is_fallback = (current_val == key and key not in ALLOWLIST)
                is_stale = (stored_hash and current_hash and stored_hash != current_hash)
                # A translation that lost or gained a format specifier is wrong
                # whatever its hash says: at best the argument is dropped, and
                # tools/translate_all.py --audit reports it as drift. Catch it
                # here so one run of this tool actually fixes it.
                is_placeholder_drift = (
                    current_val != ""
                    and _placeholders(current_val) != _placeholders(en_val))

                if is_missing or is_fallback or is_stale or is_placeholder_drift:
                    untranslated[key] = en_val
                    
        if untranslated:
            all_untranslated[lang_code] = untranslated

    # Intercept and translate known keys locally to bypass Gemini API requirement
    local_translations = {
        "ar": {
                "unit_scanning_book": "جاري مسح الكتاب بحثًا عن الوحدات...",
                "unit_scanning_title": "X-Ray: محول الوحدات",
                "btn_paste": "لصق",
                "import_file_not_found": "لم يتم العثور على ملف xray_key.txt في الدليل الجذري أو مجلد الإعدادات.",
                "import_file_success": "تم استيراد %d مفتاح API بنجاح من %s!",
                "key_status_err": "[ERR] فشل: %s",
                "key_status_not_set": "[--] غير مهيأ",
                "key_status_ok": "[OK] متصل (%d مللي ثانية)",
                "menu_import_file": "استيراد المفاتيح من xray_key.txt",
                "menu_paste_clipboard": "لصق مفتاح %s من الحافظة",
                "menu_test_key": "اختبار الاتصال",
                "menu_validate_all_keys": "اختبار والتحقق من جميع مفاتيح API",
                "menu_web_setup": "إعداد مفتاح API عبر الهاتف / الحاسوب (رمز QR)",
                "paste_clipboard_confirm": "هل تريد استخدام مفتاح API الموجود في الحافظة لـ %s؟",
                "testing_api_keys": "جاري اختبار اتصالات مفاتيح API...",
                "validate_keys_title": "حالة والتحقق من مفاتيح API",
                "web_setup_msg": "1. اتصل بنفس شبكة Wi-Fi على هاتفك/حاسوبك.\n2. امسح رمز QR هذا أو زر:\n\n%s\n\n3. الصق مفتاح API واضغط حفظ.",
                "web_setup_no_wifi": "شبكة Wi-Fi غير متصلة. يرجى الاتصال بشبكة Wi-Fi لاستخدام الإعداد عبر الويب.",
                "web_setup_success": "تم استلام وحفظ مفتاح API لـ %s بنجاح!",
                "web_setup_title": "الاتصال عبر الهاتف / الحاسوب"
        },
        "de": {
                "unit_scanning_book": "Buch wird nach Einheiten gescannt...",
                "unit_scanning_title": "X-Ray: Einheitenumrechner",
                "btn_paste": "Einfügen",
                "import_file_not_found": "Keine xray_key.txt Datei im Speicher-Stammverzeichnis oder Einstellungsverzeichnis gefunden.",
                "import_file_success": "%d API-Schlüssel erfolgreich aus %s importiert!",
                "key_status_err": "[ERR] Fehlgeschlagen: %s",
                "key_status_not_set": "[--] Nicht konfiguriert",
                "key_status_ok": "[OK] Verbunden (%d ms)",
                "menu_import_file": "Schlüssel aus xray_key.txt importieren",
                "menu_paste_clipboard": "%s-Schlüssel aus Zwischenablage einfügen",
                "menu_test_key": "Verbindung testen",
                "menu_validate_all_keys": "Alle API-Schlüssel testen & validieren",
                "menu_web_setup": "API-Schlüssel über Smartphone / PC einrichten (QR-Code)",
                "paste_clipboard_confirm": "Den in der Zwischenablage gefundenen API-Schlüssel für %s verwenden?",
                "testing_api_keys": "API-Schlüsselverbindungen werden getestet...",
                "validate_keys_title": "API-Schlüssel-Status & Validierung",
                "web_setup_msg": "1. Verbinden Sie Ihr Smartphone/PC mit demselben WLAN.\n2. Scannen Sie diesen QR-Code oder öffnen Sie:\n\n%s\n\n3. Fügen Sie Ihren API-Schlüssel ein und tippen Sie auf Speichern.",
                "web_setup_no_wifi": "WLAN ist getrennt. Bitte stellen Sie eine WLAN-Verbindung her, um das Web-Setup zu nutzen.",
                "web_setup_success": "API-Schlüssel für %s empfangen und gespeichert!",
                "web_setup_title": "Über Smartphone / PC verbinden"
        },
        "en": {
                "unit_scanning_book": "Scanning book for units...",
                "unit_scanning_title": "X-Ray: Unit Converter",
                "btn_paste": "Paste",
                "import_file_not_found": "No xray_key.txt file found in storage root or settings directory.",
                "import_file_success": "Successfully imported %d API key(s) from %s!",
                "key_status_err": "[ERR] Failed: %s",
                "key_status_not_set": "[--] Not configured",
                "key_status_ok": "[OK] Connected (%d ms)",
                "menu_import_file": "Import Keys from xray_key.txt",
                "menu_paste_clipboard": "Paste %s Key from Clipboard",
                "menu_test_key": "Test Connection",
                "menu_validate_all_keys": "Test & Validate All API Keys",
                "menu_web_setup": "Set API Key from Phone / PC (QR Code)",
                "paste_clipboard_confirm": "Use the API key found in clipboard for %s?",
                "testing_api_keys": "Testing API key connections...",
                "validate_keys_title": "API Key Status & Validation",
                "web_setup_msg": "1. Connect your phone/PC to the same Wi-Fi.\n2. Scan this QR code or visit:\n\n%s\n\n3. Paste your API key and tap Save.",
                "web_setup_no_wifi": "Wi-Fi is disconnected. Please connect to Wi-Fi to use Web Setup.",
                "web_setup_success": "API key for %s received and saved!",
                "web_setup_title": "Connect via Phone / PC"
        },
        "es": {
                "unit_scanning_book": "Escaneando el libro en busca de unidades...",
                "unit_scanning_title": "X-Ray: Conversor de unidades",
                "btn_paste": "Pegar",
                "import_file_not_found": "No se encontró el archivo xray_key.txt en la raíz del almacenamiento ni en los ajustes.",
                "import_file_success": "¡Se importaron correctamente %d clave(s) API desde %s!",
                "key_status_err": "[ERR] Error: %s",
                "key_status_not_set": "[--] No configurado",
                "key_status_ok": "[OK] Conectado (%d ms)",
                "menu_import_file": "Importar claves desde xray_key.txt",
                "menu_paste_clipboard": "Pegar clave de %s del portapapeles",
                "menu_test_key": "Probar conexión",
                "menu_validate_all_keys": "Probar y validar todas las claves API",
                "menu_web_setup": "Configurar clave API desde móvil / PC (código QR)",
                "paste_clipboard_confirm": "¿Usar la clave API encontrada en el portapapeles para %s?",
                "testing_api_keys": "Probando conexiones de claves API...",
                "validate_keys_title": "Estado y validación de claves API",
                "web_setup_msg": "1. Conecta tu móvil/PC a la misma red Wi-Fi.\n2. Escanea este código QR o visita:\n\n%s\n\n3. Pega tu clave API y pulsa Guardar.",
                "web_setup_no_wifi": "Wi-Fi desconectado. Conéctate a una red Wi-Fi para usar la configuración web.",
                "web_setup_success": "¡Clave API para %s recibida y guardada!",
                "web_setup_title": "Conectar mediante móvil / PC"
        },
        "fr": {
                "unit_scanning_book": "Analyse du livre pour les unités...",
                "unit_scanning_title": "X-Ray: Convertisseur d'unités",
                "btn_paste": "Coller",
                "import_file_not_found": "Aucun fichier xray_key.txt trouvé à la racine du stockage ou des paramètres.",
                "import_file_success": "%d clé(s) API importée(s) avec succès depuis %s !",
                "key_status_err": "[ERR] Échec : %s",
                "key_status_not_set": "[--] Non configuré",
                "key_status_ok": "[OK] Connecté (%d ms)",
                "menu_import_file": "Importer les clés depuis xray_key.txt",
                "menu_paste_clipboard": "Coller la clé %s depuis le presse-papiers",
                "menu_test_key": "Tester la connexion",
                "menu_validate_all_keys": "Tester et valider toutes les clés API",
                "menu_web_setup": "Configurer la clé API via smartphone / PC (QR Code)",
                "paste_clipboard_confirm": "Utiliser la clé API trouvée dans le presse-papiers pour %s ?",
                "testing_api_keys": "Test des connexions aux clés API...",
                "validate_keys_title": "Statut et validation des clés API",
                "web_setup_msg": "1. Connectez votre smartphone/PC au même réseau Wi-Fi.\n2. Scannez ce QR code ou visitez :\n\n%s\n\n3. Collez votre clé API et appuyez sur Enregistrer.",
                "web_setup_no_wifi": "Le Wi-Fi est déconnecté. Veuillez vous connecter au Wi-Fi pour utiliser la configuration web.",
                "web_setup_success": "Clé API pour %s reçue et enregistrée !",
                "web_setup_title": "Connexion via smartphone / PC"
        },
        "hu": {
                "unit_scanning_book": "Könyv pásztázása mértékegységekért...",
                "unit_scanning_title": "X-Ray: Mértékegység-átváltó",
                "btn_paste": "Beillesztés",
                "import_file_not_found": "Nem található xray_key.txt fájl a gyökérkönyvtárban vagy a beállításoknál.",
                "import_file_success": "Sikeresen importálva %d API kulcs a(z) %s fájlból!",
                "key_status_err": "[ERR] Sikertelen: %s",
                "key_status_not_set": "[--] Nincs konfigurálva",
                "key_status_ok": "[OK] Csatlakozva (%d ms)",
                "menu_import_file": "Kulcsok importálása az xray_key.txt fájlból",
                "menu_paste_clipboard": "%s kulcs beillesztése a vágólapról",
                "menu_test_key": "Kapcsolat tesztelése",
                "menu_validate_all_keys": "Minden API kulcs tesztelése és érvényesítése",
                "menu_web_setup": "API kulcs beállítása telefonról / PC-ről (QR-kód)",
                "paste_clipboard_confirm": "Használja a vágólapon található API kulcsot a(z) %s szolgáltatáshoz?",
                "testing_api_keys": "API kulcs kapcsolatok tesztelése...",
                "validate_keys_title": "API kulcsok állapota és érvényesítése",
                "web_setup_msg": "1. Csatlakoztassa telefonját/PC-jét ugyanahhoz a Wi-Fi-hez.\n2. Olvassa be ezt a QR-kódot vagy látogasson el ide:\n\n%s\n\n3. Illessze be az API kulcsot, majd koppintson a Mentésre.",
                "web_setup_no_wifi": "Wi-Fi lekapcsolva. A webes beállításhoz kérjük, csatlakozzon Wi-Fi hálózathoz.",
                "web_setup_success": "A(z) %s API kulcsa sikeresen fogadva és mentve!",
                "web_setup_title": "Csatlakozás telefonról / PC-ről"
        },
        "id": {
                "unit_scanning_book": "Memindai buku untuk unit...",
                "unit_scanning_title": "X-Ray: Konverter Satuan",
                "btn_paste": "Tempel",
                "import_file_not_found": "Berkas xray_key.txt tidak ditemukan di penyimpanan utama atau direktori pengaturan.",
                "import_file_success": "Berhasil mengimpor %d kunci API dari %s!",
                "key_status_err": "[ERR] Gagal: %s",
                "key_status_not_set": "[--] Belum dikonfigurasi",
                "key_status_ok": "[OK] Terhubung (%d ms)",
                "menu_import_file": "Impor Kunci dari xray_key.txt",
                "menu_paste_clipboard": "Tempel Kunci %s dari Papan Klip",
                "menu_test_key": "Uji Sambungan",
                "menu_validate_all_keys": "Uji & Validasi Semua Kunci API",
                "menu_web_setup": "Atur Kunci API dari Ponsel / PC (Kode QR)",
                "paste_clipboard_confirm": "Gunakan kunci API dari papan klip untuk %s?",
                "testing_api_keys": "Menguji koneksi kunci API...",
                "validate_keys_title": "Status & Validasi Kunci API",
                "web_setup_msg": "1. Sambungkan ponsel/PC Anda ke Wi-Fi yang sama.\n2. Pindai kode QR ini atau kunjungi:\n\n%s\n\n3. Tempel kunci API dan ketuk Simpan.",
                "web_setup_no_wifi": "Wi-Fi terputus. Harap sambungkan ke Wi-Fi untuk menggunakan Pengaturan Web.",
                "web_setup_success": "Kunci API untuk %s berhasil diterima dan disimpan!",
                "web_setup_title": "Hubungkan via Ponsel / PC"
        },
        "it": {
                "unit_scanning_book": "Scansione del libro per le unità...",
                "unit_scanning_title": "X-Ray: Convertitore di unità",
                "btn_paste": "Incolla",
                "import_file_not_found": "Nessun file xray_key.txt trovato nella root di memoria o nella cartella impostazioni.",
                "import_file_success": "Importate con successo %d chiave/i API da %s!",
                "key_status_err": "[ERR] Fallito: %s",
                "key_status_not_set": "[--] Non configurato",
                "key_status_ok": "[OK] Connesso (%d ms)",
                "menu_import_file": "Importa chiavi da xray_key.txt",
                "menu_paste_clipboard": "Incolla chiave %s dagli appunti",
                "menu_test_key": "Testa connessione",
                "menu_validate_all_keys": "Testa e convalida tutte le chiavi API",
                "menu_web_setup": "Imposta chiave API da smartphone / PC (codice QR)",
                "paste_clipboard_confirm": "Utilizzare la chiave API trovata negli appunti per %s?",
                "testing_api_keys": "Test delle connessioni delle chiavi API in corso...",
                "validate_keys_title": "Stato e convalida chiavi API",
                "web_setup_msg": "1. Connetti smartphone/PC alla stessa rete Wi-Fi.\n2. Scansiona questo codice QR o visita:\n\n%s\n\n3. Incolla la tua chiave API e tocca Salva.",
                "web_setup_no_wifi": "Wi-Fi disconnesso. Connettiti al Wi-Fi per utilizzare la configurazione web.",
                "web_setup_success": "Chiave API per %s ricevuta e salvata!",
                "web_setup_title": "Connetti via smartphone / PC"
        },
        "ja": {
                "unit_scanning_book": "書籍の単位をスキャン中...",
                "unit_scanning_title": "X-Ray: 単位コンバーター",
                "btn_paste": "貼り付け",
                "import_file_not_found": "ストレージルートまたは設定ディレクトリに xray_key.txt が見つかりません。",
                "import_file_success": "%2$s から %1$d 個のAPIキーを正常にインポートしました！",
                "key_status_err": "[ERR] 失敗: %s",
                "key_status_not_set": "[--] 未設定",
                "key_status_ok": "[OK] 接続完了 (%d ms)",
                "menu_import_file": "xray_key.txt からキーをインポート",
                "menu_paste_clipboard": "クリップボードから %s キーを貼り付け",
                "menu_test_key": "接続テスト",
                "menu_validate_all_keys": "すべてのAPIキーをテスト＆検証",
                "menu_web_setup": "スマホ / PC からAPIキーを設定 (QRコード)",
                "paste_clipboard_confirm": "クリップボードのAPIキーを %s に使用しますか？",
                "testing_api_keys": "APIキー接続をテスト中...",
                "validate_keys_title": "APIキーの状態と検証",
                "web_setup_msg": "1. スマホ/PCを同じWi-Fiに接続してください。\n2. このQRコードをスキャンするか以下にアクセスしてください:\n\n%s\n\n3. APIキーを貼り付けて「保存」をタップします。",
                "web_setup_no_wifi": "Wi-Fiが切断されています。Web設定を使用するにはWi-Fiに接続してください。",
                "web_setup_success": "%s のAPIキーを受信して保存しました！",
                "web_setup_title": "スマホ / PC から接続"
        },
        "nl": {
                "unit_scanning_book": "Boek scannen op eenheden...",
                "unit_scanning_title": "X-Ray: Eenhedenomrekenaar",
                "btn_paste": "Plakken",
                "import_file_not_found": "Geen xray_key.txt-bestand gevonden in opslaghoofdmap of instellingenmap.",
                "import_file_success": "Succesvol %d API-sleutel(s) geïmporteerd uit %s!",
                "key_status_err": "[ERR] Mislukt: %s",
                "key_status_not_set": "[--] Niet geconfigureerd",
                "key_status_ok": "[OK] Verbonden (%d ms)",
                "menu_import_file": "Sleutels importeren uit xray_key.txt",
                "menu_paste_clipboard": "%s-sleutel plakken van klembord",
                "menu_test_key": "Verbinding testen",
                "menu_validate_all_keys": "Alle API-sleutels testen & valideren",
                "menu_web_setup": "API-sleutel instellen via telefoon / pc (QR-code)",
                "paste_clipboard_confirm": "De API-sleutel van het klembord gebruiken voor %s?",
                "testing_api_keys": "API-sleutelverbindingen testen...",
                "validate_keys_title": "API-sleutelstatus & validatie",
                "web_setup_msg": "1. Verbind je telefoon/pc met dezelfde wifi.\n2. Scan deze QR-code of ga naar:\n\n%s\n\n3. Plak je API-sleutel en tik op Opslaan.",
                "web_setup_no_wifi": "Wifi is verbroken. Maak verbinding met wifi om Web Setup te gebruiken.",
                "web_setup_success": "API-sleutel voor %s ontvangen en opgeslagen!",
                "web_setup_title": "Verbinden via telefoon / pc"
        },
        "pl": {
                "unit_scanning_book": "Skanowanie książki pod kątem jednostek...",
                "unit_scanning_title": "X-Ray: Konwerter jednostek",
                "btn_paste": "Wklej",
                "import_file_not_found": "Nie znaleziono pliku xray_key.txt w katalogu głównym pamięci ani w ustawieniach.",
                "import_file_success": "Pomyślnie zaimportowano %d klucz(y) API z %s!",
                "key_status_err": "[ERR] Niepowodzenie: %s",
                "key_status_not_set": "[--] Nieskonfigurowane",
                "key_status_ok": "[OK] Połączono (%d ms)",
                "menu_import_file": "Importuj klucze z xray_key.txt",
                "menu_paste_clipboard": "Wklej klucz %s ze schowka",
                "menu_test_key": "Testuj połączenie",
                "menu_validate_all_keys": "Testuj i waliduj wszystkie klucze API",
                "menu_web_setup": "Ustaw klucz API z telefonu / PC (kod QR)",
                "paste_clipboard_confirm": "Użyć klucza API znalezionego w schowku dla %s?",
                "testing_api_keys": "Testowanie połączeń kluczy API...",
                "validate_keys_title": "Status i walidacja kluczy API",
                "web_setup_msg": "1. Połącz telefon/PC z tą samą siecią Wi-Fi.\n2. Zeskanuj ten kod QR lub wejdź na:\n\n%s\n\n3. Wklej klucz API i dotknij Zapisz.",
                "web_setup_no_wifi": "Wi-Fi jest odłączone. Połącz się z Wi-Fi, aby użyć konfiguracji przez przeglądarkę.",
                "web_setup_success": "Klucz API dla %s został odebrany i zapisany!",
                "web_setup_title": "Połącz przez telefon / PC"
        },
        "pt_br": {
                "unit_scanning_book": "Escaneando o livro em busca de unidades...",
                "unit_scanning_title": "X-Ray: Conversor de unidades",
                "btn_paste": "Colar",
                "import_file_not_found": "Nenhum arquivo xray_key.txt encontrado na raiz do armazenamento ou nas configurações.",
                "import_file_success": "%d chave(s) de API importada(s) com sucesso de %s!",
                "key_status_err": "[ERR] Falhou: %s",
                "key_status_not_set": "[--] Não configurado",
                "key_status_ok": "[OK] Conectado (%d ms)",
                "menu_import_file": "Importar chaves de xray_key.txt",
                "menu_paste_clipboard": "Colar chave de %s da área de transferência",
                "menu_test_key": "Testar conexão",
                "menu_validate_all_keys": "Testar e validar todas as chaves de API",
                "menu_web_setup": "Configurar chave de API via celular / PC (código QR)",
                "paste_clipboard_confirm": "Usar a chave de API encontrada na área de transferência para %s?",
                "testing_api_keys": "Testando conexões das chaves de API...",
                "validate_keys_title": "Status e validação de chaves de API",
                "web_setup_msg": "1. Conecte seu celular/PC ao mesmo Wi-Fi.\n2. Escaneie este código QR ou acesse:\n\n%s\n\n3. Cole sua chave de API e toque em Salvar.",
                "web_setup_no_wifi": "Wi-Fi desconectado. Conecte-se ao Wi-Fi para usar a configuração via web.",
                "web_setup_success": "Chave de API para %s recebida e salva!",
                "web_setup_title": "Conectar via celular / PC"
        },
        "ru": {
                "unit_scanning_book": "Сканирование книги на наличие единиц...",
                "unit_scanning_title": "X-Ray: Конвертер величин",
                "btn_paste": "Вставить",
                "import_file_not_found": "Файл xray_key.txt не найден в корневом каталоге или папке настроек.",
                "import_file_success": "Успешно импортировано %d ключ(ей) API из %s!",
                "key_status_err": "[ERR] Ошибка: %s",
                "key_status_not_set": "[--] Не настроено",
                "key_status_ok": "[OK] Подключено (%d мс)",
                "menu_import_file": "Импортировать ключи из xray_key.txt",
                "menu_paste_clipboard": "Вставить ключ %s из буфера обмена",
                "menu_test_key": "Проверить соединение",
                "menu_validate_all_keys": "Проверить и валидировать все ключи API",
                "menu_web_setup": "Настроить ключ API через телефон / ПК (QR-код)",
                "paste_clipboard_confirm": "Использовать ключ API из буфера обмена для %s?",
                "testing_api_keys": "Проверка соединений по ключам API...",
                "validate_keys_title": "Статус и валидация ключей API",
                "web_setup_msg": "1. Подключите телефон/ПК к той же сети Wi-Fi.\n2. Отсканируйте этот QR-код или перейдите по адресу:\n\n%s\n\n3. Вставьте ключ API и нажмите Сохранить.",
                "web_setup_no_wifi": "Wi-Fi отключен. Подключитесь к Wi-Fi для веб-настройки.",
                "web_setup_success": "Ключ API для %s получен и сохранен!",
                "web_setup_title": "Подключение через телефон / ПК"
        },
        "sr": {
                "unit_scanning_book": "Скенирање књиге за јединице...",
                "unit_scanning_title": "X-Ray: Конвертор јединица",
                "btn_paste": "Налепи",
                "import_file_not_found": "Датотека xray_key.txt није пронађена у корену меморије или директоријуму подешавања.",
                "import_file_success": "Успешно увезено %d API кључ(ева) из %s!",
                "key_status_err": "[ERR] Неуспешно: %s",
                "key_status_not_set": "[--] Није подешено",
                "key_status_ok": "[OK] Повезано (%d ms)",
                "menu_import_file": "Увези кључеве из xray_key.txt",
                "menu_paste_clipboard": "Налепи %s кључ из оставе",
                "menu_test_key": "Тестирај везу",
                "menu_validate_all_keys": "Тестирај и потврди све API кључеве",
                "menu_web_setup": "Подеси API кључ преко телефона / рачунара (QR код)",
                "paste_clipboard_confirm": "Користити API кључ из оставе за %s?",
                "testing_api_keys": "Тестирање веза са API кључевима...",
                "validate_keys_title": "Статус и верификација API кључева",
                "web_setup_msg": "1. Повежите телефон/рачунар на исти Wi-Fi.\n2. Скенирајте овај QR код или посетите:\n\n%s\n\n3. Налепите API кључ и додирните Сачувај.",
                "web_setup_no_wifi": "Wi-Fi је искључен. Повежите се на Wi-Fi да бисте користили веб подешавање.",
                "web_setup_success": "API кључ за %s је примљен и сачуван!",
                "web_setup_title": "Повезивање преко телефона / рачунара"
        },
        "tr": {
                "unit_scanning_book": "Kitap birimler için taranıyor...",
                "unit_scanning_title": "X-Ray: Birim Dönüştürücü",
                "btn_paste": "Yapıştır",
                "import_file_not_found": "Depolama kök dizininde veya ayarlar klasöründe xray_key.txt dosyası bulunamadı.",
                "import_file_success": "%2$s dosyasından %1$d API anahtarı başarıyla içe aktarıldı!",
                "key_status_err": "[ERR] Başarısız: %s",
                "key_status_not_set": "[--] Yapılandırılmadı",
                "key_status_ok": "[OK] Bağlandı (%d ms)",
                "menu_import_file": "xray_key.txt dosyasından anahtarları içe aktar",
                "menu_paste_clipboard": "Panodan %s anahtarını yapıştır",
                "menu_test_key": "Bağlantıyı Test Et",
                "menu_validate_all_keys": "Tüm API Anahtarlarını Test Et ve Doğrula",
                "menu_web_setup": "Telefondan / PC'den API Anahtarı Ayarla (QR Kod)",
                "paste_clipboard_confirm": "Panodaki API anahtarı %s için kullanılsın mı?",
                "testing_api_keys": "API anahtarı bağlantıları test ediliyor...",
                "validate_keys_title": "API Anahtarı Durumu ve Doğrulama",
                "web_setup_msg": "1. Telefonunuzu/PC'nizi aynı Wi-Fi ağına bağlayın.\n2. Bu QR kodunu tarayın veya şu adrese gidin:\n\n%s\n\n3. API anahtarınızı yapıştırıp Kaydet'e dokunun.",
                "web_setup_no_wifi": "Wi-Fi bağlantısı kesildi. Web kurulumunu kullanmak için lütfen Wi-Fi'ye bağlanın.",
                "web_setup_success": "%s için API anahtarı alındı ve kaydedildi!",
                "web_setup_title": "Telefon / PC ile Bağlan"
        },
        "uk": {
                "unit_scanning_book": "Сканування книги на наявність одиниць...",
                "unit_scanning_title": "X-Ray: Конвертер величин",
                "btn_paste": "Вставити",
                "import_file_not_found": "Файл xray_key.txt не знайдено в кореневому каталозі або папці налаштувань.",
                "import_file_success": "Успішно імпортовано %d ключ(ів) API з %s!",
                "key_status_err": "[ERR] Помилка: %s",
                "key_status_not_set": "[--] Не налаштовано",
                "key_status_ok": "[OK] Підключено (%d мс)",
                "menu_import_file": "Імпортувати ключі з xray_key.txt",
                "menu_paste_clipboard": "Вставити ключ %s з буфера обміну",
                "menu_test_key": "Перевірити з'єднання",
                "menu_validate_all_keys": "Перевірити та валідувати всі ключі API",
                "menu_web_setup": "Налаштувати ключ API через телефон / ПК (QR-код)",
                "paste_clipboard_confirm": "Використати ключ API з буфера обміну для %s?",
                "testing_api_keys": "Перевірка з'єднань ключів API...",
                "validate_keys_title": "Статус та валідація ключів API",
                "web_setup_msg": "1. Підключіть телефон/ПК до тієї ж мережі Wi-Fi.\n2. Відскануйте цей QR-код або перейдіть за адресою:\n\n%s\n\n3. Вставте ключ API та натисніть Зберегти.",
                "web_setup_no_wifi": "Wi-Fi вимкнено. Будь ласка, підключіться до Wi-Fi для веб-налаштування.",
                "web_setup_success": "Ключ API для %s отримано та збережено!",
                "web_setup_title": "Підключення через телефон / ПК"
        },
        "zh_CN": {
                "unit_scanning_book": "正在扫描图书中的单位...",
                "unit_scanning_title": "X-Ray: 单位转换器",
                "btn_paste": "粘贴",
                "import_file_not_found": "在存储根目录或设置目录中未找到 xray_key.txt 文件。",
                "import_file_success": "已成功从 %2$s 导入 %1$d 个 API 密钥！",
                "key_status_err": "[ERR] 失败：%s",
                "key_status_not_set": "[--] 未配置",
                "key_status_ok": "[OK] 已连接（%d 毫秒）",
                "menu_import_file": "从 xray_key.txt 导入密钥",
                "menu_paste_clipboard": "从剪贴板粘贴 %s 密钥",
                "menu_test_key": "测试连接",
                "menu_validate_all_keys": "测试并验证所有 API 密钥",
                "menu_web_setup": "通过手机 / 电脑配置 API 密钥（二维码）",
                "paste_clipboard_confirm": "是否将剪贴板中的 API 密钥用于 %s？",
                "testing_api_keys": "正在测试 API 密钥连接...",
                "validate_keys_title": "API 密钥状态与验证",
                "web_setup_msg": "1. 将手机/电脑连接到同一 Wi-Fi 网络。\n2. 扫描此二维码或访问：\n\n%s\n\n3. 粘贴 API 密钥并点击保存。",
                "web_setup_no_wifi": "Wi-Fi 未连接。请连接 Wi-Fi 后使用网页配置。",
                "web_setup_success": "已成功接收并保存 %s 的 API 密钥！",
                "web_setup_title": "通过手机 / 电脑连接"
        }
}
    # Keys whose translation this run actually replaced. Only these may have
    # their en-hash refreshed; see save_po.
    updated = {code: set() for code in lang_files_codes}

    for lang_code, keys in list(all_untranslated.items()):
        if lang_code in local_translations:
            for k in list(keys.keys()):
                if k in local_translations[lang_code]:
                    val = local_translations[lang_code][k]
                    all_existing_tr[lang_code][k] = val
                    updated.setdefault(lang_code, set()).add(k)
                    del keys[k]
            if not keys:
                del all_untranslated[lang_code]

    # 4. Handle Translations
    mode = args.mode
    has_gemini = get_gemini_key() is not None
    is_interactive = sys.stdin.isatty()
    
    if all_untranslated:
        print("\nMissing or stale translations detected:")
        for lang_code, keys in sorted(all_untranslated.items()):
            name = lang_names.get(lang_code, lang_code.capitalize())
            print(f"  - {name} ({lang_code}): {len(keys)} key(s)")
            
        if not mode:
            if is_interactive:
                print("\nChoose translation method:")
                opt_auto = "[1] Auto-translate with Gemini API" if has_gemini else "[1] (Disabled - GEMINI_API_KEY not set) Auto-translate with Gemini"
                print(f"  {opt_auto}")
                print("  [2] Interactively translate in console")
                print("  [3] Skip translations (leave as fallback/empty)")
                try:
                    choice = input("Enter choice [1/2/3] (default 3): ").strip()
                except (KeyboardInterrupt, EOFError):
                    choice = "3"
                if choice == "1" and has_gemini:
                    mode = "auto"
                elif choice == "2":
                    mode = "manual"
                else:
                    mode = "skip"
            else:
                mode = "auto" if has_gemini else "skip"
                print(f"\nNon-interactive shell. Defaulting to mode: {mode}")
                
        if mode == "auto":
            if not has_gemini:
                print("\nError: GEMINI_API_KEY environment variable is not set. Cannot run auto-translation.")
                if is_interactive:
                    print("Falling back to manual translation mode...")
                    mode = "manual"
                else:
                    print("Skipping translation.")
                    mode = "skip"
                    
        if mode == "auto":
            print(f"\nAuto-translating using Gemini API...")
            translations = translate_all_gemini(all_untranslated, lang_names)
            # Apply translations
            for lang_code, tr_map in translations.items():
                if lang_code in all_existing_tr:
                    for k, v in tr_map.items():
                        all_existing_tr[lang_code][k] = v
                        updated.setdefault(lang_code, set()).add(k)
                        
        elif mode == "manual":
            manual_translate_languages(all_untranslated, lang_names, all_existing_tr,
                                       updated)
            
        elif mode == "skip":
            print("\nSkipping translations. Saving updated keys with fallbacks.")
    else:
        print("\nAll translation files are up to date.")

    # 5. Save all files
    for file in lang_files:
        lang_code = file.split('.')[0]
        path = os.path.join(LANGUAGES_DIR, file)
        lang_name = lang_names[lang_code]
        existing_tr = all_existing_tr[lang_code]
        
        save_po(path, lang_name, lang_code, en_final.keys(), existing_tr, en_final, en_final,
                stored_hashes=all_existing_hashes.get(lang_code, {}),
                updated_keys=updated.get(lang_code, set()))
        
        missing_count = len([k for k in en_final if k not in existing_tr or existing_tr[k] == ""])
        print(f"Updated {file} ({missing_count} keys need translation)")

    print("--- Sync Complete ---")

if __name__ == "__main__":
    sync()

