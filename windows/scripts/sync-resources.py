#!/usr/bin/env python3
"""Reuse reviewed/machine-translated Mac labels; do not silently claim a new translation."""
import argparse
import json
import re
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
LABELS = {
    'NewChat': 'New Chat', 'AddProject': 'Add Project…', 'Search': 'Search',
    'ShowArchived': 'Show Archived Threads', 'Settings': 'Settings', 'Archive': 'Archive',
    'Undo': 'Undo', 'Redo': 'Redo', 'Message': 'Message', 'You': 'You', 'Close': 'Close',
    'Send': 'Send', 'Stop': 'Stop', 'Ready': 'Ready', 'Allow': 'Allow', 'Deny': 'Deny',
    'Submit': 'Submit', 'Dismiss': 'Dismiss', 'Connecting': 'Connecting…',
}


def ui_key(text):
    value = 14695981039346656037
    for byte in text.encode('utf-8'):
        value = ((value ^ byte) * 1099511628211) & ((1 << 64) - 1)
    return f'Text_{value:016x}'


def labels():
    result = dict(LABELS)
    for path in sorted((ROOT / 'App').glob('*')):
        if path.suffix not in {'.cpp', '.h', '.inl'}:
            continue
        source = path.read_text(encoding='utf-8')
        literal = r'"((?:[^"\\]|\\.)*)"'
        for match in re.finditer(r'\b(?:label|button|toolbar_button|action)\(\s*L' + literal + r'\s*,\s*L' + literal, source):
            resource, text = [json.loads('"' + value + '"') for value in match.groups()]
            result[resource] = text
        for match in re.finditer(r'\bui_text\(\s*L' + literal, source):
            text = json.loads('"' + match.group(1) + '"')
            result[ui_key(text)] = text
        for match in re.finditer(r'(?:std::pair\{\s*|\{\s*)L' + literal + r'\s*,\s*L' + literal + r'\s*\}', source):
            resource, text = [json.loads('"' + value + '"') for value in match.groups()]
            if resource.replace('_', '').isalnum():
                result[resource] = text
    # The fallback lookup in label() uses the hashed English text too.
    for text in list(result.values()):
        result[ui_key(text)] = text
    return result


def generate():
    catalog = json.loads((ROOT.parent / 'Coincide/Resources/Localizable.xcstrings').read_text(encoding='utf-8'))
    values = labels()
    languages = sorted({language for key in LABELS.values()
                        for language in catalog['strings'].get(key, {}).get('localizations', {})} | {'en'})
    result = {}
    for language in languages:
        root = ET.Element('root')
        for name, key in sorted(values.items()):
            entry = catalog['strings'].get(key, {}).get('localizations', {}).get(language, {})
            value = entry.get('stringUnit', {}).get('value', key)
            node = ET.SubElement(root, 'data', {'name': name, 'xml:space': 'preserve'})
            ET.SubElement(node, 'value').text = value
        ET.indent(root, space='  ')
        tag = 'en-US' if language == 'en' else language
        result[ROOT / 'Strings' / tag / 'Resources.resw'] = (
            '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(root, encoding='unicode') + '\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    stale = []
    for path, contents in generate().items():
        if args.check:
            if not path.exists() or path.read_text(encoding='utf-8') != contents:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents, encoding='utf-8', newline='\n')
    if stale:
        raise SystemExit('Regenerate Windows resources: ' + ', '.join(stale))
