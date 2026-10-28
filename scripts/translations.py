#!/usr/bin/env python3
"""Translates Coincide's string catalog: lists what a language is missing, checks translations and imports them.

  scripts/translations.py missing <lang> [out.json]   strings <lang> has no translation for, as [{"key", "source"}]
  scripts/translations.py check <lang> <in.json>      validates a translation file against the catalog
  scripts/translations.py import <lang> <in.json>     writes a validated file into the catalog (state needs_review)

A translation file maps catalog keys to a string, or to {"plural": {"one": "...", "other": "..."}} for a string with
exactly one integer placeholder, using only the CLDR plural categories of the language. Placeholders must match the
English source: the same specifiers and types, reordered only with numbers (%2$@ … %1$@). Run scripts/sync-strings.sh
first so the catalog lists every string the code uses.
"""
import json
import re
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "Coincide/Resources/Localizable.xcstrings"
# CLDR plural categories each supported language uses for whole numbers.
PLURALS = {
    "de": {"one", "other"}, "es": {"one", "many", "other"}, "es-419": {"one", "many", "other"},
    "fr": {"one", "many", "other"}, "hi": {"one", "other"}, "id": {"other"}, "it": {"one", "many", "other"},
    "ja": {"other"}, "ko": {"other"}, "nl": {"one", "other"}, "pl": {"one", "few", "many", "other"},
    "pt-BR": {"one", "many", "other"}, "ru": {"one", "few", "many", "other"}, "tr": {"one", "other"},
    "uk": {"one", "few", "many", "other"}, "vi": {"other"}, "zh-Hans": {"other"}, "zh-Hant": {"other"},
}
SPEC = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|f|%)")


def specs(text):
    """The placeholders as sorted (position, type) pairs, numbering unnumbered ones in order; %% is ignored."""
    found, position = [], 0
    for match in SPEC.finditer(text):
        kind = match.group(2)
        if kind == "%":
            continue
        kind = "d" if kind in ("lld", "ld") else kind
        if match.group(1):
            found.append((int(match.group(1)), kind))
        else:
            position += 1
            found.append((position, kind))
    return sorted(found)


def load():
    return json.loads(CATALOG.read_text())


def write(catalog):
    """Writes the catalog the way Xcode does, down to its empty objects, so diffs stay small."""
    text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
    text = re.sub(r"\n( *)(\"(?:[^\"\\]|\\.)*\" : )\{\}", lambda m: f"\n{m.group(1)}{m.group(2)}{{\n\n{m.group(1)}}}", text)
    CATALOG.write_text(text)


def sources(catalog):
    """Every translatable string: its key and English text."""
    result = {}
    for key, value in catalog["strings"].items():
        unit = ((value.get("localizations") or {}).get("en") or {}).get("stringUnit")
        source = unit["value"] if unit else key
        if value.get("shouldTranslate") is not False and re.search(r"[A-Za-z]", source):
            result[key] = source
    return result


def missing(lang, out=None):
    catalog = load()
    entries = [
        {"key": key, "source": source} for key, source in sorted(sources(catalog).items())
        if lang not in (catalog["strings"][key].get("localizations") or {})
    ]
    text = json.dumps(entries, ensure_ascii=False, indent=1)
    Path(out).write_text(text) if out else print(text)
    print(f"{len(entries)} strings without {lang}", file=sys.stderr)


def check(lang, path):
    if lang not in PLURALS:
        print(f"unknown language {lang}; known: {', '.join(sorted(PLURALS))}")
        return False
    known = sources(load())
    errors = []
    for key, value in json.loads(Path(path).read_text()).items():
        if key not in known:
            errors.append(f"unknown key {key!r}")
            continue
        want = specs(known[key])
        if isinstance(value, dict):
            forms = value.get("plural")
            if set(value) != {"plural"} or not isinstance(forms, dict):
                errors.append(f"{key!r}: an object must be {{\"plural\": {{...}}}}")
                continue
            if [kind for _, kind in want].count("d") != 1:
                errors.append(f"{key!r}: plural forms need exactly one integer placeholder in the source")
            if "other" not in forms or not set(forms) <= PLURALS[lang] | {"zero"}:
                errors.append(f"{key!r}: categories {sorted(forms)} aren't {lang}'s {sorted(PLURALS[lang])}")
            texts = list(forms.values())
        else:
            texts = [value]
        for text in texts:
            if not isinstance(text, str) or not text.strip():
                errors.append(f"{key!r}: empty translation")
            elif specs(text) != want:
                errors.append(f"{key!r}: placeholders {specs(text)} differ from the source's {want}")
    print("\n".join(errors[:40]) if errors else f"OK {lang}")
    return not errors


def numbered(text):
    """Numbers the placeholders of a string with several (%@ → %1$@), as Xcode stores them."""
    if len(specs(text)) < 2 or re.search(r"%\d+\$", text):
        return text
    counter = iter(range(1, 100))
    return SPEC.sub(lambda m: m.group(0) if m.group(2) == "%" else f"%{next(counter)}${m.group(2)}", text)


def import_(lang, path):
    if not check(lang, path):
        sys.exit(1)
    catalog = load()
    for key, value in json.loads(Path(path).read_text()).items():
        localizations = catalog["strings"][key].setdefault("localizations", {})
        if isinstance(value, dict):
            localizations[lang] = {"variations": {"plural": {
                category: {"stringUnit": {"state": "needs_review", "value": numbered(text)}}
                for category, text in value["plural"].items()}}}
        else:
            localizations[lang] = {"stringUnit": {"state": "needs_review", "value": numbered(value)}}
    write(catalog)


if __name__ == "__main__":
    commands = {"missing": missing, "check": lambda lang, path: sys.exit(0 if check(lang, path) else 1), "import": import_}
    if len(sys.argv) < 3 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    commands[sys.argv[1]](*sys.argv[2:])
