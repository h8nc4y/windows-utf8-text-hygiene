# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

### Changed

- Added a bounded `macos-15` PowerShell 7 CI contract for the native POSIX
  session fallback. Run
  [30205393010](https://github.com/h8nc4y/windows-utf8-text-hygiene/actions/runs/30205393010)
  verified PowerShell Core 7.6.3 on `macos-15-arm64` image
  `20260715.0234.1`; Windows PowerShell 5.1 remains a separate Windows-only
  contract.
- Kept Git worktree-root validation fail closed without comparing absolute
  path spellings. A bounded `--show-toplevel` probe still proves worktree
  context, while raw `--show-prefix` output must be exactly LF or CRLF to
  distinguish the root from a subdirectory and accept macOS physical aliases
  such as `/var` and `/private/var`.
- Made POSIX containment evidence fail closed on the observed session gate,
  target exit code, descendant start, and descendant cleanup. Native
  `setsid(2)` and `kill(2)` imports continue to use the POSIX runtime's
  established `libc` resolver.
- Added bounded, allowlisted native-gate stage diagnostics and made process
  launch, the gate handshake, and target execution share the existing caller
  timeout. Elapsed-only pre-cleanup and final checks reject already-exited
  zero-code children after setup or cleanup overruns. The PowerShell wrapper
  also avoids the read-only `$IsMacOS` automatic-variable name.
- Hardened private-marker scanning so Git file enumeration runs in bounded,
  hermetic child processes. Ambient `GIT_*`, home/config, hooks, attributes,
  excludes, templates, filters, prompts, and trace settings can no longer
  redirect tracked-file discovery or create scan-side artifacts.
- Closed the Windows start-before-Job-assignment race with suspended direct
  creation, a three-handle inheritance allowlist, Job assignment, and
  resume; read unique staged blobs through one binary-safe batch; require
  exact final raw stage/flag snapshots; and cover high-signal `.env`,
  PEM/key, extensionless, and dotfile candidates.
- Added an atomic POSIX session/process-group boundary, direct `kill(2)`
  cleanup with errno-aware `ESRCH` handling, Ubuntu descendant pipe/sentinel
  regression coverage, and a dedicated Ubuntu 24.04 CI job.
- Bounded line traversal, regex-match traversal, per-file and total
  findings, and diagnostic width; escaped control/format, bidi, and
  Unicode line/paragraph separator characters in diagnostics; and
  excluded leaf `.git` files from non-Git fallback scanning.
- Added a finite, PowerShell 5.1-compatible .NET match timeout to every regex
  in `scripts/scan-private-markers.ps1`. Regex timeouts now fail closed with
  one fixed redacted exit-2 diagnostic after successful Git-isolation cleanup;
  Git-isolation integrity failures retain precedence. This is backed by an
  adversarial one-million-character no-match regression, a near-limit safe
  positive control, and an AST mutation gate covering alternate construction
  paths and timeout provenance.
- Added adversarial success/failure fixtures that preserve the parent
  environment (including present-empty values), verify target-repository
  enumeration, staged/worktree union, real staged add/replace drift,
  flags-only metadata drift, present/missing-worktree intent-to-add,
  ordinary staged empty blobs, delay-free immediate descendants,
  fail-closed index states, descendant
  pipe cleanup, replace-ref isolation, no-fetch promisor handling, dangling
  `.git` markers, leaf gitfiles, parent-directory junctions, ambient OS
  forgery, exact/over-limit raw UTF-8 bytes, hostile nonexistent paths,
  exact fixed raw diagnostics without PowerShell exception framing,
  match/finding amplification, Git-unavailable repository
  boundaries, tracked local-marker rejection, and redaction, and exercise
  PowerShell 7 and Windows PowerShell 5.1 as distinct hosts.
- Declared the intentional UTF-8 BOM on the Japanese-commented scanner,
  process-boundary, and self-test scripts that Windows PowerShell 5.1
  executes, and bounded the CI job.
- Pinned the CI checkout action to the verified `v5` commit instead of a
  mutable tag.

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
