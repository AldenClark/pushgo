# Update Notes

This directory stores Sparkle appcast update note source files for Apple self-distributed builds.

Rules:
- Use one JSON file per version, matching Android release note storage.
- Name files as `vX.Y.Z.json` or `vX.Y.Z-beta.N.json`.
- Keep values as plain text with `\n` line breaks; no Markdown headings.
- Keep content user-facing; engineering details stay in `release/CHANGELOG.md`.
- Required locale keys:
  `en`, `de`, `es`, `fr`, `ja`, `ko`, `zh-CN`, `zh-TW`

During `scripts/release_appcast.sh`, the matching version file is copied into the archives
directory as same-basename localized `.txt` files so Sparkle `generate_appcast` can attach them
to the corresponding archive item.

Sparkle `generate_appcast` only scans base language identifiers for localized release notes.
That means `zh-CN` and `zh-TW` are both kept in the JSON source for cross-platform parity, but
the generated appcast can currently emit only one generic `zh.txt`.
