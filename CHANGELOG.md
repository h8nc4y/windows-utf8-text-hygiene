# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

## 0.1.0 - 2026-07-16

### Added

- Initial Windows UTF-8 text hygiene skill (`SKILL.md`): the
  UTF-8-without-BOM + LF + no-trailing-whitespace + no-NUL convention,
  non-destructive inspection (git whitespace checks including the
  staged/unstaged split, byte-level BOM checks, NUL detection with the
  ripgrep/grep `-a` requirement), strict-UTF-8-decode-guarded
  normalization that refuses ANSI / CP932 (Shift_JIS) input instead of
  silently destroying it, the Windows PowerShell 5.1 BOM exception with
  three measured BOM-less failure modes (silently skipped statement,
  `TerminatorExpectedAtEndOfString`, `UnexpectedToken`), backtick-expansion
  prevention via single-quoted here-strings with placeholder substitution,
  raw-UTF-8 hook stdout, post-append readback verification, safety-condition
  checklist, and completion checklist.
- Japanese full version of the skill (`docs/SKILL.ja.md`).
- Synthetic examples: inspection one-liners (BOM / CRLF / NUL / control
  characters), guarded normalization with the measured corruption
  incident, and a minimal `.gitattributes` / `.editorconfig` sample.
- Private-marker scan for common secret prefixes, private-looking absolute
  paths, and non-allowlisted GitHub repository URLs, with a self-test and
  local marker support through `.private-markers.local` or the
  `WINDOWS_UTF8_TEXT_HYGIENE_PRIVATE_MARKERS` environment variable.
- OSS readiness validation script for required public project files and
  skill frontmatter.
- GitHub Actions workflow for validation, private-marker scanning, and
  whitespace checks.
- Issue and pull request templates with sanitized-report guidance.
- Contributor, security, code of conduct, editor, and Git attribute
  documentation.
