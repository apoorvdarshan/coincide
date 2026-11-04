#!/usr/bin/env python3
"""Reuse reviewed/machine-translated Mac labels; do not silently claim a new translation."""
import argparse
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
LABELS = {
    'NewChat': 'New Chat', 'AddProject': 'Add Project…', 'Search': 'Search',
    'ShowArchived': 'Show Archived Threads', 'Settings': 'Settings', 'Archive': 'Archive',
    'Undo': 'Undo', 'Redo': 'Redo', 'Message': 'Message', 'You': 'You', 'Close': 'Close',
}


def generate():
    catalog = json.loads((ROOT.parent / 'Coincide/Resources/Localizable.xcstrings').read_text(encoding='utf-8'))
    languages = sorted({language for key in LABELS.values()
                        for language in catalog['strings'][key].get('localizations', {})} | {'en'})
    result = {}
    for language in languages:
        root = ET.Element('root')
        for name, key in LABELS.items():
            entry = catalog['strings'][key].get('localizations', {}).get(language, {})
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
