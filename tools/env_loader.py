#!/usr/bin/env python3
"""Read a .env file into the process environment.

The translation tools need GEMINI_API_KEY. A git-ignored .env file at the repo
root keeps the key off the command line and out of the shell history.
Real environment variables always win over values in the file.
"""
import os

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))


def _parse_line(line):
    """Return a (key, value) pair for one line, or None if there is nothing to set."""
    line = line.strip()
    if not line or line.startswith('#'):
        return None
    if line.startswith('export '):
        line = line[len('export '):].lstrip()
    if '=' not in line:
        return None
    key, value = line.split('=', 1)
    key = key.strip()
    if not key:
        return None
    value = value.strip()
    # Drop one matching pair of surrounding quotes.
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        value = value[1:-1]
    return key, value


def load_env_file(path=None):
    """Set every variable in the .env file that the environment does not define yet.

    Set XRAY_ENV_FILE to read a different path. A missing or unreadable file is
    not an error. Returns the list of names that this call set.
    """
    if path is None:
        path = os.environ.get('XRAY_ENV_FILE') or os.path.join(REPO_ROOT, '.env')

    loaded = []
    try:
        with open(path, 'r', encoding='utf-8-sig') as f:
            lines = f.readlines()
    except OSError:
        return loaded

    for line in lines:
        pair = _parse_line(line)
        if not pair:
            continue
        key, value = pair
        if key in os.environ:
            continue
        os.environ[key] = value
        loaded.append(key)
    return loaded
