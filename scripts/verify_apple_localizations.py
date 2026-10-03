#!/usr/bin/env python3
"""Validate that supported Apple locales cannot silently fall back to English."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REQUIRED_LOCALES = ("en", "zh-Hans", "zh-Hant")
PLACEHOLDER_RE = re.compile(r"%(?!%)(?:\d+\$)?[-#+ 0,(<]*\d*(?:\.\d+)?(?:hh|h|ll|l|L|z|j|t|q)?[a-zA-Z@]")


def placeholder_signature(value: str) -> tuple[str, ...]:
    normalized = []
    for placeholder in PLACEHOLDER_RE.findall(value):
        normalized.append(re.sub(r"^%(?:\d+\$)?", "%", placeholder))
    return tuple(sorted(normalized))


def validate_catalog(path: Path) -> list[str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    errors: list[str] = []
    for key, entry in sorted(payload.get("strings", {}).items()):
        if not key or entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        values: dict[str, str] = {}
        for locale in REQUIRED_LOCALES:
            string_unit = localizations.get(locale, {}).get("stringUnit")
            if string_unit is None:
                errors.append(f"{path.name}: {key!r} missing {locale}")
                continue
            value = string_unit.get("value", "")
            if string_unit.get("state") != "translated":
                errors.append(f"{path.name}: {key!r} {locale} is not translated")
            if not value.strip():
                errors.append(f"{path.name}: {key!r} {locale} is blank")
            values[locale] = value
        if "en" not in values:
            continue
        expected = placeholder_signature(values["en"])
        for locale in REQUIRED_LOCALES[1:]:
            if locale in values and placeholder_signature(values[locale]) != expected:
                errors.append(
                    f"{path.name}: {key!r} {locale} placeholder mismatch: "
                    f"expected {expected}, got {placeholder_signature(values[locale])}"
                )
    return errors


def discover_production_catalogs(repo_root: Path) -> list[Path]:
    catalogs: set[Path] = set()
    for relative_root in ("Resources", "Apps", "Extensions"):
        root = repo_root / relative_root
        if root.is_dir():
            catalogs.update(root.rglob("*.xcstrings"))
    return sorted(catalogs)


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "catalogs",
        nargs="*",
        type=Path,
    )
    args = parser.parse_args()
    try:
        catalogs = args.catalogs or discover_production_catalogs(repo_root)
        if not catalogs:
            print("status=FAILED")
            print("localization_error=no production .xcstrings catalogs found")
            return 1
        errors = [error for path in catalogs for error in validate_catalog(path)]
    except (json.JSONDecodeError, TypeError) as error:
        print("status=FAILED")
        print(f"localization_error={error}")
        return 1
    except OSError as error:
        print(f"status=BLOCKED\nreason={error}", file=sys.stderr)
        return 2
    if errors:
        print("status=FAILED")
        for error in errors:
            print(f"localization_error={error}")
        return 1
    print("status=PASSED")
    print("claim=all translatable production Apple strings exist in en, zh-Hans, and zh-Hant with compatible placeholders")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
